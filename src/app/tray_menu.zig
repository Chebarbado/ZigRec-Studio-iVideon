//! Что показывать в меню значка в трее.
//!
//! Задача #63. Значок в трее нужен ровно тогда, когда окна на экране нет:
//! программа свёрнута, а сделать что-то надо прямо сейчас. Значит, в меню
//! должно лежать то, ради чего её держат открытой, — и оно должно
//! соответствовать тому, что происходит.
//!
//! Состав меню — чистый счёт, поэтому живёт отдельно от Windows и проверяется
//! тестами. Ошибка здесь не роняет программу: она даёт человеку строку,
//! которая ничего не делает, или прячет ту, которая нужна.
const std = @import("std");
const lang = @import("../lang.zig");

/// Что можно выбрать в меню значка.
pub const Item = enum {
    /// Показать окно.
    show,
    /// Обвести область и начать запись.
    record_area,
    /// Остановить идущую запись.
    stop,
    /// Приостановить или продолжить.
    pause,
    /// Открыть последнюю запись.
    open_last,
    /// Настройки.
    settings,
    /// Закрыть программу совсем.
    exit,
    /// Разделительная черта.
    separator,

    pub fn label(self: Item, paused: bool) []const u8 {
        return switch (self) {
            .show => lang.t("Открыть"),
            .record_area => lang.t("Снять область"),
            .stop => lang.t("Остановить запись"),
            .pause => if (paused) lang.t("Продолжить") else lang.t("Пауза"),
            .open_last => lang.t("Открыть последнюю запись"),
            .settings => lang.t("Настройки…"),
            .exit => lang.t("Выйти"),
            .separator => "",
        };
    }
};

/// Что сейчас с программой — от этого зависит состав меню.
pub const State = struct {
    /// Идёт ли запись.
    recording: bool = false,
    /// Приостановлена ли она.
    paused: bool = false,
    /// Есть ли записанный файл, который можно открыть.
    has_last: bool = false,
};

pub const max_items = 8;

/// Собрать меню под текущее состояние.
///
/// Правила простые, но их легко нарушить по недосмотру:
///
///  * пока запись идёт, в меню должно быть чем её остановить — иначе значок
///    в трее говорит меньше, чем подсказка под указателем;
///  * пока запись идёт, «снять область» показывать нельзя: вторая запись
///    поверх первой — это не то, что человек имел в виду;
///  * «выйти» есть всегда и стоит последним. Программа, из которой неочевидно
///    выйти, раздражает именно этим.
pub fn build(state: State, out: *[max_items]Item) []const Item {
    var n: usize = 0;
    out[n] = .show;
    n += 1;

    if (state.recording) {
        out[n] = .pause;
        n += 1;
        out[n] = .stop;
        n += 1;
    } else {
        out[n] = .record_area;
        n += 1;
        if (state.has_last) {
            out[n] = .open_last;
            n += 1;
        }
    }

    out[n] = .separator;
    n += 1;
    out[n] = .settings;
    n += 1;
    out[n] = .separator;
    n += 1;
    out[n] = .exit;
    n += 1;
    return out[0..n];
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;

fn has(items: []const Item, want: Item) bool {
    for (items) |i| {
        if (i == want) return true;
    }
    return false;
}

test "в покое: открыть, снять область, настройки, выйти" {
    var buf: [max_items]Item = undefined;
    const items = build(.{}, &buf);
    try testing.expect(has(items, .show));
    try testing.expect(has(items, .record_area));
    try testing.expect(has(items, .settings));
    try testing.expect(has(items, .exit));
    // Останавливать нечего.
    try testing.expect(!has(items, .stop));
    try testing.expect(!has(items, .pause));
}

test "во время записи есть чем её остановить" {
    var buf: [max_items]Item = undefined;
    const items = build(.{ .recording = true }, &buf);
    try testing.expect(has(items, .stop));
    try testing.expect(has(items, .pause));
    // И нельзя начать вторую поверх первой.
    try testing.expect(!has(items, .record_area));
}

test "«выйти» есть всегда и стоит последним" {
    // Программа, из которой неочевидно выйти, раздражает именно этим.
    var buf: [max_items]Item = undefined;
    for ([_]State{
        .{},
        .{ .recording = true },
        .{ .recording = true, .paused = true },
        .{ .has_last = true },
    }) |state| {
        const items = build(state, &buf);
        try testing.expectEqual(Item.exit, items[items.len - 1]);
    }
}

test "«открыть последнюю» появляется, когда есть что открывать" {
    var buf: [max_items]Item = undefined;
    try testing.expect(!has(build(.{}, &buf), .open_last));
    try testing.expect(has(build(.{ .has_last = true }, &buf), .open_last));
    // Во время записи её нет: последняя запись ещё не дописана.
    try testing.expect(!has(build(.{ .recording = true, .has_last = true }, &buf), .open_last));
}

test "пауза меняет подпись, а не строку" {
    try testing.expectEqualStrings("Пауза", Item.pause.label(false));
    try testing.expectEqualStrings("Продолжить", Item.pause.label(true));
}

test "меню не пустое и влезает в отведённое место" {
    var buf: [max_items]Item = undefined;
    for ([_]State{
        .{},
        .{ .recording = true },
        .{ .recording = true, .paused = true, .has_last = true },
        .{ .has_last = true },
    }) |state| {
        const items = build(state, &buf);
        try testing.expect(items.len > 0);
        try testing.expect(items.len <= max_items);
        // Черта не должна стоять с краю: это выглядит как обрезанное меню.
        try testing.expect(items[0] != .separator);
        try testing.expect(items[items.len - 1] != .separator);
    }
}

test "у каждой строки, кроме черты, есть подпись" {
    var buf: [max_items]Item = undefined;
    const items = build(.{ .recording = true, .has_last = true }, &buf);
    for (items) |i| {
        if (i == .separator) continue;
        try testing.expect(i.label(false).len > 0);
    }
}

test "на английском пауза тоже меняет подпись" {
    lang.set(.en);
    defer lang.set(.ru);
    try testing.expectEqualStrings("Pause", Item.pause.label(false));
    try testing.expectEqualStrings("Resume", Item.pause.label(true));
    try testing.expectEqualStrings("Exit", Item.exit.label(false));
}
