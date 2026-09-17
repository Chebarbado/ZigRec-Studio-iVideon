//! Рисование аннотаций (#28): текст, стрелка, выноска — в окне и в кадре.
//!
//! Одно место для двух потребителей: предпросмотр рисует на своём DC, а
//! экспорт — на DIB-секции, куда кладёт кадр и откуда забирает обратно.
//! Раскладка (где и какого размера) — чистая арифметика с тестами:
//! тысячные доли кадра переводятся в точки прямоугольника, в который
//! кадр вписан. Шрифт — доля высоты кадра, чтобы в экспорте 1080p и в
//! предпросмотре 400 точек надпись занимала одну и ту же часть картинки.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;
const annotations = @import("../edit/annotations.zig");

pub const Point = struct { x: i32, y: i32 };

/// Прямоугольник кадра на поверхности рисования.
pub const Frame = struct {
    left: i32,
    top: i32,
    width: i32,
    height: i32,

    /// Точка кадра из тысячных долей.
    pub fn at(self: Frame, mille_x: i32, mille_y: i32) Point {
        return .{
            .x = self.left + @divTrunc(mille_x * self.width, annotations.per_mille),
            .y = self.top + @divTrunc(mille_y * self.height, annotations.per_mille),
        };
    }

    /// Обратно: из точки — тысячные доли, прижатые к кадру.
    pub fn mille(self: Frame, x: i32, y: i32) Point {
        if (self.width <= 0 or self.height <= 0) return .{ .x = 0, .y = 0 };
        return .{
            .x = std.math.clamp(@divTrunc((x - self.left) * annotations.per_mille, self.width), 0, annotations.per_mille),
            .y = std.math.clamp(@divTrunc((y - self.top) * annotations.per_mille, self.height), 0, annotations.per_mille),
        };
    }

    /// Высота шрифта: сороковая часть высоты кадра, не меньше десяти точек.
    pub fn fontHeight(self: Frame) i32 {
        return @max(@divTrunc(self.height, 40), 10);
    }

    /// Толщина линий стрелки: доля высоты, не тоньше двух точек.
    pub fn stroke(self: Frame) i32 {
        return @max(@divTrunc(self.height, 240), 2);
    }
};

/// Три точки наконечника стрелки, идущей из (x1,y1) в (x2,y2):
/// остриё и два крыла длиной `size`.
pub fn arrowHead(x1: i32, y1: i32, x2: i32, y2: i32, size: i32) [3]Point {
    const dx: f32 = @floatFromInt(x2 - x1);
    const dy: f32 = @floatFromInt(y2 - y1);
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1) return .{ .{ .x = x2, .y = y2 }, .{ .x = x2, .y = y2 }, .{ .x = x2, .y = y2 } };
    const ux = dx / len;
    const uy = dy / len;
    const s: f32 = @floatFromInt(size);
    // Крылья — назад от острия и в стороны.
    const bx = @as(f32, @floatFromInt(x2)) - ux * s;
    const by = @as(f32, @floatFromInt(y2)) - uy * s;
    const wx = -uy * s * 0.5;
    const wy = ux * s * 0.5;
    return .{
        .{ .x = x2, .y = y2 },
        .{ .x = @intFromFloat(bx + wx), .y = @intFromFloat(by + wy) },
        .{ .x = @intFromFloat(bx - wx), .y = @intFromFloat(by - wy) },
    };
}

fn wide(buf: []u16, text: []const u8) []u16 {
    const n = std.unicode.utf8ToUtf16Le(buf, text) catch 0;
    return buf[0..n];
}

/// Нарисовать одну аннотацию на DC внутри кадра.
pub fn drawOnDc(dc: c.HDC, a: annotations.Annotation, frame: Frame) void {
    if (builtin.os.tag != .windows) return;
    const colour: c.COLORREF = a.colour.rgb();
    const p = frame.at(a.x, a.y);
    const stroke = frame.stroke();

    if (a.kind == .arrow) {
        const q = frame.at(a.x2, a.y2);
        const pen = c.CreatePen(c.PS_SOLID, stroke, colour);
        defer _ = c.DeleteObject(@ptrCast(pen));
        const brush = c.CreateSolidBrush(colour);
        defer _ = c.DeleteObject(@ptrCast(brush));
        const old_pen = c.SelectObject(dc, @ptrCast(pen));
        const old_brush = c.SelectObject(dc, @ptrCast(brush));
        _ = c.MoveToEx(dc, p.x, p.y, null);
        _ = c.LineTo(dc, q.x, q.y);
        const head = arrowHead(p.x, p.y, q.x, q.y, stroke * 5);
        var poly: [3]c.POINT = undefined;
        for (head, 0..) |h, i| poly[i] = .{ .x = h.x, .y = h.y };
        _ = c.Polygon(dc, &poly, 3);
        _ = c.SelectObject(dc, old_pen);
        _ = c.SelectObject(dc, old_brush);
        return;
    }

    // Надпись: шрифт по кадру, подложка цветом аннотации, текст тёмный.
    var lf = std.mem.zeroes(c.LOGFONTW);
    lf.lfHeight = -frame.fontHeight();
    lf.lfWeight = c.FW_BOLD;
    lf.lfCharSet = c.DEFAULT_CHARSET;
    const face = "Segoe UI";
    for (face, 0..) |ch, i| lf.lfFaceName[i] = ch;
    const font = c.CreateFontIndirectW(&lf);
    defer _ = c.DeleteObject(@ptrCast(font));
    const old_font = c.SelectObject(dc, @ptrCast(font));
    defer _ = c.SelectObject(dc, old_font);

    var wbuf: [annotations.max_text * 2 + 2]u16 = undefined;
    const text = a.title();
    const shown = if (text.len > 0) text else a.kind.label();
    const w = wide(&wbuf, shown);
    var size: c.SIZE = std.mem.zeroes(c.SIZE);
    _ = c.GetTextExtentPoint32W(dc, @ptrCast(w.ptr), @intCast(w.len), &size);
    const pad = @divTrunc(frame.fontHeight(), 2);
    const box = c.RECT{
        .left = p.x,
        .top = p.y,
        .right = p.x + size.cx + pad * 2,
        .bottom = p.y + size.cy + pad,
    };

    if (a.kind == .callout) {
        // Указка — от нижнего края подложки к цели.
        const q = frame.at(a.x2, a.y2);
        const pen = c.CreatePen(c.PS_SOLID, stroke, colour);
        defer _ = c.DeleteObject(@ptrCast(pen));
        const old_pen = c.SelectObject(dc, @ptrCast(pen));
        _ = c.MoveToEx(dc, @divTrunc(box.left + box.right, 2), box.bottom, null);
        _ = c.LineTo(dc, q.x, q.y);
        _ = c.SelectObject(dc, old_pen);
        const dot = c.CreateSolidBrush(colour);
        defer _ = c.DeleteObject(@ptrCast(dot));
        const old_brush = c.SelectObject(dc, @ptrCast(dot));
        const r = stroke * 2;
        _ = c.Ellipse(dc, q.x - r, q.y - r, q.x + r, q.y + r);
        _ = c.SelectObject(dc, old_brush);
    }

    const back = c.CreateSolidBrush(colour);
    defer _ = c.DeleteObject(@ptrCast(back));
    _ = c.FillRect(dc, &box, back);
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    _ = c.SetTextColor(dc, 0x00202020);
    _ = c.TextOutW(dc, box.left + pad, box.top + @divTrunc(pad, 2), @ptrCast(w.ptr), @intCast(w.len));
}

/// Впечатать все видимые в момент `when_ns` аннотации в кадр BGRA.
///
/// Кадр кладётся в DIB-секцию того же размера, рисуется GDI и забирается
/// обратно. Дорого (две копии кадра), поэтому только когда есть что рисовать.
pub fn paintFrame(pixels: []u8, stride: usize, width: u32, height: u32, list: []const annotations.Annotation, when_ns: u64) void {
    if (builtin.os.tag != .windows) return;
    var any = false;
    for (list) |a| {
        if (a.visibleAt(when_ns)) any = true;
    }
    if (!any or width == 0 or height == 0) return;

    var info = std.mem.zeroes(c.BITMAPINFO);
    info.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    info.bmiHeader.biWidth = @intCast(width);
    info.bmiHeader.biHeight = -@as(i32, @intCast(height));
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = c.BI_RGB;

    const screen_dc = c.GetDC(null);
    defer _ = c.ReleaseDC(null, screen_dc);
    const dc = c.CreateCompatibleDC(screen_dc);
    if (dc == null) return;
    defer _ = c.DeleteDC(dc);
    var bits: ?*anyopaque = null;
    const dib = c.CreateDIBSection(dc, &info, c.DIB_RGB_COLORS, &bits, null, 0);
    if (dib == null or bits == null) return;
    defer _ = c.DeleteObject(@ptrCast(dib));
    const old = c.SelectObject(dc, @ptrCast(dib));
    defer _ = c.SelectObject(dc, old);

    const row_bytes: usize = @as(usize, width) * 4;
    const dst: [*]u8 = @ptrCast(bits.?);
    var y: usize = 0;
    while (y < height) : (y += 1) {
        @memcpy(dst[y * row_bytes ..][0..row_bytes], pixels[y * stride ..][0..row_bytes]);
    }

    const frame = Frame{ .left = 0, .top = 0, .width = @intCast(width), .height = @intCast(height) };
    for (list) |a| {
        if (a.visibleAt(when_ns)) drawOnDc(dc, a, frame);
    }
    _ = c.GdiFlush();

    y = 0;
    while (y < height) : (y += 1) {
        @memcpy(pixels[y * stride ..][0..row_bytes], dst[y * row_bytes ..][0..row_bytes]);
    }
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;

test "тысячные доли переводятся в точки кадра и обратно" {
    const f = Frame{ .left = 100, .top = 50, .width = 400, .height = 200 };
    const p = f.at(500, 250);
    try testing.expectEqual(@as(i32, 300), p.x);
    try testing.expectEqual(@as(i32, 100), p.y);
    const m = f.mille(300, 100);
    try testing.expectEqual(@as(i32, 500), m.x);
    try testing.expectEqual(@as(i32, 250), m.y);
    // За кадром — прижимается.
    try testing.expectEqual(@as(i32, 0), f.mille(-10, 60).x);
    try testing.expectEqual(annotations.per_mille, f.mille(9999, 60).x);
    // Пустой кадр не делит на ноль.
    try testing.expectEqual(@as(i32, 0), (Frame{ .left = 0, .top = 0, .width = 0, .height = 0 }).mille(5, 5).x);
}

test "шрифт и толщина — доля высоты кадра, с нижним пределом" {
    try testing.expectEqual(@as(i32, 27), (Frame{ .left = 0, .top = 0, .width = 1920, .height = 1080 }).fontHeight());
    try testing.expectEqual(@as(i32, 10), (Frame{ .left = 0, .top = 0, .width = 100, .height = 100 }).fontHeight());
    try testing.expectEqual(@as(i32, 4), (Frame{ .left = 0, .top = 0, .width = 1920, .height = 1080 }).stroke());
    try testing.expectEqual(@as(i32, 2), (Frame{ .left = 0, .top = 0, .width = 100, .height = 100 }).stroke());
}

test "наконечник стрелки смотрит остриём в конец" {
    const h = arrowHead(0, 0, 100, 0, 10);
    try testing.expectEqual(@as(i32, 100), h[0].x);
    try testing.expectEqual(@as(i32, 0), h[0].y);
    try testing.expectEqual(@as(i32, 90), h[1].x);
    try testing.expectEqual(@as(i32, 5), h[1].y);
    try testing.expectEqual(@as(i32, -5), h[2].y);
    // Нулевая стрелка не делит на ноль.
    const z = arrowHead(5, 5, 5, 5, 10);
    try testing.expectEqual(@as(i32, 5), z[1].x);
}

test "впечатывание красит подложку цветом аннотации" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var buf: [200 * 100 * 4]u8 = @splat(0);
    const list = [_]annotations.Annotation{.{ .at_ns = 0, .len_ns = std.time.ns_per_s, .kind = .text, .x = 100, .y = 100, .colour = .yellow }};
    paintFrame(&buf, 200 * 4, 200, 100, &list, 0);
    // Подложка начинается в (20,10); чуть правее и ниже — её цвет.
    // COLORREF жёлтого 0x0020C8E8 — это 0x00bbggrr: B=0x20, G=0xC8, R=0xE8;
    // в буфере BGRA байты идут B, G, R. Первый заход теста перепутал порядок.
    const at = (12 * 200 + 24) * 4;
    try testing.expectEqual(@as(u8, 0x20), buf[at]);
    try testing.expectEqual(@as(u8, 0xC8), buf[at + 1]);
    try testing.expectEqual(@as(u8, 0xE8), buf[at + 2]);
    // Вне времени — ничего не тронуто.
    var buf2: [200 * 100 * 4]u8 = @splat(0);
    paintFrame(&buf2, 200 * 4, 200, 100, &list, 5 * std.time.ns_per_s);
    try testing.expectEqual(@as(u8, 0), buf2[at]);
}
