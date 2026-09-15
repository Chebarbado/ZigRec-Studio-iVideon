//! Списки недавних файлов: что записали и что смотрели.
//!
//! Задача #52. Списка два, и это нарочно: «где моя вчерашняя запись»
//! и «что я вчера монтировал» — разные вопросы, и мешать их в одну кучу
//! значит не ответить ни на один.
//!
//! **Пропавший файл не прячем.** Строка, молча исчезнувшая из списка,
//! выглядит так, будто программа что-то потеряла. Показываем и говорим,
//! что файла нет на месте: диск мог быть отключён, папка переименована,
//! файл унесён на другую машину — всё это человек разберёт сам, если
//! ему сказать.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;

pub const magic = "zigrec-recent";
pub const version: u32 = 1;

/// Имя файла со списками. Лежит там же, где настройки.
pub const file_name = "недавние.txt";

/// Сколько строк помним.
///
/// Двенадцать: в меню это ещё читается одним взглядом, а дальше список
/// превращается в свалку, по которой проще искать в проводнике.
pub const max_items = 12;
pub const max_path = 260;

pub const List = struct {
    items: [max_items][max_path]u8 = @splat(@splat(0)),
    lens: [max_items]usize = @splat(0),
    count: usize = 0,

    pub fn at(self: *const List, i: usize) []const u8 {
        if (i >= self.count) return "";
        return self.items[i][0..self.lens[i]];
    }

    /// Положить путь в начало списка.
    ///
    /// Тот же файл не появляется дважды: он всплывает наверх. Список
    /// с повторами — это список, в котором нельзя найти нужное, потому что
    /// одно и то же занимает все строки.
    pub fn add(self: *List, path: []const u8) void {
        if (path.len == 0 or path.len > max_path) return;

        // Уже есть — убираем со старого места, чтобы поставить наверх.
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (samePath(self.at(i), path)) {
                self.removeAt(i);
                break;
            }
        }

        // Сдвигаем всё вниз, самое старое выпадает за край.
        var k = @min(self.count, max_items - 1);
        while (k > 0) : (k -= 1) {
            self.items[k] = self.items[k - 1];
            self.lens[k] = self.lens[k - 1];
        }
        @memcpy(self.items[0][0..path.len], path);
        self.lens[0] = path.len;
        self.count = @min(self.count + 1, max_items);
    }

    pub fn removeAt(self: *List, index: usize) void {
        if (index >= self.count) return;
        var i = index;
        while (i + 1 < self.count) : (i += 1) {
            self.items[i] = self.items[i + 1];
            self.lens[i] = self.lens[i + 1];
        }
        self.count -= 1;
        self.lens[self.count] = 0;
    }
};

/// Одинаковые ли это пути.
///
/// Windows не различает большие и малые буквы в путях, и `D:\Видео\а.mp4`
/// с `d:\Видео\а.mp4` — один и тот же файл. Сравнивать побайтно значило бы
/// показать его в списке дважды.
pub fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

pub const Recent = struct {
    /// То, что сняли сами.
    recorded: List = .{},
    /// То, что открывали в редакторе.
    viewed: List = .{},
};

pub const Error = error{
    /// Это не список недавних.
    NotRecent,
    /// Файл от более новой версии.
    TooNew,
};

pub fn write(r: *const Recent, w: *std.Io.Writer) !void {
    try w.print("{s} {d}\n", .{ magic, version });
    // Пишем сверху вниз, как показываем: файл, открытый глазами, должен
    // читаться в том же порядке, что и меню.
    var i: usize = 0;
    while (i < r.recorded.count) : (i += 1) {
        try w.print("recorded {s}\n", .{r.recorded.at(i)});
    }
    i = 0;
    while (i < r.viewed.count) : (i += 1) {
        try w.print("viewed {s}\n", .{r.viewed.at(i)});
    }
}

/// Прочитать списки из текста.
///
/// Незнакомая строка пропускается. Список недавних — не то, из-за чего
/// стоит отказываться запускаться.
pub fn read(data: []const u8) Error!Recent {
    var lines = std.mem.splitScalar(u8, data, '\n');
    const head = trim(lines.next() orelse return Error.NotRecent);
    var head_parts = std.mem.splitScalar(u8, head, ' ');
    const name = head_parts.next() orelse return Error.NotRecent;
    if (!std.mem.eql(u8, name, magic)) return Error.NotRecent;
    const got = std.fmt.parseInt(u32, head_parts.next() orelse "0", 10) catch 0;
    if (got > version) return Error.TooNew;

    // Собираем в обратном порядке: `add` кладёт в начало, а в файле
    // строки идут сверху вниз.
    var recorded_paths: [max_items][]const u8 = @splat("");
    var viewed_paths: [max_items][]const u8 = @splat("");
    var recorded_n: usize = 0;
    var viewed_n: usize = 0;

    while (lines.next()) |raw| {
        const text = trim(raw);
        if (text.len == 0) continue;
        var parts = std.mem.splitScalar(u8, text, ' ');
        const word = parts.next() orelse continue;
        const path = parts.rest();
        if (path.len == 0) continue;

        if (std.mem.eql(u8, word, "recorded")) {
            if (recorded_n < max_items) {
                recorded_paths[recorded_n] = path;
                recorded_n += 1;
            }
        } else if (std.mem.eql(u8, word, "viewed")) {
            if (viewed_n < max_items) {
                viewed_paths[viewed_n] = path;
                viewed_n += 1;
            }
        }
    }

    var out = Recent{};
    var i = recorded_n;
    while (i > 0) : (i -= 1) out.recorded.add(recorded_paths[i - 1]);
    i = viewed_n;
    while (i > 0) : (i -= 1) out.viewed.add(viewed_paths[i - 1]);
    return out;
}

fn trim(text: []const u8) []const u8 {
    var out = text;
    while (out.len > 0 and (out[out.len - 1] == '\r' or out[out.len - 1] == ' ')) out.len -= 1;
    return out;
}

// ------------------------------------------------------------- диск

/// Прочитать списки. Нет файла — пустые списки: первый запуск ничем
/// не отличается от обычного.
pub fn load(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) Recent {
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ dir_path, file_name }) catch
        return .{};
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 16)) catch
        return .{};
    defer allocator.free(data);
    return read(data) catch .{};
}

pub fn save(r: *const Recent, dir_path: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ dir_path, file_name }) catch return false;

    var text: [(max_path + 16) * max_items * 2 + 64]u8 = undefined;
    var w = std.Io.Writer.fixed(&text);
    write(r, &w) catch return false;
    const bytes = w.buffered();

    var wide_buf: [1024]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide_buf, path) catch return false;
    if (n >= wide_buf.len) return false;
    wide_buf[n] = 0;

    const handle = c.CreateFileW(
        @ptrCast(&wide_buf),
        c.GENERIC_WRITE,
        0,
        null,
        c.CREATE_ALWAYS,
        c.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == c.INVALID_HANDLE_VALUE) return false;
    defer _ = c.CloseHandle(handle);

    var written: c.DWORD = 0;
    const ok = c.WriteFile(handle, bytes.ptr, @intCast(bytes.len), &written, null) != 0;
    return ok and written == bytes.len;
}

/// Лежит ли файл на месте. Пропавший показываем, а не прячем.
pub fn onDisk(path: []const u8) bool {
    if (builtin.os.tag != .windows or path.len == 0) return false;
    var wide_buf: [1024]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide_buf, path) catch return false;
    if (n >= wide_buf.len) return false;
    wide_buf[n] = 0;
    return c.GetFileAttributesW(@ptrCast(&wide_buf)) != c.INVALID_FILE_ATTRIBUTES;
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;

test "новое встаёт наверх" {
    var l = List{};
    l.add("D:\\а.mp4");
    l.add("D:\\б.mp4");
    l.add("D:\\в.mp4");
    try testing.expectEqual(@as(usize, 3), l.count);
    try testing.expectEqualStrings("D:\\в.mp4", l.at(0));
    try testing.expectEqualStrings("D:\\б.mp4", l.at(1));
    try testing.expectEqualStrings("D:\\а.mp4", l.at(2));
}

test "тот же файл всплывает, а не появляется дважды" {
    var l = List{};
    l.add("D:\\а.mp4");
    l.add("D:\\б.mp4");
    l.add("D:\\а.mp4");
    try testing.expectEqual(@as(usize, 2), l.count);
    try testing.expectEqualStrings("D:\\а.mp4", l.at(0));
    try testing.expectEqualStrings("D:\\б.mp4", l.at(1));
}

test "большие и малые буквы в пути — это один файл" {
    // Windows их не различает, и показывать такое дважды значит врать.
    var l = List{};
    l.add("D:\\Видео\\Запись.MP4");
    l.add("d:\\Видео\\Запись.mp4");
    try testing.expectEqual(@as(usize, 1), l.count);
    try testing.expect(samePath("D:\\A\\B.MP4", "d:\\a\\b.mp4"));
    try testing.expect(!samePath("D:\\A.mp4", "D:\\B.mp4"));
    try testing.expect(!samePath("D:\\A.mp4", "D:\\A.mp4x"));
}

test "список не растёт бесконечно, самое старое выпадает" {
    var l = List{};
    var i: usize = 0;
    var buf: [32]u8 = undefined;
    while (i < max_items + 5) : (i += 1) {
        l.add(std.fmt.bufPrint(&buf, "D:\\{d}.mp4", .{i}) catch unreachable);
    }
    try testing.expectEqual(max_items, l.count);
    // Наверху — последнее добавленное, внизу — не самое первое.
    try testing.expectEqualStrings("D:\\16.mp4", l.at(0));
    try testing.expectEqualStrings("D:\\5.mp4", l.at(max_items - 1));
}

test "пустой путь и слишком длинный не берём" {
    var l = List{};
    l.add("");
    const long = "D:\\" ++ "я" ** 200;
    l.add(long);
    try testing.expectEqual(@as(usize, 0), l.count);
}

test "оба списка переживают запись и чтение, порядок сохраняется" {
    var r = Recent{};
    r.recorded.add("D:\\Видео\\первая запись.mp4");
    r.recorded.add("D:\\Видео\\вторая запись.mp4");
    r.viewed.add("E:\\чужое\\клип.mov");

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(&r, &w);

    const back = try read(w.buffered());
    try testing.expectEqual(@as(usize, 2), back.recorded.count);
    try testing.expectEqualStrings("D:\\Видео\\вторая запись.mp4", back.recorded.at(0));
    try testing.expectEqualStrings("D:\\Видео\\первая запись.mp4", back.recorded.at(1));
    try testing.expectEqual(@as(usize, 1), back.viewed.count);
    try testing.expectEqualStrings("E:\\чужое\\клип.mov", back.viewed.at(0));
}

test "списки не смешиваются" {
    // «Где моя вчерашняя запись» и «что я вчера монтировал» — разные вопросы.
    var r = Recent{};
    r.recorded.add("D:\\своё.mp4");
    r.viewed.add("D:\\чужое.mp4");
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(&r, &w);
    const back = try read(w.buffered());
    try testing.expectEqualStrings("D:\\своё.mp4", back.recorded.at(0));
    try testing.expectEqualStrings("D:\\чужое.mp4", back.viewed.at(0));
    try testing.expectEqual(@as(usize, 1), back.recorded.count);
    try testing.expectEqual(@as(usize, 1), back.viewed.count);
}

test "путь с пробелами не разваливается" {
    var r = Recent{};
    r.recorded.add("C:\\Users\\Юрий\\Мои видео\\запись экрана 2026.mp4");
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(&r, &w);
    const back = try read(w.buffered());
    try testing.expectEqualStrings("C:\\Users\\Юрий\\Мои видео\\запись экрана 2026.mp4", back.recorded.at(0));
}

test "чужой файл узнаётся, файл из будущего отклоняется" {
    try testing.expectError(Error.NotRecent, read("просто текст"));
    try testing.expectError(Error.NotRecent, read(""));
    try testing.expectError(Error.TooNew, read("zigrec-recent 99\n"));
}

test "испорченная строка пропускается, остальное читается" {
    const back = try read(
        \\zigrec-recent 1
        \\recorded D:\а.mp4
        \\это не строка списка
        \\recorded
        \\viewed D:\б.mp4
        \\
    );
    try testing.expectEqual(@as(usize, 1), back.recorded.count);
    try testing.expectEqual(@as(usize, 1), back.viewed.count);
}

test "переводы строк Windows не мешают" {
    const back = try read("zigrec-recent 1\r\nrecorded D:\\а.mp4\r\n");
    try testing.expectEqualStrings("D:\\а.mp4", back.recorded.at(0));
}

test "пустые списки целиком нулевые" {
    // То же правило, что и у проекта: ненулевое умолчание у большой
    // структуры кладёт её целиком в .exe готовыми байтами.
    const plain = Recent{};
    const zeroed = std.mem.zeroes(Recent);
    try testing.expect(std.meta.eql(plain, zeroed));
}
