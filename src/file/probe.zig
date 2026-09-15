//! Что внутри mp4: дорожки, длительность, размер кадра.
//!
//! Задача #24. Редактору надо показать открытый файл ещё до того, как он
//! научится его проигрывать: сколько дорожек, какие, насколько длинные.
//! Для этого декодер не нужен — всё это написано в заголовке `moov`.
//!
//! Разбираем ровно то, что нужно, и не притворяемся полным разборщиком mp4:
//! `mvhd` даёт общую длительность, `tkhd` — номер дорожки и размер кадра,
//! `mdhd` — свои часы дорожки, `hdlr` — что это за дорожка, `stsd` — каким
//! кодеком она закодирована.
//!
//! Всё считается **по буферу в памяти**, без чтения файла: так разбор
//! проверяется тестами на собранных вручную заголовках, а не «открой файл
//! и посмотри».
const std = @import("std");

pub const Error = error{
    /// Это не mp4: нет ни одного знакомого бокса верхнего уровня.
    NotMp4,
    /// Заголовок обрывается на полуслове.
    Truncated,
    /// Файл есть, `moov` нет: обычно это недописанная запись.
    NoMoov,
};

pub const Kind = enum {
    video,
    audio,
    other,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .video => "видео",
            .audio => "звук",
            .other => "прочее",
        };
    }
};

pub const Track = struct {
    id: u32 = 0,
    kind: Kind = .other,
    /// Четырёхбуквенное имя кодека: `avc1`, `mp4a` и подобные.
    codec: [4]u8 = "    ".*,
    /// Длительность дорожки по её собственным часам.
    duration_ns: u64 = 0,
    /// Размер кадра. У звуковой дорожки нули.
    width: u32 = 0,
    height: u32 = 0,
    /// Сколько отсчётов или кадров в дорожке.
    samples: u32 = 0,

    pub fn codecName(self: *const Track) []const u8 {
        // Отрезаем хвост из пробелов и нулей вручную: имя кодека приходит
        // ровно четырьмя байтами и добивается тем и другим.
        var end: usize = self.codec.len;
        while (end > 0 and (self.codec[end - 1] == ' ' or self.codec[end - 1] == 0)) end -= 1;
        return self.codec[0..end];
    }

    /// Понятное имя кодека вместо четырёх букв.
    pub fn codecLabel(self: *const Track) []const u8 {
        const name = self.codecName();
        if (std.mem.eql(u8, name, "avc1") or std.mem.eql(u8, name, "h264")) return "H.264";
        if (std.mem.eql(u8, name, "hvc1") or std.mem.eql(u8, name, "hev1")) return "H.265";
        if (std.mem.eql(u8, name, "mp4a")) return "AAC";
        if (std.mem.eql(u8, name, "Opus")) return "Opus";
        if (name.len == 0) return "неизвестно";
        return name;
    }

    pub fn seconds(self: *const Track) f64 {
        return @as(f64, @floatFromInt(self.duration_ns)) / @as(f64, std.time.ns_per_s);
    }

    /// Кадров в секунду. Считается из числа кадров и длительности, а не
    /// берётся из заголовка: в заголовке лежит желаемая частота, а нам нужна
    /// та, что получилась.
    pub fn fps(self: *const Track) f64 {
        const secs = self.seconds();
        if (secs <= 0 or self.samples == 0) return 0;
        return @as(f64, @floatFromInt(self.samples)) / secs;
    }
};

pub const max_tracks = 16;

pub const Info = struct {
    duration_ns: u64 = 0,
    tracks: [max_tracks]Track = @splat(.{}),
    count: usize = 0,
    /// Лежит ли `moov` перед `mdat` — то есть начнёт ли браузер играть файл,
    /// не скачав его целиком.
    fast_start: bool = false,

    pub fn list(self: *const Info) []const Track {
        return self.tracks[0..self.count];
    }

    pub fn seconds(self: *const Info) f64 {
        return @as(f64, @floatFromInt(self.duration_ns)) / @as(f64, std.time.ns_per_s);
    }

    pub fn videoCount(self: *const Info) usize {
        var n: usize = 0;
        for (self.list()) |t| {
            if (t.kind == .video) n += 1;
        }
        return n;
    }

    pub fn audioCount(self: *const Info) usize {
        var n: usize = 0;
        for (self.list()) |t| {
            if (t.kind == .audio) n += 1;
        }
        return n;
    }

    /// Самая длинная дорожка. По ней рисуется шкала времени: файл длится
    /// столько, сколько длится его самая длинная дорожка, даже если в `mvhd`
    /// написано иначе.
    pub fn longestNs(self: *const Info) u64 {
        var top = self.duration_ns;
        for (self.list()) |t| top = @max(top, t.duration_ns);
        return top;
    }
};

fn readU32(data: []const u8, at: usize) u32 {
    if (at + 4 > data.len) return 0;
    return std.mem.readInt(u32, data[at..][0..4], .big);
}

fn readU64(data: []const u8, at: usize) u64 {
    if (at + 8 > data.len) return 0;
    return std.mem.readInt(u64, data[at..][0..8], .big);
}

/// Перевести длительность из тактов дорожки в наносекунды.
fn toNs(units: u64, scale: u32) u64 {
    if (scale == 0) return 0;
    return units * std.time.ns_per_s / scale;
}

/// Пройти по вложенным боксам и позвать `visit` на каждом.
///
/// Своя маленькая прогулка по дереву, а не общий разборщик: нам нужны шесть
/// боксов из сотни возможных, и написать их разбор короче, чем настроить
/// чужой.
const Walker = struct {
    data: []const u8,

    fn walk(self: Walker, from: usize, to: usize, ctx: anytype, comptime visit: fn (@TypeOf(ctx), []const u8, usize, usize) void) void {
        var at = from;
        while (at + 8 <= to) {
            var size: u64 = readU32(self.data, at);
            const name_at = at + 4;
            if (name_at + 4 > to) return;
            const body_at = at + 8;

            if (size == 1) {
                // Большой бокс: настоящий размер лежит следом за именем.
                size = readU64(self.data, body_at);
                if (size < 16) return;
                visit(ctx, self.data[name_at..][0..4], body_at + 8, @min(at + @as(usize, @intCast(size)), to));
                at += @intCast(size);
                continue;
            }
            if (size == 0) size = to - at; // до конца родителя
            if (size < 8) return;
            const end = @min(at + @as(usize, @intCast(size)), to);
            visit(ctx, self.data[name_at..][0..4], body_at, end);
            at += @intCast(size);
        }
    }
};

const State = struct {
    walker: Walker,
    info: *Info,
    /// Дорожка, которую сейчас собираем.
    current: Track = .{},
    /// Часы текущей дорожки.
    timescale: u32 = 0,
    building: bool = false,
};

fn eq(name: []const u8, want: []const u8) bool {
    return std.mem.eql(u8, name, want);
}

fn visitTop(state: *State, name: []const u8, body: usize, end: usize) void {
    if (eq(name, "moov")) state.walker.walk(body, end, state, visitMoov);
}

fn visitMoov(state: *State, name: []const u8, body: usize, end: usize) void {
    const d = state.walker.data;
    if (eq(name, "mvhd")) {
        const version = if (body < d.len) d[body] else 0;
        if (version == 1) {
            const scale = readU32(d, body + 20);
            state.info.duration_ns = toNs(readU64(d, body + 24), scale);
        } else {
            const scale = readU32(d, body + 12);
            state.info.duration_ns = toNs(readU32(d, body + 16), scale);
        }
        return;
    }
    if (!eq(name, "trak")) return;
    if (state.info.count >= max_tracks) return;

    state.current = .{};
    state.timescale = 0;
    state.building = true;
    state.walker.walk(body, end, state, visitTrak);
    if (state.building) {
        state.info.tracks[state.info.count] = state.current;
        state.info.count += 1;
        state.building = false;
    }
}

fn visitTrak(state: *State, name: []const u8, body: usize, end: usize) void {
    const d = state.walker.data;
    if (eq(name, "tkhd")) {
        const version = if (body < d.len) d[body] else 0;
        state.current.id = if (version == 1) readU32(d, body + 20) else readU32(d, body + 12);
        // Размер кадра лежит в конце бокса в формате 16.16.
        const size_at = end -| 8;
        state.current.width = readU32(d, size_at) >> 16;
        state.current.height = readU32(d, size_at + 4) >> 16;
        return;
    }
    if (eq(name, "mdia")) state.walker.walk(body, end, state, visitMdia);
}

fn visitMdia(state: *State, name: []const u8, body: usize, end: usize) void {
    const d = state.walker.data;
    if (eq(name, "mdhd")) {
        const version = if (body < d.len) d[body] else 0;
        if (version == 1) {
            state.timescale = readU32(d, body + 20);
            state.current.duration_ns = toNs(readU64(d, body + 24), state.timescale);
        } else {
            state.timescale = readU32(d, body + 12);
            state.current.duration_ns = toNs(readU32(d, body + 16), state.timescale);
        }
        return;
    }
    if (eq(name, "hdlr")) {
        // Тип обработчика: четыре буквы через восемь байт от начала тела.
        if (body + 12 > d.len) return;
        const handler = d[body + 8 ..][0..4];
        state.current.kind = if (eq(handler, "vide"))
            .video
        else if (eq(handler, "soun"))
            .audio
        else
            .other;
        return;
    }
    if (eq(name, "minf")) state.walker.walk(body, end, state, visitMinf);
}

fn visitMinf(state: *State, name: []const u8, body: usize, end: usize) void {
    if (eq(name, "stbl")) state.walker.walk(body, end, state, visitStbl);
}

fn visitStbl(state: *State, name: []const u8, body: usize, end: usize) void {
    const d = state.walker.data;
    if (eq(name, "stsd")) {
        // Внутри `stsd`: счётчик, а за ним записи; имя кодека — в первой.
        if (body + 16 > d.len) return;
        @memcpy(&state.current.codec, d[body + 12 ..][0..4]);
        return;
    }
    if (eq(name, "stsz")) {
        state.current.samples = readU32(d, body + 8);
        return;
    }
    _ = end;
}

/// Разобрать заголовок mp4 из буфера.
pub fn parse(data: []const u8) Error!Info {
    if (data.len < 8) return Error.Truncated;

    var info = Info{};
    var state = State{ .walker = .{ .data = data }, .info = &info };

    // Заодно смотрим порядок боксов верхнего уровня: `moov` перед `mdat`
    // означает, что браузер начнёт играть, не скачав файл целиком.
    var at: usize = 0;
    var seen_moov = false;
    var seen_mdat = false;
    var known = false;
    while (at + 8 <= data.len) {
        var size: u64 = readU32(data, at);
        const name = data[at + 4 ..][0..4];
        if (size == 1) size = readU64(data, at + 8);
        if (size == 0) size = data.len - at;
        if (size < 8) break;

        if (eq(name, "ftyp") or eq(name, "moov") or eq(name, "mdat") or eq(name, "free") or eq(name, "uuid")) known = true;
        if (eq(name, "moov")) {
            seen_moov = true;
            if (!seen_mdat) info.fast_start = true;
        }
        if (eq(name, "mdat")) seen_mdat = true;

        at += @intCast(size);
    }
    if (!known) return Error.NotMp4;
    if (!seen_moov) return Error.NoMoov;

    state.walker.walk(0, data.len, &state, visitTop);
    return info;
}

/// Прочитать файл и разобрать его заголовок.
///
/// Читаем целиком: заголовок лежит в начале, но у файла без быстрого старта
/// он в конце, и читать «первые сколько-нибудь байт» значит промахиваться
/// ровно на тех файлах, которые чаще всего и приносят.
pub fn read(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Info {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 31));
    defer allocator.free(data);
    return parse(data);
}

// ---------------------------------------------------------------- тесты

/// Собрать бокс: размер, имя, тело.
fn box(out: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, body: []const u8) !void {
    var head: [8]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], @intCast(8 + body.len), .big);
    @memcpy(head[4..8], name);
    try out.appendSlice(allocator, &head);
    try out.appendSlice(allocator, body);
}

fn u32be(v: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    return b;
}

/// Собрать mp4 с одной видеодорожкой и одной звуковой — ровно такой, какой
/// пишет сама программа.
fn buildSample(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try box(&out, allocator, "ftyp", "isom" ++ &u32be(512) ++ "isomavc1");

    // Видеодорожка: 1000 тактов в секунду, 3000 тактов, 90 кадров, 384x64.
    var video: std.ArrayList(u8) = .empty;
    defer video.deinit(allocator);
    {
        var tkhd: [84]u8 = @splat(0);
        @memcpy(tkhd[12..16], &u32be(1)); // номер дорожки
        @memcpy(tkhd[76..80], &u32be(384 << 16));
        @memcpy(tkhd[80..84], &u32be(64 << 16));
        try box(&video, allocator, "tkhd", &tkhd);

        var mdia: std.ArrayList(u8) = .empty;
        defer mdia.deinit(allocator);
        var mdhd: [24]u8 = @splat(0);
        @memcpy(mdhd[12..16], &u32be(1000));
        @memcpy(mdhd[16..20], &u32be(3000));
        try box(&mdia, allocator, "mdhd", &mdhd);
        try box(&mdia, allocator, "hdlr", &([_]u8{0} ** 8 ++ "vide".* ++ [_]u8{0} ** 12));

        var stbl: std.ArrayList(u8) = .empty;
        defer stbl.deinit(allocator);
        try box(&stbl, allocator, "stsd", &([_]u8{0} ** 8 ++ u32be(86) ++ "avc1".* ++ [_]u8{0} ** 8));
        try box(&stbl, allocator, "stsz", &([_]u8{0} ** 8 ++ u32be(90)));

        var minf: std.ArrayList(u8) = .empty;
        defer minf.deinit(allocator);
        try box(&minf, allocator, "stbl", stbl.items);
        try box(&mdia, allocator, "minf", minf.items);
        try box(&video, allocator, "mdia", mdia.items);
    }

    // Звуковая дорожка: 48000 тактов в секунду, 144000 тактов.
    var audio: std.ArrayList(u8) = .empty;
    defer audio.deinit(allocator);
    {
        var tkhd: [84]u8 = @splat(0);
        @memcpy(tkhd[12..16], &u32be(2));
        try box(&audio, allocator, "tkhd", &tkhd);

        var mdia: std.ArrayList(u8) = .empty;
        defer mdia.deinit(allocator);
        var mdhd: [24]u8 = @splat(0);
        @memcpy(mdhd[12..16], &u32be(48000));
        @memcpy(mdhd[16..20], &u32be(144000));
        try box(&mdia, allocator, "mdhd", &mdhd);
        try box(&mdia, allocator, "hdlr", &([_]u8{0} ** 8 ++ "soun".* ++ [_]u8{0} ** 12));

        var stbl: std.ArrayList(u8) = .empty;
        defer stbl.deinit(allocator);
        try box(&stbl, allocator, "stsd", &([_]u8{0} ** 8 ++ u32be(36) ++ "mp4a".* ++ [_]u8{0} ** 8));
        try box(&stbl, allocator, "stsz", &([_]u8{0} ** 8 ++ u32be(141)));

        var minf: std.ArrayList(u8) = .empty;
        defer minf.deinit(allocator);
        try box(&minf, allocator, "stbl", stbl.items);
        try box(&mdia, allocator, "minf", minf.items);
        try box(&audio, allocator, "mdia", mdia.items);
    }

    var moov: std.ArrayList(u8) = .empty;
    defer moov.deinit(allocator);
    var mvhd: [100]u8 = @splat(0);
    @memcpy(mvhd[12..16], &u32be(1000));
    @memcpy(mvhd[16..20], &u32be(3000));
    try box(&moov, allocator, "mvhd", &mvhd);
    try box(&moov, allocator, "trak", video.items);
    try box(&moov, allocator, "trak", audio.items);

    try box(&out, allocator, "moov", moov.items);
    try box(&out, allocator, "mdat", "данные кадров");
    return out.toOwnedSlice(allocator);
}

test "в файле видно обе дорожки" {
    const data = try buildSample(std.testing.allocator);
    defer std.testing.allocator.free(data);

    const info = try parse(data);
    try std.testing.expectEqual(@as(usize, 2), info.list().len);
    try std.testing.expectEqual(@as(usize, 1), info.videoCount());
    try std.testing.expectEqual(@as(usize, 1), info.audioCount());
}

test "видеодорожка: размер кадра, кодек, частота" {
    const data = try buildSample(std.testing.allocator);
    defer std.testing.allocator.free(data);

    const info = try parse(data);
    const v = info.list()[0];
    try std.testing.expectEqual(Kind.video, v.kind);
    try std.testing.expectEqual(@as(u32, 1), v.id);
    try std.testing.expectEqual(@as(u32, 384), v.width);
    try std.testing.expectEqual(@as(u32, 64), v.height);
    try std.testing.expectEqualStrings("H.264", v.codecLabel());
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), v.seconds(), 0.001);
    // 90 кадров за три секунды — тридцать в секунду.
    try std.testing.expectApproxEqAbs(@as(f64, 30.0), v.fps(), 0.01);
}

test "звуковая дорожка: свои часы, свой кодек, кадра нет" {
    const data = try buildSample(std.testing.allocator);
    defer std.testing.allocator.free(data);

    const info = try parse(data);
    const a = info.list()[1];
    try std.testing.expectEqual(Kind.audio, a.kind);
    try std.testing.expectEqualStrings("AAC", a.codecLabel());
    // Часы у звука свои: 144000 тактов по 48 кГц — те же три секунды.
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), a.seconds(), 0.001);
    try std.testing.expectEqual(@as(u32, 0), a.width);
    try std.testing.expectEqual(@as(u32, 0), a.height);
}

test "длительность файла и самая длинная дорожка" {
    const data = try buildSample(std.testing.allocator);
    defer std.testing.allocator.free(data);

    const info = try parse(data);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), info.seconds(), 0.001);
    try std.testing.expectEqual(info.duration_ns, info.longestNs());
}

test "moov перед mdat — файл начнёт играть, не скачавшись целиком" {
    const data = try buildSample(std.testing.allocator);
    defer std.testing.allocator.free(data);
    try std.testing.expect((try parse(data)).fast_start);
}

test "не mp4 и обрубленный файл различаются" {
    try std.testing.expectError(Error.Truncated, parse("abc"));
    try std.testing.expectError(Error.NotMp4, parse("это точно не мп4, а просто текст"));
}

test "файл без moov — это недописанная запись, и так и сказано" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try box(&out, std.testing.allocator, "ftyp", "isom" ++ &u32be(512) ++ "isom");
    try box(&out, std.testing.allocator, "mdat", "кадры без заголовка");
    try std.testing.expectError(Error.NoMoov, parse(out.items));
}

test "неизвестный кодек не выдумывается" {
    var t = Track{};
    @memcpy(&t.codec, "xyzw");
    try std.testing.expectEqualStrings("xyzw", t.codecLabel());
    t.codec = "    ".*;
    try std.testing.expectEqualStrings("неизвестно", t.codecLabel());
}

test "частота не делится на ноль" {
    const empty = Track{};
    try std.testing.expectEqual(@as(f64, 0), empty.fps());
    const no_samples = Track{ .duration_ns = std.time.ns_per_s };
    try std.testing.expectEqual(@as(f64, 0), no_samples.fps());
}
