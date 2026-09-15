//! Курсор в кадре: форма, подсветка, вспышка на клик.
//!
//! Задача #15. Захват отдаёт рабочий стол **без курсора** — и DXGI, и GDI без
//! `CAPTUREBLT` рисуют только окна. Для скринкаста это никуда не годится:
//! человек показывает мышью, а на записи её нет.
//!
//! Поэтому курсор дорисовываем сами. Заодно это даёт то, чего нет у системного
//! курсора: подсветку под указателем и вспышку на клик, чтобы зритель видел,
//! куда нажали.
//!
//! Форма курсора кэшируется по его дескриптору: система меняет курсор десятки
//! раз в секунду (стрелка, текст, рука), но сами формы повторяются.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;
const types = @import("capture_types.zig");

pub const Rect = types.Rect;

pub const Options = struct {
    /// Рисовать ли курсор вообще.
    draw: bool = true,
    /// Круг под курсором.
    highlight: bool = true,
    /// Вспышка при нажатии.
    clicks: bool = true,
    /// Радиус круга подсветки в пикселях.
    radius: u32 = 24,
    /// Сколько живёт вспышка клика.
    flash_ms: u32 = 350,
};

/// Цвета в BGRA. Левая кнопка тёплая, правая холодная: на записи сразу видно,
/// какой кнопкой нажали, без всяких подписей.
pub const colors = struct {
    pub const halo = [4]u8{ 40, 190, 255, 60 }; // мягкий янтарный, полупрозрачный
    pub const left = [4]u8{ 40, 190, 255, 150 };
    pub const right = [4]u8{ 255, 140, 40, 150 };
};

/// Смешать цвет с фоном по альфе. Без гаммы: разница на глаз незаметна,
/// а деление на каждый пиксель заметно очень.
pub fn blend(dst: []u8, src: [4]u8, strength: u32) void {
    const a: u32 = @min(@as(u32, src[3]) * strength / 255, 255);
    if (a == 0) return;
    inline for (0..3) |i| {
        const s: u32 = src[i];
        const d: u32 = dst[i];
        dst[i] = @intCast((s * a + d * (255 - a)) / 255);
    }
}

/// Одна снятая форма курсора: пиксели BGRA и точка привязки.
pub const Shape = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    hot_x: i32,
    hot_y: i32,
    handle: ?*anyopaque = null,
};

/// Рисовальщик курсора поверх кадра.
pub const Painter = struct {
    allocator: std.mem.Allocator,
    opt: Options,
    shape: ?Shape = null,
    /// Когда была вспышка и какой кнопкой.
    flash_ns: u64 = 0,
    flash_right: bool = false,
    left_was_down: bool = false,
    right_was_down: bool = false,

    pub fn init(allocator: std.mem.Allocator, opt: Options) Painter {
        return .{ .allocator = allocator, .opt = opt };
    }

    pub fn deinit(self: *Painter) void {
        if (self.shape) |s| self.allocator.free(s.pixels);
        self.shape = null;
    }

    /// Опросить мышь и обновить состояние вспышки. Вызывается на каждом кадре.
    pub fn poll(self: *Painter, now_ns: u64) void {
        if (builtin.os.tag != .windows or !self.opt.clicks) return;
        const left_down = (c.GetAsyncKeyState(c.VK_LBUTTON) & @as(c_short, @bitCast(@as(u16, 0x8000)))) != 0;
        const right_down = (c.GetAsyncKeyState(c.VK_RBUTTON) & @as(c_short, @bitCast(@as(u16, 0x8000)))) != 0;
        // Вспышка на нажатии, а не на отпускании: зритель должен увидеть щелчок
        // одновременно с тем, как на экране что-то произошло.
        if (left_down and !self.left_was_down) {
            self.flash_ns = now_ns;
            self.flash_right = false;
        } else if (right_down and !self.right_was_down) {
            self.flash_ns = now_ns;
            self.flash_right = true;
        }
        self.left_was_down = left_down;
        self.right_was_down = right_down;
    }

    /// Сила вспышки от 0 до 255: сразу после клика ярко, потом гаснет.
    pub fn flashStrength(self: Painter, now_ns: u64) u32 {
        if (self.flash_ns == 0) return 0;
        const life = @as(u64, self.opt.flash_ms) * std.time.ns_per_ms;
        const passed = now_ns -| self.flash_ns;
        if (passed >= life) return 0;
        return @intCast(255 - passed * 255 / life);
    }

    /// Положение курсора в координатах рабочего стола или `null`, если он скрыт.
    pub fn position(self: *Painter) ?struct { x: i32, y: i32 } {
        _ = self;
        if (builtin.os.tag != .windows) return null;
        var info = std.mem.zeroes(c.CURSORINFO);
        info.cbSize = @sizeOf(c.CURSORINFO);
        if (c.GetCursorInfo(&info) == 0) return null;
        if (info.flags & c.CURSOR_SHOWING == 0) return null;
        return .{ .x = info.ptScreenPos.x, .y = info.ptScreenPos.y };
    }

    /// Снять текущую форму курсора, если она сменилась.
    fn ensureShape(self: *Painter) ?Shape {
        if (builtin.os.tag != .windows) return null;
        var info = std.mem.zeroes(c.CURSORINFO);
        info.cbSize = @sizeOf(c.CURSORINFO);
        if (c.GetCursorInfo(&info) == 0) return null;
        if (info.flags & c.CURSOR_SHOWING == 0) return null;
        const handle: ?*anyopaque = @ptrCast(info.hCursor);
        if (self.shape) |s| {
            if (s.handle == handle) return s;
            self.allocator.free(s.pixels);
            self.shape = null;
        }
        self.shape = grabShape(self.allocator, info.hCursor) catch null;
        if (self.shape) |*s| s.handle = handle;
        return self.shape;
    }

    /// Нарисовать курсор поверх кадра. `origin` — левый верхний угол кадра
    /// в координатах рабочего стола.
    pub fn paint(self: *Painter, dst: []u8, stride: u32, area: Rect, origin_x: i32, origin_y: i32, now_ns: u64) void {
        if (builtin.os.tag != .windows or !self.opt.draw) return;
        const pos = self.position() orelse return;
        const x = pos.x - origin_x;
        const y = pos.y - origin_y;

        if (self.opt.highlight) {
            self.circle(dst, stride, area, x, y, self.opt.radius, colors.halo, 255);
        }
        const flash = self.flashStrength(now_ns);
        if (flash > 0) {
            const color = if (self.flash_right) colors.right else colors.left;
            // Кольцо расходится: так вспышка читается как «щёлкнули»,
            // а не как «тут что-то подсвечено».
            const grow = self.opt.radius + (255 - flash) * self.opt.radius / 255;
            self.circle(dst, stride, area, x, y, grow, color, flash);
        }

        const shape = self.ensureShape() orelse return;
        drawShape(dst, stride, area, shape, x, y);
    }

    fn circle(self: Painter, dst: []u8, stride: u32, area: Rect, cx: i32, cy: i32, r: u32, color: [4]u8, strength: u32) void {
        _ = self;
        const ri: i32 = @intCast(r);
        const rr: i32 = ri * ri;
        var dy: i32 = -ri;
        while (dy <= ri) : (dy += 1) {
            const py = cy + dy;
            if (py < 0 or py >= area.height) continue;
            var dx: i32 = -ri;
            while (dx <= ri) : (dx += 1) {
                const px = cx + dx;
                if (px < 0 or px >= area.width) continue;
                const d2 = dx * dx + dy * dy;
                if (d2 > rr) continue;
                // К краю мягче: резкий круг выглядит как наклейка.
                const edge: u32 = @intCast(255 - @divTrunc(d2 * 255, @max(rr, 1)));
                const o = @as(usize, @intCast(py)) * stride + @as(usize, @intCast(px)) * 4;
                if (o + 4 > dst.len) continue;
                blend(dst[o..][0..4], color, edge * strength / 255);
            }
        }
    }
};

fn drawShape(dst: []u8, stride: u32, area: Rect, shape: Shape, x: i32, y: i32) void {
    const left = x - shape.hot_x;
    const top = y - shape.hot_y;
    var sy: u32 = 0;
    while (sy < shape.height) : (sy += 1) {
        const py = top + @as(i32, @intCast(sy));
        if (py < 0 or py >= area.height) continue;
        var sx: u32 = 0;
        while (sx < shape.width) : (sx += 1) {
            const px = left + @as(i32, @intCast(sx));
            if (px < 0 or px >= area.width) continue;
            const si = (sy * shape.width + sx) * 4;
            const a = shape.pixels[si + 3];
            if (a == 0) continue;
            const o = @as(usize, @intCast(py)) * stride + @as(usize, @intCast(px)) * 4;
            if (o + 4 > dst.len) continue;
            blend(dst[o..][0..4], .{
                shape.pixels[si],
                shape.pixels[si + 1],
                shape.pixels[si + 2],
                a,
            }, 255);
        }
    }
}

/// Снять картинку курсора в BGRA.
///
/// Рисуем курсор `DrawIconEx` на прозрачный DIB, а не разбираем маски руками:
/// у курсоров три разных устройства (цветной с альфой, цветной с маской,
/// чёрно-белый), и системная отрисовка знает про все три.
fn grabShape(allocator: std.mem.Allocator, hcursor: c.HCURSOR) !Shape {
    if (builtin.os.tag != .windows) return error.Unsupported;

    var info: c.ICONINFO = undefined;
    if (c.GetIconInfo(hcursor, &info) == 0) return error.NoCursor;
    defer {
        if (info.hbmColor != null) _ = c.DeleteObject(info.hbmColor);
        if (info.hbmMask != null) _ = c.DeleteObject(info.hbmMask);
    }

    var bm: c.BITMAP = undefined;
    const src = if (info.hbmColor != null) info.hbmColor else info.hbmMask;
    if (c.GetObjectA(src, @sizeOf(c.BITMAP), &bm) == 0) return error.NoCursor;
    const width: u32 = @intCast(bm.bmWidth);
    // У чёрно-белого курсора маска вдвое выше картинки: сверху AND, снизу XOR.
    const height: u32 = if (info.hbmColor != null) @intCast(bm.bmHeight) else @intCast(@divTrunc(bm.bmHeight, 2));
    if (width == 0 or height == 0 or width > 512 or height > 512) return error.NoCursor;

    const screen_dc = c.GetDC(null) orelse return error.NoCursor;
    defer _ = c.ReleaseDC(null, screen_dc);
    const mem_dc = c.CreateCompatibleDC(screen_dc) orelse return error.NoCursor;
    defer _ = c.DeleteDC(mem_dc);

    var bmi = std.mem.zeroes(c.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = @intCast(width);
    bmi.bmiHeader.biHeight = -@as(i32, @intCast(height));
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = c.BI_RGB;

    var bits: ?*anyopaque = null;
    const dib = c.CreateDIBSection(screen_dc, &bmi, c.DIB_RGB_COLORS, &bits, null, 0) orelse return error.NoCursor;
    defer _ = c.DeleteObject(dib);
    const old = c.SelectObject(mem_dc, dib);
    defer _ = c.SelectObject(mem_dc, old);

    const bytes = @as(usize, width) * @as(usize, height) * 4;
    const raw: [*]u8 = @ptrCast(bits.?);
    @memset(raw[0..bytes], 0);
    if (c.DrawIconEx(mem_dc, 0, 0, hcursor, 0, 0, 0, null, c.DI_NORMAL) == 0) return error.NoCursor;
    _ = c.GdiFlush();

    const pixels = try allocator.alloc(u8, bytes);
    @memcpy(pixels, raw[0..bytes]);

    // У чёрно-белых курсоров альфа нулевая: там, где нарисовано, ставим
    // непрозрачность руками, иначе стрелка окажется невидимой.
    var opaque_count: usize = 0;
    var i: usize = 3;
    while (i < bytes) : (i += 4) {
        if (pixels[i] != 0) opaque_count += 1;
    }
    if (opaque_count == 0) {
        i = 0;
        while (i < bytes) : (i += 4) {
            const lit = pixels[i] != 0 or pixels[i + 1] != 0 or pixels[i + 2] != 0;
            pixels[i + 3] = if (lit) 255 else 0;
        }
    }

    return Shape{
        .pixels = pixels,
        .width = width,
        .height = height,
        .hot_x = @intCast(info.xHotspot),
        .hot_y = @intCast(info.yHotspot),
    };
}

// ---------------------------------------------------------------- тесты

test "смешивание: полная непрозрачность заменяет цвет" {
    var px = [_]u8{ 0, 0, 0, 255 };
    blend(&px, .{ 10, 20, 30, 255 }, 255);
    try std.testing.expectEqual(@as(u8, 10), px[0]);
    try std.testing.expectEqual(@as(u8, 20), px[1]);
    try std.testing.expectEqual(@as(u8, 30), px[2]);
}

test "смешивание: нулевая альфа не трогает фон" {
    var px = [_]u8{ 7, 8, 9, 255 };
    blend(&px, .{ 200, 200, 200, 0 }, 255);
    try std.testing.expectEqual(@as(u8, 7), px[0]);
}

test "смешивание: половина альфы даёт середину" {
    var px = [_]u8{ 0, 0, 0, 255 };
    blend(&px, .{ 200, 200, 200, 128 }, 255);
    try std.testing.expect(px[0] > 90 and px[0] < 110);
}

test "сила вспышки гаснет со временем" {
    var p = Painter.init(std.testing.allocator, .{ .flash_ms = 100 });
    defer p.deinit();
    p.flash_ns = 1_000_000_000;
    try std.testing.expectEqual(@as(u32, 255), p.flashStrength(1_000_000_000));
    const mid = p.flashStrength(1_050_000_000);
    try std.testing.expect(mid > 100 and mid < 160);
    try std.testing.expectEqual(@as(u32, 0), p.flashStrength(1_200_000_000));
}

test "без клика вспышки нет" {
    var p = Painter.init(std.testing.allocator, .{});
    defer p.deinit();
    try std.testing.expectEqual(@as(u32, 0), p.flashStrength(999));
}

test "круг рисуется внутри кадра и не вылезает за края" {
    const w: u32 = 40;
    const h: u32 = 20;
    const stride = w * 4;
    var buf = [_]u8{0} ** (40 * 20 * 4);
    var p = Painter.init(std.testing.allocator, .{});
    defer p.deinit();
    // Центр в углу: половина круга за кадром.
    p.circle(&buf, stride, .{ .width = w, .height = h }, 0, 0, 10, colors.halo, 255);
    // Пиксель в углу закрашен, дальний угол — нет.
    try std.testing.expect(buf[0] != 0 or buf[1] != 0 or buf[2] != 0);
    const far = (h - 1) * stride + (w - 1) * 4;
    try std.testing.expectEqual(@as(u8, 0), buf[far]);
}

test "форма курсора рисуется со сдвигом на точку привязки" {
    const w: u32 = 20;
    const h: u32 = 20;
    const stride = w * 4;
    var buf = [_]u8{0} ** (20 * 20 * 4);
    var shape_pixels = [_]u8{ 255, 255, 255, 255 } ** 4; // 2x2 белых пикселя
    const shape = Shape{
        .pixels = &shape_pixels,
        .width = 2,
        .height = 2,
        .hot_x = 1,
        .hot_y = 1,
    };
    drawShape(&buf, stride, .{ .width = w, .height = h }, shape, 10, 10);
    // Привязка (1,1) значит, что левый верхний угол формы лёг в (9,9).
    const at = 9 * stride + 9 * 4;
    try std.testing.expectEqual(@as(u8, 255), buf[at]);
    try std.testing.expectEqual(@as(u8, 0), buf[8 * stride + 8 * 4]);
}
