//! Ключевые кадры mp4: где в файле можно резать без перекодирования.
//!
//! Задача #24. H.264 хранит целиком только ключевые кадры, остальные —
//! разница с предыдущими. Резать между ключевыми можно, но тогда стык
//! придётся перекодировать (#27). Чтобы человек видел, где резать
//! дёшево, редактору нужен список ключевых кадров.
//!
//! Список лежит в `moov`: `stts` — длительности отсчётов, `stss` —
//! номера ключевых. Ходим по коробкам сами: верхний уровень разбирает
//! `mp4.zig`, а здесь — вглубь до таблиц первой видеодорожки.
//! Сторонняя проверка — ffmpeg перечисляет I-кадры (`keyframes-smoke`).
const std = @import("std");
const mp4 = @import("mp4.zig");

pub const Error = error{
    /// В файле нет `moov` или нет видеодорожки.
    NoVideo,
    /// Таблицы обрезаны или не сходятся.
    Malformed,
    OutOfMemory,
};

/// Запись `stts`: столько-то отсчётов подряд такой-то длины.
pub const Run = struct { count: u32, delta: u32 };

/// Время каждого ключевого кадра по таблицам. Чистая арифметика с тестами.
///
/// `sync` — номера ключевых отсчётов, считая с единицы (так в файле);
/// `timescale` — единиц в секунде у дорожки.
pub fn timesFromTables(
    allocator: std.mem.Allocator,
    runs: []const Run,
    sync: []const u32,
    timescale: u32,
) Error![]u64 {
    if (timescale == 0) return Error.Malformed;
    const out = allocator.alloc(u64, sync.len) catch return Error.OutOfMemory;
    errdefer allocator.free(out);

    // Идём по номерам ключевых по возрастанию и одновременно по прогонам
    // `stts`: суммарное время до отсчёта — это сумма длительностей всех
    // предыдущих. Линейно, без квадрата даже на часовом файле.
    var run_i: usize = 0;
    var run_left: u64 = if (runs.len > 0) runs[0].count else 0;
    var sample: u64 = 1;
    var elapsed: u64 = 0;
    var last: u32 = 0;
    for (sync, 0..) |number, k| {
        if (number == 0 or number < last) return Error.Malformed;
        last = number;
        while (sample < number) {
            if (run_i >= runs.len) return Error.Malformed;
            elapsed += runs[run_i].delta;
            sample += 1;
            run_left -= 1;
            if (run_left == 0) {
                run_i += 1;
                run_left = if (run_i < runs.len) runs[run_i].count else 0;
            }
        }
        out[k] = elapsed * std.time.ns_per_s / timescale;
    }
    return out;
}

/// Ближайший ключевой кадр к моменту, если он не дальше `within_ns`.
pub fn nearest(times: []const u64, when_ns: u64, within_ns: u64) ?u64 {
    var best: ?u64 = null;
    var best_gap: u64 = within_ns + 1;
    for (times) |t| {
        const gap = if (t > when_ns) t - when_ns else when_ns - t;
        if (gap < best_gap) {
            best_gap = gap;
            best = t;
        }
    }
    return best;
}

/// Следующий (или предыдущий) ключевой кадр строго после (до) момента.
pub fn step(times: []const u64, when_ns: u64, forward: bool) ?u64 {
    if (forward) {
        for (times) |t| if (t > when_ns) return t;
        return null;
    }
    var found: ?u64 = null;
    for (times) |t| {
        if (t < when_ns) found = t else break;
    }
    return found;
}

// ------------------------------------------------------------ разбор moov

fn be32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

fn be64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .big);
}

/// Коробка внутри буфера: где её содержимое.
const Child = struct { kind: [4]u8, body: []const u8 };

/// Обход детей контейнера.
const Walker = struct {
    data: []const u8,
    at: usize = 0,

    fn next(self: *Walker) ?Child {
        if (self.at + 8 > self.data.len) return null;
        var size: u64 = be32(self.data[self.at..]);
        const kind = self.data[self.at + 4 ..][0..4].*;
        var head: usize = 8;
        if (size == 1) {
            if (self.at + 16 > self.data.len) return null;
            size = be64(self.data[self.at + 8 ..]);
            head = 16;
        } else if (size == 0) {
            size = self.data.len - self.at;
        }
        if (size < head or self.at + size > self.data.len) return null;
        const body = self.data[self.at + head .. self.at + @as(usize, @intCast(size))];
        self.at += @intCast(size);
        return .{ .kind = kind, .body = body };
    }
};

fn find(container: []const u8, name: *const [4]u8) ?[]const u8 {
    var w = Walker{ .data = container };
    while (w.next()) |ch| {
        if (std.mem.eql(u8, &ch.kind, name)) return ch.body;
    }
    return null;
}

/// Таблицы первой видеодорожки в `moov`.
pub const Tables = struct {
    timescale: u32,
    runs: []Run,
    sync: []u32,
    /// Смещения показа (`ctts`): у кадров с B-кадрами показ позже декодирования.
    /// Пусто — смещений нет.
    offsets: []Run = &.{},
    /// Сдвиг всей дорожки по списку правок (`elst`), в наносекундах:
    /// плюс — пустая правка в начале (первый кадр показывается позже),
    /// минус — начало отрезано.
    shift_ns: i64 = 0,

    pub fn deinit(self: *Tables, allocator: std.mem.Allocator) void {
        allocator.free(self.runs);
        allocator.free(self.sync);
        if (self.offsets.len > 0) allocator.free(self.offsets);
    }
};

/// Смещение показа отсчёта номер `number` (с единицы) по прогонам `ctts`.
fn compositionOffset(offsets: []const Run, number: u32) u32 {
    var left = number;
    for (offsets) |r| {
        if (left <= r.count) return r.delta;
        left -= r.count;
    }
    return 0;
}

/// Время показа ключевых кадров с учётом смещений и списка правок —
/// то, что ffmpeg зовёт `pts_time`.
pub fn presentationTimes(
    allocator: std.mem.Allocator,
    t: *const Tables,
) Error![]u64 {
    const times = try timesFromTables(allocator, t.runs, t.sync, t.timescale);
    for (times, t.sync) |*when, number| {
        const extra = @as(u64, compositionOffset(t.offsets, number)) * std.time.ns_per_s / t.timescale;
        const shifted = @as(i64, @intCast(when.* + extra)) + t.shift_ns;
        when.* = if (shifted < 0) 0 else @intCast(shifted);
    }
    return times;
}

/// Сдвиг по списку правок дорожки. `movie_timescale` — единиц в секунде
/// у фильма (`mvhd`): длительности правок считаются в них.
fn editShiftNs(trak: []const u8, movie_timescale: u32, track_timescale: u32) i64 {
    const edts = find(trak, "edts") orelse return 0;
    const elst = find(edts, "elst") orelse return 0;
    if (elst.len < 8 or movie_timescale == 0 or track_timescale == 0) return 0;
    const version = elst[0];
    const count: usize = be32(elst[4..]);
    if (count == 0) return 0;
    var at: usize = 8;
    var shift: i64 = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var duration: u64 = 0;
        var media_time: i64 = 0;
        if (version == 1) {
            if (at + 20 > elst.len) return shift;
            duration = be64(elst[at..]);
            media_time = @bitCast(be64(elst[at + 8 ..]));
            at += 20;
        } else {
            if (at + 12 > elst.len) return shift;
            duration = be32(elst[at..]);
            media_time = @as(i32, @bitCast(be32(elst[at + 4 ..])));
            at += 12;
        }
        if (media_time == -1) {
            // Пустая правка: до неё ничего не показывается.
            shift += @intCast(duration * std.time.ns_per_s / movie_timescale);
        } else {
            // Первая непустая правка говорит, с какого момента дорожки
            // начинается показ: всё до него отрезано.
            shift -= @intCast(@as(u64, @intCast(@max(media_time, 0))) * std.time.ns_per_s / track_timescale);
            break;
        }
    }
    return shift;
}

/// Разобрать `moov` (его содержимое, без заголовка коробки).
pub fn tablesFromMoov(allocator: std.mem.Allocator, moov: []const u8) Error!Tables {
    // mvhd: единицы времени фильма — в них меряются правки.
    var movie_timescale: u32 = 0;
    if (find(moov, "mvhd")) |mvhd| {
        if (mvhd.len >= 4 and mvhd[0] == 1) {
            if (mvhd.len >= 24) movie_timescale = be32(mvhd[20..]);
        } else if (mvhd.len >= 16) movie_timescale = be32(mvhd[12..]);
    }
    var traks = Walker{ .data = moov };
    while (traks.next()) |trak| {
        if (!std.mem.eql(u8, &trak.kind, "trak")) continue;
        const mdia = find(trak.body, "mdia") orelse continue;
        const hdlr = find(mdia, "hdlr") orelse continue;
        // hdlr: версия/флаги 4, pre_defined 4, handler_type 4.
        if (hdlr.len < 12 or !std.mem.eql(u8, hdlr[8..12], "vide")) continue;
        const mdhd = find(mdia, "mdhd") orelse return Error.Malformed;
        if (mdhd.len < 4) return Error.Malformed;
        // mdhd: версия 0 — timescale со смещения 12; версия 1 — с 20.
        const timescale = if (mdhd[0] == 1) blk: {
            if (mdhd.len < 24) return Error.Malformed;
            break :blk be32(mdhd[20..]);
        } else blk: {
            if (mdhd.len < 16) return Error.Malformed;
            break :blk be32(mdhd[12..]);
        };
        const minf = find(mdia, "minf") orelse return Error.Malformed;
        const stbl = find(minf, "stbl") orelse return Error.Malformed;

        const stts = find(stbl, "stts") orelse return Error.Malformed;
        if (stts.len < 8) return Error.Malformed;
        const run_count: usize = be32(stts[4..]);
        if (stts.len < 8 + run_count * 8) return Error.Malformed;
        const runs = allocator.alloc(Run, run_count) catch return Error.OutOfMemory;
        errdefer allocator.free(runs);
        for (runs, 0..) |*r, i| {
            r.* = .{ .count = be32(stts[8 + i * 8 ..]), .delta = be32(stts[12 + i * 8 ..]) };
        }

        // Без `stss` каждый отсчёт ключевой — так у несжатого видео.
        // Тогда список — все отсчёты.
        var sync: []u32 = undefined;
        if (find(stbl, "stss")) |stss| {
            if (stss.len < 8) return Error.Malformed;
            const n: usize = be32(stss[4..]);
            if (stss.len < 8 + n * 4) return Error.Malformed;
            sync = allocator.alloc(u32, n) catch return Error.OutOfMemory;
            for (sync, 0..) |*s, i| s.* = be32(stss[8 + i * 4 ..]);
        } else {
            var total: usize = 0;
            for (runs) |r| total += r.count;
            sync = allocator.alloc(u32, total) catch return Error.OutOfMemory;
            for (sync, 0..) |*s, i| s.* = @intCast(i + 1);
        }
        errdefer allocator.free(sync);

        var offsets: []Run = &.{};
        if (find(stbl, "ctts")) |ctts| {
            if (ctts.len < 8) return Error.Malformed;
            const n: usize = be32(ctts[4..]);
            if (ctts.len < 8 + n * 8) return Error.Malformed;
            offsets = allocator.alloc(Run, n) catch return Error.OutOfMemory;
            for (offsets, 0..) |*r, i| {
                r.* = .{ .count = be32(ctts[8 + i * 8 ..]), .delta = be32(ctts[12 + i * 8 ..]) };
            }
        }

        return .{
            .timescale = timescale,
            .runs = runs,
            .sync = sync,
            .offsets = offsets,
            .shift_ns = editShiftNs(trak.body, movie_timescale, timescale),
        };
    }
    return Error.NoVideo;
}

/// Ключевые кадры файла в наносекундах от его начала.
///
/// Читаем только `moov`, а не весь файл: у часовой записи это мегабайт
/// против гигабайта.
pub fn read(io: std.Io, allocator: std.mem.Allocator, path: []const u8) Error![]u64 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return Error.NoVideo;
    defer file.close(io);
    const total = file.length(io) catch return Error.NoVideo;

    // Идём по верхним коробкам, читая только заголовки: `mdat` на гигабайт
    // перешагиваем по его размеру, не читая.
    var at: u64 = 0;
    var head: [16]u8 = undefined;
    while (at + 8 <= total) {
        const got = file.readPositionalAll(io, head[0..@min(16, total - at)], at) catch return Error.Malformed;
        if (got < 8) return Error.Malformed;
        var size: u64 = be32(head[0..]);
        var head_len: u64 = 8;
        if (size == 1) {
            if (got < 16) return Error.Malformed;
            size = be64(head[8..]);
            head_len = 16;
        } else if (size == 0) {
            size = total - at;
        }
        if (size < head_len) return Error.Malformed;
        if (std.mem.eql(u8, head[4..8], "moov")) {
            if (size > (1 << 28)) return Error.Malformed;
            const body_len: usize = @intCast(size - head_len);
            const data = allocator.alloc(u8, body_len) catch return Error.OutOfMemory;
            defer allocator.free(data);
            const read_len = file.readPositionalAll(io, data, at + head_len) catch return Error.Malformed;
            if (read_len != data.len) return Error.Malformed;
            var tables = try tablesFromMoov(allocator, data);
            defer tables.deinit(allocator);
            return presentationTimes(allocator, &tables);
        }
        at += size;
    }
    return Error.NoVideo;
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;
const sec = std.time.ns_per_s;

test "время ключевых кадров по таблицам: равный шаг, каждый шестидесятый" {
    // 30 кадров в секунду в единицах 90 000, ключевой каждые 60 кадров.
    const runs = [_]Run{.{ .count = 300, .delta = 3000 }};
    const sync = [_]u32{ 1, 61, 121, 181, 241 };
    const times = try timesFromTables(testing.allocator, &runs, &sync, 90_000);
    defer testing.allocator.free(times);
    try testing.expectEqual(@as(usize, 5), times.len);
    try testing.expectEqual(@as(u64, 0), times[0]);
    try testing.expectEqual(@as(u64, 2 * sec), times[1]);
    try testing.expectEqual(@as(u64, 8 * sec), times[4]);
}

test "неравный шаг: прогоны stts складываются, а не берётся первый" {
    // Первые два отсчёта по секунде, потом по полсекунды.
    const runs = [_]Run{ .{ .count = 2, .delta = 1000 }, .{ .count = 10, .delta = 500 } };
    const sync = [_]u32{ 1, 3, 5 };
    const times = try timesFromTables(testing.allocator, &runs, &sync, 1000);
    defer testing.allocator.free(times);
    try testing.expectEqual(@as(u64, 0), times[0]);
    try testing.expectEqual(@as(u64, 2 * sec), times[1]);
    try testing.expectEqual(@as(u64, 3 * sec), times[2]);
}

test "испорченные таблицы кончаются словами, а не падением" {
    const runs = [_]Run{.{ .count = 2, .delta = 1000 }};
    // Ключевой номер 10 — а отсчётов всего два.
    try testing.expectError(Error.Malformed, timesFromTables(testing.allocator, &runs, &[_]u32{ 1, 10 }, 1000));
    // Нулевой номер и убывание — тоже не таблица.
    try testing.expectError(Error.Malformed, timesFromTables(testing.allocator, &runs, &[_]u32{0}, 1000));
    try testing.expectError(Error.Malformed, timesFromTables(testing.allocator, &runs, &[_]u32{ 2, 1 }, 1000));
    try testing.expectError(Error.Malformed, timesFromTables(testing.allocator, &runs, &[_]u32{1}, 0));
}

test "ближайший ключевой — в пределах допуска, иначе никакой" {
    const times = [_]u64{ 0, 2 * sec, 4 * sec };
    try testing.expectEqual(@as(?u64, 2 * sec), nearest(&times, 2 * sec + 100, sec / 2));
    try testing.expectEqual(@as(?u64, 2 * sec), nearest(&times, 2 * sec - 100, sec / 2));
    try testing.expectEqual(@as(?u64, null), nearest(&times, 3 * sec, sec / 2));
    try testing.expectEqual(@as(?u64, 0), nearest(&times, 0, 0));
}

test "шаг к следующему и предыдущему ключевому" {
    const times = [_]u64{ 0, 2 * sec, 4 * sec };
    try testing.expectEqual(@as(?u64, 2 * sec), step(&times, sec, true));
    try testing.expectEqual(@as(?u64, 4 * sec), step(&times, 2 * sec, true));
    try testing.expectEqual(@as(?u64, null), step(&times, 4 * sec, true));
    try testing.expectEqual(@as(?u64, 2 * sec), step(&times, 3 * sec, false));
    try testing.expectEqual(@as(?u64, 0), step(&times, 2 * sec, false));
    try testing.expectEqual(@as(?u64, null), step(&times, 0, false));
}

/// Собрать коробку: размер, имя, содержимое.
fn box(allocator: std.mem.Allocator, name: *const [4]u8, parts: []const []const u8) ![]u8 {
    var total: usize = 8;
    for (parts) |p| total += p.len;
    const out = try allocator.alloc(u8, total);
    std.mem.writeInt(u32, out[0..4], @intCast(total), .big);
    @memcpy(out[4..8], name);
    var at: usize = 8;
    for (parts) |p| {
        @memcpy(out[at .. at + p.len], p);
        at += p.len;
    }
    return out;
}

fn u32be(v: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    return b;
}

test "moov разбирается до таблиц первой видеодорожки, звуковая пропускается" {
    const a = testing.allocator;
    // Звуковая дорожка — первой: её надо пропустить.
    const hdlr_soun = try box(a, "hdlr", &.{ &[_]u8{0} ** 8, "soun", &[_]u8{0} ** 13 });
    defer a.free(hdlr_soun);
    const mdia_soun = try box(a, "mdia", &.{hdlr_soun});
    defer a.free(mdia_soun);
    const trak_soun = try box(a, "trak", &.{mdia_soun});
    defer a.free(trak_soun);

    const hdlr_vide = try box(a, "hdlr", &.{ &[_]u8{0} ** 8, "vide", &[_]u8{0} ** 13 });
    defer a.free(hdlr_vide);
    // mdhd версии 0: 12 байт до timescale, потом timescale 90000 и длительность.
    const mdhd = try box(a, "mdhd", &.{ &[_]u8{0} ** 12, &u32be(90_000), &u32be(900_000), &[_]u8{0} ** 4 });
    defer a.free(mdhd);
    const stts = try box(a, "stts", &.{ &[_]u8{0} ** 4, &u32be(1), &u32be(300), &u32be(3000) });
    defer a.free(stts);
    const stss = try box(a, "stss", &.{ &[_]u8{0} ** 4, &u32be(2), &u32be(1), &u32be(61) });
    defer a.free(stss);
    const stbl = try box(a, "stbl", &.{ stts, stss });
    defer a.free(stbl);
    const minf = try box(a, "minf", &.{stbl});
    defer a.free(minf);
    const mdia_vide = try box(a, "mdia", &.{ mdhd, hdlr_vide, minf });
    defer a.free(mdia_vide);
    const trak_vide = try box(a, "trak", &.{mdia_vide});
    defer a.free(trak_vide);
    const moov = try box(a, "moov", &.{ trak_soun, trak_vide });
    defer a.free(moov);

    var tables = try tablesFromMoov(a, moov[8..]);
    defer tables.deinit(a);
    try testing.expectEqual(@as(u32, 90_000), tables.timescale);
    try testing.expectEqual(@as(usize, 1), tables.runs.len);
    try testing.expectEqual(@as(u32, 300), tables.runs[0].count);
    try testing.expectEqualSlices(u32, &[_]u32{ 1, 61 }, tables.sync);

    const times = try timesFromTables(a, tables.runs, tables.sync, tables.timescale);
    defer a.free(times);
    try testing.expectEqualSlices(u64, &[_]u64{ 0, 2 * sec }, times);
}

test "пустая правка в начале сдвигает показ, смещения ctts прибавляются" {
    const a = testing.allocator;
    const hdlr_vide = try box(a, "hdlr", &.{ &[_]u8{0} ** 8, "vide", &[_]u8{0} ** 13 });
    defer a.free(hdlr_vide);
    const mdhd = try box(a, "mdhd", &.{ &[_]u8{0} ** 12, &u32be(90_000), &u32be(900_000), &[_]u8{0} ** 4 });
    defer a.free(mdhd);
    const stts = try box(a, "stts", &.{ &[_]u8{0} ** 4, &u32be(1), &u32be(300), &u32be(3000) });
    defer a.free(stts);
    const stss = try box(a, "stss", &.{ &[_]u8{0} ** 4, &u32be(2), &u32be(1), &u32be(61) });
    defer a.free(stss);
    // ctts: первые 60 отсчётов показываются на кадр позже, остальные вовремя.
    const ctts = try box(a, "ctts", &.{ &[_]u8{0} ** 4, &u32be(2), &u32be(60), &u32be(3000), &u32be(240), &u32be(0) });
    defer a.free(ctts);
    const stbl = try box(a, "stbl", &.{ stts, stss, ctts });
    defer a.free(stbl);
    const minf = try box(a, "minf", &.{stbl});
    defer a.free(minf);
    const mdia = try box(a, "mdia", &.{ mdhd, hdlr_vide, minf });
    defer a.free(mdia);
    // elst v0: пустая правка на 560 мс в единицах фильма (1000/с).
    const elst = try box(a, "elst", &.{ &[_]u8{0} ** 4, &u32be(1), &u32be(560), &u32be(0xFFFF_FFFF), &u32be(0x0001_0000) });
    defer a.free(elst);
    const edts = try box(a, "edts", &.{elst});
    defer a.free(edts);
    const trak = try box(a, "trak", &.{ edts, mdia });
    defer a.free(trak);
    const mvhd = try box(a, "mvhd", &.{ &[_]u8{0} ** 12, &u32be(1000), &u32be(8150), &[_]u8{0} ** 80 });
    defer a.free(mvhd);
    const moov = try box(a, "moov", &.{ mvhd, trak });
    defer a.free(moov);

    var tables = try tablesFromMoov(a, moov[8..]);
    defer tables.deinit(a);
    try testing.expectEqual(@as(i64, 560 * std.time.ns_per_ms), tables.shift_ns);
    const times = try presentationTimes(a, &tables);
    defer a.free(times);
    // Первый ключевой: 0 + смещение кадра (33.3 мс) + 560 мс правки.
    try testing.expectEqual(@as(u64, 560 * std.time.ns_per_ms + 33_333_333), times[0]);
    // Шестьдесят первый: 2 с + 0 + 560 мс.
    try testing.expectEqual(@as(u64, 2 * sec + 560 * std.time.ns_per_ms), times[1]);
}

test "правка с отрезанным началом сдвигает назад, а ниже нуля не уходит" {
    var runs = [_]Run{.{ .count = 10, .delta = 1000 }};
    var sync = [_]u32{ 1, 5 };
    const t = Tables{ .timescale = 1000, .runs = &runs, .sync = &sync, .shift_ns = -3 * sec };
    const times = try presentationTimes(testing.allocator, &t);
    defer testing.allocator.free(times);
    try testing.expectEqual(@as(u64, 0), times[0]);
    try testing.expectEqual(@as(u64, sec), times[1]);
}

test "moov без видеодорожки — NoVideo, обрубок — Malformed" {
    const a = testing.allocator;
    const hdlr_soun = try box(a, "hdlr", &.{ &[_]u8{0} ** 8, "soun", &[_]u8{0} ** 13 });
    defer a.free(hdlr_soun);
    const mdia = try box(a, "mdia", &.{hdlr_soun});
    defer a.free(mdia);
    const trak = try box(a, "trak", &.{mdia});
    defer a.free(trak);
    const moov = try box(a, "moov", &.{trak});
    defer a.free(moov);
    try testing.expectError(Error.NoVideo, tablesFromMoov(a, moov[8..]));

    // Видео есть, а stbl нет.
    const hdlr_vide = try box(a, "hdlr", &.{ &[_]u8{0} ** 8, "vide", &[_]u8{0} ** 13 });
    defer a.free(hdlr_vide);
    const mdhd = try box(a, "mdhd", &.{ &[_]u8{0} ** 12, &u32be(90_000), &u32be(0), &[_]u8{0} ** 4 });
    defer a.free(mdhd);
    const mdia_v = try box(a, "mdia", &.{ mdhd, hdlr_vide });
    defer a.free(mdia_v);
    const trak_v = try box(a, "trak", &.{mdia_v});
    defer a.free(trak_v);
    const moov_v = try box(a, "moov", &.{trak_v});
    defer a.free(moov_v);
    try testing.expectError(Error.Malformed, tablesFromMoov(a, moov_v[8..]));
}
