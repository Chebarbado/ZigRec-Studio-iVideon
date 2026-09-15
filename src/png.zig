//! Запись PNG: снимок кадра одной картинкой.
//!
//! Задача #50. Кадр уже декодирован и лежит перед глазами; сохранить его
//! отдельной картинкой — дело одной кнопки. Формат выбран не случайно:
//! снимок экрана это текст и линии, PNG сжимает их без потерь и вчетверо
//! плотнее BMP, а JPEG размыл бы буквы, ради которых снимок и делается.
//!
//! Своя запись, а не системная библиотека изображений: три десятка строк
//! на заголовки плюс готовое сжатие из стандартной библиотеки — против
//! ещё одного набора COM-интерфейсов. И всё это проверяется тестами
//! в памяти, без файлов и без окна.
const std = @import("std");
const flate = std.compress.flate;

/// Восемь байт, по которым PNG узнают все.
pub const signature = [8]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

pub const Error = error{
    /// Ширина или высота нулевая — картинки нет.
    EmptyImage,
    /// Пикселей меньше, чем обещают ширина с высотой.
    NotEnoughPixels,
};

/// Больше этого сторона кадра не бывает: шестнадцать тысяч точек — это
/// вдвое больше 8K. Такое число скорее испорчено, чем настоящее.
pub const max_side: u32 = 16384;

/// Собрать PNG из кадра BGRA, как его отдаёт Windows.
///
/// `stride` — шаг строки в байтах: у буферов Media Foundation он бывает
/// больше ширины кадра. Строки идут сверху вниз.
///
/// Память возвращается вызывающему: освобождать ему.
pub fn fromBgra(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: usize,
) ![]u8 {
    if (width == 0 or height == 0) return Error.EmptyImage;
    if (width > max_side or height > max_side) return Error.EmptyImage;

    const step = @max(stride, @as(usize, width) * 4);
    // Последняя строка не обязана быть полной до шага: считаем ровно то,
    // что нужно прочитать.
    if (pixels.len < step * (height - 1) + @as(usize, width) * 4) return Error.NotEnoughPixels;

    const rows = try filtered(allocator, pixels, width, height, step);
    defer allocator.free(rows);

    const squeezed = try squeeze(allocator, rows);
    defer allocator.free(squeezed);

    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, squeezed.len + 128);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll(&signature);

    var head: [13]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], width, .big);
    std.mem.writeInt(u32, head[4..8], height, .big);
    head[8] = 8; // восемь бит на составляющую
    head[9] = 2; // цвет без прозрачности: три составляющих
    head[10] = 0; // способ сжатия — он в PNG один
    head[11] = 0; // способ предсказания строк — тоже один
    head[12] = 0; // без чересстрочности: она нужна медленной сети, не нам
    try chunk(w, "IHDR", &head);
    try chunk(w, "IDAT", squeezed);
    try chunk(w, "IEND", "");

    return out.toOwnedSlice();
}

/// Кусок файла: длина, имя, данные и их контрольная сумма.
fn chunk(w: *std.Io.Writer, name: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(name);
    try w.writeAll(data);

    var sum = std.hash.crc.Crc32.init();
    sum.update(name);
    sum.update(data);
    try w.writeInt(u32, sum.final(), .big);
}

/// Строки кадра, переведённые в RGB и подготовленные к сжатию.
///
/// Перед каждой строкой стоит байт способа предсказания. Берём из двух:
/// «как есть» и «разница с соседом слева». На снимке экрана сосед слева
/// чаще всего того же цвета, разница выходит нулевой, и такая строка
/// сжимается в несколько байт.
fn filtered(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: usize,
) ![]u8 {
    const row_len = @as(usize, width) * 3;
    const out = try allocator.alloc(u8, (row_len + 1) * height);
    errdefer allocator.free(out);

    const line = try allocator.alloc(u8, row_len);
    defer allocator.free(line);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src = pixels[@as(usize, y) * stride ..];
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            // В памяти Windows синий идёт первым, в файле — красный.
            line[x * 3 + 0] = src[x * 4 + 2];
            line[x * 3 + 1] = src[x * 4 + 1];
            line[x * 3 + 2] = src[x * 4 + 0];
        }

        const dest = out[y * (row_len + 1) ..][0 .. row_len + 1];
        if (scorePlain(line) <= scoreLeft(line)) {
            dest[0] = 0;
            @memcpy(dest[1..], line);
        } else {
            dest[0] = 1;
            var i: usize = 0;
            while (i < row_len) : (i += 1) {
                dest[1 + i] = line[i] -% leftOf(line, i);
            }
        }
    }
    return out;
}

/// Сосед слева того же цвета. У первого пикселя соседа нет — считаем нулём.
fn leftOf(line: []const u8, i: usize) u8 {
    return if (i < 3) 0 else line[i - 3];
}

/// Насколько строка «дорогая»: сумма расстояний байтов до нуля.
///
/// Общепринятая прикидка: чем ближе байты к нулю, тем лучше сожмётся.
/// Считать настоящий размер для каждого способа было бы честнее
/// и в сто раз медленнее.
fn scorePlain(line: []const u8) u64 {
    var total: u64 = 0;
    for (line) |v| total += @min(v, 256 - @as(u16, v));
    return total;
}

fn scoreLeft(line: []const u8) u64 {
    var total: u64 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const v = line[i] -% leftOf(line, i);
        total += @min(v, 256 - @as(u16, v));
    }
    return total;
}

/// Сжать поток строк так, как этого ждёт PNG.
fn squeeze(allocator: std.mem.Allocator, rows: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, @max(rows.len / 4, 4096));
    errdefer out.deinit();

    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);

    var press = try flate.Compress.init(&out.writer, window, .zlib, .default);
    try press.writer.writeAll(rows);
    try press.finish();

    return out.toOwnedSlice();
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;

const Decoded = struct {
    width: u32,
    height: u32,
    rgb: []u8,

    fn free(self: Decoded, a: std.mem.Allocator) void {
        a.free(self.rgb);
    }
};

/// Разобрать наш же файл обратно.
///
/// Живёт только в тестах: программе читать PNG незачем, а тесту без этого
/// нечем проверить, что записалось именно то. Контрольные суммы считаются
/// заново — испорченный кусок должен всплыть здесь, а не в чужой программе.
fn decode(allocator: std.mem.Allocator, data: []const u8) !Decoded {
    try testing.expectEqualSlices(u8, &signature, data[0..8]);

    var at: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var body_bytes: std.ArrayList(u8) = .empty;
    defer body_bytes.deinit(allocator);
    var saw_end = false;

    while (at + 12 <= data.len) {
        const len = std.mem.readInt(u32, data[at..][0..4], .big);
        const name = data[at + 4 ..][0..4];
        const body = data[at + 8 ..][0..len];

        var sum = std.hash.crc.Crc32.init();
        sum.update(name);
        sum.update(body);
        try testing.expectEqual(sum.final(), std.mem.readInt(u32, data[at + 8 + len ..][0..4], .big));

        if (std.mem.eql(u8, name, "IHDR")) {
            width = std.mem.readInt(u32, body[0..4], .big);
            height = std.mem.readInt(u32, body[4..8], .big);
            try testing.expectEqual(@as(u8, 8), body[8]);
            try testing.expectEqual(@as(u8, 2), body[9]);
        } else if (std.mem.eql(u8, name, "IDAT")) {
            try body_bytes.appendSlice(allocator, body);
        } else if (std.mem.eql(u8, name, "IEND")) {
            saw_end = true;
        }
        at += 12 + len;
    }
    try testing.expect(saw_end);
    // Ни одного лишнего байта в хвосте.
    try testing.expectEqual(data.len, at);

    var input: std.Io.Reader = .fixed(body_bytes.items);
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);
    var un = flate.Decompress.init(&input, .zlib, window);

    const row_len = @as(usize, width) * 3;
    const rows = try un.reader.allocRemaining(allocator, .limited((row_len + 1) * height + 1));
    defer allocator.free(rows);
    try testing.expectEqual((row_len + 1) * height, rows.len);

    const rgb = try allocator.alloc(u8, row_len * height);
    errdefer allocator.free(rgb);
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const kind = rows[y * (row_len + 1)];
        const src = rows[y * (row_len + 1) + 1 ..][0..row_len];
        const dest = rgb[y * row_len ..][0..row_len];
        var i: usize = 0;
        while (i < row_len) : (i += 1) {
            dest[i] = switch (kind) {
                0 => src[i],
                1 => src[i] +% leftOf(dest, i),
                else => unreachable,
            };
        }
    }
    return .{ .width = width, .height = height, .rgb = rgb };
}

/// Кадр-полосатик: слева направо меняется цвет, сверху вниз — яркость.
fn sampleFrame(allocator: std.mem.Allocator, width: u32, height: u32, stride: usize) ![]u8 {
    const buf = try allocator.alloc(u8, stride * height);
    @memset(buf, 0);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const at = y * stride + x * 4;
            buf[at + 0] = @truncate(x * 7 + y); // синий
            buf[at + 1] = @truncate(y * 3); // зелёный
            buf[at + 2] = @truncate(x * 11); // красный
            buf[at + 3] = 255;
        }
    }
    return buf;
}

test "картинка переживает запись и чтение байт в байт" {
    const a = testing.allocator;
    const w: u32 = 37;
    const h: u32 = 11;
    const src = try sampleFrame(a, w, h, w * 4);
    defer a.free(src);

    const file = try fromBgra(a, src, w, h, w * 4);
    defer a.free(file);

    const got = try decode(a, file);
    defer got.free(a);
    try testing.expectEqual(w, got.width);
    try testing.expectEqual(h, got.height);

    // Сверяем каждый пиксель: порядок составляющих перепутать легко,
    // а на глаз такой снимок выглядит правдоподобно — просто чужого цвета.
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const at = (y * w + x) * 4;
            const to = (y * w + x) * 3;
            try testing.expectEqual(src[at + 2], got.rgb[to + 0]);
            try testing.expectEqual(src[at + 1], got.rgb[to + 1]);
            try testing.expectEqual(src[at + 0], got.rgb[to + 2]);
        }
    }
}

test "шаг строки больше ширины кадра не сдвигает картинку" {
    // Буферы Media Foundation почти всегда шире кадра. Не учтёшь шаг —
    // каждая следующая строка уезжает вбок; в плеере это уже случалось.
    const a = testing.allocator;
    const w: u32 = 40;
    const h: u32 = 9;
    const stride: usize = 64 * 4;
    const src = try sampleFrame(a, w, h, stride);
    defer a.free(src);

    const file = try fromBgra(a, src, w, h, stride);
    defer a.free(file);
    const got = try decode(a, file);
    defer got.free(a);

    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            try testing.expectEqual(src[y * stride + x * 4 + 2], got.rgb[(y * w + x) * 3]);
        }
    }
}

test "одноцветный кадр сжимается в сотни раз" {
    // Ради этого и выбран PNG: снимок экрана — это большие ровные поля.
    const a = testing.allocator;
    const w: u32 = 640;
    const h: u32 = 480;
    const src = try a.alloc(u8, w * h * 4);
    defer a.free(src);
    @memset(src, 0x20);

    const file = try fromBgra(a, src, w, h, w * 4);
    defer a.free(file);
    try testing.expect(file.len * 200 < src.len);
}

test "пустая картинка и нехватка пикселей замечаются, а не пишутся" {
    const a = testing.allocator;
    var one: [4]u8 = .{ 1, 2, 3, 255 };
    try testing.expectError(Error.EmptyImage, fromBgra(a, &one, 0, 5, 0));
    try testing.expectError(Error.EmptyImage, fromBgra(a, &one, 5, 0, 20));
    try testing.expectError(Error.EmptyImage, fromBgra(a, &one, max_side + 1, 5, 0));
    try testing.expectError(Error.NotEnoughPixels, fromBgra(a, &one, 10, 10, 40));
}

test "кадр в один пиксель тоже картинка" {
    const a = testing.allocator;
    var one: [4]u8 = .{ 10, 20, 30, 255 };
    const file = try fromBgra(a, &one, 1, 1, 4);
    defer a.free(file);
    const got = try decode(a, file);
    defer got.free(a);
    try testing.expectEqualSlices(u8, &.{ 30, 20, 10 }, got.rgb);
}
