//! Усиление картинки осциллографа.
//!
//! Тихий микрофон даёт около минус сорока семи децибел, и на графике это
//! прямая линия: видно, что сигнал есть, но не видно, что происходит.
//! Ползунок растягивает волну по вертикали.
//!
//! **Усиление трогает картинку, но не число.** Показание в децибелах остаётся
//! настоящим. Иначе прибор начнёт врать: человек накрутит усиление, увидит
//! большую волну и решит, что микрофон громкий, — а запись выйдет тихой.
//! Растянута только картинка, уровень прежний.
//!
//! Шаг — ровно вдвое (плюс шесть децибел). Так подпись читается без счёта:
//! `x8` — это в восемь раз, а не «примерно во столько же».
const std = @import("std");

/// Крайнее положение ползунка. Семь положений: от `x1` до `x64`.
/// Больше не нужно: `x64` поднимает минус сорок семь децибел до минус одиннадцати,
/// а всё, что тише, — это уже шум входа, и растягивать там нечего.
pub const max_pos: u8 = 6;

/// Во сколько раз растянуть волну.
pub fn factorFor(pos: u8) f32 {
    const p = @min(pos, max_pos);
    return @floatFromInt(@as(u32, 1) << @intCast(p));
}

/// То же усиление в децибелах — для тех, кто считает в них, а не в разах.
pub fn dbFor(pos: u8) f32 {
    return 20 * std.math.log10(factorFor(pos));
}

/// Отсчёт, готовый к рисованию: усиленный и прижатый к краям поля.
///
/// Без прижатия усиленная волна ушла бы за границы панели и рисовалась поверх
/// соседних элементов окна.
pub fn scaled(sample: f32, factor: f32) f32 {
    return std.math.clamp(sample * factor, -1.0, 1.0);
}

/// Упёрлась ли **картинка** в края поля.
///
/// Это не перегруз входа: волна упирается в край потому, что её растянули.
/// Два состояния надо различать, иначе подпись «ПЕРЕГРУЗ» будет появляться
/// от движения ползунка, а не от громкого звука.
pub fn pictureClipped(peak: f32, factor: f32) bool {
    return peak * factor >= 1.0;
}

/// Подпись положения: `x1`, `x2`, … Возвращает срез из переданного буфера.
pub fn label(pos: u8, buf: []u8) []const u8 {
    const times: u32 = @intFromFloat(factorFor(pos));
    return std.fmt.bufPrint(buf, "x{d}", .{times}) catch "x1";
}

// ---------------------------------------------------------------- тесты

test "крайние положения: без усиления и в шестьдесят четыре раза" {
    try std.testing.expectEqual(@as(f32, 1), factorFor(0));
    try std.testing.expectEqual(@as(f32, 64), factorFor(max_pos));
}

test "положение выше крайнего не даёт усиления больше крайнего" {
    // Ползунок ограничен системой, но правило не должно зависеть от того,
    // что пришло: чужое число не должно уводить масштаб в бесконечность.
    try std.testing.expectEqual(factorFor(max_pos), factorFor(200));
}

test "шаг ползунка — ровно вдвое" {
    var pos: u8 = 0;
    while (pos < max_pos) : (pos += 1) {
        try std.testing.expectEqual(factorFor(pos) * 2, factorFor(pos + 1));
    }
}

test "шаг вдвое — это шесть децибел" {
    try std.testing.expectApproxEqAbs(@as(f32, 0), dbFor(0), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 6.02), dbFor(1), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 36.12), dbFor(max_pos), 0.01);
}

test "усиление растягивает, но не выпускает волну за поле" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), scaled(0.1, 4), 0.0001);
    try std.testing.expectEqual(@as(f32, 1), scaled(0.5, 8));
    try std.testing.expectEqual(@as(f32, -1), scaled(-0.5, 8));
    // Без усиления отсчёт проходит как есть.
    try std.testing.expectApproxEqAbs(@as(f32, -0.25), scaled(-0.25, 1), 0.0001);
}

test "упёршаяся картинка — это не перегруз входа" {
    // Тихий сигнал, растянутый до края: картинка упёрлась, вход — нет.
    try std.testing.expect(pictureClipped(0.2, 8));
    // Тот же сигнал без усиления никуда не упирается.
    try std.testing.expect(!pictureClipped(0.2, 1));
}

test "подпись читается без счёта" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("x1", label(0, &buf));
    try std.testing.expectEqualStrings("x2", label(1, &buf));
    try std.testing.expectEqualStrings("x64", label(max_pos, &buf));
}

test "усиление не меняет измеренный уровень" {
    // Главное требование: ползунок — это лупа, а не регулятор входа.
    const mic = @import("mic.zig");
    const level = mic.Level{ .peak = 0.1, .rms = 0.07 };
    const before = level.dbfs();

    // Что бы ни делали с картинкой…
    var pos: u8 = 0;
    while (pos <= max_pos) : (pos += 1) {
        _ = scaled(level.peak, factorFor(pos));
    }

    // …измеренный уровень остался тем же.
    try std.testing.expectEqual(before, level.dbfs());
    try std.testing.expectApproxEqAbs(@as(f32, -20), before, 0.01);
}
