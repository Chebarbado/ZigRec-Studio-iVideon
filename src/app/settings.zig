//! Настройки, которые переживают перезапуск.
//!
//! Задача #48. Часть решений была зашита в программу: куда класть записи,
//! как называть файлы, на каком порту слушать. Это решения владельца машины,
//! а не наши.
//!
//! **В настройках нет того, что уже есть на главном окне** — частоты кадров,
//! качества, звука, курсора. Одна и та же вещь в двух местах — это два места,
//! где она может разойтись.
//!
//! **Формат — простой текст**, как у файла проекта: десяток строк, которые
//! можно посмотреть глазами и поправить руками. Лежит рядом с записями,
//! а не в реестре: файл видно, реестр — нет.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const hotkey = @import("hotkey.zig");
const c = win32.c;

pub const magic = "zigrec-settings";
pub const version: u32 = 1;

/// Имя файла настроек. Лежит в папке записей: настройки и записи — одно
/// хозяйство, и переносятся вместе.
pub const file_name = "настройки.txt";

pub const max_path = 260;
pub const max_template = 96;
pub const max_hotkey = hotkey.max_text;

pub const Settings = struct {
    /// Куда класть записи. Пусто — значит «как было по умолчанию».
    out_dir: [max_path]u8 = @splat(0),
    out_dir_len: usize = 0,

    /// Шаблон имени файла: `%d` дата, `%t` время, `%n` номер.
    template: [max_template]u8 = @splat(0),
    template_len: usize = 0,

    /// Сочетание «обвести область и писать».
    area_key: [max_hotkey]u8 = @splat(0),
    area_key_len: usize = 0,

    /// Высота окна кадра в редакторе. Подогнал границу один раз —
    /// и при следующем запуске она там же.
    preview_h: i32 = 260,

    /// Порт, на котором слушает сервер для Claude Code.
    port: u16 = 15599,
    /// Поднимать сервер сразу при запуске окна.
    serve_at_start: bool = false,

    pub const default_template = "zigrec-%d-%t.mp4";
    /// Пределы высоты кадра. Те же, что у правила в `editor_view.zig`,
    /// но проверяются и здесь: файл настроек правят руками.
    pub const min_preview_h: i32 = 120;
    pub const max_preview_h: i32 = 4000;

    pub fn init() Settings {
        var s = Settings{};
        s.setTemplate(default_template);
        _ = s.setAreaKey(hotkey.default_text);
        return s;
    }

    pub fn areaKey(self: *const Settings) []const u8 {
        // Пустое — значит «как было по умолчанию»: так настройки,
        // прочитанные из старого файла, ведут себя разумно.
        if (self.area_key_len == 0) return hotkey.default_text;
        return self.area_key[0..self.area_key_len];
    }

    /// Запомнить сочетание. Негодное не берём: без клавиши остаться можно,
    /// а вот тихо получить чужую — нельзя.
    pub fn setAreaKey(self: *Settings, text: []const u8) bool {
        const clean = std.mem.trim(u8, text, " \t");
        _ = hotkey.parse(clean) catch return false;
        const n = @min(clean.len, self.area_key.len);
        @memcpy(self.area_key[0..n], clean[0..n]);
        self.area_key_len = n;
        return true;
    }

    pub fn dir(self: *const Settings) []const u8 {
        return self.out_dir[0..self.out_dir_len];
    }

    pub fn setDir(self: *Settings, path: []const u8) void {
        const n = @min(path.len, self.out_dir.len);
        @memcpy(self.out_dir[0..n], path[0..n]);
        self.out_dir_len = n;
    }

    pub fn nameTemplate(self: *const Settings) []const u8 {
        return self.template[0..self.template_len];
    }

    pub fn setTemplate(self: *Settings, text: []const u8) void {
        // Пустой шаблон дал бы файл без имени. Молча подставляем обычный:
        // это не та ошибка, из-за которой стоит отказываться сохранять.
        const use = if (text.len == 0) default_template else text;
        const n = @min(use.len, self.template.len);
        @memcpy(self.template[0..n], use[0..n]);
        self.template_len = n;
    }

    /// Высота кадра из строки. Негодное число не берём: подправленный
    /// руками файл не должен схлопнуть окно.
    pub fn setPreviewH(self: *Settings, text: []const u8) bool {
        const value = std.fmt.parseInt(i32, std.mem.trim(u8, text, " \t"), 10) catch return false;
        if (value < min_preview_h or value > max_preview_h) return false;
        self.preview_h = value;
        return true;
    }

    /// Порт из строки. Ноль и слишком малые числа не берём: порты ниже
    /// тысячи заняты системой и требуют прав.
    pub fn setPort(self: *Settings, text: []const u8) bool {
        const value = std.fmt.parseInt(u32, std.mem.trim(u8, text, " \t"), 10) catch return false;
        if (value < 1024 or value > 65535) return false;
        self.port = @intCast(value);
        return true;
    }
};

pub const Error = error{
    /// Это не файл настроек.
    NotSettings,
    /// Файл от более новой версии.
    TooNew,
};

pub fn write(s: *const Settings, w: *std.Io.Writer) !void {
    try w.print("{s} {d}\n", .{ magic, version });
    try w.print("dir {s}\n", .{s.dir()});
    try w.print("template {s}\n", .{s.nameTemplate()});
    try w.print("areakey {s}\n", .{s.areaKey()});
    try w.print("preview {d}\n", .{s.preview_h});
    try w.print("port {d}\n", .{s.port});
    try w.print("serve {d}\n", .{@intFromBool(s.serve_at_start)});
}

/// Прочитать настройки из текста.
///
/// Незнакомая строка пропускается, испорченное значение заменяется
/// разумным по умолчанию. Настройки — не тот случай, когда стоит отказаться
/// запускаться: человек останется без программы из-за опечатки в строке.
pub fn read(data: []const u8) Error!Settings {
    var lines = std.mem.splitScalar(u8, data, '\n');
    const head = trim(lines.next() orelse return Error.NotSettings);
    var head_parts = std.mem.splitScalar(u8, head, ' ');
    const name = head_parts.next() orelse return Error.NotSettings;
    if (!std.mem.eql(u8, name, magic)) return Error.NotSettings;
    const got = std.fmt.parseInt(u32, head_parts.next() orelse "0", 10) catch 0;
    if (got > version) return Error.TooNew;

    var out = Settings.init();
    while (lines.next()) |raw| {
        const text = trim(raw);
        if (text.len == 0) continue;
        var parts = std.mem.splitScalar(u8, text, ' ');
        const word = parts.next() orelse continue;
        const rest = parts.rest();

        if (std.mem.eql(u8, word, "dir")) {
            out.setDir(rest);
        } else if (std.mem.eql(u8, word, "template")) {
            out.setTemplate(rest);
        } else if (std.mem.eql(u8, word, "areakey")) {
            _ = out.setAreaKey(rest);
        } else if (std.mem.eql(u8, word, "preview")) {
            _ = out.setPreviewH(rest);
        } else if (std.mem.eql(u8, word, "port")) {
            _ = out.setPort(rest);
        } else if (std.mem.eql(u8, word, "serve")) {
            out.serve_at_start = !std.mem.eql(u8, rest, "0") and rest.len > 0;
        }
    }
    return out;
}

fn trim(text: []const u8) []const u8 {
    var out = text;
    while (out.len > 0 and (out[out.len - 1] == '\r' or out[out.len - 1] == ' ')) out.len -= 1;
    return out;
}

/// Лежит ли файл настроек в этой папке.
///
/// Нужна не из любопытства: прежние выпуски клали настройки в папку записей,
/// и при переезде надо отличить «настроек тут нет» от «настройки по
/// умолчанию». `load` этого не различает — он в обоих случаях отдаёт
/// умолчания.
pub fn present(dir_path: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    var path_buf: [max_path * 2]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ dir_path, file_name }) catch return false;
    var wide: [std.fs.max_path_bytes]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, path) catch return false;
    if (n >= wide.len) return false;
    wide[n] = 0;
    return c.GetFileAttributesW(@ptrCast(&wide)) != c.INVALID_FILE_ATTRIBUTES;
}

/// Прочитать настройки с диска. Нет файла — вернём умолчания: первый запуск
/// не должен ничем отличаться от обычного.
pub fn load(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) Settings {
    var path_buf: [max_path * 2]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ dir_path, file_name }) catch
        return Settings.init();

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 16)) catch
        return Settings.init();
    defer allocator.free(data);

    return read(data) catch Settings.init();
}

/// Записать настройки на диск. Возвращает, получилось ли.
pub fn save(s: *const Settings, dir_path: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    var path_buf: [max_path * 2]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ dir_path, file_name }) catch return false;

    var text: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&text);
    write(s, &w) catch return false;
    const bytes = w.buffered();

    var wide: [std.fs.max_path_bytes]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, path) catch return false;
    wide[n] = 0;

    const handle = c.CreateFileW(
        @ptrCast(&wide),
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

// ---------------------------------------------------------------- тесты

test "записанное читается обратно" {
    var s = Settings.init();
    s.setDir("D:\\Мои записи");
    s.setTemplate("экран-%d-%n.mp4");
    s.port = 15600;
    s.preview_h = 333;
    _ = s.setAreaKey("Ctrl+Alt+F8");
    s.serve_at_start = true;

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(&s, &w);

    const back = try read(w.buffered());
    try std.testing.expectEqualStrings("D:\\Мои записи", back.dir());
    try std.testing.expectEqualStrings("экран-%d-%n.mp4", back.nameTemplate());
    try std.testing.expectEqual(@as(u16, 15600), back.port);
    try std.testing.expectEqual(@as(i32, 333), back.preview_h);
    try std.testing.expectEqualStrings("Ctrl+Alt+F8", back.areaKey());
    try std.testing.expect(back.serve_at_start);
}

test "путь с пробелами цел" {
    var s = Settings.init();
    s.setDir("C:\\Users\\Юрий\\Мои видео\\записи экрана");
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(&s, &w);
    const back = try read(w.buffered());
    try std.testing.expectEqualStrings("C:\\Users\\Юрий\\Мои видео\\записи экрана", back.dir());
}

test "пустой шаблон заменяется обычным, а не оставляет файл без имени" {
    var s = Settings.init();
    s.setTemplate("");
    try std.testing.expectEqualStrings(Settings.default_template, s.nameTemplate());
}

test "порт: берём только годный" {
    var s = Settings.init();
    try std.testing.expect(s.setPort("15600"));
    try std.testing.expectEqual(@as(u16, 15600), s.port);

    // Системные порты и мусор не берём, прежнее значение остаётся.
    try std.testing.expect(!s.setPort("80"));
    try std.testing.expect(!s.setPort("0"));
    try std.testing.expect(!s.setPort("99999"));
    try std.testing.expect(!s.setPort("порт"));
    try std.testing.expectEqual(@as(u16, 15600), s.port);
}

test "испорченное значение не мешает прочитать остальное" {
    // Настройки — не тот случай, когда стоит отказаться запускаться:
    // человек останется без программы из-за одной опечатки.
    const back = try read(
        \\zigrec-settings 1
        \\dir D:\видео
        \\port совсем не число
        \\template моё-%d.mp4
        \\неизвестная строка 42
        \\
    );
    try std.testing.expectEqualStrings("D:\\видео", back.dir());
    try std.testing.expectEqualStrings("моё-%d.mp4", back.nameTemplate());
    // Порт остался умолчанием, а не превратился в ноль.
    try std.testing.expectEqual(@as(u16, 15599), back.port);
}

test "чужой файл узнаётся, файл из будущего отклоняется" {
    try std.testing.expectError(Error.NotSettings, read("просто текст"));
    try std.testing.expectError(Error.NotSettings, read(""));
    try std.testing.expectError(Error.TooNew, read("zigrec-settings 99\n"));
}

test "переводы строк Windows не мешают" {
    const back = try read("zigrec-settings 1\r\ndir D:\\а\r\nserve 1\r\n");
    try std.testing.expectEqualStrings("D:\\а", back.dir());
    try std.testing.expect(back.serve_at_start);
}

test "умолчания разумны сами по себе" {
    const s = Settings.init();
    try std.testing.expectEqualStrings(Settings.default_template, s.nameTemplate());
    try std.testing.expectEqual(@as(u16, 15599), s.port);
    try std.testing.expect(!s.serve_at_start);
    // Пустая папка означает «как было»: первый запуск ничем не отличается.
    try std.testing.expectEqual(@as(usize, 0), s.dir().len);
}

test "высота кадра: негодное число не схлопывает окно" {
    var s = Settings.init();
    try std.testing.expect(s.setPreviewH("400"));
    try std.testing.expectEqual(@as(i32, 400), s.preview_h);

    // Правленый руками файл может содержать что угодно.
    try std.testing.expect(!s.setPreviewH("0"));
    try std.testing.expect(!s.setPreviewH("-100"));
    try std.testing.expect(!s.setPreviewH("99999"));
    try std.testing.expect(!s.setPreviewH("высоко"));
    try std.testing.expectEqual(@as(i32, 400), s.preview_h);
}

test "сочетание: годное берём, негодное не портит прежнее" {
    var s = Settings.init();
    try std.testing.expectEqualStrings(hotkey.default_text, s.areaKey());

    try std.testing.expect(s.setAreaKey("Ctrl+Shift+R"));
    try std.testing.expectEqualStrings("Ctrl+Shift+R", s.areaKey());

    // Голая буква перехватывала бы ввод во всех программах, а «Win+Щ»
    // просто не существует. Прежнее сочетание при этом остаётся.
    try std.testing.expect(!s.setAreaKey("R"));
    try std.testing.expect(!s.setAreaKey("Win+Щ"));
    try std.testing.expect(!s.setAreaKey(""));
    try std.testing.expectEqualStrings("Ctrl+Shift+R", s.areaKey());
}

test "файл без строки о сочетании даёт сочетание по умолчанию" {
    // Настройки от прежнего выпуска: строки нет, но клавиша должна работать.
    const back = try read("zigrec-settings 1\r\nport 15599\r\n");
    try std.testing.expectEqualStrings(hotkey.default_text, back.areaKey());
}
