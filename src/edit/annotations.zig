//! Аннотации: текст, стрелки и выноски поверх кадра, со временем появления
//! и исчезновения.
//!
//! Задача #28. Аннотация живёт на времени проекта, как метка (#79), но
//! в отличие от метки у неё есть место в кадре и вид. Место — в тысячных
//! долях ширины и высоты кадра, а не в точках: кадр в предпросмотре и
//! кадр в экспорте разного размера, а аннотация должна стоять там же.
//! Правила здесь — без окна, с тестами.
const std = @import("std");
const lang = @import("../lang.zig");
const marks = @import("marks.zig");

pub const max_annotations = 32;
pub const max_text = 80;
/// Сколько держится аннотация, если не сказано иначе: три секунды —
/// успеть прочитать короткую фразу.
pub const default_len_ns: u64 = 3 * std.time.ns_per_s;
/// Короче — не увидеть.
pub const min_len_ns: u64 = std.time.ns_per_s / 4;
/// Тысячные доли: 0 — левый (верхний) край, 1000 — правый (нижний).
pub const per_mille: i32 = 1000;

pub const Error = error{
    TooManyAnnotations,
    NoSuchAnnotation,
};

pub const Kind = enum {
    /// Надпись с подложкой.
    text,
    /// Стрелка от (x, y) к (x2, y2).
    arrow,
    /// Надпись с указкой на (x2, y2).
    callout,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .text => lang.t("текст"),
            .arrow => lang.t("стрелка"),
            .callout => lang.t("выноска"),
        };
    }
};

pub const Annotation = struct {
    at_ns: u64 = 0,
    len_ns: u64 = 0,
    kind: Kind = .text,
    /// Место в тысячных долях кадра.
    x: i32 = 0,
    y: i32 = 0,
    /// Куда показывает стрелка или указка выноски.
    x2: i32 = 0,
    y2: i32 = 0,
    colour: marks.Colour = .yellow,
    text: [max_text]u8 = @splat(0),
    text_len: u8 = 0,

    pub fn title(self: *const Annotation) []const u8 {
        return self.text[0..self.text_len];
    }

    pub fn setText(self: *Annotation, value: []const u8) void {
        const n: u8 = @intCast(@min(value.len, max_text));
        @memcpy(self.text[0..n], value[0..n]);
        self.text_len = n;
    }

    pub fn endsAt(self: Annotation) u64 {
        return self.at_ns + self.len_ns;
    }

    /// Видна ли в этот момент.
    pub fn visibleAt(self: Annotation, when_ns: u64) bool {
        return when_ns >= self.at_ns and when_ns < self.endsAt();
    }

    /// Есть ли у вида вторая точка.
    pub fn hasEnd(self: Annotation) bool {
        return self.kind != .text;
    }
};

fn clampMille(v: i32) i32 {
    return std.math.clamp(v, 0, per_mille);
}

pub const Annotations = struct {
    items: [max_annotations]Annotation = @splat(.{}),
    count: usize = 0,

    pub fn list(self: *const Annotations) []const Annotation {
        return self.items[0..self.count];
    }

    /// Добавить; возвращает номер. Держим по времени начала.
    pub fn add(self: *Annotations, made: Annotation) Error!usize {
        if (self.count >= max_annotations) return Error.TooManyAnnotations;
        var a = made;
        a.len_ns = @max(a.len_ns, min_len_ns);
        a.x = clampMille(a.x);
        a.y = clampMille(a.y);
        a.x2 = clampMille(a.x2);
        a.y2 = clampMille(a.y2);
        var at: usize = self.count;
        while (at > 0 and self.items[at - 1].at_ns > a.at_ns) : (at -= 1) {
            self.items[at] = self.items[at - 1];
        }
        self.items[at] = a;
        self.count += 1;
        return at;
    }

    pub fn removeAt(self: *Annotations, index: usize) Error!void {
        if (index >= self.count) return Error.NoSuchAnnotation;
        var i = index;
        while (i + 1 < self.count) : (i += 1) self.items[i] = self.items[i + 1];
        self.count -= 1;
    }

    /// Передвинуть по времени; возвращает новый номер.
    pub fn moveTo(self: *Annotations, index: usize, at_ns: u64) Error!usize {
        if (index >= self.count) return Error.NoSuchAnnotation;
        var moved = self.items[index];
        moved.at_ns = at_ns;
        try self.removeAt(index);
        return self.add(moved) catch unreachable;
    }

    pub fn setLength(self: *Annotations, index: usize, len_ns: u64) Error!void {
        if (index >= self.count) return Error.NoSuchAnnotation;
        self.items[index].len_ns = @max(len_ns, min_len_ns);
    }

    pub fn setText(self: *Annotations, index: usize, text: []const u8) Error!void {
        if (index >= self.count) return Error.NoSuchAnnotation;
        self.items[index].setText(text);
    }

    /// Поставить в кадре: начало и, если есть, конец.
    pub fn place(self: *Annotations, index: usize, x: i32, y: i32) Error!void {
        if (index >= self.count) return Error.NoSuchAnnotation;
        self.items[index].x = clampMille(x);
        self.items[index].y = clampMille(y);
    }

    pub fn placeEnd(self: *Annotations, index: usize, x2: i32, y2: i32) Error!void {
        if (index >= self.count) return Error.NoSuchAnnotation;
        self.items[index].x2 = clampMille(x2);
        self.items[index].y2 = clampMille(y2);
    }

    /// Сколько аннотаций видно в этот момент.
    pub fn visibleCount(self: *const Annotations, when_ns: u64) usize {
        var n: usize = 0;
        for (self.list()) |a| {
            if (a.visibleAt(when_ns)) n += 1;
        }
        return n;
    }

    /// Ближайшая к точке кадра из видимых в этот момент: по началу или
    /// по концу (`grab_end`), в тысячных долях, не дальше `within`.
    pub const Hit = struct { index: usize, end: bool };

    pub fn nearestAt(self: *const Annotations, when_ns: u64, x: i32, y: i32, within: i32) ?Hit {
        var best: ?Hit = null;
        var best_d: i64 = @as(i64, within) * within + 1;
        for (self.list(), 0..) |a, i| {
            if (!a.visibleAt(when_ns)) continue;
            const d1 = dist2(a.x, a.y, x, y);
            if (d1 < best_d) {
                best_d = d1;
                best = .{ .index = i, .end = false };
            }
            if (a.hasEnd()) {
                const d2 = dist2(a.x2, a.y2, x, y);
                if (d2 < best_d) {
                    best_d = d2;
                    best = .{ .index = i, .end = true };
                }
            }
        }
        return best;
    }

    fn dist2(ax: i32, ay: i32, bx: i32, by: i32) i64 {
        const dx: i64 = ax - bx;
        const dy: i64 = ay - by;
        return dx * dx + dy * dy;
    }
};

/// Шаблоны для горячих клавиш во время записи (#28): одно слово, свой цвет.
pub const Template = struct { text: []const u8, colour: marks.Colour };
pub const templates = [_]Template{
    .{ .text = "Внимание", .colour = .yellow },
    .{ .text = "Шаг", .colour = .green },
    .{ .text = "Ошибка", .colour = .red },
};

// ---------------------------------------------------------------- тесты

const testing = std.testing;
const sec = std.time.ns_per_s;

test "аннотации держатся по времени и видны свой отрезок" {
    var a = Annotations{};
    _ = try a.add(.{ .at_ns = 5 * sec, .len_ns = 2 * sec, .kind = .text, .x = 100, .y = 100 });
    const first = try a.add(.{ .at_ns = 1 * sec, .len_ns = default_len_ns, .kind = .arrow, .x = 10, .y = 10, .x2 = 200, .y2 = 300 });
    try testing.expectEqual(@as(usize, 0), first);
    try testing.expectEqual(@as(u64, 1 * sec), a.list()[0].at_ns);
    try testing.expectEqual(@as(usize, 1), a.visibleCount(2 * sec));
    try testing.expectEqual(@as(usize, 0), a.visibleCount(4 * sec + sec / 2));
    try testing.expectEqual(@as(usize, 1), a.visibleCount(6 * sec));
    // Конец не включается: на седьмой секунде надписи уже нет.
    try testing.expect(!a.list()[1].visibleAt(7 * sec));
}

test "сдвиг по времени сохраняет порядок и всё остальное" {
    var a = Annotations{};
    _ = try a.add(.{ .at_ns = 1 * sec, .len_ns = sec, .kind = .callout, .x = 50, .y = 60, .x2 = 70, .y2 = 80 });
    _ = try a.add(.{ .at_ns = 5 * sec, .len_ns = sec, .kind = .text, .x = 1, .y = 2 });
    try a.setText(0, "смотри сюда");
    const where = try a.moveTo(0, 9 * sec);
    try testing.expectEqual(@as(usize, 1), where);
    try testing.expectEqualStrings("смотри сюда", a.list()[1].title());
    try testing.expectEqual(@as(i32, 70), a.list()[1].x2);
    try testing.expectEqual(Kind.callout, a.list()[1].kind);
}

test "место прижимается к кадру, длина — не короче четверти секунды" {
    var a = Annotations{};
    _ = try a.add(.{ .at_ns = 0, .len_ns = 1, .x = -50, .y = 5000 });
    try testing.expectEqual(@as(i32, 0), a.list()[0].x);
    try testing.expectEqual(per_mille, a.list()[0].y);
    try testing.expectEqual(min_len_ns, a.list()[0].len_ns);
    try a.setLength(0, 0);
    try testing.expectEqual(min_len_ns, a.list()[0].len_ns);
    try a.place(0, 2000, -1);
    try testing.expectEqual(per_mille, a.list()[0].x);
    try testing.expectEqual(@as(i32, 0), a.list()[0].y);
}

test "ближайшая к точке — только из видимых, и конец стрелки тоже цель" {
    var a = Annotations{};
    _ = try a.add(.{ .at_ns = 0, .len_ns = sec, .kind = .arrow, .x = 100, .y = 100, .x2 = 800, .y2 = 800 });
    _ = try a.add(.{ .at_ns = 5 * sec, .len_ns = sec, .kind = .text, .x = 500, .y = 500 });
    const near_start = a.nearestAt(sec / 2, 110, 95, 40).?;
    try testing.expectEqual(@as(usize, 0), near_start.index);
    try testing.expect(!near_start.end);
    const near_end = a.nearestAt(sec / 2, 790, 810, 40).?;
    try testing.expect(near_end.end);
    // Текст на пятой секунде сейчас не виден — не цель.
    try testing.expect(a.nearestAt(sec / 2, 500, 500, 40) == null);
    // Далеко — тоже ничего.
    try testing.expect(a.nearestAt(sec / 2, 400, 400, 40) == null);
}

test "больше предела не помещается, чужой номер — словами" {
    var a = Annotations{};
    var i: usize = 0;
    while (i < max_annotations) : (i += 1) _ = try a.add(.{ .at_ns = i * sec, .len_ns = sec });
    try testing.expectError(Error.TooManyAnnotations, a.add(.{ .at_ns = 0, .len_ns = sec }));
    try testing.expectError(Error.NoSuchAnnotation, a.removeAt(999));
    try testing.expectError(Error.NoSuchAnnotation, a.setText(999, "x"));
}

test "шаблоны для горячих клавиш — три, у каждого своё слово" {
    try testing.expectEqual(@as(usize, 3), templates.len);
    for (templates) |t| try testing.expect(t.text.len > 0);
}
