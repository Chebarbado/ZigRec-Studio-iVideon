//! Общие типы захвата: одинаковы для DXGI и для GDI.
//!
//! Вынесены отдельно, чтобы бэкенды не зависели друг от друга, а верхние слои
//! (кодировщик, стенд, запись) работали с одним видом кадра независимо от того,
//! откуда он пришёл.
const std = @import("std");

pub const Error = error{
    NoDevice,
    NoOutput,
    /// Захват этого выхода запрещён системой или занят другим процессом.
    AccessDenied,
    /// Дубликация отвалилась и не поднялась после повторных попыток.
    Lost,
    /// Не Windows: захват возможен только там.
    Unsupported,
    OutOfMemory,
    Failed,
};

/// Прямоугольник в пикселях экрана. Ширина и высота приводятся к чётным:
/// yuv420p не умеет нечётные размеры, а обрезать лучше здесь, чем в кодировщике.
pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: u32,
    height: u32,

    pub fn evenSized(self: Rect) Rect {
        return .{
            .x = self.x,
            .y = self.y,
            .width = self.width & ~@as(u32, 1),
            .height = self.height & ~@as(u32, 1),
        };
    }

    pub fn isEmpty(self: Rect) bool {
        return self.width == 0 or self.height == 0;
    }

    /// Пересечение с кадром экрана: область не должна вылезать за его границы.
    pub fn clampTo(self: Rect, w: u32, h: u32) Rect {
        const x0: i64 = @max(self.x, 0);
        const y0: i64 = @max(self.y, 0);
        const x1: i64 = @min(@as(i64, self.x) + self.width, w);
        const y1: i64 = @min(@as(i64, self.y) + self.height, h);
        if (x1 <= x0 or y1 <= y0) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        return .{
            .x = @intCast(x0),
            .y = @intCast(y0),
            .width = @intCast(x1 - x0),
            .height = @intCast(y1 - y0),
        };
    }
};

/// Вырезать из кадра прямоугольник. Сам буфер не трогаем: сдвигаем начало и
/// уменьшаем размеры, длина строки остаётся прежней. Копировать нечего —
/// кодировщик всё равно читает построчно.
pub fn cropView(pixels: []const u8, stride: u32, area: Rect) []const u8 {
    const start = @as(usize, @intCast(area.y)) * @as(usize, stride) +
        @as(usize, @intCast(area.x)) * 4;
    const need = @as(usize, stride) * (area.height - 1) + @as(usize, area.width) * 4;
    const end = @min(pixels.len, start + need);
    if (start >= pixels.len) return pixels[pixels.len..];
    return pixels[start..end];
}

/// Кадр: BGRA8, строка выровнена по `stride`.
/// Данные живут до следующего `next` — копировать, если нужны дольше.
pub const Frame = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: u32,
    /// Метка времени QPC в наносекундах: общий счёт для видео и звука.
    timestamp_ns: u64,
    /// Сколько кадров система накопила с прошлого раза. Больше единицы —
    /// значит между вызовами что-то показали, а мы не забрали: это и есть потеря.
    accumulated: u32,
};

/// Итог прогона захвата. То, чем проверяется задача, а не «на глаз плавно».
pub const Stats = struct {
    frames: u64 = 0,
    /// Кадров показано системой сверх забранных нами.
    dropped: u64 = 0,
    /// Сколько раз новый кадр не появился (экран не менялся).
    idle: u64 = 0,
    /// Сколько раз дубликация терялась и пересоздавалась.
    recoveries: u64 = 0,
    elapsed_ns: u64 = 0,

    pub fn fps(self: Stats) f64 {
        if (self.elapsed_ns == 0) return 0;
        return @as(f64, @floatFromInt(self.frames)) *
            @as(f64, std.time.ns_per_s) / @as(f64, @floatFromInt(self.elapsed_ns));
    }

    pub fn dropRate(self: Stats) f64 {
        const total = self.frames + self.dropped;
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(self.dropped)) / @as(f64, @floatFromInt(total));
    }
};

// ---------------------------------------------------------------- тесты

test "нечётные размеры срезаются до чётных" {
    const r = (Rect{ .width = 1749, .height = 1009 }).evenSized();
    try std.testing.expectEqual(@as(u32, 1748), r.width);
    try std.testing.expectEqual(@as(u32, 1008), r.height);
}

test "чётные размеры не трогаются" {
    const r = (Rect{ .x = 10, .y = 20, .width = 1920, .height = 1080 }).evenSized();
    try std.testing.expectEqual(@as(u32, 1920), r.width);
    try std.testing.expectEqual(@as(u32, 1080), r.height);
    try std.testing.expectEqual(@as(i32, 10), r.x);
}

test "область обрезается по краю экрана" {
    const r = (Rect{ .x = 1800, .y = 1000, .width = 400, .height = 400 }).clampTo(1920, 1080);
    try std.testing.expectEqual(@as(i32, 1800), r.x);
    try std.testing.expectEqual(@as(u32, 120), r.width);
    try std.testing.expectEqual(@as(u32, 80), r.height);
}

test "отрицательный угол области подтягивается к нулю" {
    const r = (Rect{ .x = -50, .y = -30, .width = 200, .height = 100 }).clampTo(1920, 1080);
    try std.testing.expectEqual(@as(i32, 0), r.x);
    try std.testing.expectEqual(@as(u32, 150), r.width);
    try std.testing.expectEqual(@as(u32, 70), r.height);
}

test "область вне экрана становится пустой" {
    const r = (Rect{ .x = 5000, .y = 5000, .width = 100, .height = 100 }).clampTo(1920, 1080);
    try std.testing.expect(r.isEmpty());
}

test "частота кадров считается по времени прогона" {
    const s = Stats{ .frames = 300, .elapsed_ns = 5 * std.time.ns_per_s };
    try std.testing.expectApproxEqAbs(@as(f64, 60), s.fps(), 0.001);
}

test "доля потерь: накопленные кадры против забранных" {
    const s = Stats{ .frames = 90, .dropped = 10 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), s.dropRate(), 0.001);
}

test "пустой прогон не делит на ноль" {
    const s = Stats{};
    try std.testing.expectEqual(@as(f64, 0), s.fps());
    try std.testing.expectEqual(@as(f64, 0), s.dropRate());
}

test "вырезка сдвигает начало и оставляет шаг строки" {
    // Кадр 4x3, шаг 16 байт. Вырезаем 2x2 с (1,1).
    var buf: [16 * 3]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @intCast(i % 256);
    const view = cropView(&buf, 16, .{ .x = 1, .y = 1, .width = 2, .height = 2 });
    // Начало: строка 1, пиксель 1 → 16 + 4 = 20.
    try std.testing.expectEqual(@as(u8, 20), view[0]);
    // Длина: одна полная строка плюс два пикселя.
    try std.testing.expectEqual(@as(usize, 16 + 8), view.len);
}

test "вырезка не вылезает за конец буфера" {
    var buf: [64]u8 = undefined;
    const view = cropView(&buf, 16, .{ .x = 2, .y = 3, .width = 2, .height = 1 });
    try std.testing.expect(view.len <= buf.len);
}

test "вырезка вне буфера отдаёт пустоту, а не мусор" {
    var buf: [16]u8 = undefined;
    const view = cropView(&buf, 16, .{ .x = 0, .y = 10, .width = 1, .height = 1 });
    try std.testing.expectEqual(@as(usize, 0), view.len);
}
