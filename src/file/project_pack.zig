//! Файл проекта `.zigrec`: архив с разметкой и, при желании, с исходниками.
//!
//! Задача #71. Прежний `.zrs` помнил только пути к файлам. Переехал файл —
//! и проект показывает пустую дорожку. Архив это чинит: при желании всё
//! нужное лежит внутри, и проект можно отдать другому человеку или унести
//! на другую машину одним файлом.
//!
//! Внутри обычный ZIP:
//!
//! ```
//! ZIGREC-V-0.5.5.0     метка: первой и без сжатия
//! проект.zrs           та же текстовая разметка, что и раньше
//! исходники/…          копии файлов, если просили собрать всё с собой
//! ```
//!
//! **Метка первой и без сжатия** — чтобы файл узнавался по содержимому,
//! а не по расширению: имя метки видно в первых байтах архива простым
//! поиском. Так же устроены ODF и EPUB, и не от хорошей жизни, а потому
//! что расширение врёт.
//!
//! **Разметка внутри — тот же текст.** Ничего не переизобретаем: формат
//! разметки уже есть, проверен и читается глазами. Архив добавляет к нему
//! оболочку, а не заменяет его.
const std = @import("std");
const zip = @import("zip.zig");
const project_file = @import("project_file.zig");
const timeline = @import("../edit/timeline.zig");

/// С чего начинается имя метки. Дальше идёт версия программы.
pub const marker_prefix = "ZIGREC-V-";
/// Как называется разметка внутри архива.
pub const project_entry = "проект.zrs";
/// Куда складываются копии исходников.
pub const media_prefix = "исходники/";

/// Расширение файла проекта.
pub const extension = ".zigrec";
/// Расширение прежнего формата. Читать его мы не перестаём.
pub const old_extension = ".zrs";

pub const Error = error{
    /// Это не наш архив.
    NotPack,
    /// Архив есть, а разметки внутри нет.
    NoProject,
};

/// Что класть в архив.
pub const Bundle = enum {
    /// Только разметка. Сотни байт, исходники остаются по своим путям.
    markup_only,
    /// Разметка и копии исходников. Тяжело, зато самодостаточно.
    with_media,

    pub fn label(self: Bundle) []const u8 {
        return switch (self) {
            .markup_only => "только разметка",
            .with_media => "вместе с исходниками",
        };
    }
};

/// Имя метки для этой версии программы.
pub fn markerName(buf: []u8, version: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}", .{ marker_prefix, version }) catch marker_prefix;
}

/// Метка ли это.
pub fn isMarker(name: []const u8) bool {
    return std.mem.startsWith(u8, name, marker_prefix);
}

/// Версия из имени метки. Пусто — если это не метка.
pub fn versionOf(name: []const u8) []const u8 {
    if (!isMarker(name)) return "";
    return name[marker_prefix.len..];
}

/// Имя куска для исходника.
pub fn mediaEntry(buf: []u8, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}", .{ media_prefix, std.fs.path.basename(path) }) catch media_prefix;
}

/// Просят ли новый формат.
pub fn wantsPack(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, extension);
}

/// Похоже ли это на наш архив по первым байтам.
///
/// Смотрим в содержимое, а не на расширение: расширение врёт. Метка лежит
/// первой и без сжатия, поэтому её имя видно прямо в начале файла.
pub fn looksLikePack(head: []const u8) bool {
    if (head.len < 4) return false;
    if (!std.mem.eql(u8, head[0..2], "PK")) return false;
    const window = head[0..@min(head.len, 256)];
    return std.mem.indexOf(u8, window, marker_prefix) != null;
}

// ------------------------------------------------------------- запись

/// Что положить в архив вместе с разметкой.
pub const Media = struct {
    /// Откуда взят файл.
    path: []const u8,
    /// Его содержимое.
    data: []const u8,
};

/// Собрать архив.
///
/// Исходники кладём без сжатия: видео и звук уже сжаты, и второй проход
/// только тратит время, добавляя байты.
pub fn write(
    allocator: std.mem.Allocator,
    project: *const timeline.Project,
    version: []const u8,
    media: []const Media,
) ![]u8 {
    var archive = zip.Archive.init(allocator);
    defer archive.deinit();

    var marker_buf: [64]u8 = undefined;
    const marker = markerName(&marker_buf, version);
    try archive.add(marker, marker, .store);

    var text: [256 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&text);
    try project_file.write(project, &w);
    try archive.add(project_entry, w.buffered(), .deflate);

    var name_buf: [512]u8 = undefined;
    for (media) |m| {
        try archive.add(mediaEntry(&name_buf, m.path), m.data, .store);
    }

    return archive.finish();
}

// ------------------------------------------------------------- чтение

/// Сколько головы архива читаем, чтобы достать разметку.
///
/// Метка и разметка лежат первыми, и вместе они — единицы килобайт.
/// Мегабайта хватает с запасом даже на проект из сотни клипов, а вот
/// поднимать в память гигабайтный архив ради этого незачем.
pub const head_limit: usize = 1 << 20;

/// Что оказалось внутри.
pub const Opened = struct {
    /// Версия программы из метки. Пусто — метки не было.
    version: [32]u8 = @splat(0),
    version_len: usize = 0,
    /// Сколько исходников лежит внутри.
    media: usize = 0,

    pub fn madeBy(self: *const Opened) []const u8 {
        return self.version[0..self.version_len];
    }
};

/// Прочитать разметку из архива.
///
/// Исходники при этом не трогаем: они могут весить гигабайты, а чтобы
/// показать дорожки, они не нужны. Распаковывать их — отдельная просьба.
pub fn readMarkup(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    project: *timeline.Project,
) !Opened {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const head = try allocator.alloc(u8, head_limit);
    defer allocator.free(head);
    var scratch: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &scratch);
    const got = try reader.interface.readSliceShort(head);
    if (got == 0) return Error.NotPack;
    const window = head[0..got];

    if (!looksLikePack(window)) return Error.NotPack;

    var out = Opened{};
    var list: [64][]const u8 = undefined;
    const n = zip.names(window, &list);
    for (list[0..n]) |name| {
        if (isMarker(name)) {
            const v = versionOf(name);
            const keep = @min(v.len, out.version.len);
            @memcpy(out.version[0..keep], v[0..keep]);
            out.version_len = keep;
        } else if (std.mem.startsWith(u8, name, media_prefix)) {
            out.media += 1;
        }
    }

    const markup = (try zip.find(allocator, window, project_entry)) orelse return Error.NoProject;
    defer allocator.free(markup);
    try project_file.read(project, markup);
    return out;
}

/// Распаковать исходники из архива в указанную папку.
///
/// Возвращает, сколько файлов распаковано. Идём через `std.zip`: он читает
/// архив по кускам, а не целиком, и гигабайтный файл не поднимается
/// в память ради одного видео.
pub fn unpackMedia(
    io: std.Io,
    path: []const u8,
    dest: []const u8,
) !usize {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var scratch: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &scratch);

    var dir = try std.Io.Dir.cwd().openDir(io, dest, .{});
    defer dir.close(io);

    var it = try std.zip.Iterator.init(&reader);
    var name_buf: [512]u8 = undefined;
    var count: usize = 0;
    while (try it.next()) |entry| {
        if (entry.filename_len > name_buf.len) continue;
        // Имя лежит в оглавлении сразу за заголовком куска.
        try reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        const name = name_buf[0..entry.filename_len];
        try reader.interface.readSliceAll(name);
        if (!std.mem.startsWith(u8, name, media_prefix)) continue;

        // Уже распакованное не трогаем: второй раз открывать тот же архив
        // человек будет чаще, чем первый, а гигабайт перекладывать заново
        // незачем. Сверяем размер — этого достаточно, чтобы отличить
        // готовую копию от оборванной.
        if (dir.openFile(io, name, .{})) |existing| {
            defer existing.close(io);
            if (existing.stat(io)) |info| {
                if (info.size == entry.uncompressed_size) {
                    count += 1;
                    continue;
                }
            } else |_| {}
        } else |_| {}

        // Распаковка создаёт файл и отказывается писать поверх. Значит,
        // недоделанную копию убираем сами.
        dir.deleteFile(io, name) catch {};
        entry.extract(&reader, .{}, &name_buf, dir) catch continue;
        count += 1;
    }
    return count;
}

/// Где искать исходник после открытия архива.
///
/// Распакованная копия важнее записанного пути: архив на то и собирали,
/// чтобы проект открылся там, где исходного файла нет. Но если копии
/// не оказалось, идёт в ход путь — и тогда всё как раньше.
///
/// Копии лежат в подпапке с тем же именем, что и в архиве: распакованное
/// повторяет устройство архива, и человеку не приходится держать в голове
/// два разных расклада.
pub fn sourcePath(buf: []u8, original: []const u8, unpacked_dir: []const u8, unpacked_present: bool) []const u8 {
    if (!unpacked_present or unpacked_dir.len == 0) return original;
    // Отрезаем косую в конце: на диске её место займёт разделитель пути.
    const folder = media_prefix[0 .. media_prefix.len - 1];
    return std.fmt.bufPrint(buf, "{s}\\{s}\\{s}", .{
        unpacked_dir,
        folder,
        std.fs.path.basename(original),
    }) catch original;
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;

fn sampleProject() !*timeline.Project {
    const p = try testing.allocator.create(timeline.Project);
    p.* = .{};
    const src = try p.addSource("D:\\видео\\моя запись.mp4", 60 * std.time.ns_per_s);
    _ = try p.addTrack(.video, "Видео");
    _ = try p.addTrack(.audio, "Микрофон");
    const link = p.newLink();
    try p.placeLinked(0, src, 0, 10 * std.time.ns_per_s, link);
    try p.placeLinked(1, src, 0, 10 * std.time.ns_per_s, link);
    return p;
}

test "метка несёт версию и узнаётся" {
    var buf: [64]u8 = undefined;
    const name = markerName(&buf, "0.5.5.0");
    try testing.expectEqualStrings("ZIGREC-V-0.5.5.0", name);
    try testing.expect(isMarker(name));
    try testing.expectEqualStrings("0.5.5.0", versionOf(name));

    try testing.expect(!isMarker("проект.zrs"));
    try testing.expectEqualStrings("", versionOf("проект.zrs"));
}

test "архив узнаётся по содержимому, а не по имени" {
    const a = testing.allocator;
    const p = try sampleProject();
    defer a.destroy(p);

    const bytes = try write(a, p, "0.5.5.0", &.{});
    defer a.free(bytes);

    try testing.expect(looksLikePack(bytes));
    // Обычный ZIP без нашей метки — не наш архив.
    try testing.expect(!looksLikePack("PK\x03\x04какой-то чужой архив"));
    try testing.expect(!looksLikePack("zigrec-project 1\n"));
    try testing.expect(!looksLikePack(""));
}

test "метка лежит первой и без сжатия" {
    // На этом и держится узнавание по содержимому: сжатую метку в начале
    // файла не найти простым поиском.
    const a = testing.allocator;
    const p = try sampleProject();
    defer a.destroy(p);

    const bytes = try write(a, p, "1.2.3.4", &.{});
    defer a.free(bytes);

    const method = std.mem.readInt(u16, bytes[8..10], .little);
    try testing.expectEqual(@as(u16, 0), method);
    const name_len = std.mem.readInt(u16, bytes[26..28], .little);
    try testing.expectEqualStrings("ZIGREC-V-1.2.3.4", bytes[30..][0..name_len]);
}

test "разметка внутри — тот же текст, что и раньше" {
    const a = testing.allocator;
    const p = try sampleProject();
    defer a.destroy(p);

    const bytes = try write(a, p, "0.5.5.0", &.{});
    defer a.free(bytes);

    // Имя куска с разметкой должно встречаться в архиве: по нему её ищут.
    try testing.expect(std.mem.indexOf(u8, bytes, project_entry) != null);
}

test "исходники называются по имени файла, без путей" {
    // Путь внутри архива с двоеточием и обратными косыми не распакуется
    // ни на одной другой машине.
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "исходники/моя запись.mp4",
        mediaEntry(&buf, "D:\\видео\\моя запись.mp4"),
    );
    try testing.expectEqualStrings(
        "исходники/клип.mov",
        mediaEntry(&buf, "клип.mov"),
    );
}

test "исходники попадают в архив" {
    const a = testing.allocator;
    const p = try sampleProject();
    defer a.destroy(p);

    const media = [_]Media{.{ .path = "D:\\видео\\моя запись.mp4", .data = "тут было бы видео" }};
    const bytes = try write(a, p, "0.5.5.0", &media);
    defer a.free(bytes);

    try testing.expect(std.mem.indexOf(u8, bytes, "исходники/моя запись.mp4") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "тут было бы видео") != null);
}

test "архив с исходниками заметно тяжелее пустого" {
    const a = testing.allocator;
    const p = try sampleProject();
    defer a.destroy(p);

    const light = try write(a, p, "0.5.5.0", &.{});
    defer a.free(light);

    const payload = "данные" ** 1000;
    const media = [_]Media{.{ .path = "видео.mp4", .data = payload }};
    const heavy = try write(a, p, "0.5.5.0", &media);
    defer a.free(heavy);

    try testing.expect(heavy.len > light.len + payload.len / 2);
    // А пустой — действительно маленький: сотни байт, а не мегабайты.
    try testing.expect(light.len < 1024);
}

test "какой формат просят — видно по имени" {
    try testing.expect(wantsPack("проект.zigrec"));
    try testing.expect(wantsPack("D:\\работа\\ПРОЕКТ.ZIGREC"));
    try testing.expect(!wantsPack("проект.zrs"));
    try testing.expect(!wantsPack("проект"));
}

test "два одинаковых проекта дают одинаковые архивы" {
    // Время в заголовках нулевое нарочно: иначе один и тот же проект давал
    // бы разные байты при каждом сохранении.
    const a = testing.allocator;
    const p = try sampleProject();
    defer a.destroy(p);

    const one = try write(a, p, "0.5.5.0", &.{});
    defer a.free(one);
    const two = try write(a, p, "0.5.5.0", &.{});
    defer a.free(two);
    try testing.expectEqualSlices(u8, one, two);
}

test "у каждого способа сборки есть подпись" {
    for ([_]Bundle{ .markup_only, .with_media }) |b| {
        try testing.expect(b.label().len > 0);
    }
}

test "где искать исходник после открытия архива" {
    var buf: [512]u8 = undefined;
    // Копия из архива важнее записанного пути.
    try testing.expectEqualStrings(
        "C:\\распаковано\\исходники\\моя запись.mp4",
        sourcePath(&buf, "D:\\видео\\моя запись.mp4", "C:\\распаковано", true),
    );
    // Копии нет — идёт в ход путь, и всё как раньше.
    try testing.expectEqualStrings(
        "D:\\видео\\моя запись.mp4",
        sourcePath(&buf, "D:\\видео\\моя запись.mp4", "C:\\распаковано", false),
    );
    // Распаковывать было некуда — тоже путь.
    try testing.expectEqualStrings(
        "D:\\видео\\моя запись.mp4",
        sourcePath(&buf, "D:\\видео\\моя запись.mp4", "", true),
    );
}

test "версия из метки достаётся" {
    var o = Opened{};
    const v = "0.5.6.0";
    @memcpy(o.version[0..v.len], v);
    o.version_len = v.len;
    try testing.expectEqualStrings("0.5.6.0", o.madeBy());
    try testing.expectEqualStrings("", (Opened{}).madeBy());
}
