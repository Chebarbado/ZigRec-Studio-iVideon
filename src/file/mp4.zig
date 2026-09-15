//! Разбор контейнера mp4 на верхнем уровне.
//!
//! Задача #16. Нужен, чтобы проверять свой же файл, ничего не устанавливая:
//! лежит ли `moov` перед `mdat` (без этого браузер не начнёт играть, пока не
//! скачает файл целиком), не оборвана ли запись, есть ли вообще данные.
//!
//! Разбираем только верхний уровень: этого хватает для приёмки, а полный
//! разбор — работа плеера (#23), у которого для этого есть Media Foundation.
const std = @import("std");

pub const Error = error{
    /// Файл короче самого маленького бокса.
    TooSmall,
    /// Размер бокса не влезает в файл или равен нулю: запись оборвана.
    BrokenBox,
    /// Нет `ftyp` в начале: это не mp4.
    NotMp4,
};

pub const Box = struct {
    offset: u64,
    size: u64,
    kind: [4]u8,

    pub fn is(self: Box, name: *const [4]u8) bool {
        return std.mem.eql(u8, &self.kind, name);
    }
};

/// Итог осмотра файла: то, что нужно знать для приёмки.
pub const Layout = struct {
    boxes: []const Box,
    moov_at: ?u64 = null,
    mdat_at: ?u64 = null,
    mdat_size: u64 = 0,
    total: u64 = 0,

    /// `moov` перед `mdat` — файл начинает играть, не будучи скачанным целиком.
    pub fn fastStart(self: Layout) bool {
        const m = self.moov_at orelse return false;
        const d = self.mdat_at orelse return false;
        return m < d;
    }

    pub fn playable(self: Layout) bool {
        return self.moov_at != null and self.mdat_at != null and self.mdat_size > 0;
    }
};

/// Разобрать верхний уровень. `boxes` пишутся в переданный буфер, чтобы не
/// заводить аллокатор ради десятка записей.
pub fn parse(data: []const u8, boxes: []Box) Error!Layout {
    if (data.len < 8) return Error.TooSmall;

    var n: usize = 0;
    var off: u64 = 0;
    var layout = Layout{ .boxes = &.{}, .total = data.len };

    while (off + 8 <= data.len and n < boxes.len) {
        const head = data[@intCast(off)..];
        var size: u64 = std.mem.readInt(u32, head[0..4], .big);
        var header: u64 = 8;
        if (size == 1) {
            // Большой бокс: настоящий размер в следующих восьми байтах.
            if (off + 16 > data.len) return Error.BrokenBox;
            size = std.mem.readInt(u64, head[8..16], .big);
            header = 16;
        } else if (size == 0) {
            // «До конца файла» — законно для последнего бокса.
            size = data.len - off;
        }
        if (size < header or off + size > data.len) return Error.BrokenBox;

        const box = Box{ .offset = off, .size = size, .kind = head[4..8].* };
        if (off == 0 and !box.is("ftyp")) return Error.NotMp4;
        if (box.is("moov") and layout.moov_at == null) layout.moov_at = off;
        if (box.is("mdat") and layout.mdat_at == null) {
            layout.mdat_at = off;
            layout.mdat_size = size - header;
        }
        boxes[n] = box;
        n += 1;
        off += size;
    }

    layout.boxes = boxes[0..n];
    return layout;
}

/// Прочитать файл и разобрать его. Читаем целиком: mp4 скринкаста это единицы
/// мегабайт, а частичное чтение усложняет разбор ради ничего.
pub fn inspect(io: std.Io, allocator: std.mem.Allocator, path: []const u8, boxes: []Box) !Layout {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 30));
    defer allocator.free(data);
    return parse(data, boxes);
}

/// Переложить файл так, чтобы `moov` оказался перед `mdat`.
///
/// Своими руками, а не ключом `MF_MPEG4SINK_MOOV_BEFORE_MDAT`: тот ключ на
/// проверке переносил `moov` в начало, но не сдвигал данные — получался файл,
/// у которого метаданные читаются, а картинка рассыпается («Invalid NAL unit
/// size» у любого декодера). Проверено на 90 кадрах стенда 10.09.2026.
///
/// Перенос — это не просто перестановка кусков: таблицы `stco` и `co64` внутри
/// `moov` указывают на смещения кадров в файле, и все их надо подвинуть на ту
/// же величину, на которую съехал `mdat`.
///
/// Возвращает `false`, если переносить нечего (уже быстрый старт).
pub fn makeFastStart(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !bool {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 30));
    defer allocator.free(data);

    const out = try allocator.alloc(u8, data.len);
    defer allocator.free(out);
    if (!try rearrange(data, out)) return false;

    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var wbuf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &wbuf);
    try fw.interface.writeAll(out);
    try fw.interface.flush();
    return true;
}

/// Собрать в `out` тот же файл, но с `moov` перед `mdat`. Возвращает `false`,
/// если переставлять нечего. Без файлов — чтобы перестановку можно было
/// проверить тестом, а не только на живой записи.
pub fn rearrange(data: []const u8, out: []u8) Error!bool {
    if (out.len != data.len) return Error.BrokenBox;

    var boxes_buf: [64]Box = undefined;
    const layout = try parse(data, &boxes_buf);
    if (layout.moov_at == null or layout.mdat_at == null) return Error.BrokenBox;
    if (layout.fastStart()) return false;

    const moov = blk: {
        for (layout.boxes) |b| if (b.is("moov")) break :blk b;
        return Error.BrokenBox;
    };

    // Раскладка: всё, что было до mdat (кроме moov), затем moov, затем mdat
    // и остальное. Смещения кадров сдвигаются ровно на размер moov.
    var pos: usize = 0;
    var moov_out: usize = 0;
    for (layout.boxes) |b| {
        if (b.is("moov")) continue;
        if (b.is("mdat")) {
            moov_out = pos;
            @memcpy(out[pos..][0..@intCast(moov.size)], data[@intCast(moov.offset)..][0..@intCast(moov.size)]);
            pos += @intCast(moov.size);
        }
        @memcpy(out[pos..][0..@intCast(b.size)], data[@intCast(b.offset)..][0..@intCast(b.size)]);
        pos += @intCast(b.size);
    }
    if (pos != data.len) return Error.BrokenBox;

    const delta: i64 = @as(i64, @intCast(moov_out + @as(usize, @intCast(moov.size)))) -
        @as(i64, @intCast(layout.mdat_at.?));
    shiftChunkOffsets(out[moov_out..][0..@intCast(moov.size)], delta);
    return true;
}

/// Пройти по дереву боксов и подвинуть каждую таблицу смещений кадров.
///
/// Ищем везде, а не по известному пути `trak/mdia/minf/stbl`: дорожек бывает
/// несколько, а лишний обход дешевле пропущенной таблицы, из-за которой файл
/// потом не играется.
fn shiftChunkOffsets(container: []u8, delta: i64) void {
    var off: usize = 8; // пропускаем заголовок самого контейнера
    while (off + 8 <= container.len) {
        var size: usize = std.mem.readInt(u32, container[off..][0..4], .big);
        const kind = container[off + 4 ..][0..4];
        var header: usize = 8;
        if (size == 1) {
            if (off + 16 > container.len) return;
            size = @intCast(std.mem.readInt(u64, container[off + 8 ..][0..8], .big));
            header = 16;
        } else if (size == 0) {
            size = container.len - off;
        }
        if (size < header or off + size > container.len) return;

        const body = container[off + header .. off + size];
        if (std.mem.eql(u8, kind, "stco")) {
            shiftTable(body, u32, delta);
        } else if (std.mem.eql(u8, kind, "co64")) {
            shiftTable(body, u64, delta);
        } else if (isContainer(kind)) {
            shiftChunkOffsets(container[off .. off + size], delta);
        }
        off += size;
    }
}

/// Боксы, внутри которых лежат другие боксы. Остальные — данные, и лезть
/// внутрь них нельзя: там встречаются байты, похожие на заголовок.
fn isContainer(kind: *const [4]u8) bool {
    const names = [_][]const u8{ "trak", "mdia", "minf", "stbl", "edts", "udta" };
    for (names) |n| {
        if (std.mem.eql(u8, kind, n)) return true;
    }
    return false;
}

fn shiftTable(body: []u8, comptime T: type, delta: i64) void {
    const width = @sizeOf(T);
    if (body.len < 8) return;
    const count = std.mem.readInt(u32, body[4..8], .big);
    var i: usize = 0;
    while (i < count and 8 + (i + 1) * width <= body.len) : (i += 1) {
        const at = body[8 + i * width ..][0..width];
        const old: i64 = @intCast(std.mem.readInt(T, at, .big));
        const new = old + delta;
        if (new < 0) continue;
        std.mem.writeInt(T, at, @intCast(new), .big);
    }
}

// ---------------------------------------------------------------- тесты

/// Собрать mp4-подобный буфер из перечня боксов.
fn build(comptime specs: []const struct { []const u8, u32 }) [
    blk: {
        var total: usize = 0;
        for (specs) |s| total += s[1];
        break :blk total;
    }
]u8 {
    var buf: [
        blk: {
            var total: usize = 0;
            for (specs) |s| total += s[1];
            break :blk total;
        }
    ]u8 = undefined;
    var off: usize = 0;
    for (specs) |s| {
        std.mem.writeInt(u32, buf[off..][0..4], s[1], .big);
        @memcpy(buf[off + 4 ..][0..4], s[0]);
        @memset(buf[off + 8 .. off + s[1]], 0);
        off += s[1];
    }
    return buf;
}

test "moov перед mdat: файл с быстрым стартом" {
    const data = build(&.{ .{ "ftyp", 24 }, .{ "moov", 200 }, .{ "mdat", 1000 } });
    var boxes: [16]Box = undefined;
    const l = try parse(&data, &boxes);
    try std.testing.expectEqual(@as(usize, 3), l.boxes.len);
    try std.testing.expect(l.fastStart());
    try std.testing.expect(l.playable());
    try std.testing.expectEqual(@as(u64, 992), l.mdat_size);
}

test "moov в конце: играть можно, но не сразу" {
    const data = build(&.{ .{ "ftyp", 24 }, .{ "mdat", 1000 }, .{ "moov", 200 } });
    var boxes: [16]Box = undefined;
    const l = try parse(&data, &boxes);
    try std.testing.expect(!l.fastStart());
    try std.testing.expect(l.playable());
}

test "без moov файл не играется" {
    const data = build(&.{ .{ "ftyp", 24 }, .{ "mdat", 1000 } });
    var boxes: [16]Box = undefined;
    const l = try parse(&data, &boxes);
    try std.testing.expect(!l.playable());
    try std.testing.expect(!l.fastStart());
}

test "пустой mdat означает, что данных нет" {
    const data = build(&.{ .{ "ftyp", 24 }, .{ "moov", 200 }, .{ "mdat", 8 } });
    var boxes: [16]Box = undefined;
    const l = try parse(&data, &boxes);
    try std.testing.expect(!l.playable());
}

test "чужой формат отвергается" {
    const data = build(&.{ .{ "junk", 24 }, .{ "moov", 200 } });
    var boxes: [16]Box = undefined;
    try std.testing.expectError(Error.NotMp4, parse(&data, &boxes));
}

test "оборванный бокс виден по размеру" {
    var data = build(&.{ .{ "ftyp", 24 }, .{ "mdat", 1000 } });
    // Размер больше, чем осталось файла: так выглядит прерванная запись.
    std.mem.writeInt(u32, data[24..28], 100_000, .big);
    var boxes: [16]Box = undefined;
    try std.testing.expectError(Error.BrokenBox, parse(&data, &boxes));
}

test "слишком короткий файл" {
    var boxes: [4]Box = undefined;
    try std.testing.expectError(Error.TooSmall, parse("mp4", &boxes));
}

test "нулевой размер означает бокс до конца файла" {
    var data = build(&.{ .{ "ftyp", 24 }, .{ "moov", 200 }, .{ "mdat", 1000 } });
    std.mem.writeInt(u32, data[224..228], 0, .big);
    var boxes: [16]Box = undefined;
    const l = try parse(&data, &boxes);
    try std.testing.expectEqual(@as(u64, 1000), l.boxes[2].size);
    try std.testing.expect(l.fastStart());
}

test "перестановка: moov уезжает вперёд, смещения кадров сдвигаются" {
    // ftyp(16) + mdat(40, данные с 24) + moov(64: trak > mdia > minf > stbl > stco)
    const stco_entries = [_]u32{ 24, 32 };
    var data: [16 + 40 + 8 + 8 + 8 + 8 + 8 + (8 + 8 + 8)]u8 = undefined;
    @memset(&data, 0);

    var p: usize = 0;
    // ftyp
    std.mem.writeInt(u32, data[p..][0..4], 16, .big);
    @memcpy(data[p + 4 ..][0..4], "ftyp");
    p += 16;
    // mdat
    const mdat_at = p;
    std.mem.writeInt(u32, data[p..][0..4], 40, .big);
    @memcpy(data[p + 4 ..][0..4], "mdat");
    p += 40;
    // moov > trak > mdia > minf > stbl > stco
    const moov_at = p;
    const moov_size: u32 = @intCast(data.len - p);
    std.mem.writeInt(u32, data[p..][0..4], moov_size, .big);
    @memcpy(data[p + 4 ..][0..4], "moov");
    var q = p + 8;
    for ([_][]const u8{ "trak", "mdia", "minf", "stbl" }) |name| {
        std.mem.writeInt(u32, data[q..][0..4], @intCast(data.len - q), .big);
        @memcpy(data[q + 4 ..][0..4], name[0..4]);
        q += 8;
    }
    std.mem.writeInt(u32, data[q..][0..4], @intCast(data.len - q), .big);
    @memcpy(data[q + 4 ..][0..4], "stco");
    std.mem.writeInt(u32, data[q + 8 ..][0..4], 0, .big); // версия и флаги
    std.mem.writeInt(u32, data[q + 12 ..][0..4], stco_entries.len, .big);
    const table_at = q + 16;
    for (stco_entries, 0..) |v, i| std.mem.writeInt(u32, data[table_at + i * 4 ..][0..4], v, .big);

    var boxes: [8]Box = undefined;
    const before = try parse(&data, &boxes);
    try std.testing.expect(!before.fastStart());
    try std.testing.expectEqual(@as(u64, mdat_at), before.mdat_at.?);
    try std.testing.expectEqual(@as(u64, moov_at), before.moov_at.?);

    var out: [data.len]u8 = undefined;
    try std.testing.expect(try rearrange(&data, &out));

    const after = try parse(&out, &boxes);
    try std.testing.expect(after.fastStart());
    try std.testing.expectEqual(@as(usize, 3), after.boxes.len);
    try std.testing.expect(after.boxes[1].is("moov"));
    try std.testing.expect(after.boxes[2].is("mdat"));

    // mdat уехал вправо ровно на размер moov — на столько же сдвинулись смещения.
    // Сама таблица переехала вместе с moov, поэтому её адрес считаем от него.
    const new_table_at = table_at - moov_at + @as(usize, @intCast(after.moov_at.?));
    for (stco_entries, 0..) |v, i| {
        const got = std.mem.readInt(u32, out[new_table_at + i * 4 ..][0..4], .big);
        try std.testing.expectEqual(v + moov_size, got);
    }
}

test "файл с быстрым стартом не трогается" {
    const data = build(&.{ .{ "ftyp", 24 }, .{ "moov", 200 }, .{ "mdat", 1000 } });
    var out: [data.len]u8 = undefined;
    try std.testing.expect(!try rearrange(&data, &out));
}

test "перестановка требует буфера того же размера" {
    const data = build(&.{ .{ "ftyp", 24 }, .{ "mdat", 100 }, .{ "moov", 40 } });
    var small: [10]u8 = undefined;
    try std.testing.expectError(Error.BrokenBox, rearrange(&data, &small));
}
