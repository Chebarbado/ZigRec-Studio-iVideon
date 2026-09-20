//! Ivideon: токен и подписанный URL живого потока камеры.
//!
//! Плагин-источник камеры для ZigRec (тикет #74 в ivideon-trac). Протокол
//! восстановлен из приложения `com.ivideon.client` 3.7.1 и проверен вживую:
//! вход + 2FA даёт токен с `access_token`, `hmac_secret`, `api_host`; поток
//! `GET {api_host}/cameras/{id}/live_stream?…` отдаётся как FLV/H.264, а URL
//! подписывается парой `cseq`/`cs`. Полная документация — в `../../docs` и в
//! ivideon-trac (wiki:Protocol, раздел 4).
//!
//! Вход в аккаунт и обмен 2FA пока делает питоновский `watch_camera.py`,
//! который кладёт токен в `.ivideon/token.json`; здесь мы его только читаем и
//! подписываем адрес потока. Полный вход на Zig — отдельный тикет.
const std = @import("std");
const Sha1 = std.crypto.hash.Sha1;
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Token = struct {
    access_token: []const u8,
    hmac_secret: []const u8,
    api_host: []const u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Token) void {
        self.arena.deinit();
    }

    /// Базовый URL API: `api_host` со схемой `https://`, если её нет.
    pub fn baseUrl(self: Token, buf: []u8) ![]const u8 {
        if (std.mem.startsWith(u8, self.api_host, "http")) return self.api_host;
        return std.fmt.bufPrint(buf, "https://{s}", .{self.api_host});
    }
};

pub const LoadError = error{ TokenNotFound, TokenMalformed, OutOfMemory };

/// Прочитать токен из `.ivideon/token.json` (кандидаты пробуются по порядку).
pub fn loadToken(gpa: Allocator, io: Io, path: ?[]const u8) LoadError!Token {
    const candidates = [_][]const u8{
        path orelse ".ivideon/token.json",
        ".ivideon/token.json",
        "../.ivideon/token.json",
        "../../.ivideon/token.json",
    };
    var bytes: ?[]u8 = null;
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    for (candidates) |cand| {
        bytes = std.Io.Dir.cwd().readFileAlloc(io, cand, a, .limited(1 << 20)) catch continue;
        break;
    }
    const raw = bytes orelse return error.TokenNotFound;

    const parsed = std.json.parseFromSlice(std.json.Value, a, raw, .{}) catch return error.TokenMalformed;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.TokenMalformed,
    };
    const access = strField(obj, "access_token") orelse return error.TokenMalformed;
    const host = strField(obj, "api_host") orelse "openapi-alpha-eu01.ivideon.com";
    const secret = strField(obj, "hmac_secret") orelse "";
    return .{
        .access_token = try a.dupe(u8, access),
        .hmac_secret = try a.dupe(u8, secret),
        .api_host = try a.dupe(u8, host),
        .arena = arena,
    };
}

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

// ---- подпись стримовых URL (cseq/cs), см. wiki:Protocol#4 ----

const SAFE = blk: {
    var set = [_]bool{false} ** 256;
    for ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*") |ch| set[ch] = true;
    break :blk set;
};

/// Кодирование query-компонента как в OkHttp (verbatim из наблюдаемого клиента).
fn writeQuery(w: *std.Io.Writer, raw: []const u8) std.Io.Writer.Error!void {
    for (raw) |ch| {
        if (SAFE[ch]) try w.writeByte(ch) else try w.print("%{X:0>2}", .{ch});
    }
}

pub const Quality = enum(u8) { low = 0, medium = 1, high = 2 };

/// Собрать подписанный URL живого потока камеры `camera_id`.
/// `session` — 8 символов [0-9a-zA-Z]; `counter` — монотонные миллисекунды.
pub fn liveStreamUrl(
    gpa: Allocator,
    token: Token,
    camera_id: []const u8,
    q: Quality,
    session: []const u8,
    counter: u64,
) ![]u8 {
    var host_buf: [128]u8 = undefined;
    const base = try token.baseUrl(&host_buf);

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/cameras/{s}/live_stream", .{camera_id});

    // Параметры в том же порядке, что шлёт приложение, плюс access_token и cseq.
    var q_al: std.Io.Writer.Allocating = .init(gpa);
    defer q_al.deinit();
    const qw = &q_al.writer;
    try writeQuery(qw, "q");
    try qw.writeByte('=');
    try writeQuery(qw, &[_]u8{'0' + @intFromEnum(q)});
    try qw.writeAll("&");
    try writeQuery(qw, "video_codecs");
    try qw.writeByte('=');
    try writeQuery(qw, "h265,h264");
    try qw.writeAll("&");
    try writeQuery(qw, "audio_codecs");
    try qw.writeByte('=');
    try writeQuery(qw, "pcmu,pcma,aac,mp3");
    try qw.writeAll("&");
    try writeQuery(qw, "access_token");
    try qw.writeByte('=');
    try writeQuery(qw, token.access_token);

    const signed = token.hmac_secret.len != 0;
    if (signed) {
        var cseq_buf: [80]u8 = undefined;
        const cseq = try std.fmt.bufPrint(&cseq_buf, "{s}:{d}", .{ session, counter });
        try qw.writeAll("&");
        try writeQuery(qw, "cseq");
        try qw.writeByte('=');
        try writeQuery(qw, cseq);
    }
    const query = q_al.written();

    var url_al: std.Io.Writer.Allocating = .init(gpa);
    errdefer url_al.deinit();
    try url_al.writer.print("{s}{s}?{s}", .{ base, path, query });
    if (signed) {
        // to_sign = METHOD:path:query:body ; body пуст для GET
        var to_sign: std.Io.Writer.Allocating = .init(gpa);
        defer to_sign.deinit();
        try to_sign.writer.print("GET:{s}:{s}:", .{ path, query });

        var digest: [Sha1.digest_length]u8 = undefined;
        Sha1.hash(to_sign.written(), &digest, .{});
        const digest_hex = std.fmt.bytesToHex(digest, .lower);
        var mac: [HmacSha1.mac_length]u8 = undefined;
        HmacSha1.create(&mac, &digest_hex, token.hmac_secret);
        try url_al.writer.print("&cs={s}", .{std.fmt.bytesToHex(mac, .lower)});
    }
    return url_al.toOwnedSlice();
}

/// 8 символов [0-9a-zA-Z] для идентификатора сессии подписи.
/// `seed` — любой меняющийся источник (напр. `win32.nowNs()`): криптостойкость
/// тут не нужна, это одноразовый nonce сессии.
pub fn newSession(seed: u64) [8]u8 {
    const alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    var out: [8]u8 = undefined;
    for (&out) |*ch| ch.* = alphabet[rnd.intRangeLessThan(usize, 0, alphabet.len)];
    return out;
}

// ---- инфо о камере из .ivideon/camera.json (пишет watch_camera.py) ----

pub const CameraInfo = struct {
    id: []const u8,
    name: []const u8,
    online: bool,
    width: u32,
    height: u32,
    video_codec: []const u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *CameraInfo) void {
        self.arena.deinit();
    }
};

fn intField(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

/// Первая камера из `.ivideon/camera.json`.
pub fn loadFirstCamera(gpa: Allocator, io: Io) LoadError!CameraInfo {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const candidates = [_][]const u8{
        ".ivideon/camera.json", "../.ivideon/camera.json", "../../.ivideon/camera.json",
    };
    var raw: ?[]u8 = null;
    for (candidates) |cand| {
        raw = std.Io.Dir.cwd().readFileAlloc(io, cand, a, .limited(1 << 20)) catch continue;
        break;
    }
    const bytes = raw orelse return error.TokenNotFound;
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return error.TokenMalformed;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.TokenMalformed,
    };
    const arr = switch (obj.get("cameras") orelse return error.TokenMalformed) {
        .array => |x| x,
        else => return error.TokenMalformed,
    };
    if (arr.items.len == 0) return error.TokenMalformed;
    const cam = switch (arr.items[0]) {
        .object => |o| o,
        else => return error.TokenMalformed,
    };
    return .{
        .id = try a.dupe(u8, strField(cam, "id") orelse return error.TokenMalformed),
        .name = try a.dupe(u8, strField(cam, "name") orelse "camera"),
        .online = switch (cam.get("online") orelse std.json.Value{ .bool = false }) {
            .bool => |b| b,
            else => false,
        },
        .width = intField(cam, "width") orelse 1920,
        .height = intField(cam, "height") orelse 1080,
        .video_codec = try a.dupe(u8, strField(cam, "video_codec") orelse "h264"),
        .arena = arena,
    };
}

// ---------------------------------------------------------------- тесты
// Ожидаемые значения — из независимой реализации на Python (hashlib+hmac),
// те же векторы, что в zig-client/src/sign.zig.

fn fixedToken() Token {
    return .{
        .access_token = "100-Kabcdef0123456789",
        .hmac_secret = "s3cr3tKey",
        .api_host = "eu01-api.ivideon.com",
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
}

test "подписанный URL совпадает с эталонным вектором" {
    var tok = fixedToken();
    defer tok.arena.deinit();
    const url = try liveStreamUrl(std.testing.allocator, tok,
        "100-0123456789abcdef0123456789abcdef:0", .high, "AbCd1234", 987654321);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://eu01-api.ivideon.com/cameras/100-0123456789abcdef0123456789abcdef:0/live_stream" ++
            "?q=2&video_codecs=h265%2Ch264&audio_codecs=pcmu%2Cpcma%2Caac%2Cmp3" ++
            "&access_token=100-Kabcdef0123456789&cseq=AbCd1234%3A987654321" ++
            "&cs=555e417709d50f8ffff3ed9c6fc273b250368ebb",
        url,
    );
}

test "пустой hmac_secret оставляет URL без подписи" {
    var tok = Token{
        .access_token = "t",
        .hmac_secret = "",
        .api_host = "api.ivideon.com",
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
    };
    defer tok.arena.deinit();
    const url = try liveStreamUrl(std.testing.allocator, tok, "1:0", .medium, "zzzzzzzz", 1);
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "&cs=") == null);
    try std.testing.expect(std.mem.indexOf(u8, url, "cseq") == null);
}

test "newSession: 8 символов из алфавита" {
    const s = newSession(0x1234_5678_9abc_def0);
    try std.testing.expectEqual(@as(usize, 8), s.len);
    for (s) |ch| try std.testing.expect(std.ascii.isAlphanumeric(ch));
}
