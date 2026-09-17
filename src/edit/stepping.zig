//! Шаг по кадрам: где следующий кадр и как его назвать.
//!
//! Задача #23. Стрелки ведут указатель на один кадр: не на тридцать
//! миллисекунд «примерно», а на сетку кадров исходника, иначе после
//! десяти шагов указатель стоит между кадрами и показывает то один,
//! то другой. Ни одного обращения к окну: чистая арифметика с тестами.
const std = @import("std");

/// Кадр, если частота неизвестна: тридцать в секунду — самая частая.
pub const default_frame_ns: u64 = std.time.ns_per_s / 30;

/// Длительность кадра по частоте. Ноль, отрицательное и NaN — умолчание.
pub fn frameNs(fps: f64) u64 {
    if (!(fps > 0.1) or fps > 1000) return default_frame_ns;
    return @intFromFloat(@as(f64, std.time.ns_per_s) / fps);
}

/// Номер кадра, на который приходится момент внутри файла.
pub fn frameIndex(inside_ns: u64, frame_ns: u64) u64 {
    return inside_ns / @max(frame_ns, 1);
}

/// Момент внутри файла после шага на `dir` кадров (−1 или +1, можно больше).
///
/// Сначала встаём на сетку: момент между кадрами — это кадр, который
/// сейчас показан, и шаг вперёд ведёт к следующему, а не к тому же.
pub fn step(inside_ns: u64, frame_ns: u64, dir: i32) u64 {
    const f = @max(frame_ns, 1);
    const index: i64 = @intCast(frameIndex(inside_ns, f));
    const next = @max(index + dir, 0);
    return @as(u64, @intCast(next)) * f;
}

/// Подпись для строки состояния: «кадр 1234 · 41.13 с».
pub fn label(buf: []u8, inside_ns: u64, frame_ns: u64) []const u8 {
    const secs = @as(f64, @floatFromInt(inside_ns)) / @as(f64, std.time.ns_per_s);
    return std.fmt.bufPrint(buf, "кадр {d} · {d:.2} с", .{ frameIndex(inside_ns, frame_ns), secs }) catch "кадр";
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;
const sec = std.time.ns_per_s;

test "длительность кадра из частоты, умолчание для чепухи" {
    try testing.expectEqual(@as(u64, 40 * std.time.ns_per_ms), frameNs(25));
    try testing.expectEqual(@as(u64, 33_333_333), frameNs(30));
    try testing.expectEqual(default_frame_ns, frameNs(0));
    try testing.expectEqual(default_frame_ns, frameNs(-5));
    try testing.expectEqual(default_frame_ns, frameNs(std.math.nan(f64)));
    try testing.expectEqual(default_frame_ns, frameNs(100_000));
}

test "шаг вперёд встаёт на следующий кадр, а не на тридцать миллисекунд" {
    const f = frameNs(25); // 40 мс
    // Между кадрами 3 и 4 (130 мс) — показан третий; вперёд — четвёртый.
    try testing.expectEqual(@as(u64, 160 * std.time.ns_per_ms), step(130 * std.time.ns_per_ms, f, 1));
    // Назад — второй, а не «130 − 40».
    try testing.expectEqual(@as(u64, 80 * std.time.ns_per_ms), step(130 * std.time.ns_per_ms, f, -1));
    // Ровно на кадре: вперёд и назад — соседи.
    try testing.expectEqual(@as(u64, 200 * std.time.ns_per_ms), step(160 * std.time.ns_per_ms, f, 1));
    try testing.expectEqual(@as(u64, 120 * std.time.ns_per_ms), step(160 * std.time.ns_per_ms, f, -1));
}

test "назад от начала — остаёмся на нулевом кадре" {
    try testing.expectEqual(@as(u64, 0), step(0, frameNs(30), -1));
    try testing.expectEqual(@as(u64, 0), step(10 * std.time.ns_per_ms, frameNs(30), -5));
}

test "десять шагов вперёд и десять назад возвращают на тот же кадр" {
    const f = frameNs(29.97);
    var at: u64 = 5 * sec + 7 * std.time.ns_per_ms;
    const start_index = frameIndex(at, f);
    var i: usize = 0;
    while (i < 10) : (i += 1) at = step(at, f, 1);
    try testing.expectEqual(start_index + 10, frameIndex(at, f));
    i = 0;
    while (i < 10) : (i += 1) at = step(at, f, -1);
    try testing.expectEqual(start_index, frameIndex(at, f));
}

test "подпись называет номер кадра и секунды" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("кадр 25 · 1.00 с", label(&buf, sec, frameNs(25)));
    try testing.expectEqualStrings("кадр 0 · 0.00 с", label(&buf, 0, frameNs(30)));
}
