//! «Разгон»: список ускорений и честный ответ, что из них работает.
//!
//! Задача #72. Разгон даёт скорость, а не берёт её из ниоткуда: за каждым
//! ускорением стоит решение со своей ценой. Поэтому здесь не одна галочка
//! «сделать хорошо», а список — с тем, что ускорение делает, чем за это
//! платится и чем оно сделано.
//!
//! **Список показывает то, что работает в этом сеансе, а не обещания.**
//! Когда человек говорит «у меня тормозит», первый вопрос — что именно
//! у него включилось. Аппаратный декодер есть не на всякой машине; если он
//! не завёлся, это должно быть написано, а не угадываться.
const std = @import("std");
const lang = @import("../lang.zig");

/// Одно ускорение.
pub const Speedup = struct {
    /// Как назвать человеку.
    name: []const u8,
    /// Что оно делает.
    what: []const u8,
    /// Чем за это платится. Пусто — если ничем.
    cost: []const u8 = "",
    /// Чем сделано: свой код, часть Windows, библиотека.
    made_by: []const u8,
    /// Включено ли по настройкам.
    on: bool = false,
    /// Завелось ли на этой машине. `null` — нечему заводиться.
    works: ?bool = null,

    /// Что написать в строке состояния.
    pub fn state(self: Speedup) []const u8 {
        if (!self.on) return lang.t("выключено");
        return switch (self.works orelse true) {
            true => lang.t("работает"),
            false => lang.t("не завелось"),
        };
    }
};

/// Что мы знаем о нынешнем сеансе.
pub const Facts = struct {
    /// Стоит ли галочка «Разгон».
    boost: bool = true,
    /// Согласился ли декодер отдавать уменьшенный кадр.
    ///
    /// `null` — ещё не спрашивали: файл не открыт.
    scaled: ?bool = null,
    /// Какой предел размера просим.
    max_width: u32 = 0,
    max_height: u32 = 0,
};

pub const max_items = 8;

/// Собрать список ускорений под нынешний сеанс.
pub fn list(facts: Facts, out: *[max_items]Speedup) []const Speedup {
    var n: usize = 0;

    out[n] = .{
        .name = lang.t("Кадр по размеру окна"),
        .what = lang.t("декодер отдаёт кадр такого размера, какой показан, а не какой в файле"),
        .cost = lang.t("снимок кадра берётся отдельно, в полном размере, и потому медленнее"),
        .made_by = lang.t("Media Foundation, продвинутое видеопреобразование"),
        .on = facts.boost,
        .works = facts.scaled,
    };
    n += 1;

    out[n] = .{
        .name = lang.t("Декодер в стороне от окна"),
        .what = lang.t("окно просит кадр и не ждёт его; просьбы склеиваются, работает последняя"),
        .cost = lang.t("пока новый кадр не готов, виден прежний"),
        .made_by = lang.t("свой код"),
        // Это не выключается: без него окно виснет, и выбирать тут нечего.
        .on = true,
    };
    n += 1;

    out[n] = .{
        .name = lang.t("Открытие по оглавлению"),
        .what = lang.t("длина и дорожки читаются из оглавления файла, а не из всего файла"),
        .cost = "",
        .made_by = lang.t("свой код"),
        .on = true,
    };
    n += 1;

    out[n] = .{
        .name = lang.t("Волна в стороне"),
        .what = lang.t("звуковая волна считается не в потоке окна: клип появляется сразу"),
        .cost = lang.t("волна дорисовывается через секунду-другую"),
        .made_by = lang.t("свой код"),
        .on = true,
    };
    n += 1;

    out[n] = .{
        .name = lang.t("Окно не рисует под кнопками"),
        .what = lang.t("перерисовка не задевает панель: кнопки не мигают при воспроизведении"),
        .cost = "",
        .made_by = lang.t("Windows, признак WS_CLIPCHILDREN"),
        .on = true,
    };
    n += 1;

    return out[0..n];
}

/// Сколько ускорений включено и сколько из них завелось.
pub const Tally = struct {
    total: usize = 0,
    on: usize = 0,
    failed: usize = 0,
};

pub fn tally(items: []const Speedup) Tally {
    var t = Tally{ .total = items.len };
    for (items) |it| {
        if (!it.on) continue;
        t.on += 1;
        if (it.works) |ok| {
            if (!ok) t.failed += 1;
        }
    }
    return t;
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;

test "список не пуст и влезает в отведённое место" {
    var buf: [max_items]Speedup = undefined;
    const items = list(.{}, &buf);
    try testing.expect(items.len > 0);
    try testing.expect(items.len <= max_items);
}

test "у каждого ускорения есть имя, смысл и чем оно сделано" {
    var buf: [max_items]Speedup = undefined;
    for (list(.{}, &buf)) |it| {
        try testing.expect(it.name.len > 0);
        try testing.expect(it.what.len > 0);
        try testing.expect(it.made_by.len > 0);
        try testing.expect(it.state().len > 0);
    }
}

test "выключенный разгон гасит то, что от него зависит" {
    var on_buf: [max_items]Speedup = undefined;
    var off_buf: [max_items]Speedup = undefined;
    const on = list(.{ .boost = true }, &on_buf);
    const off = list(.{ .boost = false }, &off_buf);

    try testing.expect(on[0].on);
    try testing.expect(!off[0].on);
    // А то, что не выключается, остаётся включённым: без него окно виснет.
    try testing.expect(off[1].on);
}

test "не завелось — так и написано" {
    var buf: [max_items]Speedup = undefined;
    const ok = list(.{ .boost = true, .scaled = true }, &buf);
    try testing.expectEqualStrings("работает", ok[0].state());

    var buf2: [max_items]Speedup = undefined;
    const bad = list(.{ .boost = true, .scaled = false }, &buf2);
    try testing.expectEqualStrings("не завелось", bad[0].state());

    var buf3: [max_items]Speedup = undefined;
    const off = list(.{ .boost = false, .scaled = true }, &buf3);
    try testing.expectEqualStrings("выключено", off[0].state());
}

test "ещё не спрашивали — считаем, что работает" {
    // Файл не открыт, спрашивать было нечего. Врать «не завелось» тут
    // не за что.
    var buf: [max_items]Speedup = undefined;
    const items = list(.{ .boost = true, .scaled = null }, &buf);
    try testing.expectEqualStrings("работает", items[0].state());
}

test "счёт включённого и незаведшегося" {
    var buf: [max_items]Speedup = undefined;
    const all_on = tally(list(.{ .boost = true, .scaled = true }, &buf));
    try testing.expectEqual(all_on.total, all_on.on);
    try testing.expectEqual(@as(usize, 0), all_on.failed);

    var buf2: [max_items]Speedup = undefined;
    const broken = tally(list(.{ .boost = true, .scaled = false }, &buf2));
    try testing.expectEqual(@as(usize, 1), broken.failed);

    var buf3: [max_items]Speedup = undefined;
    const off = tally(list(.{ .boost = false }, &buf3));
    try testing.expect(off.on < off.total);
}

test "у ускорения с ценой цена названа" {
    // Разгон даёт скорость, а не берёт её из ниоткуда. Где есть цена —
    // она должна быть написана.
    var buf: [max_items]Speedup = undefined;
    const items = list(.{ .boost = true }, &buf);
    try testing.expect(items[0].cost.len > 0);
    try testing.expect(items[1].cost.len > 0);
}
