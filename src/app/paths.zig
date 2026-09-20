//! Где программа хранит своё: настройки, историю, списки недавних.
//!
//! Задача #52. Есть два разумных ответа, и оба нужны разным людям.
//!
//!  * **Portable** — всё рядом с программой. Так носят на флешке и так
//!    ставят там, где чужие файлы в профиле нежелательны. После удаления
//!    папки от программы не остаётся ничего.
//!  * **Classic** — своё лежит в `~/.ZigRec`. Так удобнее на своей машине:
//!    программу можно переставить или обновить, а работа останется.
//!
//! **Способ хранения виден глазами.** Признак — обычный файл рядом
//! с программой, а не запись в реестре: человек имеет право знать, где
//! программа оставляет следы, и уметь это отменить, не запуская её.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;
const lang = @import("../lang.zig");

pub const Mode = enum {
    portable,
    classic,

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .portable => lang.t("Portable — рядом с программой"),
            .classic => lang.t("Classic — в профиле пользователя"),
        };
    }
};

/// Файл-признак рядом с программой. Есть — значит Portable.
///
/// Признак, а не строка в настройках: настройки сами лежат там, куда
/// указывает способ хранения, и искать их, не зная способа, негде.
pub const marker_name = "ZigRec.portable";

/// Имя папки в профиле пользователя. С точки впереди — как принято
/// у того, что человеку обычно не нужно видеть каждый день.
pub const classic_dir_name = ".ZigRec";

pub const max_path = 512;

/// Где лежит своё при таком способе хранения.
///
/// Чистый счёт: обе части приходят готовыми, и правило проверяется тестом
/// без диска и без Windows.
pub fn baseFor(buf: []u8, mode: Mode, exe_dir: []const u8, home: []const u8) ![]const u8 {
    return switch (mode) {
        .portable => std.fmt.bufPrint(buf, "{s}", .{exe_dir}),
        .classic => std.fmt.bufPrint(buf, "{s}\\{s}", .{ home, classic_dir_name }),
    };
}

/// Путь к файлу-признаку.
pub fn markerPath(buf: []u8, exe_dir: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}\\{s}", .{ exe_dir, marker_name });
}

/// Способ хранения по наличию признака.
pub fn modeFor(marker_present: bool) Mode {
    return if (marker_present) .portable else .classic;
}

// ------------------------------------------------------------- Windows

/// Папка, в которой лежит сама программа.
pub fn exeDir(buf: []u8) ![]const u8 {
    if (builtin.os.tag != .windows) return error.Unsupported;
    var wide_buf: [max_path]u16 = undefined;
    const n = c.GetModuleFileNameW(null, &wide_buf, wide_buf.len);
    if (n == 0 or n >= wide_buf.len) return error.NoPath;
    const len = try std.unicode.utf16LeToUtf8(buf, wide_buf[0..n]);
    const dir = std.fs.path.dirname(buf[0..len]) orelse return error.NoPath;
    return buf[0..dir.len];
}

/// Профиль пользователя.
pub fn homeDir(buf: []u8) ![]const u8 {
    if (builtin.os.tag != .windows) return error.Unsupported;
    var wide_buf: [max_path]u16 = undefined;
    const n = c.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("USERPROFILE"), &wide_buf, wide_buf.len);
    if (n == 0 or n >= wide_buf.len) return error.NoPath;
    const len = try std.unicode.utf16LeToUtf8(buf, wide_buf[0..n]);
    return buf[0..len];
}

fn exists(path: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    var wide_buf: [max_path]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide_buf, path) catch return false;
    if (n >= wide_buf.len) return false;
    wide_buf[n] = 0;
    return c.GetFileAttributesW(@ptrCast(&wide_buf)) != c.INVALID_FILE_ATTRIBUTES;
}

/// Какой способ хранения выбран прямо сейчас.
pub fn currentMode() Mode {
    var exe_buf: [max_path]u8 = undefined;
    const dir = exeDir(&exe_buf) catch return .classic;
    var marker_buf: [max_path]u8 = undefined;
    const marker = markerPath(&marker_buf, dir) catch return .classic;
    return modeFor(exists(marker));
}

/// Где лежит своё прямо сейчас. Папку заодно создаём: писать в неё
/// начнут в ту же секунду.
pub fn base(buf: []u8) ![]const u8 {
    const mode = currentMode();
    var exe_buf: [max_path]u8 = undefined;
    var home_buf: [max_path]u8 = undefined;
    const exe = exeDir(&exe_buf) catch "";
    const home = homeDir(&home_buf) catch "";
    if (mode == .classic and home.len == 0) return error.NoPath;

    const out = try baseFor(buf, mode, exe, home);
    ensureDir(out);
    return out;
}

/// Создать папку, если её ещё нет.
pub fn ensureDir(path: []const u8) void {
    if (builtin.os.tag != .windows or path.len == 0) return;
    var wide_buf: [max_path]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide_buf, path) catch return;
    if (n >= wide_buf.len) return;
    wide_buf[n] = 0;
    _ = c.CreateDirectoryW(@ptrCast(&wide_buf), null);
}

/// Переключить способ хранения. Возвращает, получилось ли.
///
/// Создаём или убираем файл-признак. Настройки при этом НЕ переносим:
/// перенос чужих файлов без спроса — не то, чего ждут от галочки.
/// Программа просто начнёт читать и писать в новом месте.
pub fn setMode(mode: Mode) bool {
    if (builtin.os.tag != .windows) return false;
    var exe_buf: [max_path]u8 = undefined;
    const dir = exeDir(&exe_buf) catch return false;
    var marker_buf: [max_path]u8 = undefined;
    const marker = markerPath(&marker_buf, dir) catch return false;

    var wide_buf: [max_path]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide_buf, marker) catch return false;
    if (n >= wide_buf.len) return false;
    wide_buf[n] = 0;

    switch (mode) {
        .portable => {
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
            // Не пустой файл: человек, нашедший его в папке, должен понять,
            // что это и можно ли это убрать.
            const note =
                "Этот файл говорит Zig-Rec Studio хранить настройки, историю\r\n" ++
                "и списки недавних файлов рядом с программой, а не в профиле.\r\n" ++
                "Уберите его — и программа вернётся к папке ~/.ZigRec.\r\n";
            var written: c.DWORD = 0;
            return c.WriteFile(handle, note.ptr, @intCast(note.len), &written, null) != 0;
        },
        .classic => {
            if (!exists(marker)) return true;
            return c.DeleteFileW(@ptrCast(&wide_buf)) != 0;
        },
    }
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;

test "где лежит своё при каждом способе хранения" {
    var buf: [max_path]u8 = undefined;
    try testing.expectEqualStrings(
        "D:\\Программы\\ZigRec",
        try baseFor(&buf, .portable, "D:\\Программы\\ZigRec", "C:\\Users\\Юрий"),
    );
    try testing.expectEqualStrings(
        "C:\\Users\\Юрий\\.ZigRec",
        try baseFor(&buf, .classic, "D:\\Программы\\ZigRec", "C:\\Users\\Юрий"),
    );
}

test "признак рядом с программой решает, какой это способ" {
    try testing.expectEqual(Mode.portable, modeFor(true));
    try testing.expectEqual(Mode.classic, modeFor(false));
}

test "путь к признаку собирается рядом с программой" {
    var buf: [max_path]u8 = undefined;
    try testing.expectEqualStrings(
        "D:\\ZigRec\\" ++ marker_name,
        try markerPath(&buf, "D:\\ZigRec"),
    );
}

test "короткий буфер не режет путь молча" {
    // Обрезанный путь указывал бы в чужое место, и программа писала бы
    // своё туда, куда её не просили.
    var small: [8]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, baseFor(&small, .classic, "D:\\A", "C:\\Users\\Юрий"));
}

test "оба способа дают разные места" {
    // Иначе переключение ничего не меняло бы, а человек думал бы, что меняет.
    var a: [max_path]u8 = undefined;
    var b: [max_path]u8 = undefined;
    const portable = try baseFor(&a, .portable, "D:\\ZigRec", "C:\\Users\\Ю");
    const classic = try baseFor(&b, .classic, "D:\\ZigRec", "C:\\Users\\Ю");
    try testing.expect(!std.mem.eql(u8, portable, classic));
}
