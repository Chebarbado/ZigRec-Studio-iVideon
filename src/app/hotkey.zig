//! Сочетание клавиш: разбор, запись словами, перевод в числа Windows.
//!
//! Задача #56. Человек пишет сочетание строкой — «Win+Shift+Z», — и эта
//! строка лежит в настройках, где её видно и можно поправить руками.
//! Всё превращение строки в числа — чистый счёт, и потому целиком
//! проверяется тестами: ошибка здесь означает, что клавиша не работает
//! или работает не та, а понять это можно только на живой машине.
//!
//! Числа взяты из заголовков Windows и там же зафиксированы навсегда.
//! Держать их здесь, а не тащить сюда весь `windows.h`, значит оставить
//! разбор чистым; совпадение с настоящими значениями проверяется там,
//! где эти числа встречаются с Windows.
const std = @import("std");

/// Значения `MOD_*` из `RegisterHotKey`.
pub const mod_alt: u32 = 0x0001;
pub const mod_ctrl: u32 = 0x0002;
pub const mod_shift: u32 = 0x0004;
pub const mod_win: u32 = 0x0008;
/// Удержание клавиши не должно срабатывать раз за разом.
pub const mod_norepeat: u32 = 0x4000;

pub const max_text = 48;

pub const Error = error{
    /// В строке нет самой клавиши — одни модификаторы.
    NoKey,
    /// Такой клавиши мы не знаем.
    UnknownKey,
    /// Сочетание без модификаторов.
    ///
    /// Голая буква перехватывала бы ввод во всех программах сразу:
    /// нажать «З» в письме стало бы невозможно.
    NoModifier,
};

pub const Combo = struct {
    win: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    /// Код клавиши, как его понимает Windows.
    key: u8 = 0,

    /// Числа для `RegisterHotKey`.
    pub fn modifiers(self: Combo) u32 {
        var out: u32 = mod_norepeat;
        if (self.win) out |= mod_win;
        if (self.ctrl) out |= mod_ctrl;
        if (self.alt) out |= mod_alt;
        if (self.shift) out |= mod_shift;
        return out;
    }

    pub fn hasModifier(self: Combo) bool {
        return self.win or self.ctrl or self.alt or self.shift;
    }

    /// Записать словами — так же, как это пишут в настройках.
    pub fn write(self: Combo, buf: []u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        if (self.win) w.writeAll("Win+") catch return "";
        if (self.ctrl) w.writeAll("Ctrl+") catch return "";
        if (self.alt) w.writeAll("Alt+") catch return "";
        if (self.shift) w.writeAll("Shift+") catch return "";
        w.writeAll(keyName(self.key)) catch return "";
        return w.buffered();
    }
};

/// То, что стоит по умолчанию.
///
/// Win+Shift+Z: с Win — чтобы не спорить с сочетаниями внутри программ,
/// Z — потому что соседние Win+Shift+S уже занял системный снимок экрана,
/// и рука всё равно там.
pub const default_text = "Win+Shift+Z";

/// Разобрать строку вида «Win+Shift+Z».
///
/// Регистр и пробелы не важны: человек пишет как привык.
pub fn parse(text: []const u8) Error!Combo {
    var out = Combo{};
    var parts = std.mem.splitScalar(u8, text, '+');
    var saw_key = false;

    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len == 0) continue;

        if (eqAscii(part, "win")) {
            out.win = true;
        } else if (eqAscii(part, "ctrl") or eqAscii(part, "control")) {
            out.ctrl = true;
        } else if (eqAscii(part, "alt")) {
            out.alt = true;
        } else if (eqAscii(part, "shift")) {
            out.shift = true;
        } else {
            // Последняя не-модификаторная часть и есть клавиша. Если их
            // несколько, побеждает последняя: «Ctrl+A+B» — это Ctrl+B,
            // а не отказ разбирать настройки целиком.
            out.key = keyCode(part) orelse return Error.UnknownKey;
            saw_key = true;
        }
    }

    if (!saw_key) return Error.NoKey;
    if (!out.hasModifier()) return Error.NoModifier;
    return out;
}

fn eqAscii(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Именованные клавиши. Пишутся так, как их показывают человеку;
/// при разборе регистр не важен. Буквы и цифры разбираются отдельно —
/// их слишком много, чтобы перечислять.
const named = [_]struct { name: []const u8, code: u8 }{
    .{ .name = "Space", .code = 0x20 },
    .{ .name = "Enter", .code = 0x0D },
    .{ .name = "Tab", .code = 0x09 },
    .{ .name = "Esc", .code = 0x1B },
    .{ .name = "Backspace", .code = 0x08 },
    .{ .name = "Insert", .code = 0x2D },
    .{ .name = "Delete", .code = 0x2E },
    .{ .name = "Home", .code = 0x24 },
    .{ .name = "End", .code = 0x23 },
    .{ .name = "PgUp", .code = 0x21 },
    .{ .name = "PgDn", .code = 0x22 },
    .{ .name = "Left", .code = 0x25 },
    .{ .name = "Up", .code = 0x26 },
    .{ .name = "Right", .code = 0x27 },
    .{ .name = "Down", .code = 0x28 },
    .{ .name = "PrintScreen", .code = 0x2C },
};

/// Код клавиши по её имени.
pub fn keyCode(name: []const u8) ?u8 {
    if (name.len == 0) return null;

    // Одна буква или цифра: код совпадает с заглавной буквой.
    if (name.len == 1) {
        const ch = std.ascii.toUpper(name[0]);
        if (ch >= 'A' and ch <= 'Z') return ch;
        if (ch >= '0' and ch <= '9') return ch;
        return null;
    }

    // F1…F24.
    if ((name[0] == 'F' or name[0] == 'f') and name.len <= 3) {
        const number = std.fmt.parseInt(u8, name[1..], 10) catch return null;
        if (number >= 1 and number <= 24) return 0x70 + number - 1;
        return null;
    }

    for (named) |n| {
        if (eqAscii(name, n.name)) return n.code;
    }
    return null;
}

/// Имя клавиши по коду — чтобы показать сочетание человеку.
pub fn keyName(code: u8) []const u8 {
    if (code >= 'A' and code <= 'Z') return switch (code) {
        inline 'A'...'Z' => |ch| &[_]u8{ch},
        else => unreachable,
    };
    if (code >= '0' and code <= '9') return switch (code) {
        inline '0'...'9' => |ch| &[_]u8{ch},
        else => unreachable,
    };
    if (code >= 0x70 and code <= 0x87) return switch (code) {
        inline 0x70...0x87 => |vk| comptime blk: {
            var buf: [3]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "F{d}", .{vk - 0x70 + 1}) catch unreachable;
            const frozen = buf;
            break :blk frozen[0..text.len];
        },
        else => unreachable,
    };
    for (named) |n| {
        if (n.code == code) return n.name;
    }
    return "?";
}

/// Объяснение ошибки словами — для окна настроек.
pub fn explain(err: Error) []const u8 {
    return switch (err) {
        Error.NoKey => "не хватает самой клавиши: например, Win+Shift+Z",
        Error.UnknownKey => "такой клавиши нет: годятся буквы, цифры, F1…F24 и Space, Esc, Home",
        Error.NoModifier => "нужен хотя бы Win, Ctrl, Alt или Shift: иначе клавиша пропадёт во всех программах",
    };
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;

test "сочетание по умолчанию разбирается" {
    const combo = try parse(default_text);
    try testing.expect(combo.win);
    try testing.expect(combo.shift);
    try testing.expect(!combo.ctrl);
    try testing.expect(!combo.alt);
    try testing.expectEqual(@as(u8, 'Z'), combo.key);
}

test "записанное словами читается обратно тем же" {
    for ([_][]const u8{
        "Win+Shift+Z",
        "Ctrl+Alt+F9",
        "Alt+Space",
        "Ctrl+Shift+Delete",
        "Win+1",
        "Ctrl+F12",
    }) |text| {
        const combo = try parse(text);
        var buf: [max_text]u8 = undefined;
        try testing.expectEqualStrings(text, combo.write(&buf));
    }
}

test "регистр и пробелы не мешают" {
    // Человек пишет как привык, а не как удобно разбору.
    const a = try parse("win+shift+z");
    const b = try parse("WIN + SHIFT + Z");
    const c = try parse("Win+Shift+Z");
    try testing.expectEqual(a, b);
    try testing.expectEqual(b, c);
}

test "числа для Windows складываются из тех же модификаторов" {
    const combo = try parse("Win+Shift+Z");
    const bits = combo.modifiers();
    try testing.expect(bits & mod_win != 0);
    try testing.expect(bits & mod_shift != 0);
    try testing.expect(bits & mod_ctrl == 0);
    try testing.expect(bits & mod_alt == 0);
    // Удержание не должно сыпать нажатиями: запись началась бы и тут же
    // остановилась.
    try testing.expect(bits & mod_norepeat != 0);
}

test "сочетание без модификатора не принимается" {
    // Голая буква перехватывала бы ввод во всех программах сразу.
    try testing.expectError(Error.NoModifier, parse("Z"));
    try testing.expectError(Error.NoModifier, parse("F9"));
}

test "пустое и бессмысленное отвергается словами, а не молча" {
    try testing.expectError(Error.NoKey, parse("Win+Shift"));
    try testing.expectError(Error.NoKey, parse(""));
    try testing.expectError(Error.UnknownKey, parse("Win+Щ"));
    try testing.expectError(Error.UnknownKey, parse("Ctrl+F99"));
    try testing.expectError(Error.UnknownKey, parse("Alt+никакая"));

    // И объяснение есть у каждой ошибки.
    for ([_]Error{ Error.NoKey, Error.UnknownKey, Error.NoModifier }) |e| {
        try testing.expect(explain(e).len > 0);
    }
}

test "имена клавиш и их коды сходятся в обе стороны" {
    for ([_][]const u8{ "A", "Z", "0", "9", "F1", "F12", "F24", "space", "delete", "home", "pgdn" }) |name| {
        const code = keyCode(name).?;
        const back = keyName(code);
        try testing.expect(keyCode(back).? == code);
    }
}

test "буквы и цифры дают коды, какие ждёт Windows" {
    // Коды букв совпадают с заглавными, цифр — с самими цифрами,
    // F1 начинается с 0x70. Это зафиксировано в Windows навсегда.
    try testing.expectEqual(@as(u8, 0x41), keyCode("a").?);
    try testing.expectEqual(@as(u8, 0x5A), keyCode("Z").?);
    try testing.expectEqual(@as(u8, 0x31), keyCode("1").?);
    try testing.expectEqual(@as(u8, 0x70), keyCode("F1").?);
    try testing.expectEqual(@as(u8, 0x7B), keyCode("F12").?);
}

test "неизвестный код показывается вопросом, а не мусором" {
    try testing.expectEqualStrings("?", keyName(0));
    try testing.expectEqualStrings("?", keyName(0xFF));
}
