//! `zigrec camera <id>` — окно с живым видео камеры Ivideon.
//!
//! Тикет #74. Читает токен из `.ivideon/token.json`, собирает подписанный URL
//! потока, поднимает ffmpeg (capture/camera.zig) и рисует его кадры в окне тем
//! же способом, что стенд самопроверки: `StretchDIBits` + `GdiFlush`, BGRA
//! сверху вниз (отрицательная высота `BITMAPINFO`).
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;
const camera = @import("../capture/camera.zig");
const ivideon = @import("../net/ivideon.zig");
const encode = @import("../file/encode.zig");
const mp4 = @import("../file/mp4.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const class_name = "ZigRecCamera";
const idc_arrow: c.LPCSTR = @ptrFromInt(32512);

var running: bool = true;

fn wndProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_CLOSE, c.WM_DESTROY => {
            running = false;
            return 0;
        },
        else => return c.DefWindowProcA(hwnd, msg, wp, lp),
    }
}

fn pump() void {
    var msg: c.MSG = undefined;
    while (c.PeekMessageA(&msg, null, 0, 0, c.PM_REMOVE) != 0) {
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageA(&msg);
    }
}

fn escPressed() bool {
    const s: u16 = @bitCast(c.GetAsyncKeyState(c.VK_ESCAPE));
    return (s & 0x8000) != 0;
}

pub const Options = struct {
    camera_id: []const u8,
    ffmpeg_path: []const u8,
    token_path: ?[]const u8 = null,
    q: ivideon.Quality = .medium,
    width: u32 = 640,
    height: u32 = 480,
};

pub fn run(io: Io, alloc: Allocator, opt: Options) !void {
    if (builtin.os.tag != .windows) return error.Unsupported;

    var token = try ivideon.loadToken(alloc, io, opt.token_path);
    defer token.deinit();

    const session = ivideon.newSession(win32.nowNs());
    const counter: u64 = @intCast(win32.nowNs() / std.time.ns_per_ms);
    const url = try ivideon.liveStreamUrl(alloc, token, opt.camera_id, opt.q, &session, counter);
    defer alloc.free(url);

    var cam = try camera.open(alloc, io, .{
        .ffmpeg_path = opt.ffmpeg_path,
        .url = url,
        .width = opt.width,
        .height = opt.height,
    });
    defer cam.deinit();

    _ = c.SetProcessDPIAware();
    const hinst: c.HINSTANCE = @ptrCast(c.GetModuleHandleA(null));
    var wc = std.mem.zeroes(c.WNDCLASSEXA);
    wc.cbSize = @sizeOf(c.WNDCLASSEXA);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinst;
    wc.lpszClassName = class_name;
    wc.hCursor = c.LoadCursorA(null, idc_arrow);
    if (c.RegisterClassExA(&wc) == 0) return error.WindowFailed;
    defer _ = c.UnregisterClassA(class_name, hinst);

    const w: i32 = @intCast(cam.width);
    const h: i32 = @intCast(cam.height);
    var rc = c.RECT{ .left = 0, .top = 0, .right = w, .bottom = h };
    _ = c.AdjustWindowRect(&rc, c.WS_OVERLAPPEDWINDOW, 0);
    const hwnd = c.CreateWindowExA(
        0,
        class_name,
        "Ivideon Cute2 - live (ESC to quit)",
        c.WS_OVERLAPPEDWINDOW,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        rc.right - rc.left,
        rc.bottom - rc.top,
        null,
        null,
        hinst,
        null,
    ) orelse return error.WindowFailed;
    defer _ = c.DestroyWindow(hwnd);
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.UpdateWindow(hwnd);

    var bmi = std.mem.zeroes(c.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h; // строки сверху вниз, как BGRA от ffmpeg
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = c.BI_RGB;

    while (running and !escPressed()) {
        pump();
        const frame = cam.next() catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        const dc = c.GetDC(hwnd) orelse continue;
        _ = c.StretchDIBits(dc, 0, 0, w, h, 0, 0, w, h, frame.pixels.ptr, &bmi, c.DIB_RGB_COLORS, c.SRCCOPY);
        _ = c.ReleaseDC(hwnd, dc);
        _ = c.GdiFlush();
    }
}

/// Разбор `zigrec camera <id> [out.mp4] [--sec N] [--token P] [--ffmpeg P] [--q 0..2] [--size WxH]`.
/// Без `out.mp4` — окно превью; с `out.mp4` — запись N секунд в файл.
pub fn runArgs(io: Io, alloc: Allocator, args: []const [:0]const u8) !u8 {
    if (args.len == 0) {
        std.debug.print(
            \\Использование: zigrec camera <camera_id> [out.mp4] [--sec N] [--token PATH] [--ffmpeg PATH] [--q 0..2] [--size WxH]
            \\  camera_id  — id камеры, напр. 100-...:0 (из watch_camera.py cameras)
            \\  без файла   — окно живого просмотра (выход ESC)
            \\  out.mp4     — записать N секунд (по умолчанию 15) в mp4, дальше: zigrec edit out.mp4
            \\  токен берётся из .ivideon/token.json (сделать: python watch_camera.py --code <SMS>)
            \\
        , .{});
        return 2;
    }
    var opt = Options{ .camera_id = args[0], .ffmpeg_path = "ffmpeg" };
    var out_path: ?[]const u8 = null;
    var seconds: u32 = 15;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--token") and i + 1 < args.len) {
            i += 1;
            opt.token_path = args[i];
        } else if (std.mem.eql(u8, a, "--ffmpeg") and i + 1 < args.len) {
            i += 1;
            opt.ffmpeg_path = args[i];
        } else if (std.mem.eql(u8, a, "--q") and i + 1 < args.len) {
            i += 1;
            const n = std.fmt.parseInt(u8, args[i], 10) catch 1;
            opt.q = @enumFromInt(@min(n, 2));
        } else if (std.mem.eql(u8, a, "--size") and i + 1 < args.len) {
            i += 1;
            if (std.mem.indexOfScalar(u8, args[i], 'x')) |x| {
                opt.width = std.fmt.parseInt(u32, args[i][0..x], 10) catch opt.width;
                opt.height = std.fmt.parseInt(u32, args[i][x + 1 ..], 10) catch opt.height;
            }
        } else if (std.mem.eql(u8, a, "--sec") and i + 1 < args.len) {
            i += 1;
            seconds = std.fmt.parseInt(u32, args[i], 10) catch seconds;
        } else if (std.mem.endsWith(u8, a, ".mp4")) {
            out_path = a;
        }
    }
    if (std.mem.eql(u8, opt.ffmpeg_path, "ffmpeg")) {
        opt.ffmpeg_path = findFfmpeg(io) orelse "ffmpeg";
    }
    const result = if (out_path) |p| record(io, alloc, opt, p, seconds) else run(io, alloc, opt);
    result catch |e| {
        std.debug.print("камера: ошибка {s}\n", .{@errorName(e)});
        if (e == error.TokenNotFound)
            std.debug.print("  токена нет — сначала: python watch_camera.py --code <SMS>\n", .{});
        return 1;
    };
    return 0;
}

/// Записать `seconds` секунд потока камеры в mp4 их родным H.264-энкодером.
pub fn record(io: Io, alloc: Allocator, opt: Options, out_path: []const u8, seconds: u32) !void {
    if (builtin.os.tag != .windows) return error.Unsupported;

    var token = try ivideon.loadToken(alloc, io, opt.token_path);
    defer token.deinit();
    const session = ivideon.newSession(win32.nowNs());
    const counter: u64 = @intCast(win32.nowNs() / std.time.ns_per_ms);
    const url = try ivideon.liveStreamUrl(alloc, token, opt.camera_id, opt.q, &session, counter);
    defer alloc.free(url);

    var cam = try camera.open(alloc, io, .{
        .ffmpeg_path = opt.ffmpeg_path,
        .url = url,
        .width = opt.width,
        .height = opt.height,
    });
    defer cam.deinit();

    var enc = try encode.Writer.create(out_path, cam.width, cam.height, .{ .fps = 25, .gop = 50 });
    errdefer enc.abort();

    std.debug.print("запись {d} с камеры {s} -> {s} ({d}x{d})...\n", .{ seconds, opt.camera_id, out_path, cam.width, cam.height });
    const limit_ns = @as(u64, seconds) * std.time.ns_per_s;
    while (true) {
        const frame = cam.next() catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        try enc.writeFrame(frame.pixels, frame.stride, frame.timestamp_ns);
        if (frame.timestamp_ns >= limit_ns) break;
    }
    const summary = try enc.finish();
    // Перенести moov в начало файла — иначе плеер/браузер не начнёт играть,
    // пока не скачает весь файл (тот же шаг, что в их record()).
    _ = mp4.makeFastStart(io, alloc, out_path) catch false;
    std.debug.print("готово: кадров {d}, {d:.1} с, {d} байт -> {s}\n", .{
        summary.frames,
        @as(f64, @floatFromInt(summary.duration_ns)) / @as(f64, std.time.ns_per_s),
        summary.bytes,
        out_path,
    });
}

/// Найти ffmpeg.exe рядом (portable-сборка в tools/) или положиться на PATH.
fn findFfmpeg(io: Io) ?[]const u8 {
    const candidates = [_][]const u8{
        "../tools/ffmpeg/bin/ffmpeg.exe",
        "tools/ffmpeg/bin/ffmpeg.exe",
        "../../tools/ffmpeg/bin/ffmpeg.exe",
    };
    for (candidates) |cand| {
        std.Io.Dir.cwd().access(io, cand, .{}) catch continue;
        return cand;
    }
    return null;
}
