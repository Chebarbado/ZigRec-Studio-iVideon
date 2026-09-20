//! Файл проекта: сохранить правки и открыть их снова.
//!
//! Задача #46. Без него правки живут, пока открыто окно: закрыл — и всё,
//! что нарезано, пропало.
//!
//! **Формат — простой текст**, а не двоичная упаковка. Проект это десятки
//! строк, а не мегабайты; текст можно посмотреть глазами, поправить руками
//! и сравнить двумя версиями в системе контроля версий. Двоичный формат
//! экономил бы здесь килобайты ценой невозможности понять, что внутри.
//!
//! **Исходники не копируются.** Проект помнит, где они лежат, и только.
//! Если файл переехал, при открытии об этом говорится словами, а не молча
//! показывается пустая дорожка.
//!
//! Время везде в наносекундах — теми же числами, что и в модели. Переводить
//! в секунды при записи значило бы терять точность на каждом сохранении.
const std = @import("std");
const lang = @import("../lang.zig");
const timeline = @import("../edit/timeline.zig");

/// Подпись в первой строке. По ней узнаётся файл и его поколение.
pub const magic = "zigrec-project";
pub const version: u32 = 1;

pub const Error = error{
    /// Это не файл проекта.
    NotProject,
    /// Файл от более новой версии программы.
    TooNew,
    /// Строка не разбирается.
    Malformed,
    /// В файле больше дорожек, клипов или исходников, чем помещается.
    TooBig,
};

/// Записать проект текстом.
///
/// Пишем в переданный писатель, а не в файл: так запись проверяется тестом
/// в память, без диска и без временных файлов.
/// `base_dir` — папка файла проекта: исходники из неё и из её подпапок
/// пишутся относительно (#24), и проект переезжает вместе с ними.
/// Пусто — все пути полные, как раньше.
pub fn write(project: *const timeline.Project, w: *std.Io.Writer, base_dir: []const u8) !void {
    try w.print("{s} {d}\n", .{ magic, version });

    for (project.sourceList()) |src| {
        const shown = relativeTo(base_dir, src.fullPath()) orelse src.fullPath();
        try w.print("source {d} {s}\n", .{ src.duration_ns, shown });
        // Заметка дубля — своей строкой за исходником: остаток строки
        // `source` уже занят путём с пробелами.
        if (src.comment().len > 0) try w.print("take {s}\n", .{src.comment()});
    }

    // Метки — до дорожек: они принадлежат всему проекту, а не дорожке,
    // и строка `mark` после строки `track` читалась бы как дорожкина.
    for (project.marks.list()) |m| {
        // Имя — весь остаток строки: в нём бывают пробелы.
        try w.print("mark {d} {s} {s}\n", .{ m.at_ns, @tagName(m.colour), m.title() });
        if (m.icon != .none) try w.print("icon {s}\n", .{@tagName(m.icon)});
        // Длина и комментарий — отдельными строками, а не в конец `mark`:
        // там имя уже занимает весь остаток, и второй хвост туда не влезет.
        // Прежнее поколение таких слов не знает и пропустит их, получив
        // точку без пояснения, — а не откажется открыть проект.
        if (m.isSpan()) try w.print("span {d}\n", .{m.len_ns});
        if (m.comment().len > 0) try w.print("note {s}\n", .{m.comment()});
    }

    // Аннотации (#28) — тоже до дорожек, по той же причине, что метки.
    // Текст — остаток строки.
    for (project.annotations.list()) |a| {
        try w.print("ann {d} {d} {s} {d} {d} {d} {d} {s} {s}\n", .{
            a.at_ns, a.len_ns, @tagName(a.kind), a.x, a.y, a.x2, a.y2, @tagName(a.colour), a.title(),
        });
    }

    for (project.trackList()) |track| {
        try w.print("track {s} {d} {s}\n", .{
            @tagName(track.kind),
            @intFromBool(track.muted),
            track.title(),
        });
        // Значок — отдельной строкой: имя дорожки занимает весь остаток
        // строки `track`, и дописать после него нечего.
        if (track.icon != .none) try w.print("tricon {s}\n", .{@tagName(track.icon)});
        // Громкость дорожки отдельной строкой, а не в конце строки
        // `track`: там имя дорожки, и оно занимает весь остаток строки.
        // Незнакомое слово прежнее поколение пропускает, поэтому файл
        // остаётся читаемым и для него — без громкости, но целиком.
        if (track.gain_db10 != 0 or track.curve_on) {
            try w.print("gain {d} {d}\n", .{ track.gain_db10, @intFromBool(track.curve_on) });
        }
        for (track.curve.list()) |p| {
            try w.print("point {d} {d}\n", .{ p.at_ns, p.db10 });
        }

        for (track.list()) |clip| {
            // Пятое число — номер связки, шестое — громкость клипа.
            // Дописаны в конец строки нарочно: прежнее поколение читает
            // первые четыре и просто не заметит остальных. Связка
            // и громкость потеряются, проект — нет.
            try w.print("clip {d} {d} {d} {d} {d} {d} {d}\n", .{
                clip.source,
                clip.in_ns,
                clip.len_ns,
                clip.at_ns,
                clip.link,
                clip.gain_db10,
                @intFromEnum(clip.icon),
            });
        }
    }
}

/// Прочитать проект из текста в уже созданный (пустой) проект.
/// `base_dir` — папка файла проекта: относительные пути считаются от неё.
pub fn read(project: *timeline.Project, data: []const u8, base_dir: []const u8) Error!void {
    var lines = std.mem.splitScalar(u8, data, '\n');

    const head = trim(lines.next() orelse return Error.NotProject);
    var head_parts = std.mem.splitScalar(u8, head, ' ');
    const name = head_parts.next() orelse return Error.NotProject;
    if (!std.mem.eql(u8, name, magic)) return Error.NotProject;
    const got_version = std.fmt.parseInt(u32, head_parts.next() orelse "0", 10) catch
        return Error.Malformed;
    // Файл от будущей версии не читаем наугад: лучше честно отказаться,
    // чем открыть его наполовину и молча потерять то, чего не поняли.
    if (got_version > version) return Error.TooNew;

    project.* = .{};
    var current_track: ?usize = null;

    while (lines.next()) |raw| {
        const text = trim(raw);
        if (text.len == 0) continue;

        var parts = std.mem.splitScalar(u8, text, ' ');
        const word = parts.next() orelse continue;

        if (std.mem.eql(u8, word, "source")) {
            const duration = parseU64(parts.next()) orelse return Error.Malformed;
            // Путь — весь остаток строки: в нём бывают пробелы.
            const path = parts.rest();
            if (path.len == 0) return Error.Malformed;
            var full_buf: [520]u8 = undefined;
            const full = resolve(&full_buf, base_dir, path);
            _ = project.addSource(full, duration) catch return Error.TooBig;
            continue;
        }

        if (std.mem.eql(u8, word, "take")) {
            // Относится к последнему исходнику; без исходника — пропускаем,
            // как любое непонятное слово.
            if (project.source_count > 0) project.sources[project.source_count - 1].setNote(parts.rest());
            continue;
        }

        if (std.mem.eql(u8, word, "track")) {
            const kind_text = parts.next() orelse return Error.Malformed;
            const kind: timeline.TrackKind = if (std.mem.eql(u8, kind_text, "video"))
                .video
            else if (std.mem.eql(u8, kind_text, "audio"))
                .audio
            else
                return Error.Malformed;
            const muted = parseU64(parts.next()) orelse return Error.Malformed;
            const title = parts.rest();
            const index = project.addTrack(kind, title) catch return Error.TooBig;
            project.tracks[index].muted = muted != 0;
            current_track = index;
            continue;
        }

        if (std.mem.eql(u8, word, "mark")) {
            const at_ns = parseU64(parts.next()) orelse return Error.Malformed;
            const colour_text = parts.next() orelse return Error.Malformed;
            // Незнакомый цвет — не повод не открыть проект: метка важнее
            // своего оттенка. Берём цвет по умолчанию и идём дальше.
            const colour = std.meta.stringToEnum(timeline.Marks.Colour, colour_text) orelse .yellow;
            _ = project.marks.add(at_ns, colour, parts.rest()) catch return Error.TooBig;
            continue;
        }

        if (std.mem.eql(u8, word, "ann")) {
            var a = timeline.Annotations.Annotation{};
            a.at_ns = parseU64(parts.next()) orelse return Error.Malformed;
            a.len_ns = parseU64(parts.next()) orelse return Error.Malformed;
            // Незнакомый вид или цвет — не повод не открыть проект.
            a.kind = std.meta.stringToEnum(timeline.Annotations.Kind, parts.next() orelse "") orelse .text;
            a.x = parseI32(parts.next()) orelse return Error.Malformed;
            a.y = parseI32(parts.next()) orelse return Error.Malformed;
            a.x2 = parseI32(parts.next()) orelse return Error.Malformed;
            a.y2 = parseI32(parts.next()) orelse return Error.Malformed;
            a.colour = std.meta.stringToEnum(timeline.Marks.Colour, parts.next() orelse "") orelse .yellow;
            a.setText(parts.rest());
            _ = project.annotations.add(a) catch return Error.TooBig;
            continue;
        }

        if (std.mem.eql(u8, word, "icon")) {
            // Относится к последней прочитанной метке, как `note` и `span`.
            if (project.marks.count == 0) continue;
            // Незнакомый значок — не повод не открыть проект: метка важнее
            // своей картинки.
            const icon = std.meta.stringToEnum(timeline.Marks.Icons.Icon, parts.rest()) orelse .none;
            project.marks.items[project.marks.count - 1].icon = icon;
            continue;
        }

        if (std.mem.eql(u8, word, "tricon")) {
            const track = current_track orelse continue;
            const icon = std.meta.stringToEnum(timeline.Marks.Icons.Icon, parts.rest()) orelse .none;
            project.tracks[track].icon = icon;
            continue;
        }

        if (std.mem.eql(u8, word, "span")) {
            // Как и `note`, относится к последней прочитанной метке.
            if (project.marks.count == 0) continue;
            const len_ns = parseU64(parts.next()) orelse return Error.Malformed;
            project.marks.setLength(project.marks.count - 1, len_ns) catch {};
            continue;
        }

        if (std.mem.eql(u8, word, "note")) {
            // Относится к последней прочитанной метке. Строка без метки
            // перед ней — просто мусор, и молча его пропустить лучше,
            // чем отказаться открыть проект из-за комментария.
            if (project.marks.count == 0) continue;
            project.marks.items[project.marks.count - 1].setComment(parts.rest());
            continue;
        }

        if (std.mem.eql(u8, word, "gain")) {
            const track = current_track orelse return Error.Malformed;
            const db10 = parseI16(parts.next()) orelse return Error.Malformed;
            // Признака может не быть: строку писала версия, в которой
            // кривой ещё не было. Тогда её нет — это честнее, чем включить.
            const on = parseU64(parts.next()) orelse 0;
            project.tracks[track].gain_db10 = timeline.Volume.clamp(db10);
            project.tracks[track].curve_on = on != 0;
            continue;
        }

        if (std.mem.eql(u8, word, "point")) {
            const track = current_track orelse return Error.Malformed;
            const at_ns = parseU64(parts.next()) orelse return Error.Malformed;
            const db10 = parseI16(parts.next()) orelse return Error.Malformed;
            _ = project.tracks[track].curve.add(at_ns, db10) catch return Error.TooBig;
            continue;
        }

        if (std.mem.eql(u8, word, "clip")) {
            const track = current_track orelse return Error.Malformed;
            const source = parseU64(parts.next()) orelse return Error.Malformed;
            const in_ns = parseU64(parts.next()) orelse return Error.Malformed;
            const len_ns = parseU64(parts.next()) orelse return Error.Malformed;
            const at_ns = parseU64(parts.next()) orelse return Error.Malformed;
            // Номера связки может не быть: файл от прежнего поколения.
            // Тогда клип сам по себе — это честнее, чем придумать ему связь.
            const link = parseU64(parts.next()) orelse 0;
            // Громкости может не быть — тогда клип звучит как записан.
            const gain_db10 = parseI16(parts.next()) orelse 0;
            // Значка может не быть — файл прежнего поколения.
            const icon_no = parseU64(parts.next()) orelse 0;
            // Незнакомый номер значка — без значка: файл правят руками,
            // и написанная там сотня не должна ронять открытие проекта.
            const Icon = timeline.Marks.Icons.Icon;
            const icon: Icon = if (icon_no <= @intFromEnum(Icon.flag))
                @enumFromInt(@as(u8, @intCast(icon_no)))
            else
                .none;
            project.tracks[track].clips[project.tracks[track].count] = .{
                .source = @intCast(source),
                .in_ns = in_ns,
                .len_ns = len_ns,
                .at_ns = at_ns,
                .link = @truncate(link),
                .gain_db10 = timeline.Volume.clamp(gain_db10),
                .icon = icon,
            };
            // Счётчик связок должен обгонять всё, что прочитано: иначе
            // следующая связка получила бы уже занятый номер.
            if (link >= project.next_link) project.next_link = @truncate(link + 1);
            project.tracks[track].count += 1;
            if (project.tracks[track].count >= timeline.max_clips) return Error.TooBig;
            continue;
        }

        // Незнакомое слово пропускаем, а не падаем: так файл от чуть более
        // поздней версии того же поколения всё-таки откроется.
    }

    // Открытый проект — это начало, а не продолжение: отменять нечего.
    project.past = 0;
    project.future = 0;
}

fn trim(text: []const u8) []const u8 {
    var out = text;
    while (out.len > 0 and (out[out.len - 1] == '\r' or out[out.len - 1] == ' ')) out.len -= 1;
    return out;
}

fn parseI32(maybe: ?[]const u8) ?i32 {
    return std.fmt.parseInt(i32, maybe orelse return null, 10) catch null;
}

fn parseU64(maybe: ?[]const u8) ?u64 {
    const text = maybe orelse return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// Громкость бывает отрицательной, и беззнаковым разбором её не прочесть.
fn parseI16(maybe: ?[]const u8) ?i16 {
    const text = maybe orelse return null;
    return std.fmt.parseInt(i16, text, 10) catch null;
}

/// Объяснение словами — для окна.
pub fn explain(err: anyerror) []const u8 {
    return switch (err) {
        Error.NotProject => lang.t("это не файл проекта Zig-Rec Studio"),
        Error.TooNew => lang.t("файл сделан более новой версией программы: обновите её"),
        Error.Malformed => lang.t("файл проекта повреждён: строка не разбирается"),
        Error.TooBig => lang.t("в файле больше дорожек или клипов, чем программа умеет держать"),
        else => lang.t("файл проекта не читается"),
    };
}

// ---------------------------------------------------------------- тесты

const sec = std.time.ns_per_s;

fn makeProject() !*timeline.Project {
    const p = try std.testing.allocator.create(timeline.Project);
    p.* = .{};
    return p;
}

/// Проект с дорожками и клипом — для проверок громкости.
fn withTracks() !*timeline.Project {
    const p = try makeProject();
    _ = try p.addSource("D:\\видео\\запись.mp4", 60 * sec);
    _ = try p.addTrack(.video, "Видео");
    _ = try p.addTrack(.audio, "Микрофон");
    try p.place(1, 0, 0, 10 * sec);
    // Расставленное — это ещё не правка: отменять здесь нечего.
    p.past = 0;
    p.future = 0;
    return p;
}

/// Путь относительно папки, если он в ней или в её подпапках.
///
/// Сравниваем без учёта регистра и вида косой черты: Windows их не
/// различает, а человек пишет как придётся.
pub fn relativeTo(base_dir: []const u8, path: []const u8) ?[]const u8 {
    if (base_dir.len == 0 or path.len <= base_dir.len) return null;
    var i: usize = 0;
    while (i < base_dir.len) : (i += 1) {
        if (!sameChar(base_dir[i], path[i])) return null;
    }
    const sep = path[base_dir.len];
    if (sep != '\\' and sep != '/') {
        // Папка кончается косой чертой — тогда остаток начинается сразу.
        const last = base_dir[base_dir.len - 1];
        if (last != '\\' and last != '/') return null;
        return path[base_dir.len..];
    }
    if (base_dir.len + 1 >= path.len) return null;
    return path[base_dir.len + 1 ..];
}

fn sameChar(a: u8, b: u8) bool {
    if ((a == '\\' or a == '/') and (b == '\\' or b == '/')) return true;
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

/// Полный ли это путь: с диска или с сетевого корня.
pub fn isAbsolute(path: []const u8) bool {
    if (path.len >= 2 and path[1] == ':') return true;
    if (path.len >= 2 and (path[0] == '\\' or path[0] == '/') and (path[1] == '\\' or path[1] == '/')) return true;
    return false;
}

/// Полный путь из записанного: относительный — от папки проекта.
pub fn resolve(buf: []u8, base_dir: []const u8, path: []const u8) []const u8 {
    if (isAbsolute(path) or base_dir.len == 0) return path;
    const last = base_dir[base_dir.len - 1];
    const sep: []const u8 = if (last == '\\' or last == '/') "" else "\\";
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ base_dir, sep, path }) catch path;
}

test "путь в папке проекта пишется относительно, чужой — полностью" {
    try std.testing.expectEqualStrings("запись.mp4", relativeTo("D:\\видео", "D:\\видео\\запись.mp4").?);
    // Регистр латиницы и вид косой черты не важны. Регистр кириллицы —
    // важен: складывать русские буквы без таблиц Unicode мы не берёмся,
    // а Windows сам сохраняет имя папки так, как её создали.
    try std.testing.expectEqualStrings("дубли\\1.wav", relativeTo("d:/Видео", "D:\\Видео\\дубли\\1.wav").?);
    try std.testing.expectEqual(@as(?[]const u8, null), relativeTo("D:\\видео", "E:\\видео\\запись.mp4"));
    // «D:\видео2» — не подпапка «D:\видео».
    try std.testing.expectEqual(@as(?[]const u8, null), relativeTo("D:\\видео", "D:\\видео2\\a.mp4"));
    try std.testing.expectEqual(@as(?[]const u8, null), relativeTo("", "D:\\видео\\a.mp4"));
}

test "относительный путь собирается от папки проекта, полный остаётся" {
    var buf: [520]u8 = undefined;
    try std.testing.expectEqualStrings("D:\\видео\\запись.mp4", resolve(&buf, "D:\\видео", "запись.mp4"));
    try std.testing.expectEqualStrings("D:\\видео\\запись.mp4", resolve(&buf, "D:\\видео\\", "запись.mp4"));
    try std.testing.expectEqualStrings("E:\\x.mp4", resolve(&buf, "D:\\видео", "E:\\x.mp4"));
    try std.testing.expectEqualStrings("\\\\сервер\\x.mp4", resolve(&buf, "D:\\видео", "\\\\сервер\\x.mp4"));
    // Без папки проекта относительное остаётся как есть — честнее, чем гадать.
    try std.testing.expectEqualStrings("запись.mp4", resolve(&buf, "", "запись.mp4"));
}

test "проект с относительным путём переезжает вместе с папкой" {
    var p = timeline.Project{};
    _ = try p.addSource("D:\\видео\\запись.mp4", 10 * std.time.ns_per_s);
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(&p, &w, "D:\\видео");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "source 10000000000 запись.mp4") != null);

    var moved = timeline.Project{};
    try read(&moved, w.buffered(), "E:\\архив");
    try std.testing.expectEqualStrings("E:\\архив\\запись.mp4", moved.sourceList()[0].fullPath());
}

test "аннотация пишется одной строкой и читается обратно" {
    var p = timeline.Project{};
    _ = try p.addAnnotation(.{ .at_ns = 1_500_000_000, .len_ns = 3_000_000_000, .kind = .callout, .x = 250, .y = 300, .x2 = 600, .y2 = 700, .colour = .red });
    try p.setAnnotationText(0, "вот эта кнопка");
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(&p, &w, "");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "ann 1500000000 3000000000 callout 250 300 600 700 red вот эта кнопка") != null);

    var back = timeline.Project{};
    try read(&back, w.buffered(), "");
    try std.testing.expectEqual(@as(usize, 1), back.annotations.count);
    const a = back.annotations.list()[0];
    try std.testing.expectEqual(timeline.Annotations.Kind.callout, a.kind);
    try std.testing.expectEqual(@as(i32, 600), a.x2);
    try std.testing.expectEqualStrings("вот эта кнопка", a.title());
    // Старый файл без ann читается как прежде.
    var old = timeline.Project{};
    try read(&old, "zigrec-project 1\n", "");
    try std.testing.expectEqual(@as(usize, 0), old.annotations.count);
}

test "записанное читается обратно до последнего числа" {
    const original = try makeProject();
    defer std.testing.allocator.destroy(original);

    const src = try original.addSource("D:\\видео\\моя запись.mp4", 60 * sec);
    _ = try original.addTrack(.video, "Видео");
    _ = try original.addTrack(.audio, "Микрофон");
    try original.place(0, src, 0, 10 * sec);
    try original.split(0, 4 * sec);
    try original.place(1, src, 2 * sec, 8 * sec);
    try original.setMuted(1, true);

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(original, &w, "");

    const copy = try makeProject();
    defer std.testing.allocator.destroy(copy);
    try read(copy, w.buffered(), "");

    try std.testing.expectEqual(original.source_count, copy.source_count);
    try std.testing.expectEqualStrings(
        original.sourceList()[0].fullPath(),
        copy.sourceList()[0].fullPath(),
    );
    try std.testing.expectEqual(
        original.sourceList()[0].duration_ns,
        copy.sourceList()[0].duration_ns,
    );

    try std.testing.expectEqual(original.track_count, copy.track_count);
    for (original.trackList(), copy.trackList()) |a, b| {
        try std.testing.expectEqual(a.kind, b.kind);
        try std.testing.expectEqual(a.muted, b.muted);
        try std.testing.expectEqualStrings(a.title(), b.title());
        try std.testing.expectEqual(a.count, b.count);
        for (a.list(), b.list()) |x, y| {
            try std.testing.expectEqual(x.source, y.source);
            try std.testing.expectEqual(x.in_ns, y.in_ns);
            try std.testing.expectEqual(x.len_ns, y.len_ns);
            try std.testing.expectEqual(x.at_ns, y.at_ns);
        }
    }
}

test "путь с пробелами не теряет хвост" {
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);
    _ = try p.addSource("C:\\Мои видео\\запись за 15 сентября.mp4", sec);

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(p, &w, "");

    const back = try makeProject();
    defer std.testing.allocator.destroy(back);
    try read(back, w.buffered(), "");
    try std.testing.expectEqualStrings(
        "C:\\Мои видео\\запись за 15 сентября.mp4",
        back.sourceList()[0].fullPath(),
    );
}

test "имя дорожки с пробелами тоже цело" {
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);
    _ = try p.addTrack(.audio, "Микрофон ведущего");

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(p, &w, "");

    const back = try makeProject();
    defer std.testing.allocator.destroy(back);
    try read(back, w.buffered(), "");
    try std.testing.expectEqualStrings("Микрофон ведущего", back.trackList()[0].title());
}

test "открытый проект — начало, а не продолжение" {
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);
    _ = try p.addSource("а.mp4", sec);
    _ = try p.addTrack(.video, "Видео");
    try p.place(0, 0, 0, sec);

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(p, &w, "");

    const back = try makeProject();
    defer std.testing.allocator.destroy(back);
    try read(back, w.buffered(), "");
    // Отменять только что открытое некуда: иначе первая же отмена стёрла бы
    // всё содержимое проекта.
    try std.testing.expect(!back.canUndo());
    try std.testing.expect(!back.canRedo());
}

test "чужой файл и обрубок кончаются словами, а не падением" {
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);

    try std.testing.expectError(Error.NotProject, read(p, "это просто текст", ""));
    try std.testing.expectError(Error.NotProject, read(p, "", ""));
    try std.testing.expectError(
        Error.Malformed,
        read(p, "zigrec-project 1\ntrack video 0 Видео\nclip 0 не-число 1 2\n", ""),
    );
}

test "файл от будущей версии отклоняется, а не читается наполовину" {
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);
    try std.testing.expectError(Error.TooNew, read(p, "zigrec-project 99\n", ""));
}

test "клип без дорожки — это повреждённый файл" {
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);
    try std.testing.expectError(Error.Malformed, read(p, "zigrec-project 1\nclip 0 0 1 2\n", ""));
}

test "незнакомая строка пропускается, а не роняет чтение" {
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);
    try read(p,
        \\zigrec-project 1
        \\source 1000 а.mp4
        \\marker 500 будущая возможность
        \\track video 0 Видео
        \\clip 0 0 1000 0
        \\
    , "");
    try std.testing.expectEqual(@as(usize, 1), p.track_count);
    try std.testing.expectEqual(@as(usize, 1), p.trackList()[0].list().len);
}

test "перевод строки в стиле Windows не мешает" {
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);
    try read(p, "zigrec-project 1\r\nsource 1000 а.mp4\r\ntrack audio 1 Звук\r\n", "");
    try std.testing.expectEqual(@as(usize, 1), p.source_count);
    try std.testing.expect(p.trackList()[0].muted);
    try std.testing.expectEqualStrings("Звук", p.trackList()[0].title());
}

test "ошибки объясняются словами" {
    for ([_]anyerror{ Error.NotProject, Error.TooNew, Error.Malformed, Error.TooBig }) |e| {
        try std.testing.expect(explain(e).len > 20);
    }
}

test "связка переживает запись и чтение" {
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);
    const src = try p.addSource("D:\\видео\\запись.mp4", 60 * std.time.ns_per_s);
    _ = try p.addTrack(.video, "Видео");
    _ = try p.addTrack(.audio, "Звук");
    const link = p.newLink();
    try p.placeLinked(0, src, 0, 10 * std.time.ns_per_s, link);
    try p.placeLinked(1, src, 0, 10 * std.time.ns_per_s, link);

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(p, &w, "");

    const back = try makeProject();
    defer std.testing.allocator.destroy(back);
    try read(back, w.buffered(), "");

    const got = back.tracks[0].clips[0].link;
    try std.testing.expect(got != 0);
    try std.testing.expectEqual(got, back.tracks[1].clips[0].link);
    // Следующая связка не должна получить уже занятый номер.
    try std.testing.expect(back.newLink() > got);
}

test "файл прежнего поколения без номера связки читается" {
    // Пятое число дописано в конец строки нарочно: старый файл его просто
    // не содержит, и клип оказывается сам по себе. Это честнее, чем
    // придумать ему связь, которой в файле не было.
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);
    try read(p,
        \\zigrec-project 1
        \\source 60000000000 а.mp4
        \\track video 0 Видео
        \\clip 0 0 1000000000 0
        \\
    , "");
    try std.testing.expectEqual(@as(u16, 0), p.tracks[0].clips[0].link);
}

test "громкость дорожки, клипа и кривая переживают запись и чтение" {
    const p = try withTracks();
    defer std.testing.allocator.destroy(p);
    try p.setTrackGain(1, -75);
    try p.setClipGain(1, 0, -35);
    _ = try p.addCurvePoint(1, 0, 0);
    _ = try p.addCurvePoint(1, 5 * sec, -200);
    _ = try p.addCurvePoint(1, 9 * sec, 40);

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(p, &w, "");

    const back = try makeProject();
    defer std.testing.allocator.destroy(back);
    try read(back, w.buffered(), "");

    try std.testing.expectEqual(@as(i16, -75), back.tracks[1].gain_db10);
    try std.testing.expectEqual(@as(i16, -35), back.tracks[1].clips[0].gain_db10);
    try std.testing.expect(back.tracks[1].curve_on);
    try std.testing.expectEqual(@as(usize, 3), back.tracks[1].curve.count);
    // И считается она обратно тем же числом, а не похожим.
    try std.testing.expectEqual(p.gainAt(1, 2 * sec), back.gainAt(1, 2 * sec));
    try std.testing.expectEqual(p.gainAt(1, 7 * sec), back.gainAt(1, 7 * sec));
}

test "выключенная кривая пишется выключенной и с точками" {
    // Её выключают, чтобы сравнить с ней и без неё. Нарисованное обязано
    // пережить закрытие окна, иначе сравнивать будет не с чем.
    const p = try withTracks();
    defer std.testing.allocator.destroy(p);
    _ = try p.addCurvePoint(1, sec, -120);
    try p.setCurveOn(1, false);

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(p, &w, "");

    const back = try makeProject();
    defer std.testing.allocator.destroy(back);
    try read(back, w.buffered(), "");

    try std.testing.expect(!back.tracks[1].curve_on);
    try std.testing.expectEqual(@as(usize, 1), back.tracks[1].curve.count);
}

test "проект без громкости не пишет о ней лишних строк" {
    // Файл читают глазами. Строка «gain 0 0» у каждой дорожки — это шум,
    // который не несёт ничего.
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(p, &w, "");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "gain ") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "point ") == null);
}

test "файл прежнего поколения без громкости читается как «как записано»" {
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);
    try read(p,
        \\zigrec-project 1
        \\source 60000000000 а.mp4
        \\track audio 0 Микрофон
        \\clip 0 0 1000000000 0 0
        \\
    , "");
    try std.testing.expectEqual(@as(i16, 0), p.tracks[0].gain_db10);
    try std.testing.expectEqual(@as(i16, 0), p.tracks[0].clips[0].gain_db10);
    try std.testing.expect(!p.tracks[0].curve_on);
    try std.testing.expectEqual(@as(i16, 0), p.gainAt(0, 0));
}

test "громкость из файла прижимается к пределам" {
    // Файл правят руками — это его свойство, а не беда. Написанное там
    // «999 дБ» не должно оглушить.
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);
    try read(p,
        \\zigrec-project 1
        \\source 60000000000 а.mp4
        \\track audio 0 Микрофон
        \\gain 9990 1
        \\clip 0 0 1000000000 0 0 -9990
        \\
    , "");
    try std.testing.expectEqual(timeline.Volume.max_db10, p.tracks[0].gain_db10);
    try std.testing.expectEqual(timeline.Volume.min_db10, p.tracks[0].clips[0].gain_db10);
}

test "метки переживают запись и чтение" {
    const p = try withTracks();
    defer std.testing.allocator.destroy(p);
    _ = try p.addMark(2 * sec, .red, "тут переснять");
    _ = try p.addMark(7 * sec, .violet, "сюда заставку");

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(p, &w, "");

    const back = try makeProject();
    defer std.testing.allocator.destroy(back);
    try read(back, w.buffered(), "");

    try std.testing.expectEqual(@as(usize, 2), back.marks.count);
    try std.testing.expectEqual(@as(u64, 2 * sec), back.marks.items[0].at_ns);
    try std.testing.expectEqualStrings("тут переснять", back.marks.items[0].title());
    try std.testing.expectEqual(timeline.Marks.Colour.red, back.marks.items[0].colour);
    try std.testing.expectEqualStrings("сюда заставку", back.marks.items[1].title());
    try std.testing.expectEqual(timeline.Marks.Colour.violet, back.marks.items[1].colour);
}

test "имя метки с пробелами читается целиком" {
    // Имя — весь остаток строки, и обрезать его по первому пробелу значит
    // потерять всё, кроме первого слова.
    const p = try withTracks();
    defer std.testing.allocator.destroy(p);
    _ = try p.addMark(sec, .green, "три слова тут");

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(p, &w, "");

    const back = try makeProject();
    defer std.testing.allocator.destroy(back);
    try read(back, w.buffered(), "");
    try std.testing.expectEqualStrings("три слова тут", back.marks.items[0].title());
}

test "незнакомый цвет метки не мешает открыть проект" {
    // Метка важнее своего оттенка: отказаться открыть проект из-за цвета —
    // это потерять работу из-за мелочи.
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);
    try read(p,
        \\zigrec-project 1
        \\source 60000000000 а.mp4
        \\mark 1000000000 бирюзовый важное место
        \\track video 0 Видео
        \\
    , "");
    try std.testing.expectEqual(@as(usize, 1), p.marks.count);
    try std.testing.expectEqual(timeline.Marks.Colour.yellow, p.marks.items[0].colour);
    try std.testing.expectEqualStrings("важное место", p.marks.items[0].title());
}

test "проект без меток не пишет о них лишних строк" {
    const p = try withTracks();
    defer std.testing.allocator.destroy(p);

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(p, &w, "");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "mark ") == null);
}

test "комментарий метки переживает запись и чтение" {
    const p = try withTracks();
    defer std.testing.allocator.destroy(p);
    _ = try p.addMark(2 * sec, .red, "переснять");
    try p.setMarkComment(0, "свет с другой стороны, микрофон ближе");
    _ = try p.addMark(7 * sec, .green, "без пояснения");

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(p, &w, "");

    const back = try makeProject();
    defer std.testing.allocator.destroy(back);
    try read(back, w.buffered(), "");

    try std.testing.expectEqualStrings(
        "свет с другой стороны, микрофон ближе",
        back.marks.items[0].comment(),
    );
    // У метки без комментария он и не появился.
    try std.testing.expectEqual(@as(usize, 0), back.marks.items[1].comment().len);
    // И лишней строки в файле нет.
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, w.buffered(), "note "),
    );
}

test "строка комментария без метки перед ней не мешает открыть проект" {
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);
    try read(p,
        \\zigrec-project 1
        \\note ничей комментарий
        \\source 60000000000 а.mp4
        \\track video 0 Видео
        \\
    , "");
    try std.testing.expectEqual(@as(usize, 1), p.track_count);
    try std.testing.expectEqual(@as(usize, 0), p.marks.count);
}

test "диапазон переживает запись и чтение" {
    const p = try withTracks();
    defer std.testing.allocator.destroy(p);
    _ = try p.addMark(2 * sec, .red, "вырезать");
    try p.setMarkLength(0, 3 * sec);
    try p.setMarkComment(0, "вместе со вздохом");
    _ = try p.addMark(8 * sec, .green, "точка");

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(p, &w, "");

    const back = try makeProject();
    defer std.testing.allocator.destroy(back);
    try read(back, w.buffered(), "");

    try std.testing.expect(back.marks.items[0].isSpan());
    try std.testing.expectEqual(@as(u64, 5 * sec), back.marks.items[0].endsAt());
    try std.testing.expectEqualStrings("вместе со вздохом", back.marks.items[0].comment());
    // Точка точкой и осталась.
    try std.testing.expect(!back.marks.items[1].isSpan());
    // И лишней строки про длину у неё нет.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, w.buffered(), "span "));
}

test "файл прежнего поколения без длины даёт точку" {
    // Слова `span` он не знал, и метка была точкой. Так она и читается.
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);
    try read(p,
        \\zigrec-project 1
        \\source 60000000000 а.mp4
        \\mark 2000000000 red вырезать
        \\track video 0 Видео
        \\
    , "");
    try std.testing.expectEqual(@as(usize, 1), p.marks.count);
    try std.testing.expect(!p.marks.items[0].isSpan());
}

test "значки метки, дорожки и клипа переживают запись и чтение" {
    const p = try withTracks();
    defer std.testing.allocator.destroy(p);
    _ = try p.addMark(2 * sec, .red, "вырезать");
    try p.setMarkIcon(0, .scissors);
    try p.setTrackIcon(1, .mic);
    try p.setClipIcon(1, 0, .eye);

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(p, &w, "");

    const back = try makeProject();
    defer std.testing.allocator.destroy(back);
    try read(back, w.buffered(), "");

    try std.testing.expectEqual(timeline.Marks.Icons.Icon.scissors, back.marks.items[0].icon);
    try std.testing.expectEqual(timeline.Marks.Icons.Icon.mic, back.tracks[1].icon);
    try std.testing.expectEqual(timeline.Marks.Icons.Icon.eye, back.tracks[1].clips[0].icon);
    // У дорожки без значка он не появился.
    try std.testing.expectEqual(timeline.Marks.Icons.Icon.none, back.tracks[0].icon);
}

test "проект без значков не пишет о них лишних строк" {
    const p = try withTracks();
    defer std.testing.allocator.destroy(p);
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(p, &w, "");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "icon ") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "tricon ") == null);
}

test "незнакомый значок не мешает открыть проект" {
    // Метка важнее своей картинки: отказаться открыть проект из-за значка —
    // это потерять работу из-за мелочи.
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);
    try read(p,
        \\zigrec-project 1
        \\source 60000000000 а.mp4
        \\mark 1000000000 red важное
        \\icon динозавр
        \\track video 0 Видео
        \\tricon динозавр
        \\
    , "");
    try std.testing.expectEqual(@as(usize, 1), p.marks.count);
    try std.testing.expectEqual(timeline.Marks.Icons.Icon.none, p.marks.items[0].icon);
    try std.testing.expectEqual(timeline.Marks.Icons.Icon.none, p.tracks[0].icon);
}

test "заметка дубля пишется за исходником и читается обратно" {
    var p = timeline.Project{};
    const s = try p.addSource("D:\\v\\дубли\\озвучка 2026-09-17 12-00-00.wav", 3 * std.time.ns_per_s);
    try p.setSourceNote(s, "второй заход, чище");
    _ = try p.addSource("D:\\v\\фильм.mp4", 60 * std.time.ns_per_s);
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(&p, &w, "");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "take второй заход, чище") != null);

    var back = timeline.Project{};
    try read(&back, w.buffered(), "");
    try std.testing.expectEqualStrings("второй заход, чище", back.sourceList()[0].comment());
    try std.testing.expectEqualStrings("", back.sourceList()[1].comment());
}
