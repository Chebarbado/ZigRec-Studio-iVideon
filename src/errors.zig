//! Ошибки словами, одинаково для окна и для командной строки.
//!
//! Требование цели: ошибка объясняется словами, а не кодом. Текст один на обе
//! формы — иначе они начнут расходиться, и человек, прочитавший объяснение в
//! окне, не найдёт его в консоли.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32.zig");
const lang = @import("lang.zig");
const c = win32.c;

/// Чем закончилась запись. Отсюда берётся код возврата командной строки.
pub const Outcome = enum {
    /// Файл записан, потерь нет.
    recorded,
    /// Файл записан, но часть кадров система показала мимо нас.
    recorded_with_drops,
    /// Файла нет.
    failed,
    /// Неверные ключи или их сочетание.
    bad_usage,

    pub fn exitCode(self: Outcome) u8 {
        return switch (self) {
            .recorded => 0,
            .failed => 1,
            .bad_usage => 2,
            .recorded_with_drops => 3,
        };
    }

    pub fn label(self: Outcome) []const u8 {
        return switch (self) {
            .recorded => "записан",
            .recorded_with_drops => "записан с пропусками",
            .failed => "не записан",
            .bad_usage => "неверные ключи",
        };
    }
};

/// Объяснение ошибки словами, на языке окон (#100). Возвращает предложение,
/// а не имя ошибки.
pub fn explain(err: anyerror) []const u8 {
    return switch (err) {
        error.AccessDenied => lang.t(
            \\захват экрана запрещён системой: открыт экран блокировки, окно
            \\с правами администратора или выход уже занят другой программой.
        ),
        error.NoDevice => lang.t(
            \\не создаётся устройство Direct3D: нет видеоадаптера или драйвера.
        ),
        error.NoOutput => lang.t(
            \\нет монитора с таким номером. Посмотреть список: zigrec monitors
        ),
        error.Lost => lang.t(
            \\захват экрана потерян и не восстановился: сменилось разрешение
            \\или другая программа заняла экран монопольно.
        ),
        error.Unsupported => lang.t(
            \\запись работает только в Windows.
        ),
        error.WindowNotFound => lang.t(
            \\окно с таким заголовком не найдено. Посмотреть список: zigrec windows
        ),
        error.WindowMinimized => lang.t(
            \\окно свёрнуто, снимать нечего. Разверните его и повторите.
        ),
        error.StartupFailed => lang.t(
            \\не поднимается Media Foundation: в системе нет кодировщика H.264.
        ),
        error.CreateFailed => lang.t(
            \\не получается создать файл: путь недоступен или файл занят другой
            \\программой. Закройте плеер, который его открыл, или выберите другое имя.
        ),
        error.FileBusy => lang.t(
            \\файл занят другой программой: он открыт в плеере или в проводнике.
            \\Закройте его или выберите другое имя.
        ),
        error.FormatRejected => lang.t(
            \\кодировщик не принял размер кадра: стороны должны быть чётными
            \\и не больше того, что умеет видеокарта.
        ),
        error.WriteFailed => lang.t(
            \\сбой при записи кадра: закончилось место на диске или отвалился кодировщик.
        ),
        error.FinalizeFailed => lang.t(
            \\файл не закрылся как надо и остался недоигранным.
        ),
        error.OutOfMemory => lang.t(
            \\не хватило памяти под кадр.
        ),
        error.NoMicrophone => lang.t(
            \\микрофон не найден: он отключён, не подключён или не выбран
            \\устройством записи по умолчанию. Проверьте «Параметры звука — Ввод».
        ),
        error.MicAccessDenied => lang.t(
            \\Windows не пускает к микрофону: доступ запрещён в настройках
            \\приватности. «Параметры — Конфиденциальность — Микрофон».
        ),
        error.MicBadFormat => lang.t(
            \\микрофон отдаёт формат, который мы не понимаем.
        ),
        error.NoSpeakers => lang.t(
            \\устройства вывода нет: системный звук брать неоткуда. Проверьте
            \\«Параметры звука — Вывод».
        ),
        error.AlreadyRecording => lang.t(
            \\запись уже идёт.
        ),
        error.PathTooLong => lang.t(
            \\слишком длинный путь к файлу.
        ),
        else => lang.t("неожиданный сбой"),
    };
}

/// Короткое объяснение в одну строку — для мест, где нет места на абзац:
/// строка состояния, панель осциллографа, подсказка в трее.
pub fn short(err: anyerror) []const u8 {
    return switch (err) {
        error.NoMicrophone => lang.t("микрофон не найден или отключён"),
        error.MicAccessDenied => lang.t("доступ к микрофону запрещён в настройках"),
        error.MicBadFormat => lang.t("непонятный формат микрофона"),
        error.NoSpeakers => lang.t("нет устройства вывода: системный звук брать неоткуда"),
        error.AccessDenied => lang.t("захват экрана запрещён системой"),
        error.NoDevice => lang.t("нет устройства Direct3D"),
        error.NoOutput => lang.t("нет такого монитора"),
        error.Lost => lang.t("захват потерян"),
        error.FileBusy => lang.t("файл занят другой программой"),
        error.CreateFailed => lang.t("файл не создаётся"),
        error.StartupFailed => lang.t("нет кодировщика H.264"),
        error.WriteFailed => lang.t("сбой записи кадра"),
        error.FinalizeFailed => lang.t("файл не закрылся как надо"),
        error.Unsupported => lang.t("только для Windows"),
        else => lang.t("сбой"),
    };
}

pub const CheckError = error{
    /// Файл занят другой программой.
    FileBusy,
    /// Каталога нет или в него нельзя писать.
    CreateFailed,
};

/// Проверить, что файл можно создать, ДО того как поднимать захват и кодировщик.
///
/// Иначе человек нажимает «Записать», ждёт, и только в конце узнаёт, что файл
/// был занят плеером. Проверка стоит один вызов Windows.
pub fn ensureWritable(path: []const u8) CheckError!void {
    if (builtin.os.tag != .windows) return;
    var wide: [std.fs.max_path_bytes]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, path) catch return CheckError.CreateFailed;
    wide[n] = 0;
    const handle = c.CreateFileW(
        @ptrCast(&wide),
        c.GENERIC_WRITE,
        0, // никому не даём доступ: так же откроет и кодировщик
        null,
        c.CREATE_ALWAYS,
        c.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == c.INVALID_HANDLE_VALUE) {
        return switch (c.GetLastError()) {
            c.ERROR_SHARING_VIOLATION, c.ERROR_ACCESS_DENIED, c.ERROR_LOCK_VIOLATION => CheckError.FileBusy,
            else => CheckError.CreateFailed,
        };
    }
    _ = c.CloseHandle(handle);
}

/// Удалить файл, если он пуст. Нужен после `ensureWritable`: та создаёт файл,
/// и не начавшаяся запись оставила бы в папке пустой mp4, который выглядит
/// как испорченная запись.
pub fn removeIfEmpty(path: []const u8) void {
    if (builtin.os.tag != .windows) return;
    var wide: [std.fs.max_path_bytes]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, path) catch return;
    wide[n] = 0;
    var data: c.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    if (c.GetFileAttributesExW(@ptrCast(&wide), c.GetFileExInfoStandard, &data) == 0) return;
    if (data.nFileSizeHigh != 0 or data.nFileSizeLow != 0) return;
    _ = c.DeleteFileW(@ptrCast(&wide));
}

// ---------------------------------------------------------------- тесты

test "коды возврата различают три исхода" {
    try std.testing.expectEqual(@as(u8, 0), Outcome.recorded.exitCode());
    try std.testing.expectEqual(@as(u8, 3), Outcome.recorded_with_drops.exitCode());
    try std.testing.expectEqual(@as(u8, 1), Outcome.failed.exitCode());
    try std.testing.expectEqual(@as(u8, 2), Outcome.bad_usage.exitCode());
}

test "у каждого исхода своя подпись" {
    var seen: [4][]const u8 = undefined;
    for ([_]Outcome{ .recorded, .recorded_with_drops, .failed, .bad_usage }, 0..) |o, i| {
        seen[i] = o.label();
        try std.testing.expect(seen[i].len > 0);
    }
    try std.testing.expect(!std.mem.eql(u8, seen[0], seen[1]));
}

test "ошибки объясняются предложением, а не именем" {
    for ([_]anyerror{
        error.AccessDenied,
        error.NoDevice,
        error.FileBusy,
        error.WindowNotFound,
        error.StartupFailed,
    }) |e| {
        const text = explain(e);
        try std.testing.expect(text.len > 20);
        // В объяснении не должно быть латинского имени ошибки.
        try std.testing.expect(std.mem.indexOf(u8, text, @errorName(e)) == null);
    }
}

test "неизвестная ошибка тоже объясняется" {
    try std.testing.expect(explain(error.SomethingOdd).len > 0);
}

test "короткое объяснение помещается в строку" {
    for ([_]anyerror{
        error.NoMicrophone,
        error.MicAccessDenied,
        error.AccessDenied,
        error.FileBusy,
        error.SomethingOdd,
    }) |e| {
        const text = short(e);
        try std.testing.expect(text.len > 0);
        // Для панели и строки состояния: одна короткая строка, без переносов.
        // Считаем буквы, а не байты: в UTF-8 русская буква занимает два байта,
        // и ограничение в байтах молча запретило бы вдвое более короткий текст.
        const letters = try std.unicode.utf8CountCodepoints(text);
        try std.testing.expect(letters <= 44);
        try std.testing.expect(std.mem.indexOfScalar(u8, text, '\n') == null);
    }
}

test "короткое и полное объяснение — про одно и то же" {
    // Оба должны существовать и различаться длиной: длинное объясняет, короткое называет.
    try std.testing.expect(short(error.NoMicrophone).len < explain(error.NoMicrophone).len);
}

test "на английском короткое объяснение тоже помещается в строку" {
    // Место под короткое объяснение одно на оба языка (#100).
    lang.set(.en);
    defer lang.set(.ru);
    for ([_]anyerror{
        error.NoMicrophone,
        error.MicAccessDenied,
        error.NoSpeakers,
        error.AccessDenied,
        error.FileBusy,
        error.FinalizeFailed,
        error.SomethingOdd,
    }) |e| {
        const text = short(e);
        try std.testing.expect(text.len > 0);
        try std.testing.expect(try std.unicode.utf8CountCodepoints(text) <= 44);
        try std.testing.expect(std.mem.indexOfScalar(u8, text, '\n') == null);
        // И объяснение остаётся предложением, а не именем ошибки.
        try std.testing.expect(std.mem.indexOf(u8, explain(e), @errorName(e)) == null);
    }
    try std.testing.expect(!std.mem.eql(u8, short(error.FileBusy), "файл занят другой программой"));
}
