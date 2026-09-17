//! Пульт управления съёмкой: что на нём написано и где он стоит.
//!
//! Задача #73. Во время записи главное окно мешает: оно большое и само
//! попадает в кадр, если пишется весь экран. Прятать его в трей — значит
//! остаться без управления и без вида на то, что происходит.
//!
//! Пульт — это маленькое окно поверх всех, которое не жалко оставить
//! на экране: время, стоп, пауза и здоровье записи.
//!
//! **Пульт не должен попадать в собственную запись.** При записи области
//! его надо держать за её пределами; при записи всего экрана — честно
//! сказать, что он в кадре, и дать его убрать.
//!
//! Здесь только счёт: где встать и что написать. Само окно — в `ui.zig`.
const std = @import("std");

/// Размер пульта. Маленький нарочно: он стоит поверх работы, и всё лишнее
/// на нём — это то, что закрывает собой чужое окно.
pub const width: i32 = 296;
pub const height: i32 = 120;
/// Отступ от края области и от края экрана.
pub const margin: i32 = 12;

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn right(self: Rect) i32 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) i32 {
        return self.y + self.h;
    }

    pub fn overlaps(self: Rect, other: Rect) bool {
        return self.x < other.right() and other.x < self.right() and
            self.y < other.bottom() and other.y < self.bottom();
    }
};

/// Куда встал пульт и попадает ли он в кадр.
pub const Spot = struct {
    at: Rect = .{},
    /// Пульт неизбежно в кадре: записывают весь экран или область
    /// занимает его целиком.
    in_frame: bool = false,
};

/// Найти пульту место за пределами снимаемой области.
///
/// Пробуем по очереди: под областью, над ней, справа, слева. Порядок
/// не случаен — снизу пульт мешает меньше всего, потому что там обычно
/// панель задач и взгляд туда и так опускается.
///
/// Не нашлось места — говорим об этом прямо, а не ставим пульт в кадр молча.
pub fn place(screen: Rect, area: Rect, whole_screen: bool) Spot {
    const size = Rect{ .w = width, .h = height };

    if (whole_screen) {
        // Пишем весь экран: спрятать пульт негде. Ставим в правый нижний
        // угол и честно говорим, что он в кадре.
        return .{
            .at = .{
                .x = screen.right() - width - margin,
                .y = screen.bottom() - height - margin,
                .w = width,
                .h = height,
            },
            .in_frame = true,
        };
    }

    const tries = [_]Rect{
        // Под областью.
        .{ .x = area.x, .y = area.bottom() + margin, .w = size.w, .h = size.h },
        // Над областью.
        .{ .x = area.x, .y = area.y - height - margin, .w = size.w, .h = size.h },
        // Справа.
        .{ .x = area.right() + margin, .y = area.y, .w = size.w, .h = size.h },
        // Слева.
        .{ .x = area.x - width - margin, .y = area.y, .w = size.w, .h = size.h },
    };

    for (tries) |spot| {
        const fitted = clampTo(spot, screen);
        // Прижатие к экрану могло надвинуть пульт обратно на область.
        if (fitted.overlaps(area)) continue;
        if (!inside(fitted, screen)) continue;
        return .{ .at = fitted, .in_frame = false };
    }

    // Область занимает почти весь экран: деваться некуда.
    return .{
        .at = clampTo(.{
            .x = screen.right() - width - margin,
            .y = screen.bottom() - height - margin,
            .w = width,
            .h = height,
        }, screen),
        .in_frame = true,
    };
}

fn clampTo(what: Rect, screen: Rect) Rect {
    var out = what;
    out.x = std.math.clamp(out.x, screen.x, @max(screen.right() - out.w, screen.x));
    out.y = std.math.clamp(out.y, screen.y, @max(screen.bottom() - out.h, screen.y));
    return out;
}

fn inside(what: Rect, screen: Rect) bool {
    return what.x >= screen.x and what.y >= screen.y and
        what.right() <= screen.right() and what.bottom() <= screen.bottom();
}

// ------------------------------------------------------------ надписи

/// Что происходит с записью.
pub const State = enum { recording, paused };

/// Что показывать на пульте.
pub const Look = struct {
    /// Время крупно: его читают искоса.
    time: []const u8,
    /// Подпись на кнопке паузы.
    pause: []const u8,
    /// Здоровье записи: кадры и потери.
    health: []const u8,
};

/// Время записи словами.
///
/// Минуты и секунды, а на длинной записи — часы. Доли секунды не пишем:
/// на пульте они только мельтешат.
pub fn timeText(buf: []u8, elapsed_ns: u64) []const u8 {
    const total = elapsed_ns / std.time.ns_per_s;
    const hours = total / 3600;
    const minutes = (total / 60) % 60;
    const seconds = total % 60;
    if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds }) catch "0:00";
    }
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ minutes, seconds }) catch "00:00";
}

/// Здоровье записи одной строкой.
///
/// Потери называем всегда, даже когда их нет: «потерь 0» успокаивает,
/// а молчание оставляет вопрос.
pub fn healthText(buf: []u8, frames: u64, dropped: u64) []const u8 {
    return std.fmt.bufPrint(buf, "кадров {d}, потерь {d}", .{ frames, dropped }) catch "";
}

/// Подписи кнопки паузы — обе короткие нарочно. Кнопка растягивается под
/// самую длинную из них, и с «Продолжить» она выходила вдвое шире «Стопа»:
/// пользователь так и сказал — «пауза слишком длинная». «Дальше» говорит
/// то же самое шестью буквами.
pub fn pauseLabel(state: State) []const u8 {
    return switch (state) {
        .recording => "Пауза",
        .paused => "Дальше",
    };
}

/// Какой значок рисовать на кнопке.
///
/// Значки рисуются нами, а не берутся из шрифта. Готовые знаки вроде ⏸ есть
/// не во всяком шрифте, и системный к ним как раз не относится: вместо паузы
/// на кнопке оказывается пустой квадратик. Квадрат, две черты и треугольник
/// рисуются двумя строками кода и есть везде.
pub const Icon = enum { stop, pause, play };

pub fn pauseIcon(state: State) Icon {
    return switch (state) {
        .recording => .pause,
        .paused => .play,
    };
}

// ----------------------------------------------------------- что где лежит

/// Подпись кнопки остановки. Названа здесь, а не в окне: по ней считается
/// ширина кнопки, и разойтись этим двум местам нельзя.
pub const stop_label = "Стоп";

/// Значок на кнопке: сторона квадрата и отступ до подписи.
pub const icon_w: i32 = 12;
pub const icon_gap: i32 = 6;

/// Отступ подписи от края кнопки, слева и справа поровну.
pub const label_pad: i32 = 6;

/// Сколько точек отводим на букву. Взято с запасом над измеренным: значки
/// ⏸ и ▶ шире букв, а на другом языке системы шрифт может оказаться не тем.
/// Хватило ли запаса на самом деле, проверяет стенд `remote-smoke` — он
/// меряет подписи настоящим шрифтом.
pub const per_letter: i32 = 11;

/// Сколько места надо подписи на кнопке.
///
/// Считаем по буквам с запасом: точную ширину знает только тот, кто держит
/// в руках шрифт, а здесь нужно другое — поймать кнопку, в которую подпись
/// заведомо не влезет. Обрезанная подпись на пульте — это кнопка, о смысле
/// которой приходится догадываться во время записи.
pub fn minWidthFor(label: []const u8) i32 {
    const letters = std.unicode.utf8CountCodepoints(label) catch label.len;
    return label_pad * 2 + icon_w + icon_gap + @as(i32, @intCast(letters)) * per_letter;
}

/// Кнопки живут на своей строке, а не сбоку от показаний: подпись
/// «Продолжить» длиннее «Паузы», и если тесниться с ней в один ряд,
/// она обрежется ровно тогда, когда её и надо прочитать.
const buttons_y: i32 = 78;
const button_h: i32 = 32;

/// Кнопка «Стоп».
pub fn stopButton() Rect {
    const w = minWidthFor(stop_label);
    return .{ .x = pauseButton().x - 8 - w, .y = buttons_y, .w = w, .h = button_h };
}

/// Кнопка паузы. Прижата к правому краю: её подпись меняется на длинную
/// «Продолжить», и расти ей надо влево, а не за край пульта.
pub fn pauseButton() Rect {
    const w = @max(minWidthFor(pauseLabel(.recording)), minWidthFor(pauseLabel(.paused)));
    return .{ .x = width - 10 - w, .y = buttons_y, .w = w, .h = button_h };
}

/// Где на кнопке значок.
pub fn iconAt(button: Rect) Rect {
    return .{
        .x = button.x + label_pad,
        .y = button.y + @divTrunc(button.h - icon_w, 2),
        .w = icon_w,
        .h = icon_w,
    };
}

/// С какой точки на кнопке начинается подпись.
pub fn labelX(button: Rect) i32 {
    return button.x + label_pad + icon_w + icon_gap;
}

/// Сколько места на кнопке осталось подписи.
pub fn labelRoom(button: Rect) i32 {
    return button.right() - label_pad - labelX(button);
}

/// Где написано «звук» — слева от полоски.
pub fn levelCaption() Rect {
    return .{ .x = 12, .y = 54, .w = 40, .h = 16 };
}

/// Полоска уровня звука. Стоит над кнопками во всю оставшуюся ширину.
pub fn levelBar() Rect {
    const x = levelCaption().right();
    return .{ .x = x, .y = 58, .w = width - x - 12, .h = 10 };
}

/// Строка о том, что пульт попал в кадр.
pub fn noteAt() Rect {
    return .{ .x = 12, .y = 54, .w = width - 24, .h = 18 };
}

/// Что написать, когда пульт неизбежно в кадре.
///
/// Одной строкой, а не двумя: двум строкам здесь уже не хватает высоты,
/// и нижняя залезла бы на кнопки.
pub const in_frame_note = "пульт в кадре — Esc убрать";

// ---------------------------------------------------------------- тесты

const testing = std.testing;

const screen_fhd = Rect{ .x = 0, .y = 0, .w = 1920, .h = 1080 };

test "пульт встаёт под областью и в неё не лезет" {
    const area = Rect{ .x = 200, .y = 100, .w = 800, .h = 400 };
    const spot = place(screen_fhd, area, false);
    try testing.expect(!spot.in_frame);
    try testing.expect(!spot.at.overlaps(area));
    // Снизу мешает меньше всего — туда и ставим первым делом.
    try testing.expect(spot.at.y >= area.bottom());
}

test "область у самого низа — пульт уходит наверх" {
    const area = Rect{ .x = 200, .y = 700, .w = 800, .h = 370 };
    const spot = place(screen_fhd, area, false);
    try testing.expect(!spot.in_frame);
    try testing.expect(!spot.at.overlaps(area));
}

test "область во весь экран — говорим прямо, что пульт в кадре" {
    // Молча поставить его в кадр значило бы испортить запись и не сказать.
    const area = Rect{ .x = 0, .y = 0, .w = 1920, .h = 1080 };
    const spot = place(screen_fhd, area, false);
    try testing.expect(spot.in_frame);
}

test "запись всего экрана — пульт в кадре, и это сказано" {
    const spot = place(screen_fhd, .{ .x = 0, .y = 0, .w = 1920, .h = 1080 }, true);
    try testing.expect(spot.in_frame);
    // И всё же в правом нижнем углу, а не посреди экрана.
    try testing.expect(spot.at.right() <= screen_fhd.right());
    try testing.expect(spot.at.bottom() <= screen_fhd.bottom());
}

test "пульт никогда не вылезает за экран" {
    const spots = [_]Rect{
        .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .{ .x = 1800, .y = 980, .w = 100, .h = 100 },
        .{ .x = 900, .y = 500, .w = 100, .h = 100 },
        .{ .x = 0, .y = 900, .w = 1920, .h = 180 },
    };
    for (spots) |area| {
        const spot = place(screen_fhd, area, false);
        try testing.expect(spot.at.x >= 0);
        try testing.expect(spot.at.y >= 0);
        try testing.expect(spot.at.right() <= screen_fhd.right());
        try testing.expect(spot.at.bottom() <= screen_fhd.bottom());
    }
}

test "узкая область у края — место находится сбоку" {
    const area = Rect{ .x = 0, .y = 0, .w = 300, .h = 1080 };
    const spot = place(screen_fhd, area, false);
    try testing.expect(!spot.in_frame);
    try testing.expect(!spot.at.overlaps(area));
}

test "время: минуты, а на длинной записи часы" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("00:00", timeText(&buf, 0));
    try testing.expectEqualStrings("00:07", timeText(&buf, 7 * std.time.ns_per_s));
    try testing.expectEqualStrings("01:30", timeText(&buf, 90 * std.time.ns_per_s));
    try testing.expectEqualStrings("59:59", timeText(&buf, 3599 * std.time.ns_per_s));
    try testing.expectEqualStrings("1:00:00", timeText(&buf, 3600 * std.time.ns_per_s));
    try testing.expectEqualStrings("2:05:03", timeText(&buf, (2 * 3600 + 5 * 60 + 3) * std.time.ns_per_s));
}

test "потери называются всегда, даже когда их нет" {
    // «Потерь 0» успокаивает, молчание оставляет вопрос.
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("кадров 120, потерь 0", healthText(&buf, 120, 0));
    try testing.expectEqualStrings("кадров 120, потерь 3", healthText(&buf, 120, 3));
}

test "пауза меняет подпись" {
    try testing.expect(!std.mem.eql(u8, pauseLabel(.recording), pauseLabel(.paused)));
    try testing.expect(pauseLabel(.recording).len > 0);
    try testing.expect(pauseLabel(.paused).len > 0);
}

test "подписи кнопок не наезжают друг на друга и не лезут за край" {
    const stop = stopButton();
    const pause = pauseButton();
    try testing.expect(!stop.overlaps(pause));
    try testing.expect(stop.x > 0);
    try testing.expect(pause.right() <= width);
    try testing.expect(pause.bottom() <= height);
}

test "кнопка паузы не ужимается под короткую подпись" {
    // Подпись меняется на «Продолжить» прямо во время записи. Если мерить
    // кнопку по «Паузе», длинная подпись обрежется ровно тогда, когда её
    // и надо прочитать.
    try testing.expect(pauseButton().w >= minWidthFor(pauseLabel(.paused)));
    try testing.expect(pauseButton().w >= minWidthFor(pauseLabel(.recording)));
}

test "полоска звука не заезжает под кнопки" {
    const bar = levelBar();
    try testing.expect(bar.w > 0);
    try testing.expect(bar.right() <= width - 12);
    try testing.expect(bar.bottom() <= stopButton().y);
    try testing.expect(!bar.overlaps(stopButton()));
    try testing.expect(!levelCaption().overlaps(bar));
}

test "строка о кадре не залезает на кнопки" {
    const note = noteAt();
    try testing.expect(note.bottom() <= stopButton().y);
    try testing.expect(note.right() <= width);
    try testing.expect(in_frame_note.len > 0);
}

test "значок и подпись на кнопке не налезают друг на друга" {
    for ([_]Rect{ stopButton(), pauseButton() }) |b| {
        const ic = iconAt(b);
        try testing.expect(ic.right() <= labelX(b));
        try testing.expect(ic.y >= b.y and ic.bottom() <= b.bottom());
        try testing.expect(labelRoom(b) > 0);
    }
}

test "кнопки помещаются в пульт по высоте и ширине" {
    try testing.expect(stopButton().x >= 12);
    try testing.expect(pauseButton().bottom() <= height - 8);
}
