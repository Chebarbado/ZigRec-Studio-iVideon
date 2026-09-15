//! Мигающая пунктирная рамка вокруг записываемой области.
//!
//! Пока идёт запись куска экрана, человек должен видеть границы этого куска,
//! не гадая по памяти. Рамка «бежит» пунктиром и плавно пульсирует — статичную
//! линию глаз перестаёт замечать через полминуты, а бегущая читается сразу.
//!
//! Рамка рисуется **снаружи** области, а не по её краю: иначе она попала бы
//! в кадр и осталась в готовом видео. Окно рамки прозрачно для мыши
//! (`WS_EX_TRANSPARENT`) — сквозь него можно работать, как будто его нет.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;
const types = @import("capture_types.zig");

pub const Rect = types.Rect;

/// Толщина рамки в пикселях.
pub const thickness: i32 = 3;
/// Длина штриха и промежутка.
const dash_on: i32 = 14;
const dash_off: i32 = 10;

const class_name = "ZigRecFrameOverlay";

/// `HWND_TOPMOST` — это -1, а не адрес: подставить его в поле-указатель нельзя,
/// Zig падает на проверке выравнивания. Объявляем `SetWindowPos` с целым
/// вторым параметром, как оно и есть на уровне вызова Windows.
const setWindowPosZ = @extern(
    *const fn (c.HWND, usize, i32, i32, i32, i32, c.UINT) callconv(.winapi) c.BOOL,
    .{ .name = "SetWindowPos" },
);
const hwnd_topmost: usize = @bitCast(@as(isize, -1));

/// Сдвиг пунктира и яркость на текущем шаге.
pub const Animation = struct {
    phase: i32 = 0,
    tick: u32 = 0,

    /// Шаг анимации: пунктир едет, яркость плавно дышит.
    pub fn step(self: *Animation) void {
        self.tick +%= 1;
        self.phase = @mod(self.phase + 2, dash_on + dash_off);
    }

    /// Прозрачность рамки от 140 до 255 по синусоиде.
    ///
    /// Не мигание «включено-выключено»: резкое мигание раздражает и мешает
    /// смотреть на то, что под рамкой. Плавная волна заметна боковым зрением
    /// и не отвлекает.
    pub fn alpha(self: Animation) u8 {
        const period: f32 = 40; // шагов на полный цикл
        const t = @as(f32, @floatFromInt(self.tick % @as(u32, @intFromFloat(period))));
        const wave = (1 + @sin(t / period * std.math.tau)) / 2; // 0…1
        return @intFromFloat(140 + wave * 115);
    }
};

var animation: Animation = .{};
var overlay: c.HWND = null;
var overlay_area: Rect = .{ .width = 0, .height = 0 };

fn wndProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const dc = c.BeginPaint(hwnd, &ps);
            paint(hwnd, dc);
            _ = c.EndPaint(hwnd, &ps);
            return 0;
        },
        // Ни мыши, ни фокуса: рамка только показывает, но ничего не ловит.
        c.WM_NCHITTEST => return -1, // HTTRANSPARENT
        c.WM_ERASEBKGND => return 1,
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wp, lp);
}

/// Нарисовать бегущий пунктир по четырём сторонам.
fn paint(hwnd: c.HWND, dc: c.HDC) void {
    var rc: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &rc);

    // Фон окна — цвет-ключ, он станет прозрачным (см. SetLayeredWindowAttributes).
    const back = c.CreateSolidBrush(key_color);
    _ = c.FillRect(dc, &rc, back);
    _ = c.DeleteObject(back);

    const ink = c.CreateSolidBrush(0x002E4CE8); // тёплый красный в BGR
    defer _ = c.DeleteObject(ink);

    const w = rc.right;
    const h = rc.bottom;
    const t = thickness;
    const step = dash_on + dash_off;

    // Верх и низ.
    var x: i32 = -animation.phase;
    while (x < w) : (x += step) {
        var seg = c.RECT{ .left = @max(x, 0), .top = 0, .right = @min(x + dash_on, w), .bottom = t };
        if (seg.right > seg.left) _ = c.FillRect(dc, &seg, ink);
        var seg2 = c.RECT{ .left = @max(x, 0), .top = h - t, .right = @min(x + dash_on, w), .bottom = h };
        if (seg2.right > seg2.left) _ = c.FillRect(dc, &seg2, ink);
    }
    // Бока: пунктир едет в другую сторону, чтобы рамка выглядела как единое кольцо.
    var y: i32 = -@mod(step - animation.phase, step);
    while (y < h) : (y += step) {
        var seg = c.RECT{ .left = 0, .top = @max(y, 0), .right = t, .bottom = @min(y + dash_on, h) };
        if (seg.bottom > seg.top) _ = c.FillRect(dc, &seg, ink);
        var seg2 = c.RECT{ .left = w - t, .top = @max(y, 0), .right = w, .bottom = @min(y + dash_on, h) };
        if (seg2.bottom > seg2.top) _ = c.FillRect(dc, &seg2, ink);
    }
}

/// Цвет, который становится прозрачным. Взят заведомо «неживой», чтобы
/// случайно не совпасть с цветом рамки.
const key_color: c.COLORREF = 0x00FF00FF;

/// Показать рамку вокруг области (координаты рабочего стола, физические пиксели).
pub fn show(area: Rect) void {
    if (builtin.os.tag != .windows) return;
    hide();
    if (area.isEmpty()) return;

    const hinst: c.HINSTANCE = @ptrCast(c.GetModuleHandleW(null));
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinst;
    wc.lpszClassName = std.unicode.utf8ToUtf16LeStringLiteral(class_name);
    _ = c.RegisterClassExW(&wc);

    const t = thickness;
    const outer_x = area.x - t;
    const outer_y = area.y - t;
    const outer_w = @as(i32, @intCast(area.width)) + t * 2;
    const outer_h = @as(i32, @intCast(area.height)) + t * 2;

    overlay = c.CreateWindowExW(
        c.WS_EX_TOPMOST | c.WS_EX_LAYERED | c.WS_EX_TRANSPARENT | c.WS_EX_TOOLWINDOW | c.WS_EX_NOACTIVATE,
        std.unicode.utf8ToUtf16LeStringLiteral(class_name),
        std.unicode.utf8ToUtf16LeStringLiteral("ZigRec"),
        c.WS_POPUP,
        outer_x,
        outer_y,
        outer_w,
        outer_h,
        null,
        null,
        hinst,
        null,
    );
    if (overlay == null) return;
    overlay_area = area;

    // Вырезаем середину: окно — это только рамка, а не прямоугольник поверх
    // записываемого. Иначе рамка попала бы в кадр и осталась в видео.
    const outer_rgn = c.CreateRectRgn(0, 0, outer_w, outer_h);
    const inner_rgn = c.CreateRectRgn(t, t, outer_w - t, outer_h - t);
    _ = c.CombineRgn(outer_rgn, outer_rgn, inner_rgn, c.RGN_DIFF);
    _ = c.DeleteObject(inner_rgn);
    _ = c.SetWindowRgn(overlay, outer_rgn, 1); // окно владеет областью, удалять нельзя

    _ = c.SetLayeredWindowAttributes(overlay, key_color, 255, c.LWA_COLORKEY | c.LWA_ALPHA);
    _ = c.ShowWindow(overlay, c.SW_SHOWNOACTIVATE);
}

/// Шаг анимации: вызывается по таймеру окна записи.
pub fn animate() void {
    if (builtin.os.tag != .windows or overlay == null) return;
    animation.step();
    _ = c.SetLayeredWindowAttributes(overlay, key_color, animation.alpha(), c.LWA_COLORKEY | c.LWA_ALPHA);
    _ = c.InvalidateRect(overlay, null, 0);
    // Рамка должна оставаться поверх, даже если сверху открыли другое окно.
    _ = setWindowPosZ(overlay, hwnd_topmost, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE);
}

pub fn hide() void {
    if (builtin.os.tag != .windows) return;
    if (overlay) |h| {
        _ = c.DestroyWindow(h);
        overlay = null;
    }
    animation = .{};
}

/// Текущая прозрачность рамки. Нужна кнопкам: их значок дышит в такт с рамкой.
pub fn currentAlpha() u8 {
    return animation.alpha();
}

pub fn isShown() bool {
    return overlay != null;
}

// ---------------------------------------------------------------- тесты

test "пунктир едет по кругу и не убегает за период" {
    var a = Animation{};
    const period = dash_on + dash_off;
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        a.step();
        try std.testing.expect(a.phase >= 0 and a.phase < period);
    }
}

test "яркость дышит в заданных пределах" {
    var a = Animation{};
    var min: u8 = 255;
    var max: u8 = 0;
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        a.step();
        const v = a.alpha();
        min = @min(min, v);
        max = @max(max, v);
    }
    try std.testing.expect(min >= 140);
    try std.testing.expect(max <= 255);
    // Волна должна быть заметной, а не дрожанием на пару единиц.
    try std.testing.expect(max - min > 80);
}

test "яркость меняется плавно, без скачков" {
    var a = Animation{};
    var prev = a.alpha();
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        a.step();
        const now = a.alpha();
        const jump = if (now > prev) now - prev else prev - now;
        try std.testing.expect(jump < 25);
        prev = now;
    }
}
