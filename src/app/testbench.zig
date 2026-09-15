//! Тестовый стенд: синтетический экран с таймкодом и учёт кадров.
//!
//! Задача #12. Смысл — снять проверку с человека. Стенд рисует кадр, в котором
//! номер записан двоичными квадратами, и умеет прочитать номер обратно из
//! пикселей. Дальше любой путь «нарисовали → сняли → закодировали → раскодировали»
//! проверяется машиной: пришли ли все кадры, в том ли порядке, сколько потеряно.
//!
//! Квадраты, а не цифры: шрифт после кодирования плывёт, а квадрат в 16 пикселей
//! переживает и пережатие, и масштабирование.
const std = @import("std");

/// Сколько бит номера рисуется. 24 бита это 16.7 млн кадров, больше 77 часов
/// при 60 кадрах в секунду — запас на любую запись.
pub const bits = 24;
/// Сторона квадрата одного бита в пикселях.
pub const block = 16;

/// Байт на пиксель: BGRA, как отдаёт DXGI.
pub const bytes_per_pixel = 4;

pub const Error = error{
    /// Кадр меньше, чем нужно для таймкода.
    FrameTooSmall,
    /// Буфер не вмещает кадр заданного размера.
    BufferTooSmall,
};

/// Минимальная ширина кадра, в который влезает таймкод.
pub const min_width = bits * block;
/// Минимальная высота кадра.
pub const min_height = block * 2;

/// Синтетический экран: то, что мы делаем вид, будто показываем на мониторе.
pub const Screen = struct {
    width: u32,
    height: u32,
    fps: u32 = 60,

    pub fn init(width: u32, height: u32, fps: u32) Error!Screen {
        if (width < min_width or height < min_height) return Error.FrameTooSmall;
        return .{ .width = width, .height = height, .fps = fps };
    }

    pub fn frameBytes(self: Screen) usize {
        return @as(usize, self.width) * @as(usize, self.height) * bytes_per_pixel;
    }

    /// Нарисовать кадр номер `index` в `buf` (BGRA, строка без выравнивания).
    ///
    /// Что в кадре: тёмный фон, полоса бегущая слева направо (видно движение
    /// и подвисание), и ряд квадратов сверху с номером кадра.
    pub fn render(self: Screen, buf: []u8, index: u32) Error!void {
        if (buf.len < self.frameBytes()) return Error.BufferTooSmall;
        const stride = self.width * bytes_per_pixel;

        // Фон и бегущая полоса.
        const bar_w = @max(self.width / 32, 4);
        const travel = self.width - bar_w;
        const bar_x = if (travel == 0) 0 else (index * 7) % travel;
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                const in_bar = x >= bar_x and x < bar_x + bar_w;
                const v: u8 = if (in_bar) 0x90 else 0x18;
                const o = y * stride + x * bytes_per_pixel;
                buf[o + 0] = v; // B
                buf[o + 1] = v; // G
                buf[o + 2] = v; // R
                buf[o + 3] = 0xFF; // A
            }
        }

        // Таймкод: старший бит слева, белый квадрат это единица.
        var bit: u5 = 0;
        while (bit < bits) : (bit += 1) {
            const set = (index >> (bits - 1 - bit)) & 1 == 1;
            const v: u8 = if (set) 0xFF else 0x00;
            const x0 = @as(u32, bit) * block;
            var by: u32 = 0;
            while (by < block) : (by += 1) {
                var bx: u32 = 0;
                while (bx < block) : (bx += 1) {
                    const o = (by * stride) + (x0 + bx) * bytes_per_pixel;
                    buf[o + 0] = v;
                    buf[o + 1] = v;
                    buf[o + 2] = v;
                    buf[o + 3] = 0xFF;
                }
            }
        }
    }
};

/// Прочитать номер кадра из пикселей. `stride` — байт на строку: у кадра от
/// DXGI строка бывает шире картинки, и это нормально.
///
/// Порог 0x80, а не точное равенство: после кодирования белый уже не 0xFF.
pub fn readIndex(pixels: []const u8, width: u32, stride: u32) Error!u32 {
    if (width < min_width) return Error.FrameTooSmall;
    const needed = @as(usize, stride) * block;
    if (pixels.len < needed) return Error.BufferTooSmall;

    var index: u32 = 0;
    var bit: u5 = 0;
    while (bit < bits) : (bit += 1) {
        // Центр квадрата: края после пережатия размываются, середина держится.
        const cx = @as(u32, bit) * block + block / 2;
        const cy = block / 2;
        const o = cy * stride + cx * bytes_per_pixel;
        const luma = (@as(u32, pixels[o]) + @as(u32, pixels[o + 1]) + @as(u32, pixels[o + 2])) / 3;
        index = (index << 1) | @as(u32, @intFromBool(luma >= 0x80));
    }
    return index;
}

/// Итог прогона: что стенд насчитал по снятым кадрам.
pub const Tally = struct {
    /// Сколько кадров дошло.
    captured: u32 = 0,
    /// Сколько номеров пропущено внутри дошедшего диапазона.
    dropped: u32 = 0,
    /// Сколько кадров пришло не по возрастанию номера.
    out_of_order: u32 = 0,
    /// Сколько кадров пришло дважды.
    duplicated: u32 = 0,

    pub fn ok(self: Tally) bool {
        return self.dropped == 0 and self.out_of_order == 0 and self.duplicated == 0;
    }
};

/// Сверить последовательность снятых номеров кадров.
///
/// Дырка в номерах это потерянный кадр, повтор — задвоенный, убывание — сбитый
/// порядок. Каждое из трёх ломает запись по-своему, поэтому считаются отдельно.
pub fn tally(indices: []const u32) Tally {
    var t = Tally{ .captured = @intCast(indices.len) };
    if (indices.len == 0) return t;
    var prev = indices[0];
    for (indices[1..]) |cur| {
        if (cur == prev) {
            t.duplicated += 1;
        } else if (cur < prev) {
            t.out_of_order += 1;
        } else {
            t.dropped += cur - prev - 1;
        }
        prev = cur;
    }
    return t;
}

// ---------------------------------------------------------------- тесты

test "кадр рисуется и номер читается обратно" {
    const s = try Screen.init(640, 480, 60);
    const buf = try std.testing.allocator.alloc(u8, s.frameBytes());
    defer std.testing.allocator.free(buf);

    for ([_]u32{ 0, 1, 2, 42, 12345, 0xFFFFFF }) |n| {
        try s.render(buf, n);
        try std.testing.expectEqual(n, try readIndex(buf, s.width, s.width * bytes_per_pixel));
    }
}

test "номер читается при строке шире картинки" {
    const width: u32 = min_width;
    const height: u32 = min_height;
    const stride: u32 = width * bytes_per_pixel + 128; // выравнивание, как у DXGI
    const buf = try std.testing.allocator.alloc(u8, stride * height);
    defer std.testing.allocator.free(buf);
    @memset(buf, 0);

    // Рисуем вручную в буфер с чужим stride: тот же код, что и в render.
    const n: u32 = 0b1010_1010_1010_1010_1010_1010;
    var bit: u5 = 0;
    while (bit < bits) : (bit += 1) {
        const v: u8 = if ((n >> (bits - 1 - bit)) & 1 == 1) 0xFF else 0x00;
        var by: u32 = 0;
        while (by < block) : (by += 1) {
            var bx: u32 = 0;
            while (bx < block) : (bx += 1) {
                const o = by * stride + (@as(u32, bit) * block + bx) * bytes_per_pixel;
                buf[o + 0] = v;
                buf[o + 1] = v;
                buf[o + 2] = v;
                buf[o + 3] = 0xFF;
            }
        }
    }
    try std.testing.expectEqual(n, try readIndex(buf, width, stride));
}

test "номер переживает потерю чёткости" {
    const s = try Screen.init(min_width, min_height, 30);
    const buf = try std.testing.allocator.alloc(u8, s.frameBytes());
    defer std.testing.allocator.free(buf);
    try s.render(buf, 777);

    // Имитация пережатия: белое стало 0xC8, чёрное 0x30.
    for (buf, 0..) |*px, i| {
        if (i % bytes_per_pixel == 3) continue;
        px.* = if (px.* >= 0x80) 0xC8 else 0x30;
    }
    try std.testing.expectEqual(@as(u32, 777), try readIndex(buf, s.width, s.width * bytes_per_pixel));
}

test "слишком маленький экран не заводится" {
    try std.testing.expectError(Error.FrameTooSmall, Screen.init(min_width - 1, min_height, 60));
    try std.testing.expectError(Error.FrameTooSmall, Screen.init(min_width, min_height - 1, 60));
}

test "тесный буфер не даёт рисовать за краем" {
    const s = try Screen.init(640, 480, 60);
    var small: [16]u8 = undefined;
    try std.testing.expectError(Error.BufferTooSmall, s.render(&small, 1));
}

test "ровная последовательность кадров: претензий нет" {
    const t = tally(&.{ 0, 1, 2, 3, 4, 5 });
    try std.testing.expect(t.ok());
    try std.testing.expectEqual(@as(u32, 6), t.captured);
}

test "дырки в номерах считаются потерянными кадрами" {
    const t = tally(&.{ 0, 1, 5, 6 });
    try std.testing.expectEqual(@as(u32, 3), t.dropped);
    try std.testing.expect(!t.ok());
}

test "повторы и сбитый порядок считаются отдельно" {
    const t = tally(&.{ 0, 1, 1, 5, 4 });
    try std.testing.expectEqual(@as(u32, 1), t.duplicated);
    try std.testing.expectEqual(@as(u32, 1), t.out_of_order);
    try std.testing.expectEqual(@as(u32, 3), t.dropped);
}

test "пустой прогон не падает" {
    const t = tally(&.{});
    try std.testing.expectEqual(@as(u32, 0), t.captured);
    try std.testing.expect(t.ok());
}

test "сквозной прогон: нарисовали, сняли, сверили" {
    const s = try Screen.init(min_width, 64, 60);
    const buf = try std.testing.allocator.alloc(u8, s.frameBytes());
    defer std.testing.allocator.free(buf);

    var seen: [120]u32 = undefined;
    var n: u32 = 0;
    while (n < seen.len) : (n += 1) {
        try s.render(buf, n);
        seen[n] = try readIndex(buf, s.width, s.width * bytes_per_pixel);
    }
    try std.testing.expect(tally(&seen).ok());
}
