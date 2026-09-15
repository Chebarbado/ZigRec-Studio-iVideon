//! Сквозная самопроверка захвата: нарисовали — сняли — сверили.
//!
//! Задачи #12 и #13. Смысл: проверить захват без человека и без «на глаз плавно».
//! Программа сама создаёт маленькое окно в левом верхнем углу, рисует в нём кадр
//! тестового стенда с двоичным таймкодом, снимает экран через DXGI и читает
//! номер кадра обратно из снятых пикселей.
//!
//! Так проверяется именно то, что важно: кадры доходят, доходят по порядку,
//! и то, что показали, совпадает с тем, что сняли. Статичный рабочий стол для
//! такой проверки бесполезен — там просто нечему меняться, и захват честно
//! молчит. Поэтому источник изменений создаём сами.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;
const capture = @import("../capture/capture.zig");
const testbench = @import("testbench.zig");

pub const Options = struct {
    /// Сколько кадров показать.
    frames: u32 = 240,
    /// Ожидание нового кадра, миллисекунды.
    timeout_ms: u32 = 200,
    /// Индекс монитора.
    output: u32 = 0,
    /// Каким путём снимать.
    backend: capture.Backend = .auto,
};

pub const Report = struct {
    shown: u32 = 0,
    captured: u32 = 0,
    /// Кадров, где снятый номер совпал с показанным.
    matched: u32 = 0,
    tally: testbench.Tally = .{},
    stats: capture.Stats = .{},
    width: u32 = 0,
    height: u32 = 0,
    /// Каким путём кадры в итоге снимались.
    backend: capture.Backend = .auto,

    /// Прогон засчитан, если снято достаточно кадров и номера сошлись.
    ///
    /// Порог не 100 %: между отрисовкой и снимком экрана система может показать
    /// свой кадр (всплывающая подсказка, курсор, перерисовка чужого окна), и
    /// один-два несовпавших номера это не поломка захвата. А вот меньше
    /// половины совпадений уже означает, что мы снимаем не то или не тогда.
    pub fn ok(self: Report) bool {
        if (self.captured < self.shown / 4) return false;
        if (self.captured == 0) return false;
        return self.matched * 10 >= self.captured * 8;
    }
};

const class_name = "ZigRecSmoke";

/// `IDC_ARROW` объявлен через макрос `MAKEINTRESOURCE`, а его translate-c
/// не переводит. Значение стандартное и не меняется с девяностых.
const idc_arrow: c.LPCSTR = @ptrFromInt(32512);

fn wndProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    return c.DefWindowProcA(hwnd, msg, wp, lp);
}

/// Прогнать проверку. Возвращает отчёт; печать — на вызывающей стороне.
pub fn run(allocator: std.mem.Allocator, opt: Options) !Report {
    if (builtin.os.tag != .windows) return error.Unsupported;

    // Без этого Windows отдаёт растянутые координаты при масштабе экрана
    // больше 100 %, окно уезжает, и снятые пиксели оказываются не наши.
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

    const w: i32 = testbench.min_width;
    const h: i32 = testbench.min_height;
    const hwnd = c.CreateWindowExA(
        c.WS_EX_TOPMOST | c.WS_EX_TOOLWINDOW | c.WS_EX_NOACTIVATE,
        class_name,
        class_name,
        c.WS_POPUP,
        0,
        0,
        w,
        h,
        null,
        null,
        hinst,
        null,
    ) orelse return error.WindowFailed;
    defer _ = c.DestroyWindow(hwnd);
    _ = c.ShowWindow(hwnd, c.SW_SHOWNOACTIVATE);
    _ = c.UpdateWindow(hwnd);

    const screen = try testbench.Screen.init(@intCast(w), @intCast(h), 60);
    const buf = try allocator.alloc(u8, screen.frameBytes());
    defer allocator.free(buf);

    var bmi = std.mem.zeroes(c.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    // Отрицательная высота — строки сверху вниз, как у нас и у DXGI.
    bmi.bmiHeader.biHeight = -h;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = c.BI_RGB;

    var dup = try capture.Capturer.open(allocator, .{
        .backend = opt.backend,
        .output = opt.output,
        // DXGI на неподвижном экране молчит законно, поэтому на понижение
        // даём столько же, сколько на весь показ кадров, но не меньше секунды.
        .downgrade_after_ms = @max(1000, opt.frames * 4),
    });
    defer dup.deinit();

    const size = dup.frameSize();
    var report = Report{ .width = size.width, .height = size.height };
    var seen = try std.ArrayList(u32).initCapacity(allocator, opt.frames);
    defer seen.deinit(allocator);

    const started = win32.nowNs();
    var index: u32 = 1; // с единицы: нулевой кадр не отличить от чёрного экрана
    while (index <= opt.frames) : (index += 1) {
        pumpMessages();

        try screen.render(buf, index);
        const dc = c.GetDC(hwnd) orelse return error.WindowFailed;
        _ = c.StretchDIBits(dc, 0, 0, w, h, 0, 0, w, h, buf.ptr, &bmi, c.DIB_RGB_COLORS, c.SRCCOPY);
        _ = c.ReleaseDC(hwnd, dc);
        _ = c.GdiFlush();
        report.shown += 1;

        const frame = try dup.next(opt.timeout_ms) orelse continue;
        report.captured += 1;
        const got = testbench.readIndex(frame.pixels, testbench.min_width, frame.stride) catch {
            dup.release();
            continue;
        };
        if (got == index) report.matched += 1;
        try seen.append(allocator, got);
        dup.release();
    }

    report.stats = dup.stats();
    report.backend = dup.backend();
    report.stats.elapsed_ns = win32.nowNs() - started;
    report.tally = testbench.tally(seen.items);
    return report;
}

/// Только рисовать, не снимать: источник быстрых изменений на экране.
///
/// Нужен, чтобы измерить, сколько кадров в секунду вытягивает наш захват.
/// На неподвижном экране DXGI не отдаёт ничего — и это не медленность
/// программы, а отсутствие кадров. Чтобы отличить одно от другого, экран
/// должен меняться заведомо быстрее, чем мы снимаем.
pub fn animateOnly(allocator: std.mem.Allocator, seconds: u32, width: u32, height: u32) !u64 {
    if (builtin.os.tag != .windows) return error.Unsupported;
    _ = c.SetProcessDPIAware();

    const hinst: c.HINSTANCE = @ptrCast(c.GetModuleHandleA(null));
    var wc = std.mem.zeroes(c.WNDCLASSEXA);
    wc.cbSize = @sizeOf(c.WNDCLASSEXA);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinst;
    wc.lpszClassName = "ZigRecAnimator";
    wc.hCursor = c.LoadCursorA(null, idc_arrow);
    if (c.RegisterClassExA(&wc) == 0) return error.WindowFailed;
    defer _ = c.UnregisterClassA("ZigRecAnimator", hinst);

    const w: i32 = @intCast(width);
    const h: i32 = @intCast(height);
    const hwnd = c.CreateWindowExA(
        c.WS_EX_TOPMOST | c.WS_EX_TOOLWINDOW | c.WS_EX_NOACTIVATE,
        "ZigRecAnimator",
        "ZigRecAnimator",
        c.WS_POPUP,
        0,
        0,
        w,
        h,
        null,
        null,
        hinst,
        null,
    ) orelse return error.WindowFailed;
    defer _ = c.DestroyWindow(hwnd);
    _ = c.ShowWindow(hwnd, c.SW_SHOWNOACTIVATE);

    const screen = try testbench.Screen.init(@max(width, testbench.min_width), height, 60);
    const buf = try allocator.alloc(u8, screen.frameBytes());
    defer allocator.free(buf);

    var bmi = std.mem.zeroes(c.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = @intCast(screen.width);
    bmi.bmiHeader.biHeight = -@as(i32, @intCast(screen.height));
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = c.BI_RGB;

    const dc = c.GetDC(hwnd) orelse return error.WindowFailed;
    defer _ = c.ReleaseDC(hwnd, dc);

    const until = win32.nowNs() + @as(u64, seconds) * std.time.ns_per_s;
    var painted: u64 = 0;
    var index: u32 = 1;
    while (win32.nowNs() < until) : (index +%= 1) {
        pumpMessages();
        try screen.render(buf, index);
        _ = c.StretchDIBits(dc, 0, 0, w, h, 0, 0, @intCast(screen.width), @intCast(screen.height), buf.ptr, &bmi, c.DIB_RGB_COLORS, c.SRCCOPY);
        _ = c.GdiFlush();
        painted += 1;
    }
    return painted;
}

fn pumpMessages() void {
    var msg: c.MSG = undefined;
    while (c.PeekMessageA(&msg, null, 0, 0, c.PM_REMOVE) != 0) {
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageA(&msg);
    }
}

test "прогон засчитан только при достаточных совпадениях" {
    try std.testing.expect((Report{ .shown = 100, .captured = 90, .matched = 90 }).ok());
    try std.testing.expect((Report{ .shown = 100, .captured = 90, .matched = 72 }).ok());
    try std.testing.expect(!(Report{ .shown = 100, .captured = 90, .matched = 71 }).ok());
}

test "пустой прогон не засчитан" {
    try std.testing.expect(!(Report{ .shown = 100, .captured = 0, .matched = 0 }).ok());
}

test "почти ничего не снято — не засчитан, даже если совпало всё" {
    try std.testing.expect(!(Report{ .shown = 100, .captured = 10, .matched = 10 }).ok());
}
