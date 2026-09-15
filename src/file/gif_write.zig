//! Запись GIF: палитра, сжатие, выдержки кадров.
//!
//! Задача #53. То, ради чего GIF чаще всего и нужен: снял кусок экрана —
//! получил короткую петлю, которую видно в письме и в задаче, без плеера
//! и без кнопки «играть».
//!
//! **Главная трудность — палитра.** В GIF помещается 256 цветов на всю
//! картинку, а на экране их бывают тысячи. Поэтому:
//!
//!  * если цветов и так не больше 256 — берём их как есть, и запись выходит
//!    без единой потери. На снимке окна, меню или текста так и бывает;
//!  * если больше — считаем, какие цвета встречаются чаще, и делим их
//!    на 256 групп так, чтобы внутри каждой цвета были близки друг к другу
//!    (способ известен как «медианное сечение»).
//!
//! Палитра одна на всю петлю, а не своя на кадр: кадры экрана похожи друг
//! на друга, общая палитра сжимается лучше и не заставляет цвета дрожать
//! от кадра к кадру.
const std = @import("std");
const gif = @import("gif.zig");

pub const Error = error{
    /// Кадров нет — записывать нечего.
    NoFrames,
    /// Размер картинки нулевой или запредельный.
    BadSize,
};

/// Сколько цветов помещается в палитру GIF.
pub const palette_len = 256;

/// Сколько бит на составляющую оставляет счёт цветов.
///
/// Пять: 32768 ячеек — это 128 КБ памяти и достаточная точность, чтобы
/// различить цвета, которые человек различает. Шесть дало бы миллион ячеек
/// ради разницы, которой не видно.
const hist_bits = 5;
const hist_side = 1 << hist_bits;
const hist_size = hist_side * hist_side * hist_side;

pub const Palette = struct {
    colors: [palette_len][3]u8 = @splat(.{ 0, 0, 0 }),
    len: usize = 0,
    /// Для каждой ячейки счёта — номер ближайшего цвета палитры.
    /// Готовая таблица: иначе на каждый пиксель пришлось бы перебирать
    /// всю палитру заново.
    lookup: [hist_size]u8 = @splat(0),
    /// Палитра содержит ровно те цвета, что есть в кадрах, — без потерь.
    exact: bool = false,
    /// Точные цвета по их значению. Есть только у точной палитры.
    ///
    /// Нужна потому, что ячейки счёта грубее настоящих цветов: два разных
    /// цвета могут попасть в одну ячейку, и тогда таблица по ячейкам
    /// отдала бы за оба один цвет — то есть потеряла бы то, что мы обещали
    /// сохранить.
    by_color: std.AutoHashMapUnmanaged(u32, u8) = .empty,

    pub fn deinit(self: *Palette, allocator: std.mem.Allocator) void {
        self.by_color.deinit(allocator);
    }

    /// Номер цвета для точки BGRA.
    pub fn indexOf(self: *const Palette, bgra: []const u8) u8 {
        if (self.exact) {
            if (self.by_color.get(keyOf(bgra[2], bgra[1], bgra[0]))) |i| return i;
        }
        return self.lookup[cellOf(bgra[2], bgra[1], bgra[0])];
    }
};

fn keyOf(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) << 16 | @as(u32, g) << 8 | @as(u32, b);
}

fn cellOf(r: u8, g: u8, b: u8) usize {
    const shift = 8 - hist_bits;
    return (@as(usize, r >> shift) << (hist_bits * 2)) |
        (@as(usize, g >> shift) << hist_bits) |
        @as(usize, b >> shift);
}

/// Средний цвет ячейки счёта — её середина.
fn cellColor(cell: usize) [3]u8 {
    const shift = 8 - hist_bits;
    const half = @as(u8, 1) << (shift - 1);
    const r: u8 = @intCast((cell >> (hist_bits * 2)) & (hist_side - 1));
    const g: u8 = @intCast((cell >> hist_bits) & (hist_side - 1));
    const b: u8 = @intCast(cell & (hist_side - 1));
    return .{ (r << shift) | half, (g << shift) | half, (b << shift) | half };
}

/// Собрать палитру по всем кадрам сразу.
pub fn buildPalette(allocator: std.mem.Allocator, frames: []const gif.Frame) !*Palette {
    const out = try allocator.create(Palette);
    errdefer allocator.destroy(out);
    out.* = .{};
    errdefer out.deinit(allocator);

    // Сначала пробуем обойтись без потерь: собираем настоящие цвета,
    // пока их не больше, чем помещается в палитру. На снимке окна, меню
    // или текста их обычно десяток.
    if (try collectExact(allocator, frames, out)) {
        fillLookup(out);
        return out;
    }

    const counts = try allocator.alloc(u32, hist_size);
    defer allocator.free(counts);
    @memset(counts, 0);
    for (frames) |f| {
        var at: usize = 0;
        while (at + 4 <= f.pixels.len) : (at += 4) {
            counts[cellOf(f.pixels[at + 2], f.pixels[at + 1], f.pixels[at])] += 1;
        }
    }
    try medianCut(allocator, counts, out);
    fillLookup(out);
    return out;
}

/// Собрать настоящие цвета, если их немного. `false` — их слишком много.
///
/// Бросаем сразу, как только цветов стало больше палитры: на пёстрой
/// картинке продолжать бессмысленно, а обойти её до конца — заметно долго.
fn collectExact(allocator: std.mem.Allocator, frames: []const gif.Frame, out: *Palette) !bool {
    for (frames) |f| {
        var at: usize = 0;
        while (at + 4 <= f.pixels.len) : (at += 4) {
            const key = keyOf(f.pixels[at + 2], f.pixels[at + 1], f.pixels[at]);
            const got = try out.by_color.getOrPut(allocator, key);
            if (got.found_existing) continue;
            if (out.len >= palette_len) {
                out.by_color.clearRetainingCapacity();
                out.len = 0;
                return false;
            }
            got.value_ptr.* = @intCast(out.len);
            out.colors[out.len] = .{
                f.pixels[at + 2],
                f.pixels[at + 1],
                f.pixels[at],
            };
            out.len += 1;
        }
    }
    if (out.len == 0) return Error.NoFrames;
    out.exact = true;
    return true;
}

/// Медианное сечение: делим облако цветов, пока групп не станет 256.
///
/// Коробка делится не пополам по объёму, а **по населению**: место, где
/// цветов поровну слева и справа. Деление по объёму режет пустоту — почти
/// всё пространство цветов на любой картинке пустует, и половина групп
/// оказалась бы ни о чём, а настоящие цвета делили бы одну ячейку на всех.
///
/// После каждого деления коробка ужимается до занятых ячеек: иначе «самая
/// широкая сторона» будет считаться по пустым краям, и делить мы будем
/// не там, где цвета.
fn medianCut(allocator: std.mem.Allocator, counts: []const u32, out: *Palette) !void {
    const boxes = try allocator.alloc(Box, palette_len);
    defer allocator.free(boxes);

    boxes[0] = .{ .lo = .{ 0, 0, 0 }, .hi = .{ hist_side - 1, hist_side - 1, hist_side - 1 } };
    shrink(counts, &boxes[0]);
    if (boxes[0].pop == 0) return Error.NoFrames;
    var count: usize = 1;

    while (count < palette_len) {
        // Делим ту коробку, у которой шире всего сторона: в ней цвета
        // дальше всего друг от друга, и от неё больше всего вреда.
        var best: usize = 0;
        var best_side: i32 = 0;
        var best_axis: usize = 0;
        for (boxes[0..count], 0..) |b, i| {
            if (b.cells < 2) continue;
            for (0..3) |axis| {
                const side = @as(i32, b.hi[axis]) - @as(i32, b.lo[axis]);
                if (side > best_side) {
                    best_side = side;
                    best = i;
                    best_axis = axis;
                }
            }
        }
        if (best_side == 0) break; // делить больше нечего

        const cut = medianPlane(counts, boxes[best], best_axis) orelse break;
        var left = boxes[best];
        var right = boxes[best];
        left.hi[best_axis] = cut;
        right.lo[best_axis] = cut + 1;
        shrink(counts, &left);
        shrink(counts, &right);
        if (left.pop == 0 or right.pop == 0) break;

        boxes[best] = left;
        boxes[count] = right;
        count += 1;
    }

    // Цвет группы — средний по тем точкам, что в неё попали. Средний,
    // а не середина коробки: если в углу сидит половина картинки,
    // правильнее взять её цвет, а не пустую середину.
    for (boxes[0..count]) |b| {
        var sum: [3]u64 = .{ 0, 0, 0 };
        var total: u64 = 0;
        var r: usize = b.lo[0];
        while (r <= b.hi[0]) : (r += 1) {
            var g: usize = b.lo[1];
            while (g <= b.hi[1]) : (g += 1) {
                var bl: usize = b.lo[2];
                while (bl <= b.hi[2]) : (bl += 1) {
                    const n = counts[(r << (hist_bits * 2)) | (g << hist_bits) | bl];
                    if (n == 0) continue;
                    const color = cellColor((r << (hist_bits * 2)) | (g << hist_bits) | bl);
                    sum[0] += @as(u64, color[0]) * n;
                    sum[1] += @as(u64, color[1]) * n;
                    sum[2] += @as(u64, color[2]) * n;
                    total += n;
                }
            }
        }
        if (total == 0) continue;
        out.colors[out.len] = .{
            @intCast(sum[0] / total),
            @intCast(sum[1] / total),
            @intCast(sum[2] / total),
        };
        out.len += 1;
    }
    if (out.len == 0) return Error.NoFrames;
}

const Box = struct {
    lo: [3]u8,
    hi: [3]u8,
    /// Сколько точек картинки попало в коробку.
    pop: u64 = 0,
    /// Сколько занятых ячеек: коробку из одной ячейки делить бессмысленно.
    cells: u32 = 0,
};

/// Ужать коробку до занятых ячеек и пересчитать её население.
fn shrink(counts: []const u32, b: *Box) void {
    var lo: [3]u8 = .{ hist_side - 1, hist_side - 1, hist_side - 1 };
    var hi: [3]u8 = .{ 0, 0, 0 };
    var pop: u64 = 0;
    var cells: u32 = 0;

    var r: usize = b.lo[0];
    while (r <= b.hi[0]) : (r += 1) {
        var g: usize = b.lo[1];
        while (g <= b.hi[1]) : (g += 1) {
            var bl: usize = b.lo[2];
            while (bl <= b.hi[2]) : (bl += 1) {
                const n = counts[(r << (hist_bits * 2)) | (g << hist_bits) | bl];
                if (n == 0) continue;
                pop += n;
                cells += 1;
                const here = [3]u8{ @intCast(r), @intCast(g), @intCast(bl) };
                for (0..3) |axis| {
                    lo[axis] = @min(lo[axis], here[axis]);
                    hi[axis] = @max(hi[axis], here[axis]);
                }
            }
        }
    }

    b.pop = pop;
    b.cells = cells;
    if (pop == 0) return;
    b.lo = lo;
    b.hi = hi;
}

/// Где резать, чтобы населения вышло поровну.
fn medianPlane(counts: []const u32, b: Box, axis: usize) ?u8 {
    const half = b.pop / 2;
    var passed: u64 = 0;
    var at: u8 = b.lo[axis];
    while (at < b.hi[axis]) : (at += 1) {
        passed += planePop(counts, b, axis, at);
        if (passed >= half) return at;
    }
    // Всё население на одной плоскости: режем рядом, чтобы деление
    // всё-таки состоялось.
    if (b.hi[axis] > b.lo[axis]) return b.hi[axis] - 1;
    return null;
}

/// Сколько точек лежит на одной плоскости коробки.
fn planePop(counts: []const u32, b: Box, axis: usize, at: u8) u64 {
    var total: u64 = 0;
    var i: usize = b.lo[(axis + 1) % 3];
    const i_hi = b.hi[(axis + 1) % 3];
    const j_lo = b.lo[(axis + 2) % 3];
    const j_hi = b.hi[(axis + 2) % 3];
    while (i <= i_hi) : (i += 1) {
        var j: usize = j_lo;
        while (j <= j_hi) : (j += 1) {
            var c: [3]usize = undefined;
            c[axis] = at;
            c[(axis + 1) % 3] = i;
            c[(axis + 2) % 3] = j;
            total += counts[(c[0] << (hist_bits * 2)) | (c[1] << hist_bits) | c[2]];
        }
    }
    return total;
}

/// Для каждой ячейки счёта найти ближайший цвет палитры — один раз,
/// а не на каждый пиксель.
fn fillLookup(p: *Palette) void {
    var cell: usize = 0;
    while (cell < hist_size) : (cell += 1) {
        const want = cellColor(cell);
        var best: u8 = 0;
        var best_dist: u32 = std.math.maxInt(u32);
        for (p.colors[0..p.len], 0..) |color, i| {
            const dr = @as(i32, want[0]) - @as(i32, color[0]);
            const dg = @as(i32, want[1]) - @as(i32, color[1]);
            const db = @as(i32, want[2]) - @as(i32, color[2]);
            // Зелёный весит больше: глаз к нему чувствительнее всего.
            const dist: u32 = @intCast(dr * dr * 3 + dg * dg * 6 + db * db * 1);
            if (dist < best_dist) {
                best_dist = dist;
                best = @intCast(i);
            }
        }
        p.lookup[cell] = best;
    }
}

// ------------------------------------------------------------- запись

/// Собрать GIF из кадров BGRA.
///
/// `loops` — сколько раз крутить; 0 значит «бесконечно», и это то, чего
/// от петли и ждут.
pub fn encode(
    allocator: std.mem.Allocator,
    frames: []const gif.Frame,
    width: u32,
    height: u32,
    loops: u16,
) ![]u8 {
    if (frames.len == 0) return Error.NoFrames;
    if (width == 0 or height == 0 or width > gif.max_side or height > gif.max_side) return Error.BadSize;

    const need = @as(usize, width) * @as(usize, height) * 4;
    for (frames) |f| {
        if (f.pixels.len < need) return Error.BadSize;
    }

    const palette = try buildPalette(allocator, frames);
    defer {
        palette.deinit(allocator);
        allocator.destroy(palette);
    }

    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, need / 4 + 1024);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("GIF89a");
    try w.writeInt(u16, @intCast(width), .little);
    try w.writeInt(u16, @intCast(height), .little);
    // Общая палитра на 256 цветов, восемь бит на цвет.
    try w.writeByte(0xF7);
    try w.writeByte(0); // цвет фона
    try w.writeByte(0); // соотношение сторон точки

    var i: usize = 0;
    while (i < palette_len) : (i += 1) {
        const color = if (i < palette.len) palette.colors[i] else [3]u8{ 0, 0, 0 };
        try w.writeAll(&color);
    }

    // Сколько раз крутить. Блок придуман Netscape и понимается всеми.
    try w.writeAll(&[_]u8{ 0x21, 0xFF, 11 });
    try w.writeAll("NETSCAPE2.0");
    try w.writeAll(&[_]u8{ 3, 1 });
    try w.writeInt(u16, loops, .little);
    try w.writeByte(0);

    const indices = try allocator.alloc(u8, @as(usize, width) * @as(usize, height));
    defer allocator.free(indices);

    for (frames) |f| {
        // Выдержка в сотых долях секунды — так её хранит GIF.
        const hundredths: u16 = @intCast(@min(
            @as(u64, std.math.maxInt(u16)),
            (f.delay_ns + std.time.ns_per_s / 200) / (std.time.ns_per_s / 100),
        ));
        try w.writeAll(&[_]u8{ 0x21, 0xF9, 4, 0 });
        // Ноль и единица в GIF означают «как можно быстрее», и всякий
        // показывающий подставляет вместо них сотую долю секунды. Значит,
        // самая короткая выдержка, которую поймут как выдержку, — две сотых.
        try w.writeInt(u16, @max(hundredths, 2), .little);
        try w.writeAll(&[_]u8{ 0, 0 });

        try w.writeByte(0x2C);
        try w.writeInt(u16, 0, .little); // слева
        try w.writeInt(u16, 0, .little); // сверху
        try w.writeInt(u16, @intCast(width), .little);
        try w.writeInt(u16, @intCast(height), .little);
        try w.writeByte(0); // своей палитры у кадра нет

        var at: usize = 0;
        while (at < indices.len) : (at += 1) {
            indices[at] = palette.indexOf(f.pixels[at * 4 ..][0..4]);
        }
        try squeeze(allocator, w, indices);
    }

    try w.writeByte(0x3B);
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------- LZW

/// Сжать кадр так, как этого ждёт GIF.
///
/// Словарь растёт по ходу записи, ширина кода растёт вместе с ним, биты
/// идут младшими вперёд. Когда словарь упирается в 4096 записей, шлём
/// «очистить» и начинаем заново — иначе читающий разойдётся с нами
/// в понимании кодов.
fn squeeze(allocator: std.mem.Allocator, w: *std.Io.Writer, indices: []const u8) !void {
    const min_code: u4 = 8;
    const clear_code: u16 = 1 << min_code;
    const end_code: u16 = clear_code + 1;

    // Куда ведёт «эта строка плюс этот байт». Ноль значит «пока никуда»:
    // нулевой код занят самим цветом 0 и продолжением быть не может.
    const table = try allocator.alloc(u16, 4096 * 256);
    defer allocator.free(table);
    @memset(table, 0);

    var bits: u32 = 0;
    var bit_count: u5 = 0;
    var block: [255]u8 = undefined;
    var block_len: usize = 0;

    var next: u16 = end_code + 1;
    var code_len: u4 = min_code + 1;

    // Первым байтом данных кадра идёт минимальная ширина кода. Без неё
    // читающий не знает, с какой ширины начинать, и не поймёт ни байта.
    try w.writeByte(min_code);

    const Pack = struct {
        fn put(
            code: u16,
            len: u4,
            acc: *u32,
            acc_bits: *u5,
            buf: *[255]u8,
            buf_len: *usize,
            out: *std.Io.Writer,
        ) !void {
            acc.* |= @as(u32, code) << acc_bits.*;
            acc_bits.* += len;
            while (acc_bits.* >= 8) {
                buf[buf_len.*] = @truncate(acc.*);
                buf_len.* += 1;
                acc.* >>= 8;
                acc_bits.* -= 8;
                if (buf_len.* == 255) {
                    try out.writeByte(255);
                    try out.writeAll(buf[0..255]);
                    buf_len.* = 0;
                }
            }
        }
    };

    try Pack.put(clear_code, code_len, &bits, &bit_count, &block, &block_len, w);
    @memset(table, 0);

    if (indices.len == 0) {
        try Pack.put(end_code, code_len, &bits, &bit_count, &block, &block_len, w);
    } else {
        var current: u16 = indices[0];
        var at: usize = 1;
        while (at < indices.len) : (at += 1) {
            const byte = indices[at];
            const slot = @as(usize, current) * 256 + byte;
            const known = table[slot];
            if (known != 0) {
                current = known;
                continue;
            }

            try Pack.put(current, code_len, &bits, &bit_count, &block, &block_len, w);

            if (next < 4096) {
                table[slot] = next;
                next += 1;
                // Ширина растёт ровно тогда, когда следующий код перестаёт
                // помещаться: читающий считает так же.
                if (next > (@as(u17, 1) << code_len) and code_len < 12) code_len += 1;
            } else {
                // Словарь полон: сбрасываем обе стороны в исходное.
                try Pack.put(clear_code, code_len, &bits, &bit_count, &block, &block_len, w);
                @memset(table, 0);
                next = end_code + 1;
                code_len = min_code + 1;
            }
            current = byte;
        }
        try Pack.put(current, code_len, &bits, &bit_count, &block, &block_len, w);
        try Pack.put(end_code, code_len, &bits, &bit_count, &block, &block_len, w);
    }

    // Хвост битов — в байт целиком.
    if (bit_count > 0) {
        block[block_len] = @truncate(bits);
        block_len += 1;
    }
    if (block_len > 0) {
        try w.writeByte(@intCast(block_len));
        try w.writeAll(block[0..block_len]);
    }
    try w.writeByte(0);
}

// ---------------------------------------------------------- приёмник

/// Сколько памяти отдаём под петлю.
///
/// GIF собирается целиком в памяти: палитра считается по всем кадрам сразу,
/// и пока не виден последний кадр, неизвестно, какие цвета в неё войдут.
/// Четверть гигабайта — это около четырёх минут окна 640x360 при десяти
/// кадрах в секунду; дальше петля перестаёт быть петлёй.
pub const max_bytes: usize = 256 << 20;

/// Больше этого GIF не крутят: почти все показывающие всё равно ограничивают
/// выдержку снизу, а вес растёт прямо пропорционально.
pub const max_fps: u32 = 20;

pub const Summary = struct {
    frames: usize = 0,
    /// Кадров пропущено ради частоты или памяти.
    skipped: usize = 0,
    bytes: usize = 0,
    total_ns: u64 = 0,
};

/// Приёмник кадров: копит их и в конце пишет петлю.
pub const Sink = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    /// Не чаще этого кладём кадры.
    fps: u32,
    frames: std.ArrayList(gif.Frame) = .empty,
    /// Время последнего взятого кадра.
    last_ns: u64 = 0,
    have_last: bool = false,
    used_bytes: usize = 0,
    skipped: usize = 0,
    full: bool = false,

    pub fn create(allocator: std.mem.Allocator, width: u32, height: u32, fps: u32) Sink {
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .fps = std.math.clamp(fps, 1, max_fps),
        };
    }

    /// Положить кадр. Лишние по частоте и по памяти пропускаем молча —
    /// но считаем, чтобы сказать об этом в конце.
    pub fn writeFrame(self: *Sink, pixels: []const u8, stride: u32, at_ns: u64) !void {
        const step = std.time.ns_per_s / self.fps;
        if (self.have_last) {
            if (at_ns < self.last_ns + step) {
                self.skipped += 1;
                return;
            }
            // Выдержка предыдущего кадра известна только теперь: она равна
            // тому, сколько он провисел до этого.
            self.frames.items[self.frames.items.len - 1].delay_ns = at_ns - self.last_ns;
        }

        const need = @as(usize, self.width) * @as(usize, self.height) * 4;
        if (self.used_bytes + need > max_bytes) {
            self.full = true;
            self.skipped += 1;
            return;
        }

        const copy = try self.allocator.alloc(u8, need);
        errdefer self.allocator.free(copy);
        var row: u32 = 0;
        while (row < self.height) : (row += 1) {
            const from = @as(usize, row) * stride;
            const to = @as(usize, row) * self.width * 4;
            if (from + self.width * 4 > pixels.len) break;
            @memcpy(copy[to..][0 .. self.width * 4], pixels[from..][0 .. self.width * 4]);
        }

        try self.frames.append(self.allocator, .{ .delay_ns = step, .pixels = copy });
        self.used_bytes += need;
        self.last_ns = at_ns;
        self.have_last = true;
    }

    /// Собрать петлю и записать её.
    pub fn finish(self: *Sink, io: std.Io, path: []const u8) !Summary {
        if (self.frames.items.len == 0) return Error.NoFrames;

        const bytes = try encode(self.allocator, self.frames.items, self.width, self.height, 0);
        defer self.allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });

        var total: u64 = 0;
        for (self.frames.items) |f| total += f.delay_ns;
        return .{
            .frames = self.frames.items.len,
            .skipped = self.skipped,
            .bytes = bytes.len,
            .total_ns = total,
        };
    }

    pub fn deinit(self: *Sink) void {
        for (self.frames.items) |f| self.allocator.free(f.pixels);
        self.frames.deinit(self.allocator);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------- тесты

const testing = std.testing;

/// Кадр заданного цвета.
fn solidFrame(allocator: std.mem.Allocator, w: u32, h: u32, rgb: [3]u8, delay_ns: u64) !gif.Frame {
    const px = try allocator.alloc(u8, @as(usize, w) * h * 4);
    var at: usize = 0;
    while (at < px.len) : (at += 4) {
        px[at + 0] = rgb[2];
        px[at + 1] = rgb[1];
        px[at + 2] = rgb[0];
        px[at + 3] = 255;
    }
    return .{ .delay_ns = delay_ns, .pixels = px };
}

test "три сплошных кадра переживают запись и чтение" {
    const a = testing.allocator;
    var frames: [3]gif.Frame = undefined;
    frames[0] = try solidFrame(a, 8, 4, .{ 255, 0, 0 }, 30 * std.time.ns_per_ms);
    frames[1] = try solidFrame(a, 8, 4, .{ 0, 255, 0 }, 60 * std.time.ns_per_ms);
    frames[2] = try solidFrame(a, 8, 4, .{ 0, 0, 255 }, 90 * std.time.ns_per_ms);
    defer for (frames) |f| a.free(f.pixels);

    const bytes = try encode(a, &frames, 8, 4, 0);
    defer a.free(bytes);

    var back = try gif.decode(a, bytes);
    defer back.deinit(a);

    try testing.expectEqual(@as(u32, 8), back.width);
    try testing.expectEqual(@as(u32, 4), back.height);
    try testing.expectEqual(@as(usize, 3), back.frames.len);
    try testing.expectEqual(@as(u64, 30 * std.time.ns_per_ms), back.frames[0].delay_ns);
    try testing.expectEqual(@as(u64, 90 * std.time.ns_per_ms), back.frames[2].delay_ns);

    // Цветов мало — палитра взята как есть, и цвета обязаны совпасть точно.
    try testing.expectEqual(@as(u8, 255), back.frames[0].pixels[2]);
    try testing.expectEqual(@as(u8, 255), back.frames[1].pixels[1]);
    try testing.expectEqual(@as(u8, 255), back.frames[2].pixels[0]);
}

test "картинка из немногих цветов пишется без единой потери" {
    // Снимок окна, меню или текста — это десяток цветов. Терять на них
    // нечего, и терять мы не должны.
    const a = testing.allocator;
    const w: u32 = 16;
    const h: u32 = 8;
    const px = try a.alloc(u8, w * h * 4);
    defer a.free(px);
    const shades = [_][3]u8{
        .{ 0, 0, 0 },
        .{ 255, 255, 255 },
        .{ 240, 240, 240 },
        .{ 0, 120, 215 },
        .{ 200, 30, 30 },
    };
    for (0..w * h) |i| {
        const s = shades[i % shades.len];
        px[i * 4 + 0] = s[2];
        px[i * 4 + 1] = s[1];
        px[i * 4 + 2] = s[0];
        px[i * 4 + 3] = 255;
    }
    var frames = [_]gif.Frame{.{ .delay_ns = 50 * std.time.ns_per_ms, .pixels = px }};

    const bytes = try encode(a, &frames, w, h, 0);
    defer a.free(bytes);
    var back = try gif.decode(a, bytes);
    defer back.deinit(a);

    for (0..w * h) |i| {
        try testing.expectEqual(px[i * 4 + 0], back.frames[0].pixels[i * 4 + 0]);
        try testing.expectEqual(px[i * 4 + 1], back.frames[0].pixels[i * 4 + 1]);
        try testing.expectEqual(px[i * 4 + 2], back.frames[0].pixels[i * 4 + 2]);
    }
}

test "много цветов: палитра не длиннее 256, картинка узнаваема" {
    const a = testing.allocator;
    const w: u32 = 64;
    const h: u32 = 64;
    const px = try a.alloc(u8, w * h * 4);
    defer a.free(px);
    // Плавный переход: цветов заведомо больше, чем помещается в палитру.
    for (0..h) |y| {
        for (0..w) |x| {
            const at = (y * w + x) * 4;
            px[at + 0] = @intCast(x * 4);
            px[at + 1] = @intCast(y * 4);
            px[at + 2] = @intCast((x + y) * 2);
            px[at + 3] = 255;
        }
    }
    var frames = [_]gif.Frame{.{ .delay_ns = 100 * std.time.ns_per_ms, .pixels = px }};

    const bytes = try encode(a, &frames, w, h, 0);
    defer a.free(bytes);
    var back = try gif.decode(a, bytes);
    defer back.deinit(a);

    // Каждая точка должна оказаться близка к своей, а не к случайной.
    var worst: i32 = 0;
    for (0..w * h) |i| {
        for (0..3) |k| {
            const d = @as(i32, px[i * 4 + k]) - @as(i32, back.frames[0].pixels[i * 4 + k]);
            worst = @max(worst, @as(i32, @intCast(@abs(d))));
        }
    }
    try testing.expect(worst <= 24);
}

test "пустое и негодное не пишется" {
    const a = testing.allocator;
    const empty: [0]gif.Frame = .{};
    try testing.expectError(Error.NoFrames, encode(a, &empty, 4, 4, 0));

    var one = [_]gif.Frame{.{ .delay_ns = 0, .pixels = &.{} }};
    try testing.expectError(Error.BadSize, encode(a, &one, 4, 4, 0));
}

test "выдержка округляется к ближайшей сотой, но не в ноль" {
    // Ноль означал бы «как можно быстрее», и петля превратилась бы
    // в мельтешение.
    const a = testing.allocator;
    var frames: [2]gif.Frame = undefined;
    frames[0] = try solidFrame(a, 4, 4, .{ 10, 20, 30 }, 1 * std.time.ns_per_ms);
    frames[1] = try solidFrame(a, 4, 4, .{ 40, 50, 60 }, 34 * std.time.ns_per_ms);
    defer for (frames) |f| a.free(f.pixels);

    const bytes = try encode(a, &frames, 4, 4, 0);
    defer a.free(bytes);
    var back = try gif.decode(a, bytes);
    defer back.deinit(a);

    // Миллисекунда округлилась бы в ноль, а ноль и единица означают
    // «как можно быстрее»: ставим две сотых — самую короткую выдержку,
    // которую поймут как выдержку.
    try testing.expectEqual(@as(u64, 20 * std.time.ns_per_ms), back.frames[0].delay_ns);
    // 34 мс — это ближе к трём сотым, чем к четырём.
    try testing.expectEqual(@as(u64, 30 * std.time.ns_per_ms), back.frames[1].delay_ns);
}

test "длинный однотонный кадр сжимается в сотни раз" {
    // Ради этого в GIF и сделан свой словарь: ровное поле должно
    // превращаться в несколько байт.
    const a = testing.allocator;
    var frames = [_]gif.Frame{try solidFrame(a, 320, 240, .{ 32, 32, 32 }, 100 * std.time.ns_per_ms)};
    defer a.free(frames[0].pixels);

    const bytes = try encode(a, &frames, 320, 240, 0);
    defer a.free(bytes);
    // Палитра сама по себе занимает 768 байт — считаем от пикселей.
    try testing.expect(bytes.len < 320 * 240 / 50);
}

test "приёмник берёт кадры не чаще заданного" {
    const a = testing.allocator;
    var sink = Sink.create(a, 4, 2, 10);
    defer sink.deinit();

    const px = try a.alloc(u8, 4 * 2 * 4);
    defer a.free(px);
    @memset(px, 200);

    // Десять кадров в секунду — это сотая… то есть десятая доля секунды.
    try sink.writeFrame(px, 16, 0);
    try sink.writeFrame(px, 16, 30 * std.time.ns_per_ms); // рано
    try sink.writeFrame(px, 16, 60 * std.time.ns_per_ms); // рано
    try sink.writeFrame(px, 16, 100 * std.time.ns_per_ms); // пора
    try testing.expectEqual(@as(usize, 2), sink.frames.items.len);
    try testing.expectEqual(@as(usize, 2), sink.skipped);

    // Выдержка первого кадра — сколько он на самом деле провисел.
    try testing.expectEqual(@as(u64, 100 * std.time.ns_per_ms), sink.frames.items[0].delay_ns);
}

test "частота выше разумной сама опускается" {
    // Почти все показывающие GIF всё равно ограничивают выдержку снизу,
    // а вес растёт прямо пропорционально частоте.
    const a = testing.allocator;
    var sink = Sink.create(a, 2, 2, 120);
    defer sink.deinit();
    try testing.expectEqual(max_fps, sink.fps);

    var zero = Sink.create(a, 2, 2, 0);
    defer zero.deinit();
    try testing.expectEqual(@as(u32, 1), zero.fps);
}

test "шаг строки шире кадра не сдвигает картинку в приёмнике" {
    const a = testing.allocator;
    var sink = Sink.create(a, 2, 2, 10);
    defer sink.deinit();

    // Кадр 2x2, но строки лежат с шагом на четыре точки.
    const stride: u32 = 4 * 4;
    const px = try a.alloc(u8, stride * 2);
    defer a.free(px);
    @memset(px, 0);
    // Первая строка красная, вторая синяя; хвост строки — мусор.
    for (0..2) |x| {
        px[x * 4 + 2] = 255;
        px[stride + x * 4 + 0] = 255;
    }
    @memset(px[2 * 4 .. stride], 7);

    try sink.writeFrame(px, stride, 0);
    const got = sink.frames.items[0].pixels;
    try testing.expectEqual(@as(u8, 255), got[2]); // красный
    // Вторая строка начинается с восьмого байта: две точки по четыре.
    try testing.expectEqual(@as(u8, 255), got[8]); // синий во второй строке
    // И мусор из хвоста исходной строки в кадр не попал.
    try testing.expectEqual(@as(u8, 0), got[1]);
}

test "пустая петля не пишется" {
    const a = testing.allocator;
    var sink = Sink.create(a, 4, 4, 10);
    defer sink.deinit();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    try testing.expectError(Error.NoFrames, sink.finish(threaded.io(), "не важно.gif"));
}
