//! Окно пульта управления съёмкой.
//!
//! Задача #73. Маленькое окно поверх всех: время, стоп, пауза и здоровье
//! записи. Появляется вместе с записью и исчезает с ней — держать пульт
//! при выключенной записи незачем.
//!
//! **Не крадёт ввод.** `WS_EX_NOACTIVATE`: щёлкнул мимо — работаешь дальше,
//! и запись не прерывается оттого, что пульт перехватил клавиатуру.
//!
//! **Не попадает в собственную запись.** Куда встать, решает `remote.zig`
//! чистым счётом; здесь только показ.
//!
//! Что делать по нажатию, окно не знает: оно посылает сообщение окну записи.
//! Иначе пульту пришлось бы знать про рекордер, а это не его дело.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;
const remote = @import("remote.zig");
const lang = @import("../lang.zig");

/// Что нажали на пульте. Уходит окну записи сообщением `wm_remote`.
pub const Press = enum(usize) {
    stop = 1,
    pause = 2,
};

/// Сообщение окну записи: на пульте нажали кнопку.
pub const wm_remote = c.WM_APP + 5;

const class_name = "ZigRecRemote";

var hwnd: c.HWND = null;
/// Кому докладывать о нажатиях.
var owner: c.HWND = null;

/// Что показывать прямо сейчас. Обновляется окном записи по таймеру.
var shown = struct {
    elapsed_ns: u64 = 0,
    frames: u64 = 0,
    dropped: u64 = 0,
    state: remote.State = .recording,
    /// Пульт в кадре: записывают весь экран.
    in_frame: bool = false,
    /// Уровень звука, 0..1. Меньше нуля — звука нет вовсе.
    level: f32 = -1,
}{};

/// Где кнопки внутри пульта. Считает `remote.zig` — там это проверяется
/// тестом, а здесь проверялось бы глазом.
fn winRect(r: remote.Rect) c.RECT {
    return .{ .left = r.x, .top = r.y, .right = r.right(), .bottom = r.bottom() };
}

fn stopRect() c.RECT {
    return winRect(remote.stopButton());
}

fn pauseRect() c.RECT {
    return winRect(remote.pauseButton());
}

fn hit(what: c.RECT, x: i32, y: i32) bool {
    return x >= what.left and x < what.right and y >= what.top and y < what.bottom;
}

/// Показать пульт. `area` — что снимаем, в координатах рабочего стола.
pub fn show(to: c.HWND, screen: remote.Rect, area: remote.Rect, whole_screen: bool) void {
    if (builtin.os.tag != .windows) return;
    hide();

    owner = to;
    const spot = remote.place(screen, area, whole_screen);
    shown.in_frame = spot.in_frame;

    const hinst: c.HINSTANCE = @ptrCast(c.GetModuleHandleW(null));
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinst;
    wc.lpszClassName = std.unicode.utf8ToUtf16LeStringLiteral(class_name);
    wc.hbrBackground = null; // рисуем сами, в буфере
    _ = c.RegisterClassExW(&wc);

    hwnd = c.CreateWindowExW(
        c.WS_EX_TOPMOST | c.WS_EX_TOOLWINDOW | c.WS_EX_NOACTIVATE,
        std.unicode.utf8ToUtf16LeStringLiteral(class_name),
        lang.tw("Пульт"),
        c.WS_POPUP | c.WS_BORDER,
        spot.at.x,
        spot.at.y,
        spot.at.w,
        spot.at.h,
        null,
        null,
        hinst,
        null,
    );
    if (hwnd == null) return;
    _ = c.ShowWindow(hwnd, c.SW_SHOWNOACTIVATE);
}

pub fn hide() void {
    if (builtin.os.tag != .windows or hwnd == null) return;
    _ = c.DestroyWindow(hwnd);
    hwnd = null;
}

pub fn visible() bool {
    return hwnd != null;
}

/// Попадает ли пульт в кадр.
pub fn inFrame() bool {
    return hwnd != null and shown.in_frame;
}

/// Обновить показания. Зовётся окном записи по своему таймеру.
pub fn update(elapsed_ns: u64, frames: u64, dropped: u64, paused: bool, level: f32) void {
    if (hwnd == null) return;
    shown.elapsed_ns = elapsed_ns;
    shown.frames = frames;
    shown.dropped = dropped;
    shown.state = if (paused) .paused else .recording;
    shown.level = level;
    _ = c.InvalidateRect(hwnd, null, 0);
}

fn wndProc(window: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const dc = c.BeginPaint(window, &ps);
            paintBuffered(window, dc);
            _ = c.EndPaint(window, &ps);
            return 0;
        },
        c.WM_ERASEBKGND => return 1,
        c.WM_LBUTTONDOWN => {
            const x = loWord(lp);
            const y = hiWord(lp);
            if (hit(stopRect(), x, y)) {
                tell(.stop);
                return 0;
            }
            if (hit(pauseRect(), x, y)) {
                tell(.pause);
                return 0;
            }
            // Мимо кнопок — тянем пульт за любое место. Заголовка у него нет,
            // и хвататься больше не за что.
            _ = c.ReleaseCapture();
            _ = c.SendMessageW(window, c.WM_NCLBUTTONDOWN, c.HTCAPTION, 0);
            return 0;
        },
        c.WM_DESTROY => {
            hwnd = null;
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(window, msg, wp, lp);
}

fn tell(what: Press) void {
    if (owner == null) return;
    _ = c.PostMessageW(owner, wm_remote, @intFromEnum(what), 0);
}

fn loWord(lp: c.LPARAM) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lp))))));
}

fn hiWord(lp: c.LPARAM) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lp)) >> 16))));
}

fn paintBuffered(window: c.HWND, dc: c.HDC) void {
    var rect: c.RECT = undefined;
    if (c.GetClientRect(window, &rect) == 0) return;
    const w = rect.right;
    const h = rect.bottom;
    if (w <= 0 or h <= 0) return;

    const mem = c.CreateCompatibleDC(dc);
    if (mem == null) return paint(dc, w, h);
    defer _ = c.DeleteDC(mem);
    const bmp = c.CreateCompatibleBitmap(dc, w, h);
    if (bmp == null) return paint(dc, w, h);
    defer _ = c.DeleteObject(@ptrCast(bmp));
    const old = c.SelectObject(mem, @ptrCast(bmp));
    defer _ = c.SelectObject(mem, old);

    paint(mem, w, h);
    _ = c.BitBlt(dc, 0, 0, w, h, mem, 0, 0, c.SRCCOPY);
}

fn paint(dc: c.HDC, w: i32, h: i32) void {
    fill(dc, .{ .left = 0, .top = 0, .right = w, .bottom = h }, 0x00303030);

    const font = c.GetStockObject(c.DEFAULT_GUI_FONT);
    const old_font = c.SelectObject(dc, font);
    defer _ = c.SelectObject(dc, old_font);
    _ = c.SetBkMode(dc, c.TRANSPARENT);

    // Красная точка: то же, чем помечают запись везде.
    const dot: c.COLORREF = if (shown.state == .paused) 0x00808080 else 0x003030E0;
    fill(dc, .{ .left = 12, .top = 16, .right = 26, .bottom = 30 }, dot);

    var buf: [64]u8 = undefined;
    text(dc, 34, 12, remote.timeText(&buf, shown.elapsed_ns), 0x00FFFFFF);

    var health: [64]u8 = undefined;
    text(dc, 12, 34, remote.healthText(&health, shown.frames, shown.dropped), 0x00B0B0B0);

    if (shown.in_frame) {
        const note = remote.noteAt();
        text(dc, note.x, note.y, remote.inFrameNote(), 0x0060A0F0);
    } else if (shown.level >= 0) {
        // Полоска уровня: видно, что звук идёт, не вслушиваясь.
        const cap = remote.levelCaption();
        text(dc, cap.x, cap.y, lang.t("звук"), 0x00808080);
        const bar = remote.levelBar();
        const lit: i32 = @intFromFloat(@min(shown.level, 1.0) * @as(f32, @floatFromInt(bar.w)));
        fill(dc, winRect(bar), 0x00202020);
        if (lit > 0) fill(dc, winRect(.{ .x = bar.x, .y = bar.y, .w = lit, .h = bar.h }), 0x0040C040);
    }

    button(dc, remote.stopButton(), .stop, remote.stopLabel());
    button(dc, remote.pauseButton(), remote.pauseIcon(shown.state), remote.pauseLabel(shown.state));
}

/// Влезла ли подпись в отведённое ей место и есть ли она в шрифте.
pub const Fit = struct {
    label: []const u8 = "",
    /// Сколько точек нужно подписи.
    need: i32 = 0,
    /// Сколько точек ей отведено.
    have: i32 = 0,
    /// Знак, которого в шрифте не оказалось. Ноль — все на месте.
    ///
    /// Отсутствующий знак не ломает ни вёрстку, ни замер: он рисуется
    /// пустым квадратиком ровно той же ширины. Увидеть это можно только
    /// глазами — или спросив у шрифта, что мы и делаем.
    missing: u21 = 0,

    pub fn fits(self: Fit) bool {
        return self.need <= self.have and self.missing == 0;
    }
};

pub const label_count = 4;

/// Померить подписи кнопок тем шрифтом, которым они рисуются.
///
/// Ширину кнопки мы считаем прикидкой «столько-то точек на букву»: в чистом
/// счёте взять неоткуда настоящий шрифт. Прикидка может разойтись с делом —
/// на другом языке системы, при другом масштабе экрана, — и разойдётся она
/// молча: подпись просто обрежется. Поэтому здесь спрашиваем у самой Windows.
pub fn measureLabels(out: *[label_count]Fit) []const Fit {
    const dc = c.CreateCompatibleDC(null);
    if (dc == null) return out[0..0];
    defer _ = c.DeleteDC(dc);

    const font = c.GetStockObject(c.DEFAULT_GUI_FONT);
    const old_font = c.SelectObject(dc, font);
    defer _ = c.SelectObject(dc, old_font);

    const items = [label_count]struct { label: []const u8, room: i32 }{
        .{ .label = remote.stopLabel(), .room = remote.labelRoom(remote.stopButton()) },
        .{ .label = remote.pauseLabel(.recording), .room = remote.labelRoom(remote.pauseButton()) },
        // Подпись меняется на ходу: мерить надо обе, а не ту, что видна сейчас.
        .{ .label = remote.pauseLabel(.paused), .room = remote.labelRoom(remote.pauseButton()) },
        // Строка о кадре рисуется без обрезки и молча уедет за край пульта.
        .{ .label = remote.inFrameNote(), .room = remote.noteAt().w },
    };

    for (items, 0..) |it, i| {
        var wide: [128]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wide, it.label) catch 0;
        var size: c.SIZE = std.mem.zeroes(c.SIZE);
        _ = c.GetTextExtentPoint32W(dc, @ptrCast(&wide), @intCast(n), &size);
        out[i] = .{
            .label = it.label,
            .need = size.cx,
            .have = it.room,
            .missing = missingGlyph(dc, wide[0..n], it.label),
        };
    }
    return out[0..label_count];
}

/// Знак, которого заведомо нет ни в одном шрифте: область частного
/// использования шестнадцатой плоскости. Нужен, чтобы проверить саму
/// проверку — молчаливо зелёная проверка хуже её отсутствия.
pub const absent_probe = "\u{10FFFD}";

/// Спросить у шрифта про произвольную строку. Ноль — все знаки на месте.
pub fn probeMissing(what: []const u8) u21 {
    const dc = c.CreateCompatibleDC(null);
    if (dc == null) return 0;
    defer _ = c.DeleteDC(dc);

    const font = c.GetStockObject(c.DEFAULT_GUI_FONT);
    const old_font = c.SelectObject(dc, font);
    defer _ = c.SelectObject(dc, old_font);

    var wide: [128]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, what) catch return 0;
    return missingGlyph(dc, wide[0..n], what);
}

/// Первый знак подписи, которого нет в шрифте. Ноль — все на месте.
fn missingGlyph(dc: c.HDC, wide: []const u16, label: []const u8) u21 {
    var glyphs: [128]u16 = undefined;
    const got = c.GetGlyphIndicesW(dc, @ptrCast(wide.ptr), @intCast(wide.len), &glyphs, c.GGI_MARK_NONEXISTING_GLYPHS);
    if (got == c.GDI_ERROR) return 0;

    for (glyphs[0..wide.len], 0..) |g, i| {
        if (g != 0xFFFF) continue;
        // Нашли дырку в шрифте. Назовём знак так, как он записан у нас,
        // а не суррогатной половинкой из UTF-16.
        var view = std.unicode.Utf8View.init(label) catch return '?';
        var it = view.iterator();
        var seen: usize = 0;
        while (it.nextCodepoint()) |cp| {
            if (seen >= i) return cp;
            seen += if (cp > 0xFFFF) 2 else 1;
        }
        return '?';
    }
    return 0;
}

fn button(dc: c.HDC, at: remote.Rect, icon: remote.Icon, label: []const u8) void {
    fill(dc, winRect(at), 0x00484848);
    var edge = winRect(at);
    const frame = c.CreateSolidBrush(0x00707070);
    defer _ = c.DeleteObject(@ptrCast(frame));
    _ = c.FrameRect(dc, &edge, frame);
    drawIcon(dc, icon, remote.iconAt(at));
    text(dc, remote.labelX(at), at.y + 8, label, 0x00FFFFFF);
}

/// Значки рисуем сами: в системном шрифте нет ни ⏸, ни ▶, и вместо них
/// на кнопке оказывается пустой квадратик.
fn drawIcon(dc: c.HDC, icon: remote.Icon, at: remote.Rect) void {
    const white: c.COLORREF = 0x00FFFFFF;
    switch (icon) {
        .stop => fill(dc, winRect(at), white),
        .pause => {
            // Две черты с просветом ровно посередине.
            const bar = @divTrunc(at.w - 2, 3);
            fill(dc, winRect(.{ .x = at.x, .y = at.y, .w = bar, .h = at.h }), white);
            fill(dc, winRect(.{ .x = at.right() - bar, .y = at.y, .w = bar, .h = at.h }), white);
        },
        .play => {
            // Треугольник строками: так не нужны ни кисть, ни перо.
            var i: i32 = 0;
            while (i < at.h) : (i += 1) {
                const from_edge = if (i < @divTrunc(at.h, 2)) i else at.h - 1 - i;
                const w = @min(at.w, (from_edge + 1) * 2);
                fill(dc, winRect(.{ .x = at.x, .y = at.y + i, .w = w, .h = 1 }), white);
            }
        },
    }
}

fn fill(dc: c.HDC, box: c.RECT, color: c.COLORREF) void {
    const brush = c.CreateSolidBrush(color);
    defer _ = c.DeleteObject(@ptrCast(brush));
    var r = box;
    _ = c.FillRect(dc, &r, brush);
}

fn text(dc: c.HDC, x: i32, y: i32, what: []const u8, color: c.COLORREF) void {
    var wide: [128]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, what) catch return;
    _ = c.SetTextColor(dc, color);
    _ = c.TextOutW(dc, x, y, @ptrCast(&wide), @intCast(n));
}
