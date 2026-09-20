//! Громкость: дорожки, клипа и кривая поверх дорожки.
//!
//! Задачи #61 и #62. Правка звука начинается не с эффектов, а с двух вещей:
//! сделать дорожку тише и сделать один кусок тише остального. Первое — это
//! число, второе — ломаная линия поверх волны, как в Logic.
//!
//! **Громкость считается в децибелах, а не в разах.** Слух устроен так, что
//! «вдвое тише» — это не половина отсчёта, а минус шесть децибел. Ползунок
//! в разах на середине даёт заметно тихий звук и упирается в ноль у самого
//! края; в децибелах он ведёт себя так, как человек ожидает.
//!
//! **Хранится целым числом, десятыми долями децибела.** Дробь в модели
//! проекта — это несходящееся сравнение и запись, которая не читается
//! обратно тем же числом. Десятая доля децибела неразличима на слух,
//! поэтому округлять до неё не жалко.
//!
//! **Единица — это ноль.** Умолчание всех полей проекта обязано быть
//! нулевым, иначе восемьсот килобайт модели лягут в .exe готовыми байтами
//! (это уже случалось и стоило восьмисот килобайт). Ноль децибел — это
//! «как записано», и умолчание сходится с единицей усиления само.
const std = @import("std");
const lang = @import("../lang.zig");

/// Громкость в десятых долях децибела. Ноль — как записано.
pub const Db10 = i16;

/// Как записано: ни тише, ни громче.
pub const unity: Db10 = 0;

/// Ниже этого — тишина. Шестьдесят децибел вниз это в тысячу раз тише;
/// всё, что тише, человек уже не отличает от выключенного, а хранить
/// «минус двести децибел» незачем.
pub const min_db10: Db10 = -600;

/// Выше этого не поднимаем. Двенадцать децибел вверх — это вчетверо;
/// дальше тихая запись не становится лучше, она становится шумной.
pub const max_db10: Db10 = 120;

/// Прижать к пределам. Число приходит и от ползунка, и из файла проекта,
/// написанного чужой рукой, — доверять ему нельзя ни там, ни там.
pub fn clamp(value: Db10) Db10 {
    return std.math.clamp(value, min_db10, max_db10);
}

/// Совсем ли тихо.
pub fn silent(value: Db10) bool {
    return value <= min_db10;
}

/// Во сколько раз умножать отсчёты.
///
/// На нижнем пределе отдаём ровно ноль, а не одну тысячную: «тихо» должно
/// означать тишину, иначе выведенная в ноль дорожка продолжает чуть слышно
/// звучать, и человек ищет, откуда идёт звук.
pub fn factor(value: Db10) f32 {
    const v = clamp(value);
    if (silent(v)) return 0;
    if (v == unity) return 1;
    return std.math.pow(f32, 10, @as(f32, @floatFromInt(v)) / 200.0);
}

/// Обратный счёт: во что превращается множитель.
pub fn fromFactor(mul: f32) Db10 {
    if (mul <= 0) return min_db10;
    const db10 = 200.0 * std.math.log10(mul);
    return clamp(@intFromFloat(@round(db10)));
}

/// Сложить две громкости. Децибелы складываются, разы — умножаются,
/// и это одно и то же действие; складывать дешевле и точнее.
pub fn sum(a: Db10, b: Db10) Db10 {
    if (silent(a) or silent(b)) return min_db10;
    const total = @as(i32, a) + @as(i32, b);
    return clamp(@intCast(std.math.clamp(total, @as(i32, min_db10), @as(i32, max_db10))));
}

/// Подпись для окна: «0.0 дБ», «−6.0 дБ», «тишина».
///
/// Минус — типографский, а не дефис: подпись читают, а не вычитают.
pub fn text(buf: []u8, value: Db10) []const u8 {
    const v = clamp(value);
    if (silent(v)) return lang.t("тишина");
    const whole = @divTrunc(@as(i32, if (v < 0) -v else v), 10);
    const tenth = @mod(@as(i32, if (v < 0) -v else v), 10);
    const sign: []const u8 = if (v < 0) "−" else if (v > 0) "+" else "";
    return lang.print(buf, "{s}{d}.{d} дБ", .{ sign, whole, tenth }) catch lang.t("0.0 дБ");
}

// ------------------------------------------------------------- ползунок

/// Куда встал бы ползунок длиной `span` точек.
///
/// Ползунок линеен по децибелам, а не по разам: так шаг мыши всегда значит
/// одно и то же, а не «еле слышно» у одного края и «вдвое» у другого.
pub fn sliderPos(value: Db10, span: i32) i32 {
    if (span <= 0) return 0;
    const v = clamp(value);
    const from_bottom = @as(i32, v) - @as(i32, min_db10);
    const range = @as(i32, max_db10) - @as(i32, min_db10);
    return @divTrunc(from_bottom * span, range);
}

/// Обратно: во что превращается положение ползунка.
pub fn sliderValue(pos: i32, span: i32) Db10 {
    if (span <= 0) return unity;
    const range = @as(i32, max_db10) - @as(i32, min_db10);
    const at = std.math.clamp(pos, 0, span);
    return clamp(@intCast(@as(i32, min_db10) + @divTrunc(at * range, span)));
}

// ---------------------------------------------------------------- кривая

/// Сколько точек влезает в кривую одной дорожки.
///
/// Цена посчитана, а не взята с потолка. Точка — 16 байт, значит кривая
/// это 520 байт, восемь дорожек — 4 КБ, и столько же добавляется к каждому
/// снимку отмены. Двадцать четыре снимка дают 100 КБ поверх восьмисот,
/// которые проект уже занимает.
pub const max_points = 32;

/// Точка кривой: когда и насколько.
pub const Point = struct {
    /// Время от начала дорожки.
    at_ns: u64 = 0,
    db10: Db10 = 0,
};

pub const Error = error{
    /// Точек больше не помещается.
    TooManyPoints,
    /// Такой точки нет.
    NoSuchPoint,
};

/// Ломаная громкости поверх дорожки.
///
/// Точки держатся отсортированными по времени: так и рисовать проще,
/// и считать значение между ними, и искать ту, в которую попала мышь.
pub const Curve = struct {
    points: [max_points]Point = @splat(.{}),
    count: usize = 0,

    pub fn list(self: *const Curve) []const Point {
        return self.points[0..self.count];
    }

    pub fn empty(self: *const Curve) bool {
        return self.count == 0;
    }

    /// Какова громкость в этой точке времени.
    ///
    /// Между точками — прямая по децибелам: на слух это ровное движение,
    /// а прямая по разам звучала бы как рывок в начале и топтание в конце.
    ///
    /// До первой точки и после последней громкость держится: кривая,
    /// обрывающаяся в тишину за последней точкой, — это не то, что человек
    /// нарисовал, и заметил бы он это уже на готовом файле.
    pub fn valueAt(self: *const Curve, at_ns: u64) Db10 {
        const pts = self.list();
        if (pts.len == 0) return unity;
        if (at_ns <= pts[0].at_ns) return pts[0].db10;
        if (at_ns >= pts[pts.len - 1].at_ns) return pts[pts.len - 1].db10;

        var i: usize = 1;
        while (i < pts.len) : (i += 1) {
            if (at_ns > pts[i].at_ns) continue;
            const a = pts[i - 1];
            const b = pts[i];
            const span = b.at_ns - a.at_ns;
            if (span == 0) return b.db10;
            const gone = at_ns - a.at_ns;
            const from = @as(i64, a.db10);
            const to = @as(i64, b.db10);
            // Считаем в i64: разница громкостей на длинном отрезке легко
            // переполнила бы i32 при умножении на наносекунды.
            const moved = @divTrunc((to - from) * @as(i64, @intCast(gone)), @as(i64, @intCast(span)));
            return clamp(@intCast(from + moved));
        }
        return pts[pts.len - 1].db10;
    }

    /// Поставить точку. Возвращает её номер.
    ///
    /// Точка ровно на времени уже существующей не добавляется второй раз,
    /// а меняет существующую: две точки на одном времени дали бы отвесный
    /// участок, который не нарисовать и не ухватить мышью.
    pub fn add(self: *Curve, at_ns: u64, db10: Db10) Error!usize {
        for (self.points[0..self.count], 0..) |p, i| {
            if (p.at_ns != at_ns) continue;
            self.points[i].db10 = clamp(db10);
            return i;
        }
        if (self.count >= max_points) return Error.TooManyPoints;

        var at: usize = self.count;
        while (at > 0 and self.points[at - 1].at_ns > at_ns) : (at -= 1) {
            self.points[at] = self.points[at - 1];
        }
        self.points[at] = .{ .at_ns = at_ns, .db10 = clamp(db10) };
        self.count += 1;
        return at;
    }

    pub fn removeAt(self: *Curve, index: usize) Error!void {
        if (index >= self.count) return Error.NoSuchPoint;
        var i = index;
        while (i + 1 < self.count) : (i += 1) self.points[i] = self.points[i + 1];
        self.count -= 1;
    }

    /// Передвинуть точку. Возвращает её новый номер: точка могла
    /// перепрыгнуть соседа, а весь остальной код ждёт их по порядку.
    pub fn moveTo(self: *Curve, index: usize, at_ns: u64, db10: Db10) Error!usize {
        if (index >= self.count) return Error.NoSuchPoint;
        const moved = Point{ .at_ns = at_ns, .db10 = clamp(db10) };
        try self.removeAt(index);
        // Через add: он же держит порядок и не пускает двух точек на одно время.
        return self.add(moved.at_ns, moved.db10) catch |err| switch (err) {
            // Место только что освободили — занять его обратно всегда можно.
            Error.TooManyPoints => unreachable,
            else => err,
        };
    }

    /// Какая точка попала под мышь. `tolerance_ns` — полуширина попадания
    /// по времени, пересчитанная окном из точек экрана.
    pub fn nearest(self: *const Curve, at_ns: u64, tolerance_ns: u64) ?usize {
        var best: ?usize = null;
        var best_gap: u64 = std.math.maxInt(u64);
        for (self.list(), 0..) |p, i| {
            const gap = if (p.at_ns > at_ns) p.at_ns - at_ns else at_ns - p.at_ns;
            if (gap > tolerance_ns) continue;
            if (gap >= best_gap) continue;
            best_gap = gap;
            best = i;
        }
        return best;
    }
};

// ---------------------------------------------------------------- тесты

const testing = std.testing;

test "умолчание — единица, и оно нулевое" {
    // Нулевое умолчание обязательно: иначе модель проекта ложится в .exe
    // готовыми байтами.
    const c = Curve{};
    try testing.expectEqual(@as(Db10, 0), unity);
    try testing.expect(std.meta.eql(c, std.mem.zeroes(Curve)));
    try testing.expectEqual(@as(f32, 1), factor(unity));
}

test "минус шесть децибел — это вдвое тише" {
    // Ровно вдвое — это минус 6.02 дБ, а не минус 6.0: круглое число
    // децибел даёт 0.501, и это правильный ответ, а не погрешность.
    try testing.expectApproxEqAbs(@as(f32, 0.5012), factor(-60), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.2512), factor(-120), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.9953), factor(60), 0.001);

    // Ровно половина лежит между двумя соседними десятыми долями
    // (−6.02 дБ), и ближайшая к ней — как раз круглая. Сетка в десятую
    // долю децибела мельче того, что различает слух, поэтому округление
    // сюда и не жалко.
    try testing.expect(@abs(factor(-60) - 0.5) < @abs(factor(-61) - 0.5));
}

test "тишина — это ровно ноль, а не почти ноль" {
    // Выведенная в ноль дорожка должна замолчать, а не звучать еле слышно:
    // иначе человек ищет, откуда идёт звук.
    try testing.expectEqual(@as(f32, 0), factor(min_db10));
    try testing.expectEqual(@as(f32, 0), factor(-30000));
    try testing.expect(silent(min_db10));
    try testing.expect(!silent(min_db10 + 1));
}

test "громкость прижимается к пределам" {
    try testing.expectEqual(max_db10, clamp(30000));
    try testing.expectEqual(min_db10, clamp(-30000));
    try testing.expectEqual(@as(Db10, -35), clamp(-35));
}

test "туда и обратно через множитель" {
    for ([_]Db10{ -600, -200, -60, 0, 60, 120 }) |v| {
        try testing.expectEqual(v, fromFactor(factor(v)));
    }
}

test "складываем децибелы, а не разы" {
    try testing.expectEqual(@as(Db10, -120), sum(-60, -60));
    try testing.expectEqual(@as(Db10, 0), sum(-60, 60));
    // Сумма тоже не вылезает за предел.
    try testing.expectEqual(max_db10, sum(100, 100));
    // Тихое с чем угодно остаётся тихим.
    try testing.expect(silent(sum(min_db10, 120)));
}

test "подпись читается" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0.0 дБ", text(&buf, 0));
    try testing.expectEqualStrings("−6.0 дБ", text(&buf, -60));
    try testing.expectEqualStrings("+3.5 дБ", text(&buf, 35));
    try testing.expectEqualStrings("тишина", text(&buf, min_db10));
}

test "подпись читается и по-английски" {
    // Язык — один на процесс (#100): ставим и возвращаем.
    lang.set(.en);
    defer lang.set(.ru);
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("−6.0 dB", text(&buf, -60));
    try testing.expectEqualStrings("silence", text(&buf, min_db10));
}

test "ползунок линеен по децибелам и ходит туда-обратно" {
    const span = 200;
    try testing.expectEqual(@as(i32, 0), sliderPos(min_db10, span));
    try testing.expectEqual(span, sliderPos(max_db10, span));

    // Середина ползунка — середина диапазона децибел, а не «вдвое тише».
    const middle = sliderValue(@divTrunc(span, 2), span);
    try testing.expectApproxEqAbs(@as(f32, -24), @as(f32, @floatFromInt(middle)) / 10.0, 0.5);

    for ([_]Db10{ -600, -300, -60, 0, 60, 120 }) |v| {
        const back = sliderValue(sliderPos(v, span), span);
        try testing.expectApproxEqAbs(
            @as(f32, @floatFromInt(v)),
            @as(f32, @floatFromInt(back)),
            4, // ползунок в двести точек не различает меньше 3.6 дБ
        );
    }
}

test "ползунок нулевой длины ничего не ломает" {
    try testing.expectEqual(@as(i32, 0), sliderPos(0, 0));
    try testing.expectEqual(unity, sliderValue(50, 0));
}

test "пустая кривая молчит о себе и не трогает звук" {
    const c = Curve{};
    try testing.expect(c.empty());
    try testing.expectEqual(unity, c.valueAt(0));
    try testing.expectEqual(unity, c.valueAt(std.time.ns_per_s * 1000));
}

test "между точками — прямая" {
    var c = Curve{};
    _ = try c.add(0, 0);
    _ = try c.add(std.time.ns_per_s * 10, -120);

    try testing.expectEqual(@as(Db10, 0), c.valueAt(0));
    try testing.expectEqual(@as(Db10, -120), c.valueAt(std.time.ns_per_s * 10));
    try testing.expectEqual(@as(Db10, -60), c.valueAt(std.time.ns_per_s * 5));
    try testing.expectEqual(@as(Db10, -30), c.valueAt(std.time.ns_per_s * 5 / 2));
}

test "за краями кривая держится, а не обрывается" {
    // Обрыв в тишину за последней точкой человек заметил бы уже на готовом
    // файле — это худшее место, где такое можно заметить.
    var c = Curve{};
    _ = try c.add(std.time.ns_per_s * 5, -60);
    _ = try c.add(std.time.ns_per_s * 10, -120);

    try testing.expectEqual(@as(Db10, -60), c.valueAt(0));
    try testing.expectEqual(@as(Db10, -120), c.valueAt(std.time.ns_per_s * 1000));
}

test "точки держатся по порядку, как их ни ставь" {
    var c = Curve{};
    _ = try c.add(std.time.ns_per_s * 10, -10);
    _ = try c.add(std.time.ns_per_s * 2, -20);
    _ = try c.add(std.time.ns_per_s * 6, -30);

    var last: u64 = 0;
    for (c.list()) |p| {
        try testing.expect(p.at_ns >= last);
        last = p.at_ns;
    }
    try testing.expectEqual(@as(usize, 3), c.count);
}

test "вторая точка на том же времени меняет первую, а не встаёт рядом" {
    // Две точки на одном времени дали бы отвесный участок: его не нарисовать
    // и не ухватить мышью.
    var c = Curve{};
    const first = try c.add(std.time.ns_per_s, -10);
    const again = try c.add(std.time.ns_per_s, -50);
    try testing.expectEqual(first, again);
    try testing.expectEqual(@as(usize, 1), c.count);
    try testing.expectEqual(@as(Db10, -50), c.valueAt(std.time.ns_per_s));
}

test "точек больше отведённого не помещается, и об этом говорят" {
    var c = Curve{};
    var i: usize = 0;
    while (i < max_points) : (i += 1) {
        _ = try c.add(@as(u64, i + 1) * std.time.ns_per_s, 0);
    }
    try testing.expectError(Error.TooManyPoints, c.add(std.time.ns_per_s * 10_000, 0));
    // И кривая от неудачи не испортилась.
    try testing.expectEqual(max_points, c.count);
}

test "точку можно убрать" {
    var c = Curve{};
    _ = try c.add(std.time.ns_per_s, -10);
    _ = try c.add(std.time.ns_per_s * 2, -20);
    try c.removeAt(0);
    try testing.expectEqual(@as(usize, 1), c.count);
    try testing.expectEqual(@as(Db10, -20), c.valueAt(0));
    try testing.expectError(Error.NoSuchPoint, c.removeAt(5));
}

test "передвинутая через соседа точка остаётся на своём месте по порядку" {
    var c = Curve{};
    _ = try c.add(std.time.ns_per_s * 1, -10);
    _ = try c.add(std.time.ns_per_s * 2, -20);
    _ = try c.add(std.time.ns_per_s * 3, -30);

    // Первую тянут за третью.
    const now = try c.moveTo(0, std.time.ns_per_s * 4, -10);
    try testing.expectEqual(@as(usize, 2), now);
    try testing.expectEqual(@as(usize, 3), c.count);

    var last: u64 = 0;
    for (c.list()) |p| {
        try testing.expect(p.at_ns >= last);
        last = p.at_ns;
    }
    try testing.expectEqual(@as(Db10, -10), c.valueAt(std.time.ns_per_s * 4));
}

test "мышь попадает в ближайшую точку и мимо не попадает" {
    var c = Curve{};
    _ = try c.add(std.time.ns_per_s * 1, 0);
    _ = try c.add(std.time.ns_per_s * 5, 0);

    const near = std.time.ns_per_s / 4;
    try testing.expectEqual(@as(?usize, 0), c.nearest(std.time.ns_per_s, near));
    try testing.expectEqual(@as(?usize, 1), c.nearest(std.time.ns_per_s * 5 + near / 2, near));
    try testing.expectEqual(@as(?usize, null), c.nearest(std.time.ns_per_s * 3, near));
}

test "громкость кривой прижата к пределам на всём протяжении" {
    // Точки прижаты при постановке, но между ними считается своё число —
    // и оно тоже не должно вылезать.
    var c = Curve{};
    _ = try c.add(0, max_db10);
    _ = try c.add(std.time.ns_per_s * 10, min_db10);

    var t: u64 = 0;
    while (t <= std.time.ns_per_s * 10) : (t += std.time.ns_per_s / 4) {
        const v = c.valueAt(t);
        try testing.expect(v >= min_db10 and v <= max_db10);
    }
}
