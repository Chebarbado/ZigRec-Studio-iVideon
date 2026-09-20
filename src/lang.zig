//! Язык окон: русский и английский (#100).
//!
//! Программа написана по-русски — строки лежат прямо в коде, там, где они
//! нужны, и это удобно: читаешь окно и видишь, что в нём написано. Второй
//! язык этого не ломает. Русская строка остаётся на месте и служит ключом:
//! `lang.t("Пауза")` отдаёт её саму или перевод из таблицы.
//!
//! **Перевода нет — программа не собирается.** Ключ ищется во время
//! компиляции, и строка с русскими буквами без пары в таблице — ошибка
//! сборки с текстом этой строки. Иначе непереведённое всплывало бы по одному,
//! в самых дальних углах окон, и находил бы его не тот, кто может поправить.
//! Строка без русских букв («F9», «…», «MP4») перевода не требует.
//!
//! **Язык — один на процесс.** Его читают все окна и потоки, а ставит тот,
//! кто прочёл настройки, один раз при запуске. Смена в настройках действует
//! со следующего запуска: окна собраны, и переписывать подписи на ходу
//! значило бы держать по ссылке на каждую.
//!
//! **Командная строка и самопроверки остаются русскими**: `check.cmd` читает
//! их вывод, а самопроверкам второй язык ни к чему. Переводятся окна и то,
//! что окно показывает человеку.
const std = @import("std");

const en_app = @import("lang/en_app.zig");
const en_edit = @import("lang/en_edit.zig");

pub const Language = enum(u8) {
    /// Ноль — русский: настройки по умолчанию остаются нулевыми.
    ru = 0,
    en = 1,

    /// Как язык пишется в файле настроек и в ключе `--lang`.
    pub fn code(self: Language) []const u8 {
        return switch (self) {
            .ru => "ru",
            .en => "en",
        };
    }

    /// Незнакомое слово — русский: так было до появления выбора.
    pub fn parse(text: []const u8) Language {
        return if (std.ascii.eqlIgnoreCase(text, "en")) .en else .ru;
    }
};

var current: std.atomic.Value(u8) = .init(@intFromEnum(Language.ru));

pub fn set(l: Language) void {
    current.store(@intFromEnum(l), .release);
}

pub fn get() Language {
    return @enumFromInt(current.load(.acquire));
}

/// Язык назван ключом `--lang`: он сильнее настроек. Нужен самопроверкам —
/// раскладку окон меряют на обоих языках, какой бы ни стоял у владельца.
var forced: std.atomic.Value(bool) = .init(false);

pub fn force(l: Language) void {
    set(l);
    forced.store(true, .release);
}

/// Принять язык из настроек — если его не назвали ключом.
pub fn adopt(from_settings: Language) void {
    if (!forced.load(.acquire)) set(from_settings);
}

pub const Pair = @import("lang/pair.zig").Pair;

/// Все таблицы подряд. Их несколько, чтобы каждая лежала рядом по смыслу
/// со своими окнами; одна и та же строка может встретиться в обеих —
/// лишь бы перевод совпадал (проверяет тест).
const all_pairs = en_app.pairs ++ en_edit.pairs;

const map = std.StaticStringMap([]const u8).initComptime(all_pairs);

fn hasCyrillic(comptime s: []const u8) bool {
    @setEvalBranchQuota(100_000);
    // Кириллица в UTF-8 — первый байт 0xD0 или 0xD1.
    for (s) |b| if (b == 0xD0 or b == 0xD1) return true;
    return false;
}

/// Перевод во время компиляции. Нет пары — ошибка сборки.
fn enOf(comptime ru: []const u8) []const u8 {
    @setEvalBranchQuota(1_000_000);
    if (!hasCyrillic(ru)) return ru;
    return map.get(ru) orelse @compileError("нет перевода на английский: \"" ++ ru ++ "\" — добавьте пару в src/lang/en_*.zig");
}

/// Строка на текущем языке.
pub fn t(comptime ru: []const u8) []const u8 {
    const en = comptime enOf(ru);
    return if (get() == .en) en else ru;
}

/// То же в UTF-16 — для вызовов Windows, которым нужен готовый текст.
pub fn tw(comptime ru: []const u8) [:0]const u16 {
    const en = comptime enOf(ru);
    const ru_w = comptime std.unicode.utf8ToUtf16LeStringLiteral(ru);
    const en_w = comptime std.unicode.utf8ToUtf16LeStringLiteral(en);
    return if (get() == .en) en_w else ru_w;
}

/// `std.fmt.bufPrint` на текущем языке. Перевод обязан брать те же
/// аргументы в том же порядке — иначе не соберётся.
pub fn print(buf: []u8, comptime ru: []const u8, args: anytype) std.fmt.BufPrintError![]u8 {
    const en = comptime enOf(ru);
    return if (get() == .en) std.fmt.bufPrint(buf, en, args) else std.fmt.bufPrint(buf, ru, args);
}

/// То же для писателя (`w.print`).
pub fn write(w: *std.Io.Writer, comptime ru: []const u8, args: anytype) std.Io.Writer.Error!void {
    const en = comptime enOf(ru);
    return if (get() == .en) w.print(en, args) else w.print(ru, args);
}

/// Перевод строки, известной только на ходу: подписи из таблиц, названия
/// состояний. Нет пары — остаётся русская: таких мест единицы, и каждое
/// названо в тесте «строки из таблиц переведены».
pub fn tr(ru: []const u8) []const u8 {
    if (get() != .en) return ru;
    return map.get(ru) orelse ru;
}

// ---------------------------------------------------------------- тесты

test "по умолчанию русский, и он — ноль" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Language.ru));
    try std.testing.expectEqual(Language.ru, Language.parse(""));
    try std.testing.expectEqual(Language.ru, Language.parse("de"));
    try std.testing.expectEqual(Language.en, Language.parse("en"));
    try std.testing.expectEqual(Language.en, Language.parse("EN"));
    try std.testing.expectEqualStrings("en", Language.en.code());
}

test "строка без русских букв перевода не требует" {
    set(.en);
    defer set(.ru);
    try std.testing.expectEqualStrings("F9", t("F9"));
    try std.testing.expectEqualStrings("…", t("…"));
}

test "одна и та же строка в двух таблицах переведена одинаково" {
    for (all_pairs, 0..) |a, i| {
        for (all_pairs[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a[0], b[0])) try std.testing.expectEqualStrings(a[1], b[1]);
        }
    }
}

test "перевод не пуст и не равен русскому" {
    for (all_pairs) |p| {
        try std.testing.expect(p[1].len > 0);
        try std.testing.expect(!std.mem.eql(u8, p[0], p[1]));
    }
}

test "в переводе не осталось русских букв" {
    for (all_pairs) |p| {
        for (p[1]) |b| try std.testing.expect(b != 0xD0 and b != 0xD1);
    }
}

test "перевод берёт столько же подстановок, сколько исходная строка" {
    // Разное число `{` — верный признак потерянного или лишнего аргумента.
    // Компилятор поймает это в `print`, но не в `t`: там строка уходит как
    // есть, и потерянная подстановка всплыла бы только на экране.
    for (all_pairs) |p| {
        try std.testing.expectEqual(std.mem.count(u8, p[0], "{"), std.mem.count(u8, p[1], "{"));
    }
}
