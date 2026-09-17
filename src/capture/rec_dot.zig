//! Красная точка записи на кнопках — как на технике.
//!
//! Задача #34. Кружок понятен без подписи: красный — можно писать, пульсирующий
//! — пишем, полый — стоим на паузе, квадрат — остановить. Так устроены
//! диктофоны и камеры полвека, и объяснять это никому не надо.
//!
//! Здесь только правила: какой цвет, какой размер, какая форма при каком
//! состоянии. Рисование — в окне, а правила отдельно, потому что их можно
//! проверить тестом, а рисование нет.
const std = @import("std");
const recorder = @import("../app/recorder.zig");

/// Форма значка на кнопке.
pub const Shape = enum { circle, ring, square };

/// Как выглядит значок при данном состоянии.
pub const Look = struct {
    shape: Shape,
    /// Цвет в формате COLORREF (BGR), как ждёт GDI.
    color: u32,
    /// Радиус в пикселях.
    radius: u32,
};

/// Красный «запись». В BGR, потому что GDI ждёт именно такой порядок.
pub const red: u32 = 0x002E2EE8;
/// Приглушённый красный: кнопка есть, но нажимать нечего.
pub const dim_red: u32 = 0x006E6EA8;
/// Серый для недоступной кнопки.
pub const grey: u32 = 0x00909090;

pub const base_radius: u32 = 6;

/// Значок кнопки «начать запись» или «стоп».
///
/// `pulse` — фаза пульсации от 0 до 255; в покое не используется.
pub fn recordLook(state: recorder.State, enabled: bool, pulse: u8) Look {
    if (!enabled) return .{ .shape = .circle, .color = grey, .radius = base_radius };
    return switch (state) {
        // Идёт запись — на кнопке уже «стоп», и значок квадратный.
        .recording => .{
            .shape = .square,
            .color = red,
            // Квадрат чуть дышит вместе с рамкой: два указателя об одном и том же
            // должны шевелиться в такт, иначе кажется, что это про разное.
            .radius = base_radius + @as(u32, pulse) / 128,
        },
        .paused => .{ .shape = .square, .color = dim_red, .radius = base_radius },
        .stopping => .{ .shape = .square, .color = dim_red, .radius = base_radius },
        .idle => .{ .shape = .circle, .color = red, .radius = base_radius },
    };
}

/// Значок кнопки «пауза»: полый круг, когда пауза возможна.
pub fn pauseLook(state: recorder.State, enabled: bool) Look {
    if (!enabled) return .{ .shape = .ring, .color = grey, .radius = base_radius };
    return switch (state) {
        .paused => .{ .shape = .circle, .color = red, .radius = base_radius },
        else => .{ .shape = .ring, .color = red, .radius = base_radius },
    };
}

/// Пульсация от фазы анимации рамки: значок и рамка должны дышать в такт.
pub fn pulseFromAlpha(alpha: u8) u8 {
    // Прозрачность рамки идёт от 140 до 255; растягиваем на весь диапазон.
    const low: u16 = 140;
    if (alpha <= low) return 0;
    const span: u16 = 255 - low;
    return @intCast((@as(u16, alpha) - low) * 255 / span);
}

// ---------------------------------------------------------------- тесты

test "в покое — красный круг" {
    const look = recordLook(.idle, true, 0);
    try std.testing.expectEqual(Shape.circle, look.shape);
    try std.testing.expectEqual(red, look.color);
}

test "во время записи — квадрат, и он дышит" {
    const quiet = recordLook(.recording, true, 0);
    const loud = recordLook(.recording, true, 255);
    try std.testing.expectEqual(Shape.square, quiet.shape);
    try std.testing.expect(loud.radius > quiet.radius);
}

test "на паузе значок гаснет, но не исчезает" {
    const look = recordLook(.paused, true, 255);
    try std.testing.expectEqual(dim_red, look.color);
    try std.testing.expectEqual(base_radius, look.radius);
}

test "недоступная кнопка — серая" {
    try std.testing.expectEqual(grey, recordLook(.idle, false, 0).color);
    try std.testing.expectEqual(grey, pauseLook(.recording, false).color);
}

test "пауза: полый круг в записи, полный на паузе" {
    try std.testing.expectEqual(Shape.ring, pauseLook(.recording, true).shape);
    try std.testing.expectEqual(Shape.circle, pauseLook(.paused, true).shape);
}

test "пульсация растянута на весь диапазон" {
    try std.testing.expectEqual(@as(u8, 0), pulseFromAlpha(140));
    try std.testing.expectEqual(@as(u8, 0), pulseFromAlpha(100));
    try std.testing.expectEqual(@as(u8, 255), pulseFromAlpha(255));
    const mid = pulseFromAlpha(198);
    try std.testing.expect(mid > 100 and mid < 160);
}

/// Схематичная рамка области вокруг значка записи.
///
/// Кнопка «Записать область» отличается от «Записать экран» только словом,
/// а слово читается медленнее значка. Пунктирная рамка вокруг точки говорит
/// то же самое картинкой — и повторяет ту самую рамку, которая побежит
/// вокруг выбранного прямоугольника во время записи.
pub const AreaFrame = struct {
    /// Половина ширины и высоты от центра значка.
    half_w: i32,
    half_h: i32,
    /// Длина штриха и такого же промежутка.
    dash: i32,

    /// Насколько рамка отстоит от края точки. Меньше двух точек — и рамка
    /// сливается со значком в кляксу.
    pub fn gap(self: AreaFrame, radius: i32) i32 {
        return @min(self.half_w - radius, self.half_h - radius);
    }
};

/// Рамка под значок такого размера.
///
/// Шире, чем выше: так она читается как кусок экрана, а не как рамка вокруг
/// буквы. Растёт вместе со значком, потому что значок дышит во время записи,
/// и застывшая рамка рядом с дышащей точкой выглядит поломкой.
pub fn areaFrame(radius: u32) AreaFrame {
    const r: i32 = @intCast(radius);
    return .{ .half_w = r + 7, .half_h = r + 4, .dash = 3 };
}

/// Значок «одно окно» на кнопке выбора окна.
///
/// Задача #78. Рисуем сами, а не берём знак из шрифта: системный шрифт
/// знает не всякий знак, и вместо значка выходит пустой квадратик —
/// на кнопках пульта это уже случалось.
///
/// Рамка с полосой заголовка и точкой закрытия: так окно рисуют везде,
/// и объяснять это никому не надо — ровно как с красной точкой записи.
pub const WindowGlyph = struct {
    half_w: i32,
    half_h: i32,
    /// Высота полосы заголовка.
    title_h: i32,
    /// Сторона точки закрытия в правом углу заголовка.
    dot: i32,

    /// Влезает ли точка закрытия в полосу заголовка с просветом.
    pub fn dotFits(self: WindowGlyph) bool {
        return self.dot + 2 <= self.title_h and self.dot * 3 <= self.half_w * 2;
    }
};

/// Значок под кнопку такой-то высоты.
///
/// Шире, чем выше: окно на экране шире, чем выше, и квадратный значок
/// читался бы как кнопка, а не как окно.
pub fn windowGlyph(button_h: i32) WindowGlyph {
    // Значок занимает примерно половину высоты кнопки: больше выглядит
    // тяжелее подписи, меньше — не читается.
    const half_h = @max(@divTrunc(button_h, 4), 4);
    // Заголовок считается первым, а точка — от него: точка должна влезть
    // в заголовок с просветом, а не наоборот. Считая её отдельно, легко
    // получить точку выше полосы, в которой она нарисована.
    const title_h = @max(@divTrunc(half_h, 2), 4);
    return .{
        .half_w = half_h + @divTrunc(half_h, 2) + 1,
        .half_h = half_h,
        .title_h = title_h,
        .dot = @max(title_h - 2, 2),
    };
}

test "значок окна шире, чем выше" {
    // Квадратный значок читался бы как кнопка, а не как окно.
    var h: i32 = 20;
    while (h <= 40) : (h += 2) {
        const g = windowGlyph(h);
        try std.testing.expect(g.half_w > g.half_h);
    }
}

test "полоса заголовка не съедает всё окно" {
    var h: i32 = 20;
    while (h <= 40) : (h += 2) {
        const g = windowGlyph(h);
        // Под заголовком должно остаться хотя бы столько же места,
        // сколько занял он сам, иначе значок читается как полоска.
        try std.testing.expect(g.title_h * 2 <= g.half_h * 2);
        try std.testing.expect(g.title_h >= 3);
    }
}

test "точка закрытия влезает в заголовок при любом размере кнопки" {
    var h: i32 = 20;
    while (h <= 48) : (h += 1) {
        try std.testing.expect(windowGlyph(h).dotFits());
    }
}

test "на крошечной кнопке значок не схлопывается в ноль" {
    const g = windowGlyph(4);
    try std.testing.expect(g.half_h >= 4);
    try std.testing.expect(g.half_w > 0);
    try std.testing.expect(g.dot >= 2);
}

test "рамка области шире, чем выше — читается как кусок экрана" {
    const f = areaFrame(base_radius);
    try std.testing.expect(f.half_w > f.half_h);
}

test "точка не сливается с рамкой ни при каком размере" {
    var r: u32 = 3;
    while (r <= 12) : (r += 1) {
        const f = areaFrame(r);
        // Просвет не меньше двух точек с каждой стороны.
        try std.testing.expect(f.gap(@intCast(r)) >= 2);
    }
}

test "рамка растёт вместе со значком" {
    const small = areaFrame(base_radius);
    const big = areaFrame(base_radius + 2);
    try std.testing.expect(big.half_w > small.half_w);
    try std.testing.expect(big.half_h > small.half_h);
}

test "штрих не длиннее половины стороны: иначе это не пунктир" {
    const f = areaFrame(base_radius);
    try std.testing.expect(f.dash * 2 < f.half_h * 2);
    try std.testing.expect(f.dash > 0);
}
