//! Раздражитель для замера (#30): окно, которое перерисовывается на каждую
//! сборку композитора (шестьдесят раз в секунду при 60 Гц), пока идёт запись.
//!
//! Захват экрана через DXGI отдаёт кадр только когда рабочий стол изменился:
//! на неподвижном экране запись «1080p60» — это один кадр и ноль работы, а
//! замер процессора и потерь по такой записи ничего не значит. Раздражитель
//! гарантирует движение: по окну бежит полоса и меняется цвет, каждая
//! перерисовка — новый кадр для захвата. Окно поверх всех, без рамки, живёт
//! в своём потоке со своим циклом сообщений, чтобы не мешать записи.
//!
//! Тот же раздражитель ставят перед OBS и CamStudio — тогда три программы
//! пишут одно и то же движение, и их числа сравнимы.

const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;

/// Окно раздражителя: положение и размер в точках экрана.
pub const Box = struct { x: i32 = 40, y: i32 = 40, w: i32 = 960, h: i32 = 540 };

/// Сколько перерисовок в секунду просит раздражитель.
pub const fps: u32 = 60;

/// Где полоса на таком-то кадре: бежит слева направо и возвращается.
/// Ширина полосы — десятая часть окна.
pub fn barLeft(frame: u64, width: i32) i32 {
    if (width <= 0) return 0;
    const bar = @max(@divTrunc(width, 10), 1);
    const span: u64 = @intCast(@max(width - bar, 1));
    const period = span * 2;
    const at = frame % period;
    return @intCast(if (at < span) at else period - at);
}

/// Цвет фона на таком-то кадре: плавно крутится по оттенкам, чтобы менялся
/// не только край полосы, а весь кадр — как настоящее видео, а не курсор.
pub fn background(frame: u64) u32 {
    const t: u32 = @intCast(frame % 360);
    const r: u32 = if (t < 120) 255 - t * 2 else if (t < 240) 15 else 15 + (t - 240) * 2;
    const g: u32 = if (t < 120) 15 + t * 2 else if (t < 240) 255 - (t - 120) * 2 else 15;
    const b: u32 = if (t < 120) 15 else if (t < 240) 15 + (t - 120) * 2 else 255 - (t - 240) * 2;
    return r | (g << 8) | (b << 16); // COLORREF: 0x00BBGGRR
}

/// Раздражитель в своём потоке. `start` возвращает, когда окно уже есть;
/// `stop` закрывает окно и ждёт поток.
pub const Stimulus = struct {
    thread: ?std.Thread = null,
    box: Box = .{},
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Сколько перерисовок сделано — сравнивают с кадрами записи.
    frames: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn start(self: *Stimulus, box: Box) !void {
        if (builtin.os.tag != .windows) return error.Unsupported;
        self.box = box;
        self.stop_flag.store(false, .monotonic);
        self.ready.store(false, .monotonic);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        // Ждём окно не дольше секунды: без него замер всё равно пойдёт,
        // просто на неподвижном экране — об этом скажет число перерисовок.
        var waited: u32 = 0;
        while (!self.ready.load(.acquire) and waited < 100) : (waited += 1) c.Sleep(10);
    }

    pub fn stop(self: *Stimulus) void {
        self.stop_flag.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    pub fn repaints(self: *const Stimulus) u64 {
        return self.frames.load(.monotonic);
    }

    fn run(self: *Stimulus) void {
        const hinst: c.HINSTANCE = @ptrCast(c.GetModuleHandleW(null));
        var wc = std.mem.zeroes(c.WNDCLASSEXW);
        wc.cbSize = @sizeOf(c.WNDCLASSEXW);
        wc.lpfnWndProc = proc;
        wc.hInstance = hinst;
        wc.lpszClassName = class_name;
        _ = c.RegisterClassExW(&wc);
        const hwnd = c.CreateWindowExW(
            c.WS_EX_TOPMOST | c.WS_EX_TOOLWINDOW,
            class_name,
            class_name,
            c.WS_POPUP | c.WS_VISIBLE,
            self.box.x,
            self.box.y,
            self.box.w,
            self.box.h,
            null,
            null,
            hinst,
            null,
        ) orelse return;
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.ready.store(true, .release);

        const step_ns: u64 = std.time.ns_per_s / fps;
        var next = win32.nowNs();
        while (!self.stop_flag.load(.acquire)) {
            var msg: c.MSG = undefined;
            while (c.PeekMessageW(&msg, null, 0, 0, c.PM_REMOVE) != 0) {
                _ = c.TranslateMessage(&msg);
                _ = c.DispatchMessageW(&msg);
            }
            // Шаг — по композитору (#95): `DwmFlush` возвращается после
            // очередной его сборки, и перерисовка попадает ровно в следующую.
            // Свои часы с `Sleep(1)` шли с той же частотой, но не в такт:
            // из 564 сборок за запись 49 выходили без новой перерисовки
            // (а соседние — с двумя), и захват честно считал их «экран не
            // изменился». Замер мерил дрожание раздражителя, а не запись.
            if (c.DwmFlush() == 0) {
                _ = c.InvalidateRect(hwnd, null, 0);
                _ = c.UpdateWindow(hwnd);
                continue;
            }
            // Композитор недоступен — прежний шаг по своим часам.
            const now = win32.nowNs();
            if (now >= next) {
                _ = c.InvalidateRect(hwnd, null, 0);
                _ = c.UpdateWindow(hwnd);
                next += step_ns;
                if (next < now) next = now;
            } else {
                c.Sleep(1);
            }
        }
        _ = c.DestroyWindow(hwnd);
        _ = c.UnregisterClassW(class_name, hinst);
    }

    fn proc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
        switch (msg) {
            c.WM_PAINT => {
                const raw = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
                var ps: c.PAINTSTRUCT = undefined;
                const dc = c.BeginPaint(hwnd, &ps);
                defer _ = c.EndPaint(hwnd, &ps);
                var rect: c.RECT = undefined;
                _ = c.GetClientRect(hwnd, &rect);
                const frame: u64 = if (raw != 0) blk: {
                    const self: *Stimulus = @ptrFromInt(@as(usize, @bitCast(raw)));
                    break :blk self.frames.fetchAdd(1, .monotonic);
                } else 0;
                const bg = c.CreateSolidBrush(background(frame));
                defer _ = c.DeleteObject(bg);
                _ = c.FillRect(dc, &rect, bg);
                const bar = @max(@divTrunc(rect.right, 10), 1);
                const left = barLeft(frame, rect.right);
                var bar_rect = c.RECT{ .left = left, .top = 0, .right = left + bar, .bottom = rect.bottom };
                const fg = c.CreateSolidBrush(0x00FFFFFF);
                defer _ = c.DeleteObject(fg);
                _ = c.FillRect(dc, &bar_rect, fg);
                return 0;
            },
            c.WM_ERASEBKGND => return 1,
            else => return c.DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
};

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZigRecStimulus");

const testing = std.testing;

test "полоса бежит туда и обратно, не выходя за окно" {
    const w: i32 = 1000;
    try testing.expectEqual(@as(i32, 0), barLeft(0, w));
    try testing.expectEqual(@as(i32, 1), barLeft(1, w));
    try testing.expectEqual(@as(i32, 900), barLeft(900, w));
    try testing.expectEqual(@as(i32, 899), barLeft(901, w));
    try testing.expectEqual(@as(i32, 0), barLeft(1800, w));
    var f: u64 = 0;
    while (f < 5000) : (f += 7) {
        const l = barLeft(f, w);
        try testing.expect(l >= 0 and l + 100 <= w);
    }
    try testing.expectEqual(@as(i32, 0), barLeft(5, 0));
}

test "цвет фона меняется от кадра к кадру и остаётся в пределах байтов" {
    try testing.expect(background(0) != background(1));
    try testing.expectEqual(background(0), background(360));
    var f: u64 = 0;
    while (f < 360) : (f += 1) {
        try testing.expect(background(f) <= 0x00FF_FFFF);
    }
}
