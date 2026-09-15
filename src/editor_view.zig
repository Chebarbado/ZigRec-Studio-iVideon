//! Арифметика таймлайна: где что лежит на экране и во что ткнули мышью.
//!
//! Задача #24. Вынесено отдельно от рисования нарочно. Всё, что человек
//! делает мышью, начинается с вопроса «во что он попал» — и это чистый счёт,
//! который можно проверить тестами. Ошибка здесь не роняет программу,
//! а тихо портит правки: клип берётся не тот, край хватается не с той
//! стороны, и замечают это уже на испорченном проекте.
const std = @import("std");
const timeline = @import("timeline.zig");

/// Ширина левой колонки с именами дорожек.
pub const header_w: i32 = 150;
/// Высота линейки времени сверху.
pub const ruler_h: i32 = 26;
/// Высота одной полосы дорожки.
pub const lane_h: i32 = 56;
/// Зазор между полосами.
pub const lane_gap: i32 = 6;
/// Высота строки с именем в левой колонке дорожки.
///
/// Верхняя строка — имя, всё, что ниже, — вид дорожки и выключатель звука.
/// Две разные вещи в одной колонке должны и ткаться по-разному, иначе
/// двойной щелчок по имени успевает заодно выключить дорожку.
pub const name_line_h: i32 = 24;
/// Насколько близко к краю клипа надо ткнуть, чтобы взяться за край.
pub const edge_grab: i32 = 6;

/// Толщина полосы между окном кадра и таймлайном. За неё тянут мышью.
///
/// Шесть точек: тоньше — не попасть, толще — полоса начинает выглядеть
/// как часть окна, а не как граница.
pub const splitter_h: i32 = 6;
/// Ниже этого окно кадра не сворачивается.
pub const min_preview_h: i32 = 120;
/// Ниже этого не сворачивается таймлайн: в сотню точек влезает линейка
/// и одна полоса дорожки — меньше уже нечего показывать.
pub const min_timeline_h: i32 = 120;

/// Новая высота окна кадра, когда границу тянут мышью в точку `y`.
///
/// `top` — где начинается окно кадра, `room` — сколько высоты у кадра,
/// полосы-границы и таймлайна вместе.
///
/// Вынесено сюда и проверено тестами не от избытка усердия: ошибка здесь
/// схлопывает одну из половин окна в ноль, а обратно её уже не за что
/// ухватить — полосы-границы на экране не остаётся.
pub fn previewHeightAt(y: i32, top: i32, room: i32) i32 {
    const wanted = y - top;
    // Когда окно слишком низкое, места на оба предела не хватает.
    // Тогда кадру достаётся его минимум, а таймлайн уезжает вниз:
    // лучше показать хоть что-то, чем показать ничего.
    const most = @max(room - splitter_h - min_timeline_h, min_preview_h);
    return std.math.clamp(wanted, min_preview_h, most);
}

/// Попала ли мышь на полосу-границу.
pub fn onSplitter(y: i32, top: i32, preview_h: i32) bool {
    return y >= top + preview_h and y < top + preview_h + splitter_h;
}

/// Что видно на экране: с какого времени и в каком масштабе.
pub const View = struct {
    /// Время у левого края полосы.
    at_ns: u64 = 0,
    /// Сколько наносекунд в одном пикселе. Больше — мельче масштаб.
    ns_per_px: u64 = 20 * std.time.ns_per_ms,
    /// Первая видимая дорожка.
    first_track: usize = 0,

    /// Самый мелкий и самый крупный масштаб.
    ///
    /// Крупнее миллисекунды на пиксель не нужно: точнее кадра всё равно
    /// не режем. Мельче минуты на пиксель — часовая запись уже влезает
    /// в экран целиком.
    pub const finest_ns_per_px: u64 = std.time.ns_per_ms / 2;
    pub const coarsest_ns_per_px: u64 = std.time.ns_per_s;

    pub fn timeToX(self: View, when_ns: u64) i32 {
        if (self.ns_per_px == 0) return header_w;
        const delta = @as(i64, @intCast(when_ns)) - @as(i64, @intCast(self.at_ns));
        const px = @divTrunc(delta, @as(i64, @intCast(self.ns_per_px)));
        // Прижимаем к разумным пределам: далёкое время не должно
        // переполнять координату окна.
        const clamped = std.math.clamp(px, -100_000, 100_000);
        return header_w + @as(i32, @intCast(clamped));
    }

    pub fn xToTime(self: View, x: i32) u64 {
        const from_left = @as(i64, x - header_w);
        const ns = from_left * @as(i64, @intCast(self.ns_per_px)) + @as(i64, @intCast(self.at_ns));
        return if (ns < 0) 0 else @intCast(ns);
    }

    /// Изменить масштаб, оставив на месте время под указателем.
    ///
    /// Иначе при каждом повороте колеса картинка уезжает, и человек теряет
    /// то место, на которое смотрел.
    pub fn zoomAt(self: View, x: i32, closer: bool) View {
        const anchor = self.xToTime(x);
        var out = self;
        out.ns_per_px = if (closer)
            @max(self.ns_per_px * 2 / 3, finest_ns_per_px)
        else
            @min(self.ns_per_px * 3 / 2, coarsest_ns_per_px);

        // Двигаем начало так, чтобы `anchor` остался под тем же пикселем.
        const from_left = @as(i64, x - header_w);
        const shift = from_left * @as(i64, @intCast(out.ns_per_px));
        const start = @as(i64, @intCast(anchor)) - shift;
        out.at_ns = if (start < 0) 0 else @intCast(start);
        return out;
    }

    /// Шаг делений линейки: такой, чтобы подписи не слипались.
    ///
    /// Перебираем «человеческие» доли времени, а не берём первое подходящее
    /// число: деления через 0.3 секунды читать нельзя.
    pub fn rulerStepNs(self: View) u64 {
        const nice = [_]u64{
            10 * std.time.ns_per_ms,
            50 * std.time.ns_per_ms,
            100 * std.time.ns_per_ms,
            500 * std.time.ns_per_ms,
            std.time.ns_per_s,
            2 * std.time.ns_per_s,
            5 * std.time.ns_per_s,
            10 * std.time.ns_per_s,
            30 * std.time.ns_per_s,
            60 * std.time.ns_per_s,
            300 * std.time.ns_per_s,
            600 * std.time.ns_per_s,
        };
        // Подпись занимает около шестидесяти точек.
        const want = @as(u64, 60) * self.ns_per_px;
        for (nice) |step| {
            if (step >= want) return step;
        }
        return nice[nice.len - 1];
    }

    /// Верх полосы дорожки с таким номером.
    pub fn laneTop(self: View, track_index: usize) i32 {
        const offset = @as(i32, @intCast(track_index -| self.first_track));
        return ruler_h + offset * (lane_h + lane_gap);
    }

    /// Какая дорожка под этой высотой. `null` — мимо полос.
    pub fn trackAtY(self: View, y: i32, track_count: usize) ?usize {
        if (y < ruler_h) return null;
        const step = lane_h + lane_gap;
        const index = @divTrunc(y - ruler_h, step);
        if (index < 0) return null;
        const within = y - ruler_h - index * step;
        // Попадание в зазор между полосами — это не попадание в дорожку.
        if (within >= lane_h) return null;
        const track = self.first_track + @as(usize, @intCast(index));
        return if (track < track_count) track else null;
    }
};

/// Во что ткнули.
pub const Target = enum {
    /// Мимо всего.
    empty,
    /// Линейка времени: перенос указателя воспроизведения.
    ruler,
    /// Левая колонка дорожки, строка имени: выбор и переименование.
    header_name,
    /// Левая колонка дорожки ниже имени: включение и выключение звука.
    header,
    /// Тело клипа: перетаскивание.
    clip,
    /// Левый край клипа: обрезка.
    clip_left,
    /// Правый край клипа: обрезка.
    clip_right,
    /// Пустое место на полосе дорожки.
    lane,
};

pub const Hit = struct {
    target: Target = .empty,
    track: usize = 0,
    clip: usize = 0,
    /// Время под указателем.
    when_ns: u64 = 0,

    /// Тянут ли за край — тогда курсор меняется на «растянуть».
    pub fn isEdge(self: Hit) bool {
        return self.target == .clip_left or self.target == .clip_right;
    }
};

/// Что находится под точкой.
///
/// Края проверяются раньше тела: полоска в шесть точек у границы должна
/// хвататься как край, иначе обрезать короткий клип нечем — он весь
/// оказывается «телом».
pub fn hitTest(project: *const timeline.Project, view: View, x: i32, y: i32) Hit {
    if (y < ruler_h) {
        return .{ .target = .ruler, .when_ns = view.xToTime(x) };
    }
    const track_index = view.trackAtY(y, project.track_count) orelse return .{};
    if (x < header_w) {
        const within = y - view.laneTop(track_index);
        return .{
            .target = if (within < name_line_h) .header_name else .header,
            .track = track_index,
        };
    }

    const when = view.xToTime(x);
    const track = &project.tracks[track_index];
    for (track.list(), 0..) |clip, i| {
        const left = view.timeToX(clip.at_ns);
        const right = view.timeToX(clip.endsAt());
        if (x < left - edge_grab or x > right + edge_grab) continue;

        // У очень узкого клипа края перекрываются: тогда левая половина
        // считается левым краем, правая — правым, а тела нет вовсе.
        if (right - left <= edge_grab * 2) {
            const middle = @divTrunc(left + right, 2);
            return .{
                .target = if (x < middle) .clip_left else .clip_right,
                .track = track_index,
                .clip = i,
                .when_ns = when,
            };
        }
        if (x <= left + edge_grab) {
            return .{ .target = .clip_left, .track = track_index, .clip = i, .when_ns = when };
        }
        if (x >= right - edge_grab) {
            return .{ .target = .clip_right, .track = track_index, .clip = i, .when_ns = when };
        }
        return .{ .target = .clip, .track = track_index, .clip = i, .when_ns = when };
    }
    return .{ .target = .lane, .track = track_index, .when_ns = when };
}

/// Подпись времени для линейки: минуты, секунды и доли, если масштаб мелкий.
pub fn timeLabel(buf: []u8, when_ns: u64, step_ns: u64) []const u8 {
    const total_ms = when_ns / std.time.ns_per_ms;
    const minutes = total_ms / 60_000;
    const seconds = (total_ms / 1000) % 60;
    const millis = total_ms % 1000;

    if (step_ns >= std.time.ns_per_s) {
        return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ minutes, seconds }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}.{d:0>1}", .{ minutes, seconds, millis / 100 }) catch "";
}

/// Длительность словами: для подписи на клипе.
pub fn lengthLabel(buf: []u8, len_ns: u64) []const u8 {
    const secs = @as(f64, @floatFromInt(len_ns)) / @as(f64, std.time.ns_per_s);
    if (secs < 10) return std.fmt.bufPrint(buf, "{d:.2} с", .{secs}) catch "";
    if (secs < 60) return std.fmt.bufPrint(buf, "{d:.1} с", .{secs}) catch "";
    const minutes = @as(u64, @intFromFloat(secs)) / 60;
    const rest = @as(u64, @intFromFloat(secs)) % 60;
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ minutes, rest }) catch "";
}

// ---------------------------------------------------------------- тесты

const sec = std.time.ns_per_s;

fn testProject() !*timeline.Project {
    const p = try std.testing.allocator.create(timeline.Project);
    p.* = .{};
    _ = try p.addSource("тест.mp4", 60 * sec);
    _ = try p.addTrack(.video, "Видео");
    _ = try p.addTrack(.audio, "Звук");
    return p;
}

test "время и пиксели переводятся друг в друга" {
    const v = View{ .at_ns = 0, .ns_per_px = 10 * std.time.ns_per_ms };
    // Секунда — это сто точек при десяти миллисекундах на точку.
    try std.testing.expectEqual(header_w + 100, v.timeToX(sec));
    try std.testing.expectEqual(@as(u64, sec), v.xToTime(header_w + 100));
    // Левый край полосы — это начало видимого времени.
    try std.testing.expectEqual(@as(u64, 0), v.xToTime(header_w));
}

test "прокрутка сдвигает, но не меняет масштаб" {
    const v = View{ .at_ns = 5 * sec, .ns_per_px = 10 * std.time.ns_per_ms };
    try std.testing.expectEqual(header_w, v.timeToX(5 * sec));
    try std.testing.expectEqual(header_w + 100, v.timeToX(6 * sec));
    // Время левее видимого уходит в минус, а не обрезается в ноль.
    try std.testing.expect(v.timeToX(4 * sec) < header_w);
}

test "время левее начала не уходит в отрицательное" {
    const v = View{ .at_ns = 0, .ns_per_px = 10 * std.time.ns_per_ms };
    try std.testing.expectEqual(@as(u64, 0), v.xToTime(header_w - 500));
}

test "масштаб меняется вокруг указателя, картинка не уезжает" {
    const v = View{ .at_ns = 10 * sec, .ns_per_px = 20 * std.time.ns_per_ms };
    const x: i32 = header_w + 300;
    const under = v.xToTime(x);

    const closer = v.zoomAt(x, true);
    try std.testing.expect(closer.ns_per_px < v.ns_per_px);
    // То же время осталось под тем же пикселем — с точностью до одной точки.
    const after = closer.xToTime(x);
    const diff = if (after > under) after - under else under - after;
    try std.testing.expect(diff <= closer.ns_per_px);
}

test "масштаб не уходит за пределы" {
    var v = View{ .ns_per_px = View.finest_ns_per_px };
    var i: usize = 0;
    while (i < 20) : (i += 1) v = v.zoomAt(header_w, true);
    try std.testing.expectEqual(View.finest_ns_per_px, v.ns_per_px);

    v = View{ .ns_per_px = View.coarsest_ns_per_px };
    i = 0;
    while (i < 20) : (i += 1) v = v.zoomAt(header_w, false);
    try std.testing.expectEqual(View.coarsest_ns_per_px, v.ns_per_px);
}

test "деления линейки — человеческие доли, а не любые" {
    // Мелкий масштаб: деления реже.
    const coarse = View{ .ns_per_px = std.time.ns_per_s };
    try std.testing.expect(coarse.rulerStepNs() >= 60 * sec);

    const fine = View{ .ns_per_px = std.time.ns_per_ms };
    const step = fine.rulerStepNs();
    // Шаг должен быть из списка круглых, а не произвольным.
    const nice = [_]u64{ 10, 50, 100, 500 };
    var found = false;
    for (nice) |ms| {
        if (step == ms * std.time.ns_per_ms) found = true;
    }
    try std.testing.expect(found);
}

test "дорожка под высотой, и зазор между полосами — не дорожка" {
    const v = View{};
    try std.testing.expectEqual(@as(usize, 0), v.trackAtY(ruler_h + 5, 2).?);
    try std.testing.expectEqual(@as(usize, 1), v.trackAtY(ruler_h + lane_h + lane_gap + 5, 2).?);
    // В зазоре ничего нет.
    try std.testing.expect(v.trackAtY(ruler_h + lane_h + 2, 2) == null);
    // Выше полос — линейка.
    try std.testing.expect(v.trackAtY(ruler_h - 1, 2) == null);
    // Ниже последней дорожки — пусто.
    try std.testing.expect(v.trackAtY(ruler_h + 3 * (lane_h + lane_gap), 2) == null);
}

test "попадание: линейка, колонка имён, тело клипа" {
    const p = try testProject();
    defer std.testing.allocator.destroy(p);
    try p.place(0, 0, 0, 10 * sec);

    const v = View{ .at_ns = 0, .ns_per_px = 20 * std.time.ns_per_ms };

    try std.testing.expectEqual(Target.ruler, hitTest(p, v, 300, 5).target);
    // Колонка имён делится надвое: сверху имя, ниже выключатель звука.
    try std.testing.expectEqual(Target.header_name, hitTest(p, v, 40, ruler_h + 10).target);
    try std.testing.expectEqual(Target.header, hitTest(p, v, 40, ruler_h + name_line_h + 4).target);

    // Середина клипа — тело.
    const middle = v.timeToX(5 * sec);
    const hit = hitTest(p, v, middle, ruler_h + 10);
    try std.testing.expectEqual(Target.clip, hit.target);
    try std.testing.expectEqual(@as(usize, 0), hit.clip);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), @as(f64, @floatFromInt(hit.when_ns)) / @as(f64, sec), 0.1);
}

test "края клипа хватаются раньше тела" {
    const p = try testProject();
    defer std.testing.allocator.destroy(p);
    try p.place(0, 0, 2 * sec, 10 * sec);

    const v = View{ .at_ns = 0, .ns_per_px = 20 * std.time.ns_per_ms };
    const left = v.timeToX(2 * sec);
    const right = v.timeToX(12 * sec);

    try std.testing.expectEqual(Target.clip_left, hitTest(p, v, left + 2, ruler_h + 10).target);
    try std.testing.expectEqual(Target.clip_right, hitTest(p, v, right - 2, ruler_h + 10).target);
    // Чуть дальше от края — уже тело.
    try std.testing.expectEqual(Target.clip, hitTest(p, v, left + edge_grab + 5, ruler_h + 10).target);
}

test "у очень узкого клипа тела нет, только два края" {
    const p = try testProject();
    defer std.testing.allocator.destroy(p);
    // Клип на 0.1 секунды при 20 мс на точку — это пять точек.
    try p.place(0, 0, 0, sec / 10);

    const v = View{ .at_ns = 0, .ns_per_px = 20 * std.time.ns_per_ms };
    const left = v.timeToX(0);
    const right = v.timeToX(sec / 10);

    try std.testing.expectEqual(Target.clip_left, hitTest(p, v, left, ruler_h + 10).target);
    try std.testing.expectEqual(Target.clip_right, hitTest(p, v, right, ruler_h + 10).target);
}

test "пустое место на полосе — это не клип" {
    const p = try testProject();
    defer std.testing.allocator.destroy(p);
    try p.place(0, 0, 0, 2 * sec);

    const v = View{ .at_ns = 0, .ns_per_px = 20 * std.time.ns_per_ms };
    const far = v.timeToX(30 * sec);
    const hit = hitTest(p, v, far, ruler_h + 10);
    try std.testing.expectEqual(Target.lane, hit.target);
    try std.testing.expectEqual(@as(usize, 0), hit.track);
}

test "подписи времени читаются" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1:05", timeLabel(&buf, 65 * sec, sec));
    try std.testing.expectEqualStrings("0:02.5", timeLabel(&buf, 2500 * std.time.ns_per_ms, 100 * std.time.ns_per_ms));
}

test "длительность клипа подписывается по-разному в зависимости от длины" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("3.50 с", lengthLabel(&buf, 3500 * std.time.ns_per_ms));
    try std.testing.expectEqualStrings("42.0 с", lengthLabel(&buf, 42 * sec));
    try std.testing.expectEqualStrings("2:05", lengthLabel(&buf, 125 * sec));
}

test "граница двигается вслед за мышью" {
    // Окно высотой 800, кадр начинается на 82.
    try std.testing.expectEqual(@as(i32, 200), previewHeightAt(282, 82, 700));
    try std.testing.expectEqual(@as(i32, 400), previewHeightAt(482, 82, 700));
}

test "ни кадр, ни таймлайн не схлопываются в ноль" {
    // Тянем к самому верху: кадру остаётся его минимум.
    try std.testing.expectEqual(min_preview_h, previewHeightAt(0, 82, 700));
    try std.testing.expectEqual(min_preview_h, previewHeightAt(-500, 82, 700));

    // Тянем к самому низу: таймлайну остаётся его минимум.
    const most = 700 - splitter_h - min_timeline_h;
    try std.testing.expectEqual(most, previewHeightAt(10_000, 82, 700));
    // И на этой высоте таймлайну действительно хватает места.
    try std.testing.expect(700 - most - splitter_h >= min_timeline_h);
}

test "в низком окне кадр получает свой минимум, а не отрицательную высоту" {
    // Места мало: предел снизу важнее предела сверху.
    const h = previewHeightAt(500, 82, 150);
    try std.testing.expectEqual(min_preview_h, h);
    try std.testing.expect(h > 0);
}

test "полоса-граница ловится ровно там, где нарисована" {
    // Кадр от 82 высотой 260: полоса занимает 342..348.
    try std.testing.expect(!onSplitter(341, 82, 260));
    try std.testing.expect(onSplitter(342, 82, 260));
    try std.testing.expect(onSplitter(347, 82, 260));
    try std.testing.expect(!onSplitter(348, 82, 260));
}

test "имя дорожки и выключатель звука — разные цели" {
    const p = try testProject();
    defer std.testing.allocator.destroy(p);
    const v = View{};

    // Верхняя строка первой полосы — имя.
    const top = v.laneTop(0);
    try std.testing.expectEqual(Target.header_name, hitTest(p, v, 20, top + 2).target);
    try std.testing.expectEqual(Target.header_name, hitTest(p, v, 20, top + name_line_h - 1).target);

    // Ниже — вид дорожки и выключатель.
    try std.testing.expectEqual(Target.header, hitTest(p, v, 20, top + name_line_h).target);
    try std.testing.expectEqual(Target.header, hitTest(p, v, 20, top + lane_h - 2).target);

    // Обе цели говорят про ту же дорожку.
    try std.testing.expectEqual(@as(usize, 1), hitTest(p, v, 20, v.laneTop(1) + 2).track);
}

test "за левой колонкой имени нет" {
    const p = try testProject();
    defer std.testing.allocator.destroy(p);
    const v = View{};
    const got = hitTest(p, v, header_w + 5, v.laneTop(0) + 2);
    try std.testing.expect(got.target != .header_name and got.target != .header);
}
