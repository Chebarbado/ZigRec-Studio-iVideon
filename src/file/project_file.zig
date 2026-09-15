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
pub fn write(project: *const timeline.Project, w: *std.Io.Writer) !void {
    try w.print("{s} {d}\n", .{ magic, version });

    for (project.sourceList()) |src| {
        try w.print("source {d} {s}\n", .{ src.duration_ns, src.fullPath() });
    }

    for (project.trackList()) |track| {
        try w.print("track {s} {d} {s}\n", .{
            @tagName(track.kind),
            @intFromBool(track.muted),
            track.title(),
        });
        for (track.list()) |clip| {
            // Пятое число — номер связки. Дописано в конец строки нарочно:
            // прежнее поколение читает первые четыре и просто не заметит
            // пятого. Связка потеряется, проект — нет.
            try w.print("clip {d} {d} {d} {d} {d}\n", .{
                clip.source,
                clip.in_ns,
                clip.len_ns,
                clip.at_ns,
                clip.link,
            });
        }
    }
}

/// Прочитать проект из текста в уже созданный (пустой) проект.
pub fn read(project: *timeline.Project, data: []const u8) Error!void {
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
            _ = project.addSource(path, duration) catch return Error.TooBig;
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

        if (std.mem.eql(u8, word, "clip")) {
            const track = current_track orelse return Error.Malformed;
            const source = parseU64(parts.next()) orelse return Error.Malformed;
            const in_ns = parseU64(parts.next()) orelse return Error.Malformed;
            const len_ns = parseU64(parts.next()) orelse return Error.Malformed;
            const at_ns = parseU64(parts.next()) orelse return Error.Malformed;
            // Номера связки может не быть: файл от прежнего поколения.
            // Тогда клип сам по себе — это честнее, чем придумать ему связь.
            const link = parseU64(parts.next()) orelse 0;
            project.tracks[track].clips[project.tracks[track].count] = .{
                .source = @intCast(source),
                .in_ns = in_ns,
                .len_ns = len_ns,
                .at_ns = at_ns,
                .link = @truncate(link),
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

fn parseU64(maybe: ?[]const u8) ?u64 {
    const text = maybe orelse return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// Объяснение словами — для окна.
pub fn explain(err: anyerror) []const u8 {
    return switch (err) {
        Error.NotProject => "это не файл проекта Zig-Rec Studio",
        Error.TooNew => "файл сделан более новой версией программы: обновите её",
        Error.Malformed => "файл проекта повреждён: строка не разбирается",
        Error.TooBig => "в файле больше дорожек или клипов, чем программа умеет держать",
        else => "файл проекта не читается",
    };
}

// ---------------------------------------------------------------- тесты

const sec = std.time.ns_per_s;

fn makeProject() !*timeline.Project {
    const p = try std.testing.allocator.create(timeline.Project);
    p.* = .{};
    return p;
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
    try write(original, &w);

    const copy = try makeProject();
    defer std.testing.allocator.destroy(copy);
    try read(copy, w.buffered());

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
    try write(p, &w);

    const back = try makeProject();
    defer std.testing.allocator.destroy(back);
    try read(back, w.buffered());
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
    try write(p, &w);

    const back = try makeProject();
    defer std.testing.allocator.destroy(back);
    try read(back, w.buffered());
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
    try write(p, &w);

    const back = try makeProject();
    defer std.testing.allocator.destroy(back);
    try read(back, w.buffered());
    // Отменять только что открытое некуда: иначе первая же отмена стёрла бы
    // всё содержимое проекта.
    try std.testing.expect(!back.canUndo());
    try std.testing.expect(!back.canRedo());
}

test "чужой файл и обрубок кончаются словами, а не падением" {
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);

    try std.testing.expectError(Error.NotProject, read(p, "это просто текст"));
    try std.testing.expectError(Error.NotProject, read(p, ""));
    try std.testing.expectError(
        Error.Malformed,
        read(p, "zigrec-project 1\ntrack video 0 Видео\nclip 0 не-число 1 2\n"),
    );
}

test "файл от будущей версии отклоняется, а не читается наполовину" {
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);
    try std.testing.expectError(Error.TooNew, read(p, "zigrec-project 99\n"));
}

test "клип без дорожки — это повреждённый файл" {
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);
    try std.testing.expectError(Error.Malformed, read(p, "zigrec-project 1\nclip 0 0 1 2\n"));
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
    );
    try std.testing.expectEqual(@as(usize, 1), p.track_count);
    try std.testing.expectEqual(@as(usize, 1), p.trackList()[0].list().len);
}

test "перевод строки в стиле Windows не мешает" {
    const p = try makeProject();
    defer std.testing.allocator.destroy(p);
    try read(p, "zigrec-project 1\r\nsource 1000 а.mp4\r\ntrack audio 1 Звук\r\n");
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
    try write(p, &w);

    const back = try makeProject();
    defer std.testing.allocator.destroy(back);
    try read(back, w.buffered());

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
    );
    try std.testing.expectEqual(@as(u16, 0), p.tracks[0].clips[0].link);
}
