//! Метки на дорожке: где что переснять, вырезать, вставить.
//!
//! Задача #69. Метка — это точка времени с подписью и цветом. Цвет нужен
//! не для красоты: метки бывают разного рода — «здесь вырезать», «тут
//! переснять», «сюда вставить заставку», — и цвет отличает их с одного
//! взгляда, быстрее, чем чтение подписи.
//!
//! **Метка стоит на времени проекта, а не на клипе.** Подвинул клип —
//! метка осталась там, где поставлена. Так это работает в монтажных
//! программах, и так оно и надо: метку ставят на место в готовой записи,
//! а не на кусок исходника.
//!
//! **Цветов восемь, и они готовые.** Полная палитра на выбор — это лишнее
//! решение при каждой метке; восемь понятных цветов выбираются не думая.
//!
//! Здесь только счёт: где метка, какого цвета, как они упорядочены.
//! Рисование — в окне.
const std = @import("std");

/// Цвет метки.
///
/// Первый по счёту — жёлтый: им помечают «посмотреть сюда» в бумагах
/// и в любой программе с маркером, и он же достаётся метке по умолчанию.
/// Значение нуля тут не случайно: умолчание модели проекта обязано быть
/// нулевым, иначе восемьсот килобайт лягут в .exe готовыми байтами.
pub const Colour = enum(u8) {
    yellow = 0,
    red,
    orange,
    green,
    cyan,
    blue,
    violet,
    grey,

    /// Цвет в формате COLORREF (BGR), как ждёт GDI.
    pub fn rgb(self: Colour) u32 {
        return switch (self) {
            .yellow => 0x0020C8E8,
            .red => 0x002E2EE8,
            .orange => 0x000A78F0,
            .green => 0x0040A040,
            .cyan => 0x00C0A020,
            .blue => 0x00C05020,
            .violet => 0x00C040A0,
            .grey => 0x00808080,
        };
    }

    pub fn label(self: Colour) []const u8 {
        return switch (self) {
            .yellow => "жёлтая",
            .red => "красная",
            .orange => "оранжевая",
            .green => "зелёная",
            .cyan => "голубая",
            .blue => "синяя",
            .violet => "сиреневая",
            .grey => "серая",
        };
    }

    /// Следующий цвет по кругу — для перебора колесом или клавишей.
    pub fn next(self: Colour) Colour {
        const n = @intFromEnum(self) + 1;
        return if (n > @intFromEnum(Colour.grey)) .yellow else @enumFromInt(n);
    }
};

pub const all_colours = [_]Colour{ .yellow, .red, .orange, .green, .cyan, .blue, .violet, .grey };

/// Сколько букв влезает в подпись метки.
///
/// Подпись читают на линейке, боком, между делениями времени. Длинная
/// туда всё равно не помещается, а обрезанная читается хуже короткой.
pub const max_name = 40;

/// Сколько букв влезает в комментарий метки.
///
/// Задача #79. Имя короткое — его читают на линейке между делениями.
/// Комментарий длинный: «переснять, свет с другой стороны» на линейку
/// не влезет никогда, и живёт он в окне меток. Сто двадцать байт — это
/// шестьдесят русских букв: одна строчка мысли, а не абзац.
pub const max_note = 120;

/// Сколько меток помещается в проекте.
///
/// Цена посчитана заново вместе с комментарием: метка — 176 байт
/// (восемь на время, сорок на имя, сто двадцать на комментарий и мелочь),
/// тридцать две метки это 5.5 КБ, и столько же добавляется к каждому
/// из двадцати четырёх снимков отмены — 132 КБ поверх восьмисот, которые
/// проект уже занимает. До комментария было 43 КБ; за возможность писать
/// у метки мысль, а не только имя, это недорого.
pub const max_marks = 32;

pub const Error = error{
    /// Меток больше не помещается.
    TooManyMarks,
    /// Такой метки нет.
    NoSuchMark,
};

pub const Mark = struct {
    at_ns: u64 = 0,
    colour: Colour = .yellow,
    name: [max_name]u8 = @splat(0),
    name_len: u8 = 0,
    /// Что с этим местом делать. Пусто — метка без пояснения.
    note: [max_note]u8 = @splat(0),
    note_len: u8 = 0,

    pub fn title(self: *const Mark) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setTitle(self: *Mark, text: []const u8) void {
        const n = fitName(text, max_name);
        @memcpy(self.name[0..n], text[0..n]);
        self.name_len = @intCast(n);
    }

    pub fn comment(self: *const Mark) []const u8 {
        return self.note[0..self.note_len];
    }

    pub fn setComment(self: *Mark, text: []const u8) void {
        const n = fitName(text, max_note);
        @memcpy(self.note[0..n], text[0..n]);
        self.note_len = @intCast(n);
    }
};

/// Обрезать по букве, а не по байту: русская буква занимает два байта,
/// и обрезка по границе места оставила бы половину буквы — то есть ромб
/// с вопросительным знаком вместо последней буквы подписи.
pub fn fitName(text: []const u8, room: usize) usize {
    if (text.len <= room) return text.len;
    var n = room;
    while (n > 0 and (text[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

/// Все метки проекта, по времени.
pub const Marks = struct {
    items: [max_marks]Mark = @splat(.{}),
    count: usize = 0,

    pub fn list(self: *const Marks) []const Mark {
        return self.items[0..self.count];
    }

    pub fn empty(self: *const Marks) bool {
        return self.count == 0;
    }

    /// Поставить метку. Возвращает её номер.
    ///
    /// Две метки на одном времени не заводим: их не различить ни глазом,
    /// ни мышью, и вторая просто перекрасит первую.
    pub fn add(self: *Marks, at_ns: u64, colour: Colour, name: []const u8) Error!usize {
        for (self.items[0..self.count], 0..) |m, i| {
            if (m.at_ns != at_ns) continue;
            self.items[i].colour = colour;
            if (name.len > 0) self.items[i].setTitle(name);
            return i;
        }
        if (self.count >= max_marks) return Error.TooManyMarks;

        var made = Mark{ .at_ns = at_ns, .colour = colour };
        made.setTitle(name);

        // Держим по времени: так и рисовать проще, и соседа искать,
        // и прыгать к следующей.
        var at: usize = self.count;
        while (at > 0 and self.items[at - 1].at_ns > at_ns) : (at -= 1) {
            self.items[at] = self.items[at - 1];
        }
        self.items[at] = made;
        self.count += 1;
        return at;
    }

    pub fn removeAt(self: *Marks, index: usize) Error!void {
        if (index >= self.count) return Error.NoSuchMark;
        var i = index;
        while (i + 1 < self.count) : (i += 1) self.items[i] = self.items[i + 1];
        self.count -= 1;
    }

    /// Передвинуть метку. Возвращает её новый номер: она могла перепрыгнуть
    /// соседа, а рисование и попадание мышью ждут метки по порядку.
    pub fn moveTo(self: *Marks, index: usize, at_ns: u64) Error!usize {
        if (index >= self.count) return Error.NoSuchMark;
        const moved = self.items[index];
        try self.removeAt(index);
        // Место только что освободили — занять его обратно всегда можно.
        const where = self.add(at_ns, moved.colour, moved.title()) catch unreachable;
        // Комментарий едет вместе с меткой: он про это место, а не про
        // то время, где метка стояла раньше.
        self.items[where].note = moved.note;
        self.items[where].note_len = moved.note_len;
        return where;
    }

    pub fn rename(self: *Marks, index: usize, name: []const u8) Error!void {
        if (index >= self.count) return Error.NoSuchMark;
        self.items[index].setTitle(name);
    }

    pub fn setComment(self: *Marks, index: usize, text: []const u8) Error!void {
        if (index >= self.count) return Error.NoSuchMark;
        self.items[index].setComment(text);
    }

    pub fn setColour(self: *Marks, index: usize, colour: Colour) Error!void {
        if (index >= self.count) return Error.NoSuchMark;
        self.items[index].colour = colour;
    }

    /// Какая метка попала под указатель. `tolerance_ns` — полуширина
    /// попадания по времени, пересчитанная окном из точек экрана.
    pub fn nearest(self: *const Marks, at_ns: u64, tolerance_ns: u64) ?usize {
        var best: ?usize = null;
        var best_gap: u64 = std.math.maxInt(u64);
        for (self.list(), 0..) |m, i| {
            const gap = if (m.at_ns > at_ns) m.at_ns - at_ns else at_ns - m.at_ns;
            if (gap > tolerance_ns) continue;
            if (gap >= best_gap) continue;
            best_gap = gap;
            best = i;
        }
        return best;
    }

    /// Ближайшая метка вперёд или назад — для прыжка по меткам.
    ///
    /// Прыгать по меткам нужно уметь без мыши: метки и ставят затем,
    /// чтобы потом пройти по ним подряд.
    pub fn step(self: *const Marks, from_ns: u64, forward: bool) ?usize {
        if (forward) {
            for (self.list(), 0..) |m, i| {
                if (m.at_ns > from_ns) return i;
            }
            return null;
        }
        var i = self.count;
        while (i > 0) {
            i -= 1;
            if (self.items[i].at_ns < from_ns) return i;
        }
        return null;
    }
};

/// Имя по умолчанию для новой метки.
///
/// Пустая подпись выглядит как недоделка, а придумывать имя на каждую
/// метку человек не обязан: их ставят быстро, подряд, и называют потом
/// только те, к которым возвращаются.
pub fn defaultName(buf: []u8, number: usize) []const u8 {
    return std.fmt.bufPrint(buf, "метка {d}", .{number}) catch "метка";
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;
const sec = std.time.ns_per_s;

test "умолчание нулевое" {
    // Иначе восьмисоткилобайтная модель проекта ляжет в .exe готовыми байтами.
    const m = Marks{};
    try testing.expect(std.meta.eql(m, std.mem.zeroes(Marks)));
    const one = Mark{};
    try testing.expectEqual(Colour.yellow, one.colour);
}

test "метки держатся по времени, как их ни ставь" {
    var m = Marks{};
    _ = try m.add(10 * sec, .red, "три");
    _ = try m.add(2 * sec, .green, "один");
    _ = try m.add(6 * sec, .blue, "два");

    var last: u64 = 0;
    for (m.list()) |it| {
        try testing.expect(it.at_ns >= last);
        last = it.at_ns;
    }
    try testing.expectEqualStrings("один", m.items[0].title());
    try testing.expectEqualStrings("два", m.items[1].title());
    try testing.expectEqualStrings("три", m.items[2].title());
}

test "вторая метка на том же времени перекрашивает первую, а не встаёт рядом" {
    // Две метки на одном времени не различить ни глазом, ни мышью.
    var m = Marks{};
    const first = try m.add(sec, .yellow, "раз");
    const again = try m.add(sec, .red, "два");
    try testing.expectEqual(first, again);
    try testing.expectEqual(@as(usize, 1), m.count);
    try testing.expectEqual(Colour.red, m.items[0].colour);
    try testing.expectEqualStrings("два", m.items[0].title());
}

test "меток больше отведённого не помещается, и об этом говорят" {
    var m = Marks{};
    var i: usize = 0;
    while (i < max_marks) : (i += 1) {
        _ = try m.add(@as(u64, i + 1) * sec, .yellow, "");
    }
    try testing.expectError(Error.TooManyMarks, m.add(10_000 * sec, .red, ""));
    try testing.expectEqual(max_marks, m.count);
}

test "метку можно убрать, переименовать и перекрасить" {
    var m = Marks{};
    _ = try m.add(sec, .yellow, "было");
    try m.rename(0, "стало");
    try testing.expectEqualStrings("стало", m.items[0].title());
    try m.setColour(0, .violet);
    try testing.expectEqual(Colour.violet, m.items[0].colour);

    try m.removeAt(0);
    try testing.expect(m.empty());
    try testing.expectError(Error.NoSuchMark, m.removeAt(0));
    try testing.expectError(Error.NoSuchMark, m.rename(0, "нет"));
    try testing.expectError(Error.NoSuchMark, m.setColour(0, .red));
}

test "передвинутая через соседа метка остаётся на своём месте по порядку" {
    var m = Marks{};
    _ = try m.add(1 * sec, .red, "раз");
    _ = try m.add(2 * sec, .green, "два");
    _ = try m.add(3 * sec, .blue, "три");

    const now = try m.moveTo(0, 4 * sec);
    try testing.expectEqual(@as(usize, 2), now);
    try testing.expectEqual(@as(usize, 3), m.count);
    // Подпись и цвет поехали вместе с меткой, а не остались на старом месте.
    try testing.expectEqualStrings("раз", m.items[2].title());
    try testing.expectEqual(Colour.red, m.items[2].colour);

    var last: u64 = 0;
    for (m.list()) |it| {
        try testing.expect(it.at_ns >= last);
        last = it.at_ns;
    }
}

test "мышь попадает в ближайшую метку и мимо не попадает" {
    var m = Marks{};
    _ = try m.add(1 * sec, .yellow, "");
    _ = try m.add(5 * sec, .yellow, "");

    const near = sec / 4;
    try testing.expectEqual(@as(?usize, 0), m.nearest(sec, near));
    try testing.expectEqual(@as(?usize, 1), m.nearest(5 * sec + near / 2, near));
    try testing.expectEqual(@as(?usize, null), m.nearest(3 * sec, near));
}

test "прыжок по меткам вперёд и назад" {
    // Метки и ставят затем, чтобы потом пройти по ним подряд.
    var m = Marks{};
    _ = try m.add(2 * sec, .yellow, "");
    _ = try m.add(5 * sec, .yellow, "");
    _ = try m.add(9 * sec, .yellow, "");

    try testing.expectEqual(@as(?usize, 0), m.step(0, true));
    try testing.expectEqual(@as(?usize, 1), m.step(2 * sec, true));
    try testing.expectEqual(@as(?usize, 2), m.step(6 * sec, true));
    // За последней вперёд идти некуда — и это не ошибка, а конец.
    try testing.expectEqual(@as(?usize, null), m.step(9 * sec, true));

    try testing.expectEqual(@as(?usize, 2), m.step(10 * sec, false));
    try testing.expectEqual(@as(?usize, 1), m.step(9 * sec, false));
    try testing.expectEqual(@as(?usize, null), m.step(2 * sec, false));
}

test "прыжок по пустому списку меток ничего не находит" {
    const m = Marks{};
    try testing.expectEqual(@as(?usize, null), m.step(0, true));
    try testing.expectEqual(@as(?usize, null), m.step(1000 * sec, false));
    try testing.expectEqual(@as(?usize, null), m.nearest(0, sec));
}

test "у каждого цвета есть имя и свой оттенок" {
    var seen: [all_colours.len]u32 = undefined;
    for (all_colours, 0..) |col, i| {
        try testing.expect(col.label().len > 0);
        seen[i] = col.rgb();
        // Цвета должны различаться: два одинаковых — это два названия
        // одного и того же, и выбор между ними ничего не значит.
        for (seen[0..i]) |before| {
            try testing.expect(before != col.rgb());
        }
    }
}

test "цвета перебираются по кругу и возвращаются к началу" {
    var col = Colour.yellow;
    var i: usize = 0;
    while (i < all_colours.len) : (i += 1) col = col.next();
    try testing.expectEqual(Colour.yellow, col);
}

test "длинная подпись обрезается по букве, а не по байту" {
    var m = Mark{};
    // Сорок одна русская буква — это больше отведённого места.
    m.setTitle("ааааааааааааааааааааааааааааааааааааааааа");
    try testing.expect(m.title().len <= max_name);
    // И обрезано по целой букве: строка остаётся читаемой.
    try testing.expect(std.unicode.utf8ValidateSlice(m.title()));
}

test "имя по умолчанию читается" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("метка 1", defaultName(&buf, 1));
    try testing.expectEqualStrings("метка 12", defaultName(&buf, 12));
}

test "комментарий метки живёт рядом с именем и не мешает ему" {
    var m = Mark{};
    m.setTitle("переснять");
    m.setComment("свет с другой стороны, микрофон ближе");
    try testing.expectEqualStrings("переснять", m.title());
    try testing.expectEqualStrings("свет с другой стороны, микрофон ближе", m.comment());
}

test "длинный комментарий обрезается по букве" {
    var m = Mark{};
    var long: [max_note * 2]u8 = undefined;
    var i: usize = 0;
    while (i + 1 < long.len) : (i += 2) {
        long[i] = 0xD0;
        long[i + 1] = 0xB0; // русская «а»
    }
    m.setComment(&long);
    try testing.expect(m.comment().len <= max_note);
    try testing.expect(std.unicode.utf8ValidateSlice(m.comment()));
}

test "комментарий едет вместе с меткой" {
    // Он про это место, а не про то время, где метка стояла раньше.
    var m = Marks{};
    _ = try m.add(sec, .red, "раз");
    try m.setComment(0, "тут переснять");
    _ = try m.add(3 * sec, .green, "два");

    const now = try m.moveTo(0, 5 * sec);
    try testing.expectEqualStrings("тут переснять", m.items[now].comment());
    try testing.expectEqualStrings("раз", m.items[now].title());
    // А у соседа комментария как не было, так и нет.
    try testing.expectEqual(@as(usize, 0), m.items[0].comment().len);
}

test "комментарий у несуществующей метки — отказ" {
    var m = Marks{};
    try testing.expectError(Error.NoSuchMark, m.setComment(0, "нет"));
}
