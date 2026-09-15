//! Запасной захват экрана через GDI (`BitBlt` с рабочего стола).
//!
//! Задача #13. DXGI быстрее и не грузит процессор, но у него есть условие:
//! рабочий стол должен **презентовать** кадры. Если физический монитор погашен,
//! машина стоит без дисплея или человек работает с неё удалённо, презентов нет,
//! и `AcquireNextFrame` честно отдаёт таймаут — снимать в такой ситуации DXGI
//! просто нечего.
//!
//! GDI читает текущее содержимое рабочего стола и работает в этих условиях.
//! Он медленнее и тратит процессор, зато снимает всегда. Именно так снимал
//! CamStudio, и для него это был единственный путь.
//!
//! Отсюда правило выбора: DXGI, когда он даёт кадры; GDI, когда нет.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;
const types = @import("capture_types.zig");

pub const Error = types.Error;
pub const Frame = types.Frame;
pub const Rect = types.Rect;
pub const Stats = types.Stats;

/// Снимок рабочего стола средствами GDI.
pub const Grabber = struct {
    allocator: std.mem.Allocator,
    screen_dc: c.HDC = undefined,
    mem_dc: c.HDC = undefined,
    dib: c.HBITMAP = undefined,
    old_obj: c.HGDIOBJ = undefined,
    bits: [*]const u8 = undefined,
    area: Rect,
    stats: Stats = .{},
    /// Пиксели предыдущего кадра: GDI отдаёт снимок всегда, даже если на экране
    /// ничего не изменилось, и без этой проверки кодировщик получал бы поток
    /// одинаковых кадров.
    prev: []u8,
    have_prev: bool = false,

    pub fn init(allocator: std.mem.Allocator, area_opt: ?Rect) Error!Grabber {
        if (builtin.os.tag != .windows) return Error.Unsupported;
        _ = c.SetProcessDPIAware();

        const full = Rect{
            .x = 0,
            .y = 0,
            .width = @intCast(c.GetSystemMetrics(c.SM_CXSCREEN)),
            .height = @intCast(c.GetSystemMetrics(c.SM_CYSCREEN)),
        };
        const area = (area_opt orelse full).clampTo(full.width, full.height).evenSized();
        if (area.isEmpty()) return Error.NoOutput;

        const screen_dc = c.GetDC(null) orelse return Error.NoOutput;
        errdefer _ = c.ReleaseDC(null, screen_dc);
        const mem_dc = c.CreateCompatibleDC(screen_dc) orelse return Error.NoDevice;
        errdefer _ = c.DeleteDC(mem_dc);

        var bmi = std.mem.zeroes(c.BITMAPINFO);
        bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = @intCast(area.width);
        // Минус — строки сверху вниз, как у DXGI и у нашего стенда.
        bmi.bmiHeader.biHeight = -@as(i32, @intCast(area.height));
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = c.BI_RGB;

        var bits: ?*anyopaque = null;
        const dib = c.CreateDIBSection(screen_dc, &bmi, c.DIB_RGB_COLORS, &bits, null, 0) orelse return Error.OutOfMemory;
        errdefer _ = c.DeleteObject(dib);
        const old_obj = c.SelectObject(mem_dc, dib);

        const bytes = @as(usize, area.width) * @as(usize, area.height) * 4;
        const prev = try allocator.alloc(u8, bytes);

        return .{
            .allocator = allocator,
            .screen_dc = screen_dc,
            .mem_dc = mem_dc,
            .dib = dib,
            .old_obj = old_obj,
            .bits = @ptrCast(bits.?),
            .area = area,
            .prev = prev,
        };
    }

    pub fn deinit(self: *Grabber) void {
        if (builtin.os.tag != .windows) return;
        self.allocator.free(self.prev);
        _ = c.SelectObject(self.mem_dc, self.old_obj);
        _ = c.DeleteObject(self.dib);
        _ = c.DeleteDC(self.mem_dc);
        _ = c.ReleaseDC(null, self.screen_dc);
    }

    /// Следующий кадр или `null`, если картинка не изменилась.
    ///
    /// `timeout_ms` здесь не ожидание события, а верхняя граница ожидания
    /// изменения: снимаем, сравниваем, при совпадении ждём и пробуем ещё раз.
    pub fn next(self: *Grabber, timeout_ms: u32) Error!?Frame {
        if (builtin.os.tag != .windows) return Error.Unsupported;
        const bytes = self.prev.len;
        const deadline = win32.nowNs() + @as(u64, timeout_ms) * std.time.ns_per_ms;

        while (true) {
            // CAPTUREBLT: без него не попадают слоистые окна (подсказки, меню).
            const ok = c.BitBlt(
                self.mem_dc,
                0,
                0,
                @intCast(self.area.width),
                @intCast(self.area.height),
                self.screen_dc,
                self.area.x,
                self.area.y,
                c.SRCCOPY | c.CAPTUREBLT,
            );
            if (ok == 0) return Error.Failed;

            const now = self.bits[0..bytes];
            if (self.have_prev and std.mem.eql(u8, now, self.prev)) {
                if (win32.nowNs() >= deadline) {
                    self.stats.idle += 1;
                    return null;
                }
                c.Sleep(4);
                continue;
            }
            @memcpy(self.prev, now);
            self.have_prev = true;
            self.stats.frames += 1;
            return Frame{
                .pixels = now,
                .width = self.area.width,
                .height = self.area.height,
                .stride = self.area.width * 4,
                .timestamp_ns = win32.nowNs(),
                .accumulated = 1,
            };
        }
    }

    /// У GDI нет удерживаемого кадра: метод есть только ради общего интерфейса.
    pub fn release(self: *Grabber) void {
        _ = self;
    }
};

test "объявления GDI-захвата компилируются" {
    try std.testing.expect(@hasDecl(Grabber, "init"));
    try std.testing.expect(@hasDecl(Grabber, "next"));
}
