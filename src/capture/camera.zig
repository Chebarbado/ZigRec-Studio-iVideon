//! Источник-камера: живой поток Ivideon как кадры `capture_types.Frame`.
//!
//! Тикет #74. Тот же тип кадра, что у DXGI/GDI (BGRA8), поэтому камера
//! встаёт в общий конвейер: показ в окне, а дальше — запись через тот же
//! кодировщик Media Foundation.
//!
//! H.264 в чистом Zig не декодируем, а Media Foundation не умеет тянуть живой
//! FLV из сети без своего IMFByteStream+демуксера. Поэтому декодирует ffmpeg
//! отдельным процессом: `-i <подписанный URL> -f rawvideo -pix_fmt bgra`, а мы
//! читаем сырые кадры из его stdout. Нативный MF-декодер без ffmpeg — отдельный
//! тикет.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("capture_types.zig");
const win32 = @import("../win32.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Options = struct {
    /// Путь к ffmpeg.exe.
    ffmpeg_path: []const u8,
    /// Готовый подписанный URL живого потока (см. net/ivideon.zig).
    url: []const u8,
    width: u32,
    height: u32,
};

pub const Camera = struct {
    io: Io,
    alloc: Allocator,
    child: std.process.Child,
    reader: Io.File.Reader,
    rbuf: []u8,
    frame_buf: []u8,
    width: u32,
    height: u32,
    start_ns: u64,

    /// Следующий кадр. `error.EndOfStream` — ffmpeg закончил (поток оборвался).
    /// Данные живут до следующего вызова.
    ///
    /// Отсчёт времени — от ПЕРВОГО кадра, а не от `open`: ffmpeg подключается к
    /// потоку несколько секунд, и если считать с `open`, первый кадр приходит
    /// уже «просроченным» и запись обрывается на одном кадре.
    pub fn next(self: *Camera) !types.Frame {
        try self.reader.interface.readSliceAll(self.frame_buf);
        const now = win32.nowNs();
        if (self.start_ns == 0) self.start_ns = now;
        return .{
            .pixels = self.frame_buf,
            .width = self.width,
            .height = self.height,
            .stride = self.width * 4,
            .timestamp_ns = now - self.start_ns,
            .accumulated = 1,
        };
    }

    pub fn deinit(self: *Camera) void {
        self.child.kill(self.io);
        self.alloc.free(self.rbuf);
        self.alloc.free(self.frame_buf);
        self.alloc.destroy(self);
    }
};

pub const Error = error{ Unsupported, SpawnFailed, OutOfMemory };

/// Запустить ffmpeg на потоке и подготовить чтение кадров.
pub fn open(alloc: Allocator, io: Io, opt: Options) !*Camera {
    if (builtin.os.tag != .windows) return error.Unsupported;
    const w = opt.width & ~@as(u32, 1);
    const h = opt.height & ~@as(u32, 1);

    var scale_buf: [64]u8 = undefined;
    const scale = try std.fmt.bufPrint(&scale_buf, "scale={d}:{d}", .{ w, h });
    const argv = [_][]const u8{
        opt.ffmpeg_path, "-hide_banner",  "-loglevel", "error",
        "-rw_timeout",   "20000000",      "-i",        opt.url,
        "-an",           "-vf",           scale,       "-pix_fmt",
        "bgra",          "-f",            "rawvideo",  "-",
    };

    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch return error.SpawnFailed;
    errdefer child.kill(io);

    const self = try alloc.create(Camera);
    errdefer alloc.destroy(self);
    const rbuf = try alloc.alloc(u8, 1 << 16);
    errdefer alloc.free(rbuf);
    const frame_buf = try alloc.alloc(u8, @as(usize, w) * @as(usize, h) * 4);
    errdefer alloc.free(frame_buf);

    self.* = .{
        .io = io,
        .alloc = alloc,
        .child = child,
        .reader = undefined,
        .rbuf = rbuf,
        .frame_buf = frame_buf,
        .width = w,
        .height = h,
        .start_ns = 0, // проставится на первом кадре (см. next)
    };
    // Труба не позиционируется — потоковый ридер поверх stdout ffmpeg.
    self.reader = self.child.stdout.?.readerStreaming(io, self.rbuf);
    return self;
}
