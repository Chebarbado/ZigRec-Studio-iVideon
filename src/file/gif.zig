//! Чтение GIF: кадры, задержки, прозрачность.
//!
//! Задача #53. Свой разбор, а не Media Foundation: та открывает GIF
//! не везде и не всегда одинаково, а главное — отдаёт его как одну
//! картинку, теряя и кадры, и их выдержку. Для нас же GIF ценен именно
//! этим: короткая петля, которую видно без плеера.
//!
//! **Кадр в GIF — не целая картинка, а заплатка.** Каждый следующий кадр
//! может покрывать лишь кусок экрана и класться поверх предыдущего. Поэтому
//! разбор ведёт холст: полную картинку, по которой кадры рисуют один
//! за другим. Отдаём наружу именно холст — это то, что человек видит.
//!
//! Что поддержано: GIF87a и GIF89a, палитра общая и на кадр, прозрачность,
//! чересстрочные кадры, три способа убирать за собой (оставить, очистить,
//! вернуть как было). Этого хватает на всё, что делают ffmpeg, браузеры
//! и записывалки экрана.
const std = @import("std");

pub const Error = error{
    /// Это не GIF.
    NotGif,
    /// Файл кончился на середине.
    Truncated,
    /// Внутри что-то, чего в GIF быть не может.
    Malformed,
    /// Кадров или размера больше, чем мы беремся показывать.
    TooBig,
};

/// Предел размера картинки. 8K по стороне — заведомо больше всего, что
/// бывает в GIF на самом деле.
pub const max_side: u32 = 8192;
/// Предел числа кадров. Тысяча кадров при обычной выдержке — это больше
/// минуты петли; дальше это уже не GIF, а видео не в том формате.
pub const max_frames: usize = 1024;

/// Что делать с местом кадра, когда придёт следующий.
pub const Disposal = enum {
    /// Оставить как есть.
    keep,
    /// Очистить в фон.
    clear,
    /// Вернуть то, что было под кадром.
    restore,

    pub fn from(bits: u3) Disposal {
        return switch (bits) {
            2 => .clear,
            3 => .restore,
            // 0 — «не указано», 1 — «оставить»; всё прочее трактуем так же.
            else => .keep,
        };
    }
};

pub const Frame = struct {
    /// Сколько показывать, в наносекундах.
    delay_ns: u64 = 0,
    /// Холст целиком: BGRA, строки сверху вниз, шаг равен ширине.
    ///
    /// BGRA, а не RGBA: именно в таком виде картинку ждут и Windows,
    /// и всё остальное в этом проекте.
    pixels: []u8 = &.{},
};

pub const Image = struct {
    width: u32 = 0,
    height: u32 = 0,
    frames: []Frame = &.{},
    /// Сколько раз крутить. 0 — бесконечно, это самый частый случай.
    loops: u16 = 0,

    pub fn totalNs(self: Image) u64 {
        var sum: u64 = 0;
        for (self.frames) |f| sum += f.delay_ns;
        return sum;
    }

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        for (self.frames) |f| allocator.free(f.pixels);
        allocator.free(self.frames);
        self.* = .{};
    }
};

/// Похоже ли это на GIF по первым байтам.
pub fn looksLikeGif(data: []const u8) bool {
    return data.len >= 6 and
        std.mem.eql(u8, data[0..3], "GIF") and
        (std.mem.eql(u8, data[3..6], "87a") or std.mem.eql(u8, data[3..6], "89a"));
}

/// Выдержка кадра из сотых долей секунды в наносекунды.
///
/// Ноль и единица означают «как можно быстрее», и все показывающие GIF
/// программы подставляют здесь сотую долю секунды. Делаем так же: без
/// этого кадры пролетают быстрее, чем экран успевает обновиться, и петля
/// смазывается в мельтешение.
pub fn delayNs(hundredths: u16) u64 {
    const use: u64 = if (hundredths <= 1) 10 else hundredths;
    return use * (std.time.ns_per_s / 100);
}

/// Порядок строк в чересстрочном кадре.
///
/// Чересстрочный GIF пишет сначала каждую восьмую строку, потом смещённую
/// на четыре, и так далее: так картинка проявлялась по мере загрузки
/// по медленной сети. Правило — чистый счёт, поэтому и вынесено отдельно.
pub fn interlacedRow(order: u32, height: u32) u32 {
    if (height == 0) return 0;
    // Проход 1: 0, 8, 16…  Проход 2: 4, 12, 20…
    // Проход 3: 2, 6, 10…  Проход 4: 1, 3, 5…
    const p1 = (height + 7) / 8;
    const p2 = (height + 3) / 8;
    const p3 = (height + 1) / 4;
    if (order < p1) return order * 8;
    if (order < p1 + p2) return (order - p1) * 8 + 4;
    if (order < p1 + p2 + p3) return (order - p1 - p2) * 4 + 2;
    return (order - p1 - p2 - p3) * 2 + 1;
}

// ------------------------------------------------------------ разбор

const Reader = struct {
    data: []const u8,
    at: usize = 0,

    fn byte(self: *Reader) Error!u8 {
        if (self.at >= self.data.len) return Error.Truncated;
        const out = self.data[self.at];
        self.at += 1;
        return out;
    }

    fn word(self: *Reader) Error!u16 {
        const low = try self.byte();
        const high = try self.byte();
        return @as(u16, high) << 8 | low;
    }

    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (self.at + n > self.data.len) return Error.Truncated;
        const out = self.data[self.at .. self.at + n];
        self.at += n;
        return out;
    }

    /// Пропустить цепочку блоков до пустого.
    fn skipBlocks(self: *Reader) Error!void {
        while (true) {
            const n = try self.byte();
            if (n == 0) return;
            _ = try self.take(n);
        }
    }
};

/// Сколько в GIF кадров и сколько это по времени.
pub const Measured = struct {
    width: u32 = 0,
    height: u32 = 0,
    frames: usize = 0,
    total_ns: u64 = 0,
};

/// Пересчитать кадры, не распаковывая картинки.
///
/// В GIF нет оглавления: узнать число кадров и длительность петли можно
/// только пройдя файл до конца. Но распаковывать при этом нечего —
/// сжатые данные просто пропускаются блоками. На длинной петле это
/// разница между миллисекундой и десятками мегабайт памяти.
pub fn measure(data: []const u8) Error!Measured {
    if (!looksLikeGif(data)) return Error.NotGif;

    var r = Reader{ .data = data, .at = 6 };
    var out = Measured{};
    out.width = try r.word();
    out.height = try r.word();
    if (out.width == 0 or out.height == 0) return Error.Malformed;

    const flags = try r.byte();
    _ = try r.byte();
    _ = try r.byte();
    if (flags & 0x80 != 0) {
        const len = @as(usize, 1) << @intCast((flags & 0x07) + 1);
        _ = try r.take(len * 3);
    }

    var delay_hundredths: u16 = 0;
    while (true) {
        const marker = r.byte() catch break;
        switch (marker) {
            0x3B => break,
            0x21 => {
                const kind = try r.byte();
                if (kind == 0xF9) {
                    const size = try r.byte();
                    if (size != 4) return Error.Malformed;
                    _ = try r.byte();
                    delay_hundredths = try r.word();
                    _ = try r.byte();
                    if (try r.byte() != 0) return Error.Malformed;
                } else {
                    const size = try r.byte();
                    _ = try r.take(size);
                    try r.skipBlocks();
                }
            },
            0x2C => {
                _ = try r.take(8); // положение и размер кадра
                const fflags = try r.byte();
                if (fflags & 0x80 != 0) {
                    const len = @as(usize, 1) << @intCast((fflags & 0x07) + 1);
                    _ = try r.take(len * 3);
                }
                _ = try r.byte(); // минимальная ширина кода
                try r.skipBlocks();

                out.frames += 1;
                out.total_ns += delayNs(delay_hundredths);
                delay_hundredths = 0;
                if (out.frames > max_frames) return Error.TooBig;
            },
            else => {},
        }
    }
    if (out.frames == 0) return Error.Malformed;
    return out;
}

/// Разобрать GIF целиком.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    if (!looksLikeGif(data)) return Error.NotGif;

    var r = Reader{ .data = data, .at = 6 };
    const width = try r.word();
    const height = try r.word();
    if (width == 0 or height == 0) return Error.Malformed;
    if (width > max_side or height > max_side) return Error.TooBig;

    const flags = try r.byte();
    const background = try r.byte();
    _ = try r.byte(); // соотношение сторон точки: никем не используется

    var global: [256][3]u8 = @splat(.{ 0, 0, 0 });
    var global_len: usize = 0;
    if (flags & 0x80 != 0) {
        global_len = @as(usize, 1) << @intCast((flags & 0x07) + 1);
        const raw = try r.take(global_len * 3);
        for (0..global_len) |i| global[i] = .{ raw[i * 3], raw[i * 3 + 1], raw[i * 3 + 2] };
    }

    const canvas_bytes = @as(usize, width) * @as(usize, height) * 4;
    const canvas = try allocator.alloc(u8, canvas_bytes);
    defer allocator.free(canvas);
    const saved = try allocator.alloc(u8, canvas_bytes);
    defer allocator.free(saved);

    // Начальный холст — прозрачный. Не цвет фона: у кадра, не закрывающего
    // весь экран, фон по краям чаще всего и должен быть пустым.
    @memset(canvas, 0);
    _ = background;

    var frames: std.ArrayList(Frame) = .empty;
    errdefer {
        for (frames.items) |f| allocator.free(f.pixels);
        frames.deinit(allocator);
    }

    var loops: u16 = 0;
    var delay_hundredths: u16 = 0;
    var transparent: ?u8 = null;
    var disposal: Disposal = .keep;

    while (true) {
        const marker = r.byte() catch break;
        switch (marker) {
            // Хвост файла.
            0x3B => break,

            // Расширение.
            0x21 => {
                const kind = try r.byte();
                switch (kind) {
                    // Управление показом: выдержка, прозрачность, уборка.
                    0xF9 => {
                        const size = try r.byte();
                        if (size != 4) return Error.Malformed;
                        const bits = try r.byte();
                        delay_hundredths = try r.word();
                        const index = try r.byte();
                        transparent = if (bits & 1 != 0) index else null;
                        disposal = Disposal.from(@intCast((bits >> 2) & 0x07));
                        if (try r.byte() != 0) return Error.Malformed;
                    },
                    // Приложение: нас интересует только число повторов.
                    0xFF => {
                        const size = try r.byte();
                        const name = try r.take(size);
                        if (size == 11 and std.mem.eql(u8, name[0..11], "NETSCAPE2.0")) {
                            const block = try r.byte();
                            if (block >= 3) {
                                _ = try r.byte(); // подтип
                                loops = try r.word();
                                _ = try r.take(block - 3);
                            } else {
                                _ = try r.take(block);
                            }
                            try r.skipBlocks();
                        } else {
                            try r.skipBlocks();
                        }
                    },
                    else => try r.skipBlocks(),
                }
            },

            // Кадр.
            0x2C => {
                if (frames.items.len >= max_frames) return Error.TooBig;
                const left = try r.word();
                const top = try r.word();
                const fw = try r.word();
                const fh = try r.word();
                const fflags = try r.byte();

                var local: [256][3]u8 = undefined;
                var table: []const [3]u8 = global[0..global_len];
                if (fflags & 0x80 != 0) {
                    const len = @as(usize, 1) << @intCast((fflags & 0x07) + 1);
                    const raw = try r.take(len * 3);
                    for (0..len) |i| local[i] = .{ raw[i * 3], raw[i * 3 + 1], raw[i * 3 + 2] };
                    table = local[0..len];
                }
                if (table.len == 0) return Error.Malformed;
                const interlaced = fflags & 0x40 != 0;

                // Кадр обязан помещаться в холст: иначе заплатка ляжет
                // мимо картинки и затрёт чужую память.
                if (@as(usize, left) + fw > width or @as(usize, top) + fh > height) return Error.Malformed;

                // Запоминаем, что было под кадром, — на случай «вернуть».
                if (disposal == .restore) @memcpy(saved, canvas);

                const indices = try allocator.alloc(u8, @as(usize, fw) * @as(usize, fh));
                defer allocator.free(indices);
                try inflateLzw(&r, indices);

                paint(canvas, width, indices, left, top, fw, fh, table, transparent, interlaced);

                const copy = try allocator.alloc(u8, canvas_bytes);
                errdefer allocator.free(copy);
                @memcpy(copy, canvas);
                try frames.append(allocator, .{
                    .delay_ns = delayNs(delay_hundredths),
                    .pixels = copy,
                });

                // Убираем за кадром так, как он просил.
                switch (disposal) {
                    .keep => {},
                    .clear => clearRect(canvas, width, left, top, fw, fh),
                    .restore => @memcpy(canvas, saved),
                }
                // Управление действует на один кадр и дальше не переносится.
                delay_hundredths = 0;
                transparent = null;
                disposal = .keep;
            },

            // Мусор между блоками встречается в файлах от старых программ:
            // пропускаем байт и идём дальше, а не бросаем весь файл.
            else => {},
        }
    }

    if (frames.items.len == 0) return Error.Malformed;
    return .{
        .width = width,
        .height = height,
        .frames = try frames.toOwnedSlice(allocator),
        .loops = loops,
    };
}

/// Положить заплатку на холст.
fn paint(
    canvas: []u8,
    canvas_w: u32,
    indices: []const u8,
    left: u16,
    top: u16,
    fw: u16,
    fh: u16,
    table: []const [3]u8,
    transparent: ?u8,
    interlaced: bool,
) void {
    var order: u32 = 0;
    while (order < fh) : (order += 1) {
        const row = if (interlaced) interlacedRow(order, fh) else order;
        if (row >= fh) continue;
        var x: u32 = 0;
        while (x < fw) : (x += 1) {
            const index = indices[order * fw + x];
            // Прозрачная точка не рисуется вовсе: под ней остаётся то,
            // что было. На этом и держится вся склейка кадров.
            if (transparent) |t| {
                if (index == t) continue;
            }
            if (index >= table.len) continue;
            const rgb = table[index];
            const at = ((@as(usize, top) + row) * canvas_w + left + x) * 4;
            canvas[at + 0] = rgb[2]; // синий
            canvas[at + 1] = rgb[1];
            canvas[at + 2] = rgb[0]; // красный
            canvas[at + 3] = 255;
        }
    }
}

fn clearRect(canvas: []u8, canvas_w: u32, left: u16, top: u16, fw: u16, fh: u16) void {
    var y: u32 = 0;
    while (y < fh) : (y += 1) {
        const at = ((@as(usize, top) + y) * canvas_w + left) * 4;
        @memset(canvas[at .. at + @as(usize, fw) * 4], 0);
    }
}

// -------------------------------------------------------------- LZW

/// Распаковать кадр.
///
/// LZW из GIF: словарь растёт по ходу чтения, ширина кода растёт вместе
/// с ним, биты идут младшими вперёд. Отдельного внимания стоит код,
/// которого ещё нет в словаре: он законный и означает «то, что я только
/// что добавлю» — на этом спотыкается каждая первая своя реализация.
fn inflateLzw(r: *Reader, out: []u8) !void {
    const min_code = try r.byte();
    if (min_code < 2 or min_code > 11) return Error.Malformed;

    const clear_code: u16 = @as(u16, 1) << @intCast(min_code);
    const end_code: u16 = clear_code + 1;

    // Словарь: у каждой записи есть предшественник и последний байт.
    // Так строка восстанавливается с конца, без хранения строк целиком.
    var prefix: [4096]u16 = undefined;
    var suffix: [4096]u8 = undefined;
    var stack: [4096]u8 = undefined;

    var next: u16 = end_code + 1;
    var code_len: u4 = @intCast(min_code + 1);
    var previous: ?u16 = null;

    var bits: u32 = 0;
    var bit_count: u5 = 0;
    var block_left: usize = 0;
    var wrote: usize = 0;

    while (true) {
        // Набираем битов на один код.
        while (bit_count < code_len) {
            if (block_left == 0) {
                const n = try r.byte();
                if (n == 0) {
                    // Данные кончились ровно на границе блоков.
                    if (wrote < out.len) return Error.Truncated;
                    return;
                }
                block_left = n;
            }
            const b = try r.byte();
            block_left -= 1;
            bits |= @as(u32, b) << bit_count;
            bit_count += 8;
        }

        const code: u16 = @intCast(bits & ((@as(u32, 1) << code_len) - 1));
        bits >>= code_len;
        bit_count -= code_len;

        if (code == clear_code) {
            next = end_code + 1;
            code_len = @intCast(min_code + 1);
            previous = null;
            continue;
        }
        if (code == end_code) break;

        var top: usize = 0;
        var walk: u16 = code;

        if (code >= next) {
            // Код, которого ещё нет: он означает строку, которую мы
            // добавим прямо сейчас, — предыдущая плюс её первый байт.
            const prev = previous orelse return Error.Malformed;
            stack[top] = firstByte(&prefix, prev, clear_code);
            top += 1;
            walk = prev;
        }

        // Разматываем строку с конца.
        var guard: usize = 0;
        while (walk >= clear_code) {
            if (guard > stack.len) return Error.Malformed;
            stack[top] = suffix[walk];
            top += 1;
            walk = prefix[walk];
            guard += 1;
        }
        stack[top] = @intCast(walk);
        top += 1;

        // Строка лежит в стопке задом наперёд: наверху её ПЕРВЫЙ байт.
        // Он и пойдёт в словарь — новая запись это «предыдущая строка плюс
        // первый байт нынешней». Взять здесь последний байт вместо первого
        // значит получить картинку, которая первые строки выходит верной,
        // а дальше тихо расползается: словарь расходится с тем, каким его
        // строил сжимавший.
        const first = stack[top - 1];

        // Кладём в кадр в прямом порядке.
        while (top > 0) {
            top -= 1;
            if (wrote >= out.len) break;
            out[wrote] = stack[top];
            wrote += 1;
        }

        if (previous) |prev| {
            if (next < 4096) {
                prefix[next] = prev;
                suffix[next] = first;
                next += 1;
                // Ширина кода растёт, пока не упрётся в двенадцать бит.
                if (next == (@as(u16, 1) << code_len) and code_len < 12) code_len += 1;
            }
        }
        previous = code;

        if (wrote >= out.len) {
            // Кадр набран. Досасываем хвост до пустого блока, чтобы
            // чтение продолжилось с нужного места.
            while (block_left > 0) : (block_left -= 1) _ = try r.byte();
            try r.skipBlocks();
            return;
        }
    }

    if (wrote < out.len) return Error.Truncated;
    try r.skipBlocks();
}

/// Первый байт строки с таким кодом.
///
/// Спускаемся по предшественникам до корневого кода: у корня код и есть
/// байт. Нужно ровно в одном месте — когда встречается код, которого ещё
/// нет в словаре.
fn firstByte(prefix: *const [4096]u16, code: u16, clear_code: u16) u8 {
    var walk = code;
    var guard: usize = 0;
    while (walk >= clear_code and guard < 4096) : (guard += 1) walk = prefix[walk];
    return @intCast(walk & 0xFF);
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;

test "подпись узнаётся у обоих поколений" {
    try testing.expect(looksLikeGif("GIF89a..."));
    try testing.expect(looksLikeGif("GIF87a..."));
    try testing.expect(!looksLikeGif("GIF99a..."));
    try testing.expect(!looksLikeGif("PNG"));
    try testing.expect(!looksLikeGif(""));
}

test "выдержка: ноль и единица означают «как можно быстрее»" {
    // Все показывающие GIF программы подставляют здесь сотую секунды.
    // Без этого кадры пролетают быстрее, чем обновляется экран.
    try testing.expectEqual(@as(u64, 100 * std.time.ns_per_ms), delayNs(0));
    try testing.expectEqual(@as(u64, 100 * std.time.ns_per_ms), delayNs(1));
    try testing.expectEqual(@as(u64, 20 * std.time.ns_per_ms), delayNs(2));
    try testing.expectEqual(@as(u64, std.time.ns_per_s), delayNs(100));
}

test "чересстрочный порядок строк: четыре прохода, каждая строка один раз" {
    // Высота 8: проходы дают 0,8→ только 0; 4; 2,6; 1,3,5,7.
    const h: u32 = 8;
    var seen: [8]bool = @splat(false);
    var i: u32 = 0;
    while (i < h) : (i += 1) {
        const row = interlacedRow(i, h);
        try testing.expect(row < h);
        try testing.expect(!seen[row]);
        seen[row] = true;
    }
    for (seen) |s| try testing.expect(s);

    // Первый проход начинается с нулевой строки, второй — с четвёртой.
    try testing.expectEqual(@as(u32, 0), interlacedRow(0, h));
    try testing.expectEqual(@as(u32, 4), interlacedRow(1, h));
    try testing.expectEqual(@as(u32, 2), interlacedRow(2, h));
}

test "чересстрочный порядок цел на нечётной высоте" {
    // Высота 13 — не степень двойки и не кратна восьми: самый частый
    // случай, на котором ломаются деления нацело.
    const h: u32 = 13;
    var seen: [13]bool = @splat(false);
    var i: u32 = 0;
    while (i < h) : (i += 1) {
        const row = interlacedRow(i, h);
        try testing.expect(row < h);
        try testing.expect(!seen[row]);
        seen[row] = true;
    }
    for (seen) |s| try testing.expect(s);
}

test "способ уборки читается из битов" {
    try testing.expectEqual(Disposal.keep, Disposal.from(0));
    try testing.expectEqual(Disposal.keep, Disposal.from(1));
    try testing.expectEqual(Disposal.clear, Disposal.from(2));
    try testing.expectEqual(Disposal.restore, Disposal.from(3));
    // Неизвестное значение не роняет разбор.
    try testing.expectEqual(Disposal.keep, Disposal.from(7));
}

test "не-GIF отвергается, обрезанный не читается наполовину" {
    const a = testing.allocator;
    try testing.expectError(Error.NotGif, decode(a, "не картинка"));
    try testing.expectError(Error.NotGif, decode(a, ""));
    // Подпись есть, дальше ничего.
    try testing.expectError(Error.Truncated, decode(a, "GIF89a"));
}

/// Однокадровый GIF 2x2: красный, зелёный, синий, белый.
///
/// Байты настоящие — сделаны чужой программой (Pillow), а не написаны
/// руками. Самодельные байты проверяли бы наше же понимание формата
/// против него самого.
const tiny_gif = [_]u8{
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x02, 0x00, 0x02, 0x00, 0x81, 0x00,
    0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF,
    0xFF, 0x21, 0xF9, 0x04, 0x00, 0x05, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00,
    0x00, 0x00, 0x02, 0x00, 0x02, 0x00, 0x00, 0x08, 0x07, 0x00, 0x01, 0x04,
    0x10, 0x30, 0x20, 0x20, 0x00, 0x3B,
};

/// Трёхкадровый GIF 4x2: сплошной красный, зелёный, синий.
/// Выдержки нарочно разные: 30, 60 и 90 сотых секунды.
const moving_gif = [_]u8{
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x04, 0x00, 0x02, 0x00, 0x81, 0x00,
    0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x21, 0xFF, 0x0B, 0x4E, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45,
    0x32, 0x2E, 0x30, 0x03, 0x01, 0x00, 0x00, 0x00, 0x21, 0xF9, 0x04, 0x00,
    0x03, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x02,
    0x00, 0x00, 0x08, 0x07, 0x00, 0x01, 0x08, 0x1C, 0x28, 0x30, 0x20, 0x00,
    0x21, 0xF9, 0x04, 0x01, 0x06, 0x00, 0x01, 0x00, 0x2C, 0x00, 0x00, 0x00,
    0x00, 0x04, 0x00, 0x02, 0x00, 0x81, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x07, 0x00, 0x01, 0x08, 0x1C,
    0x28, 0x30, 0x20, 0x00, 0x21, 0xF9, 0x04, 0x01, 0x09, 0x00, 0x01, 0x00,
    0x2C, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x02, 0x00, 0x81, 0x00, 0x00,
    0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x07,
    0x00, 0x01, 0x08, 0x1C, 0x28, 0x30, 0x20, 0x00, 0x3B,
};

test "однокадровый GIF: размер, выдержка, цвет каждой точки" {
    const a = testing.allocator;
    var img = try decode(a, &tiny_gif);
    defer img.deinit(a);

    try testing.expectEqual(@as(u32, 2), img.width);
    try testing.expectEqual(@as(u32, 2), img.height);
    try testing.expectEqual(@as(usize, 1), img.frames.len);
    try testing.expectEqual(@as(u64, 50 * std.time.ns_per_ms), img.frames[0].delay_ns);
    try testing.expectEqual(@as(u64, 50 * std.time.ns_per_ms), img.totalNs());

    // Точки идут слева направо, сверху вниз; в памяти цвет лежит как BGRA.
    const px = img.frames[0].pixels;
    try testing.expectEqual(@as(usize, 2 * 2 * 4), px.len);
    try expectPixel(px, 0, .{ 255, 0, 0 });
    try expectPixel(px, 1, .{ 0, 255, 0 });
    try expectPixel(px, 2, .{ 0, 0, 255 });
    try expectPixel(px, 3, .{ 255, 255, 255 });
}

/// Сверить точку по номеру. Цвет задаём как красный-зелёный-синий —
/// так его видит человек, — а в памяти он лежит наоборот.
fn expectPixel(px: []const u8, index: usize, rgb: [3]u8) !void {
    const at = index * 4;
    try testing.expectEqual(rgb[2], px[at + 0]);
    try testing.expectEqual(rgb[1], px[at + 1]);
    try testing.expectEqual(rgb[0], px[at + 2]);
    try testing.expectEqual(@as(u8, 255), px[at + 3]);
}

test "многокадровый GIF: все кадры со своими выдержками" {
    const a = testing.allocator;
    var img = try decode(a, &moving_gif);
    defer img.deinit(a);

    try testing.expectEqual(@as(u32, 4), img.width);
    try testing.expectEqual(@as(u32, 2), img.height);
    try testing.expectEqual(@as(usize, 3), img.frames.len);

    // Выдержки у кадров разные — именно этого Media Foundation и не отдаёт.
    try testing.expectEqual(@as(u64, 30 * std.time.ns_per_ms), img.frames[0].delay_ns);
    try testing.expectEqual(@as(u64, 60 * std.time.ns_per_ms), img.frames[1].delay_ns);
    try testing.expectEqual(@as(u64, 90 * std.time.ns_per_ms), img.frames[2].delay_ns);
    try testing.expectEqual(@as(u64, 180 * std.time.ns_per_ms), img.totalNs());

    // Каждый кадр — свой цвет, и палитра у второго и третьего своя.
    try expectPixel(img.frames[0].pixels, 0, .{ 255, 0, 0 });
    try expectPixel(img.frames[1].pixels, 0, .{ 0, 255, 0 });
    try expectPixel(img.frames[2].pixels, 0, .{ 0, 0, 255 });

    // Холст закрашен целиком, а не только первой точкой.
    try expectPixel(img.frames[2].pixels, 7, .{ 0, 0, 255 });
}

test "петля крутится бесконечно, если так написано в файле" {
    const a = testing.allocator;
    var img = try decode(a, &moving_gif);
    defer img.deinit(a);
    try testing.expectEqual(@as(u16, 0), img.loops);
}

test "обрезанный на середине файл не читается наполовину" {
    const a = testing.allocator;
    // Половина настоящего файла: заголовок цел, данные кадра оборваны.
    try testing.expectError(Error.Truncated, decode(a, moving_gif[0 .. moving_gif.len / 2]));
}

test "кадр за краем холста отвергается" {
    // Иначе заплатка легла бы мимо картинки и затёрла чужую память.
    var broken = tiny_gif;
    // Ширина кадра 200 при холсте 2x2.
    broken[38] = 200;
    const a = testing.allocator;
    try testing.expectError(Error.Malformed, decode(a, &broken));
}

test "счёт кадров сходится с полным разбором" {
    // Пересчёт не распаковывает картинки, и разойтись с разбором он может
    // очень тихо: числа в окне окажутся не те, что на экране.
    const a = testing.allocator;
    var img = try decode(a, &moving_gif);
    defer img.deinit(a);

    const counted = try measure(&moving_gif);
    try testing.expectEqual(img.width, counted.width);
    try testing.expectEqual(img.height, counted.height);
    try testing.expectEqual(img.frames.len, counted.frames);
    try testing.expectEqual(img.totalNs(), counted.total_ns);
}

test "счёт кадров работает и на однокадровом" {
    const counted = try measure(&tiny_gif);
    try testing.expectEqual(@as(usize, 1), counted.frames);
    try testing.expectEqual(@as(u64, 50 * std.time.ns_per_ms), counted.total_ns);
}

test "счёт кадров отвергает не-GIF" {
    try testing.expectError(Error.NotGif, measure("вовсе не картинка"));
}
