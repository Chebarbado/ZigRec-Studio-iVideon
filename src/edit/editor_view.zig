//! Арифметика таймлайна: где что лежит на экране и во что ткнули мышью.
//!
//! Задача #24. Вынесено отдельно от рисования нарочно. Всё, что человек
//! делает мышью, начинается с вопроса «во что он попал» — и это чистый счёт,
//! который можно проверить тестами. Ошибка здесь не роняет программу,
//! а тихо портит правки: клип берётся не тот, край хватается не с той
//! стороны, и замечают это уже на испорченном проекте.
const std = @import("std");
const timeline = @import("timeline.zig");
const volume = @import("../sound/volume.zig");

/// Громкость наружу: окну и проверкам нужны те же пределы.
pub const Volume = volume;

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

// ------------------------------------------------------------- метки

/// Насколько близко к метке надо ткнуть, чтобы взяться за неё.
///
/// Шире, чем за край клипа: метка — это одна вертикальная черта, и попасть
/// в неё мышью труднее, чем в край клипа высотой в полосу.
pub const mark_grab: i32 = 8;
/// Высота флажка метки на линейке.
pub const mark_flag_h: i32 = 12;
/// Ширина флажка.
pub const mark_flag_w: i32 = 9;

/// Где нарисован флажок метки, стоящей в точке `x`.
pub fn markFlag(x: i32) struct { left: i32, top: i32, right: i32, bottom: i32 } {
    return .{
        .left = x,
        .top = ruler_h - mark_flag_h - 1,
        .right = x + mark_flag_w,
        .bottom = ruler_h - 1,
    };
}

// --------------------------------------------- громкость в левой колонке

/// Высота строки с ползунком громкости — самый низ левой колонки.
///
/// Громкость живёт отдельной строкой, а не рядом с видом дорожки: по виду
/// щёлкают, чтобы выключить звук, и ползунок под тем же щелчком выключал бы
/// дорожку при каждой попытке подкрутить громкость.
pub const gain_line_h: i32 = 16;
/// Края полоски ползунка.
pub const gain_x0: i32 = 8;
pub const gain_x1: i32 = 104;

pub fn gainSpan() i32 {
    return gain_x1 - gain_x0;
}

/// Выключатель кривой — справа от ползунка, в той же строке.
///
/// Кривая принадлежит дорожке, а не всему окну: их бывает несколько,
/// и «включить кривую» без указания, у какой именно, — это вопрос,
/// на который человеку пришлось бы отвечать выбором дорожки заранее.
pub const curve_btn_x0: i32 = 112;
pub const curve_btn_x1: i32 = 142;

/// Кнопка записи с микрофона — в строке имени, справа.
///
/// У каждой звуковой дорожки своя: «записать на эту, потом на другую» —
/// это два нажатия на разных дорожках, а не выбор дорожки в отдельном
/// списке перед каждой записью.
pub const rec_btn_x0: i32 = 118;
pub const rec_btn_x1: i32 = 142;
pub const rec_btn_top: i32 = 3;
pub const rec_btn_h: i32 = 18;

/// Верх строки с ползунком.
pub fn gainTop(lane_top: i32) i32 {
    return lane_top + lane_h - gain_line_h;
}

/// Где стоит ручка ползунка.
pub fn gainX(db10: volume.Db10) i32 {
    return gain_x0 + volume.sliderPos(db10, gainSpan());
}

/// Какая громкость получится, если поставить ручку сюда.
pub fn gainFromX(x: i32) volume.Db10 {
    return volume.sliderValue(x - gain_x0, gainSpan());
}

// ------------------------------------------------- кривая громкости

/// Отступ кривой от краёв полосы.
///
/// Без него точка на самом верху рисуется половиной и хватается мышью
/// с трудом, а на самом низу залезает на границу соседней дорожки.
pub const curve_pad: i32 = 8;
/// Насколько близко надо ткнуть, чтобы взяться за кривую или её точку.
pub const curve_grab: i32 = 7;
/// Полуразмер квадратика точки.
pub const curve_dot: i32 = 3;

/// На какой высоте проходит кривая при такой громкости.
///
/// Верх полосы — самое громкое, низ — тишина. Так же, как ползунок:
/// вверх громче. Обратное отображение сбивало бы с толку каждый раз.
pub fn curveY(lane_top: i32, db10: volume.Db10) i32 {
    const top = lane_top + curve_pad;
    const room = lane_h - curve_pad * 2;
    if (room <= 0) return top;
    const from_top = @as(i32, volume.max_db10) - @as(i32, volume.clamp(db10));
    const range = @as(i32, volume.max_db10) - @as(i32, volume.min_db10);
    return top + @divTrunc(from_top * room, range);
}

/// Какая громкость получится, если поставить точку на эту высоту.
pub fn curveDbAt(lane_top: i32, y: i32) volume.Db10 {
    const top = lane_top + curve_pad;
    const room = lane_h - curve_pad * 2;
    if (room <= 0) return volume.unity;
    const from_top = std.math.clamp(y - top, 0, room);
    const range = @as(i32, volume.max_db10) - @as(i32, volume.min_db10);
    return volume.clamp(@intCast(@as(i32, volume.max_db10) - @divTrunc(from_top * range, room)));
}

/// Высота полосы с ползунком под таймлайном.
pub const bar_h: i32 = 14;
/// Короче этого ползунок не делаем: за точку не ухватиться.
pub const min_thumb: i32 = 24;

/// Где стоит ползунок и какой он длины.
pub const Thumb = struct {
    left: i32 = 0,
    width: i32 = 0,

    pub fn right(self: Thumb) i32 {
        return self.left + self.width;
    }
};

/// Посчитать ползунок прокрутки.
///
/// Длина ползунка говорит, какая часть записи видна, положение — где ты.
/// На часовой записи это единственный способ понять, где ты находишься:
/// в окно помещается десять минут, и по ним не видно ни начала, ни конца.
///
/// `span` — ширина полосы под ползунок, `visible_ns` — сколько времени
/// помещается в окно, `total_ns` — вся длина записи.
pub fn thumbFor(span: i32, at_ns: u64, visible_ns: u64, total_ns: u64) Thumb {
    if (span <= 0) return .{};
    // Видно всё — ползунок во всю полосу. Это честно говорит «дальше ничего».
    if (total_ns == 0 or visible_ns >= total_ns) return .{ .left = 0, .width = span };

    const shown = @as(u64, @intCast(span)) * visible_ns / total_ns;
    const width = std.math.clamp(@as(i32, @intCast(shown)), min_thumb, span);

    const room = span - width;
    const scroll_span = total_ns - visible_ns;
    const start = @min(at_ns, scroll_span);
    const left = if (scroll_span == 0)
        0
    else
        @as(i32, @intCast(@as(u64, @intCast(room)) * start / scroll_span));
    return .{ .left = std.math.clamp(left, 0, room), .width = width };
}

/// Куда переводит ползунок, поставленный в точку `x`.
///
/// `grab` — за какое место ползунка взялись, чтобы он не прыгал под курсор
/// своим левым краем.
pub fn scrollTo(span: i32, x: i32, grab: i32, visible_ns: u64, total_ns: u64) u64 {
    if (span <= 0 or total_ns == 0 or visible_ns >= total_ns) return 0;
    const thumb = thumbFor(span, 0, visible_ns, total_ns);
    const room = span - thumb.width;
    if (room <= 0) return 0;

    const want = std.math.clamp(x - grab, 0, room);
    const scroll_span = total_ns - visible_ns;
    return @as(u64, @intCast(want)) * scroll_span / @as(u64, @intCast(room));
}

/// Куда уехать, прокрутив на страницу.
///
/// Страница — это то, что видно: так листают везде, и глазу есть за что
/// зацепиться, потому что край прежней страницы становится краем новой.
pub fn pageBy(at_ns: u64, visible_ns: u64, total_ns: u64, forward: bool) u64 {
    const limit = total_ns -| visible_ns;
    if (forward) return @min(at_ns + visible_ns, limit);
    return at_ns -| visible_ns;
}

/// Прокрутить вбок на столько-то точек.
pub fn scrollBy(at_ns: u64, ns_per_px: u64, px: i32, visible_ns: u64, total_ns: u64) u64 {
    const limit = total_ns -| visible_ns;
    const shift = @as(u64, @intCast(@abs(px))) * ns_per_px;
    const out = if (px > 0) at_ns + shift else at_ns -| shift;
    return @min(out, limit);
}

/// Толщина полосы между окном кадра и таймлайном. За неё тянут мышью.
///
/// Шесть точек: тоньше — не попасть, толще — полоса начинает выглядеть
/// как часть окна, а не как граница.
pub const splitter_h: i32 = 6;
/// Ниже этого окно кадра не сворачивается.
pub const min_preview_h: i32 = 120;
/// Ниже этого не сворачивается таймлайн.
///
/// Считано, а не взято с потолка: линейка (26) плюс две полосы дорожки
/// с зазорами (2 x 62) плюс полоса ползунка (14) — это 164. Округляем
/// до 170. Две дорожки, а не одна: у обычного файла их две — картинка
/// и звук, — и увидеть только картинку значит не увидеть половины работы.
pub const min_timeline_h: i32 = 170;

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
    /// Ползунок громкости дорожки в левой колонке.
    header_gain,
    /// Выключатель кривой громкости в левой колонке.
    header_curve,
    /// Кнопка записи с микрофона на эту дорожку.
    header_rec,
    /// Метка на линейке: прыжок к ней и перетаскивание.
    mark,
    /// Точка кривой громкости: её тянут.
    curve_point,
    /// Сама кривая мимо точек: щелчок ставит новую точку.
    curve_line,
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
    /// Номер точки кривой — при попадании в `curve_point`.
    point: usize = 0,
    /// Номер метки — при попадании в `mark`.
    mark: usize = 0,
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
        const when_here = view.xToTime(x);
        // Метка проверяется раньше самой линейки: флажок нарисован поверх
        // делений, и ткнуть в то, что видно сверху, должно означать
        // попадание в него.
        const tolerance = @as(u64, mark_grab) * view.ns_per_px;
        if (project.marks.nearest(when_here, tolerance)) |i| {
            return .{ .target = .mark, .mark = i, .when_ns = when_here };
        }
        return .{ .target = .ruler, .when_ns = when_here };
    }
    const track_index = view.trackAtY(y, project.track_count) orelse return .{};
    const lane_top = view.laneTop(track_index);
    const track = &project.tracks[track_index];

    if (x < header_w) {
        const within = y - lane_top;
        if (within < name_line_h) {
            if (track.kind == .audio and x >= rec_btn_x0 and x < rec_btn_x1 and
                within >= rec_btn_top and within < rec_btn_top + rec_btn_h)
            {
                return .{ .target = .header_rec, .track = track_index };
            }
            return .{ .target = .header_name, .track = track_index };
        }
        if (track.kind == .audio and y >= gainTop(lane_top)) {
            if (x >= curve_btn_x0 and x < curve_btn_x1) {
                return .{ .target = .header_curve, .track = track_index };
            }
            if (x >= gain_x0 - curve_grab and x <= gain_x1 + curve_grab) {
                return .{ .target = .header_gain, .track = track_index };
            }
        }
        return .{ .target = .header, .track = track_index };
    }

    const when = view.xToTime(x);

    // Кривая проверяется раньше клипов: она нарисована поверх них, и ткнуть
    // в то, что видно сверху, должно означать попадание в него. Работает
    // это только на включённой кривой — иначе невидимая линия отнимала бы
    // у клипа полоску в семь точек.
    if (track.kind == .audio and track.curve_on) {
        const tolerance = curve_grab_ns(view);
        if (track.curve.nearest(when, tolerance)) |i| {
            const p = track.curve.points[i];
            if (@abs(y - curveY(lane_top, p.db10)) <= curve_grab) {
                return .{
                    .target = .curve_point,
                    .track = track_index,
                    .point = i,
                    .when_ns = when,
                };
            }
        }
        // Пустая кривая тоже ловится: она нарисована прямой на «как
        // записано», и в неё надо уметь ткнуть — иначе включённая кривая
        // видна, а первую точку на неё поставить нечем.
        const line_y = curveY(lane_top, track.curve.valueAt(when));
        if (@abs(y - line_y) <= curve_grab) {
            return .{ .target = .curve_line, .track = track_index, .when_ns = when };
        }
    }

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

/// Во сколько наносекунд обходится хватка мыши по времени.
fn curve_grab_ns(view: View) u64 {
    return @as(u64, curve_grab) * view.ns_per_px;
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

// ------------------------------------------------------- ползунок

test "видно всё целиком — ползунок во всю полосу" {
    // И это честно говорит: дальше ничего нет.
    const t = thumbFor(400, 0, 60 * sec, 60 * sec);
    try std.testing.expectEqual(@as(i32, 0), t.left);
    try std.testing.expectEqual(@as(i32, 400), t.width);

    // Видно даже больше, чем есть, — то же самое.
    const more = thumbFor(400, 0, 120 * sec, 60 * sec);
    try std.testing.expectEqual(@as(i32, 400), more.width);
}

test "длина ползунка говорит, какая часть видна" {
    // Час записи, видно десять минут — ползунок в шестую часть полосы.
    const t = thumbFor(600, 0, 600 * sec, 3600 * sec);
    try std.testing.expectEqual(@as(i32, 100), t.width);
    try std.testing.expectEqual(@as(i32, 0), t.left);
}

test "ползунок не исчезает в точку на очень длинной записи" {
    // Иначе за него не ухватиться.
    const t = thumbFor(600, 0, 1 * sec, 10 * 3600 * sec);
    try std.testing.expect(t.width >= min_thumb);
    try std.testing.expect(t.width <= 600);
}

test "положение ползунка показывает, где ты" {
    const total = 3600 * sec;
    const visible = 600 * sec;
    const span: i32 = 600;

    const start = thumbFor(span, 0, visible, total);
    try std.testing.expectEqual(@as(i32, 0), start.left);

    // В самом конце ползунок упирается в правый край, но не вылезает.
    const end = thumbFor(span, total - visible, visible, total);
    try std.testing.expectEqual(span, end.right());

    // Посередине — посередине.
    const middle = thumbFor(span, (total - visible) / 2, visible, total);
    try std.testing.expect(middle.left > start.left and middle.left < end.left);
}

test "перетаскивание ползунка и обратный счёт сходятся" {
    const total = 3600 * sec;
    const visible = 600 * sec;
    const span: i32 = 600;

    // Куда ни поставь ползунок — пересчёт обратно даёт то же место.
    for ([_]u64{ 0, 100 * sec, 1500 * sec, total - visible }) |at| {
        const t = thumbFor(span, at, visible, total);
        const back = scrollTo(span, t.left, 0, visible, total);
        const thumb = thumbFor(span, back, visible, total);
        // Точность ограничена шириной полосы: сходимся до точки.
        try std.testing.expect(@abs(thumb.left - t.left) <= 1);
    }
}

test "прокрутка не уезжает за конец записи" {
    // Дальше пусто, и смотреть там не на что.
    const total = 600 * sec;
    const visible = 100 * sec;
    try std.testing.expectEqual(total - visible, pageBy(total - visible, visible, total, true));
    try std.testing.expectEqual(total - visible, pageBy(total, visible, total, true));
    try std.testing.expectEqual(@as(u64, 0), pageBy(0, visible, total, false));
    try std.testing.expectEqual(total - visible, scrollBy(0, sec, 10_000, visible, total));
}

test "страница — это то, что видно" {
    const total = 600 * sec;
    const visible = 100 * sec;
    try std.testing.expectEqual(@as(u64, 100 * sec), pageBy(0, visible, total, true));
    try std.testing.expectEqual(@as(u64, 0), pageBy(100 * sec, visible, total, false));
}

test "прокрутка вбок считается в точках" {
    const total = 600 * sec;
    const visible = 100 * sec;
    // Сто точек по десять миллисекунд на точку — это секунда.
    try std.testing.expectEqual(
        @as(u64, 1 * sec),
        scrollBy(0, 10 * std.time.ns_per_ms, 100, visible, total),
    );
    // Влево от нуля уехать нельзя.
    try std.testing.expectEqual(@as(u64, 0), scrollBy(0, 10 * std.time.ns_per_ms, -100, visible, total));
}

test "пустая полоса не роняет счёт" {
    try std.testing.expectEqual(@as(i32, 0), thumbFor(0, 0, sec, 10 * sec).width);
    try std.testing.expectEqual(@as(u64, 0), scrollTo(0, 5, 0, sec, 10 * sec));
    try std.testing.expectEqual(@as(u64, 0), scrollTo(100, 5, 0, sec, 0));
}

// -------------------------------------------- громкость и кривая

test "ползунок громкости — только у звуковой дорожки" {
    const p = try testProject();
    defer std.testing.allocator.destroy(p);
    const v = View{};

    // Дорожка 0 — видео: под именем у неё по-прежнему выключатель звука.
    const video_top = v.laneTop(0);
    try std.testing.expectEqual(Target.header, hitTest(p, v, 20, gainTop(video_top) + 4).target);

    // Дорожка 1 — звук: там же ползунок.
    const audio_top = v.laneTop(1);
    const got = hitTest(p, v, 20, gainTop(audio_top) + 4);
    try std.testing.expectEqual(Target.header_gain, got.target);
    try std.testing.expectEqual(@as(usize, 1), got.track);

    // А выше ползунка — всё ещё вид дорожки и выключатель.
    try std.testing.expectEqual(Target.header, hitTest(p, v, 20, audio_top + name_line_h + 2).target);
}

test "ползунок громкости ходит туда и обратно" {
    try std.testing.expectEqual(gain_x0, gainX(Volume.min_db10));
    try std.testing.expectEqual(gain_x1, gainX(Volume.max_db10));
    for ([_]Volume.Db10{ -600, -300, -100, 0, 60, 120 }) |v| {
        const back = gainFromX(gainX(v));
        try std.testing.expect(@abs(@as(i32, back) - @as(i32, v)) <= 8);
    }
    // Мышь за краем полоски не уводит громкость за пределы.
    try std.testing.expectEqual(Volume.min_db10, gainFromX(gain_x0 - 500));
    try std.testing.expectEqual(Volume.max_db10, gainFromX(gain_x1 + 500));
}

test "кривая: вверху громче, внизу тише" {
    const top = 100;
    try std.testing.expect(curveY(top, Volume.max_db10) < curveY(top, Volume.unity));
    try std.testing.expect(curveY(top, Volume.unity) < curveY(top, Volume.min_db10));
    // И вся кривая помещается в полосу.
    try std.testing.expect(curveY(top, Volume.max_db10) >= top);
    try std.testing.expect(curveY(top, Volume.min_db10) <= top + lane_h);
}

test "высота и громкость переводятся друг в друга" {
    const top = 100;
    for ([_]Volume.Db10{ Volume.min_db10, -300, 0, Volume.max_db10 }) |v| {
        const back = curveDbAt(top, curveY(top, v));
        // Полоса в сорок точек не различает меньше двух децибел.
        try std.testing.expect(@abs(@as(i32, back) - @as(i32, v)) <= 200);
    }
    // Мышь выше и ниже полосы прижимается к пределам, а не уходит за них.
    try std.testing.expectEqual(Volume.max_db10, curveDbAt(top, top - 500));
    try std.testing.expectEqual(Volume.min_db10, curveDbAt(top, top + 500));
}

test "выключенная кривая не отнимает у клипа полоску" {
    // Невидимая линия, которая перехватывает мышь, — это клип, который
    // вдруг перестал хвататься в одном месте по непонятной причине.
    const p = try testProject();
    defer std.testing.allocator.destroy(p);
    try p.place(1, 0, 0, 10 * sec);
    _ = try p.addCurvePoint(1, 5 * sec, 0);
    try p.setCurveOn(1, false);

    const v = View{ .at_ns = 0, .ns_per_px = 20 * std.time.ns_per_ms };
    const top = v.laneTop(1);
    const x = v.timeToX(5 * sec);
    const got = hitTest(p, v, x, curveY(top, 0));
    try std.testing.expectEqual(Target.clip, got.target);
}

test "по включённой кривой попадают в точку, а рядом — в линию" {
    const p = try testProject();
    defer std.testing.allocator.destroy(p);
    try p.place(1, 0, 0, 10 * sec);
    _ = try p.addCurvePoint(1, 2 * sec, 0);
    _ = try p.addCurvePoint(1, 8 * sec, 0);

    const v = View{ .at_ns = 0, .ns_per_px = 20 * std.time.ns_per_ms };
    const top = v.laneTop(1);

    // Прямо в точку.
    const at_point = hitTest(p, v, v.timeToX(8 * sec), curveY(top, 0));
    try std.testing.expectEqual(Target.curve_point, at_point.target);
    try std.testing.expectEqual(@as(usize, 1), at_point.point);

    // Между точками, но на линии.
    const on_line = hitTest(p, v, v.timeToX(5 * sec), curveY(top, 0));
    try std.testing.expectEqual(Target.curve_line, on_line.target);

    // Далеко от линии — обычный клип.
    const off_line = hitTest(p, v, v.timeToX(5 * sec), curveY(top, 0) + curve_grab + 6);
    try std.testing.expectEqual(Target.clip, off_line.target);
}

test "кривая перехватывает мышь только на звуковой дорожке" {
    const p = try testProject();
    defer std.testing.allocator.destroy(p);
    try p.place(0, 0, 0, 10 * sec);
    // Видеодорожке кривую включить можно только в обход окна, но модель
    // не должна на это рассчитывать.
    try p.setCurveOn(0, true);
    _ = try p.addCurvePoint(0, 5 * sec, 0);

    const v = View{ .at_ns = 0, .ns_per_px = 20 * std.time.ns_per_ms };
    const top = v.laneTop(0);
    const got = hitTest(p, v, v.timeToX(5 * sec), curveY(top, 0));
    try std.testing.expectEqual(Target.clip, got.target);
}

test "выключатель кривой — своя цель, а не край ползунка" {
    const p = try testProject();
    defer std.testing.allocator.destroy(p);
    const v = View{};
    const top = v.laneTop(1);
    const y = gainTop(top) + 4;

    try std.testing.expectEqual(Target.header_gain, hitTest(p, v, gain_x1 - 2, y).target);
    try std.testing.expectEqual(Target.header_curve, hitTest(p, v, curve_btn_x0 + 2, y).target);
    try std.testing.expectEqual(Target.header_curve, hitTest(p, v, curve_btn_x1 - 1, y).target);
    // Правее выключателя — просто колонка.
    try std.testing.expectEqual(Target.header, hitTest(p, v, curve_btn_x1 + 2, y).target);
    // И ползунок с выключателем не налезают друг на друга.
    try std.testing.expect(gain_x1 + curve_grab < curve_btn_x0);
}

test "микрофон — своя цель, и только у звуковой дорожки" {
    const p = try testProject();
    defer std.testing.allocator.destroy(p);
    const v = View{};

    const audio_top = v.laneTop(1);
    const y = audio_top + rec_btn_top + 2;
    try std.testing.expectEqual(Target.header_rec, hitTest(p, v, rec_btn_x0 + 2, y).target);

    // Само имя рядом — по-прежнему имя: двойной щелчок по нему переименовывает.
    try std.testing.expectEqual(Target.header_name, hitTest(p, v, 20, y).target);
    // У видеодорожки микрофона нет: писать звук на дорожку для картинки
    // некуда, и кнопка там означала бы обещание, которого мы не выполним.
    const video_top = v.laneTop(0);
    try std.testing.expectEqual(
        Target.header_name,
        hitTest(p, v, rec_btn_x0 + 2, video_top + rec_btn_top + 2).target,
    );
    // И кнопка не залезает на соседнюю строку.
    try std.testing.expect(rec_btn_top + rec_btn_h <= name_line_h);
}

test "во включённую пустую кривую можно ткнуть" {
    // Она нарисована прямой на «как записано». Если в неё не попасть,
    // включённая кривая видна, а первую точку поставить нечем.
    const p = try testProject();
    defer std.testing.allocator.destroy(p);
    try p.place(1, 0, 0, 10 * sec);
    try p.setCurveOn(1, true);

    const v = View{ .at_ns = 0, .ns_per_px = 20 * std.time.ns_per_ms };
    const top = v.laneTop(1);
    const got = hitTest(p, v, v.timeToX(5 * sec), curveY(top, Volume.unity));
    try std.testing.expectEqual(Target.curve_line, got.target);
}

test "метка на линейке ловится раньше самой линейки" {
    const p = try testProject();
    defer std.testing.allocator.destroy(p);
    _ = try p.addMark(5 * sec, .red, "тут");

    const v = View{ .at_ns = 0, .ns_per_px = 20 * std.time.ns_per_ms };
    const at = v.timeToX(5 * sec);

    const on_mark = hitTest(p, v, at, 5);
    try std.testing.expectEqual(Target.mark, on_mark.target);
    try std.testing.expectEqual(@as(usize, 0), on_mark.mark);

    // Рядом с меткой — обычная линейка.
    const beside = hitTest(p, v, at + mark_grab + 4, 5);
    try std.testing.expectEqual(Target.ruler, beside.target);
}

test "метка не перехватывает мышь на дорожках" {
    // Флажок нарисован на линейке; ниже неё метка — только тонкая черта,
    // и отнимать у клипа полоску она не должна.
    const p = try testProject();
    defer std.testing.allocator.destroy(p);
    try p.place(0, 0, 0, 10 * sec);
    _ = try p.addMark(5 * sec, .red, "тут");

    const v = View{ .at_ns = 0, .ns_per_px = 20 * std.time.ns_per_ms };
    const got = hitTest(p, v, v.timeToX(5 * sec), ruler_h + 10);
    try std.testing.expectEqual(Target.clip, got.target);
}

test "флажок метки помещается в линейку" {
    const f = markFlag(100);
    try std.testing.expect(f.top >= 0);
    try std.testing.expect(f.bottom <= ruler_h);
    try std.testing.expect(f.right > f.left);
}
