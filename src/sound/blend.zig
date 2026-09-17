//! Сведение двух звуковых источников в одну дорожку: микрофон и система.
//!
//! Задача #20. Микрофон и системный звук приходят двумя потоками, каждый
//! со своим временем первого отсчёта по общим часам QPC. В файле дорожка
//! одна, и её время идёт по числу отсчётов. Значит, два потока надо
//! выровнять по старту, сложить и отдать одним куском.
//!
//! **Здесь нет ни одного обращения к Windows.** Смеситель получает два среза
//! отсчётов и время старта каждого — и всё. Так его можно проверить тестом
//! целиком: подали два известных сигнала со сдвигом, посмотрели на сумму.
//!
//! **Кто начался позже — получает тишину спереди.** Иначе тот, кто начался
//! позже, оказался бы в файле раньше, чем звучал, — ровно на задержку
//! своего запуска, и звук колонок разъехался бы с голосом.
const std = @import("std");

/// Сколько тишины подставить каждому источнику спереди, в отсчётах.
///
/// Тому, кто начался раньше, — ноль; тому, кто позже, — разницу стартов.
/// Разница считается по общим часам, а в отсчёты переводится частотой файла,
/// потому что оба источника уже пересчитаны к ней.
pub const Pad = struct {
    a: usize = 0,
    b: usize = 0,
};

pub fn padFor(start_a_ns: u64, start_b_ns: u64, rate: u32) Pad {
    if (start_a_ns == start_b_ns) return .{};
    const later = @max(start_a_ns, start_b_ns);
    const earlier = @min(start_a_ns, start_b_ns);
    const gap: usize = @intCast((later - earlier) * rate / std.time.ns_per_s);
    return if (start_a_ns > start_b_ns) .{ .a = gap } else .{ .b = gap };
}

/// Сложить два куска одинаковой длины в третий, не дав сумме завернуться.
///
/// Без прижатия громкая музыка из колонок плюс голос складываются
/// в переполнение, и вместо громкого места получается треск — ровно там,
/// куда человек и хотел обратить внимание.
pub fn mix(a: []const i16, b: []const i16, out: []i16) usize {
    const n = @min(@min(a.len, b.len), out.len);
    for (0..n) |i| {
        const sum = @as(i32, a[i]) + @as(i32, b[i]);
        out[i] = @intCast(std.math.clamp(sum, std.math.minInt(i16), std.math.maxInt(i16)));
    }
    return n;
}

/// Один источник с тишиной спереди.
///
/// Очередь отдаёт отсчёты кусками, а тишину спереди надо выдать до них.
/// Считать её здесь, а не класть нули в саму очередь: очередь принадлежит
/// потоку захвата, и трогать её из потока записи нельзя.
pub const Padded = struct {
    /// Сколько нулей ещё осталось выдать спереди.
    pad_left: usize = 0,

    /// Сколько отсчётов можно взять прямо сейчас: остаток тишины плюс
    /// то, что лежит в очереди.
    pub fn ready(self: Padded, queued: usize) usize {
        return self.pad_left + queued;
    }

    /// Сколько из `want` отсчётов нужно взять нулями, а сколько из очереди.
    pub fn split(self: *Padded, want: usize) struct { zeros: usize, real: usize } {
        const zeros = @min(self.pad_left, want);
        self.pad_left -= zeros;
        return .{ .zeros = zeros, .real = want - zeros };
    }
};

// ---------------------------------------------------------------- тесты

const testing = std.testing;
const sec = std.time.ns_per_s;

test "кто начался позже — получает тишину спереди" {
    // Микрофон поднялся на четверть секунды позже колонок: ему четверть
    // секунды нулей, колонкам — ничего.
    const p = padFor(sec + sec / 4, sec, 48_000);
    try testing.expectEqual(@as(usize, 12_000), p.a);
    try testing.expectEqual(@as(usize, 0), p.b);

    const q = padFor(sec, sec + sec / 4, 48_000);
    try testing.expectEqual(@as(usize, 0), q.a);
    try testing.expectEqual(@as(usize, 12_000), q.b);
}

test "одновременный старт — тишины не нужно никому" {
    const p = padFor(5 * sec, 5 * sec, 48_000);
    try testing.expectEqual(@as(usize, 0), p.a);
    try testing.expectEqual(@as(usize, 0), p.b);
}

test "сумма складывается и не заворачивается" {
    const a = [_]i16{ 1000, -1000, 30_000, -30_000 };
    const b = [_]i16{ 1000, -1000, 10_000, -10_000 };
    var out: [4]i16 = undefined;
    try testing.expectEqual(@as(usize, 4), mix(&a, &b, &out));
    try testing.expectEqual(@as(i16, 2000), out[0]);
    try testing.expectEqual(@as(i16, -2000), out[1]);
    // Упёрлось в предел, а не завернулось в треск.
    try testing.expectEqual(@as(i16, 32_767), out[2]);
    try testing.expectEqual(@as(i16, -32_768), out[3]);
}

test "берём столько, сколько есть у обоих" {
    const a = [_]i16{ 1, 2, 3, 4, 5 };
    const b = [_]i16{ 10, 20 };
    var out: [8]i16 = undefined;
    try testing.expectEqual(@as(usize, 2), mix(&a, &b, &out));
    try testing.expectEqual(@as(i16, 11), out[0]);
    try testing.expectEqual(@as(i16, 22), out[1]);
}

test "тишина спереди выдаётся до отсчётов из очереди, и ровно столько" {
    var p = Padded{ .pad_left = 5 };
    try testing.expectEqual(@as(usize, 15), p.ready(10));

    const first = p.split(3);
    try testing.expectEqual(@as(usize, 3), first.zeros);
    try testing.expectEqual(@as(usize, 0), first.real);

    const second = p.split(6);
    try testing.expectEqual(@as(usize, 2), second.zeros);
    try testing.expectEqual(@as(usize, 4), second.real);

    // Тишина кончилась — дальше только очередь.
    const third = p.split(7);
    try testing.expectEqual(@as(usize, 0), third.zeros);
    try testing.expectEqual(@as(usize, 7), third.real);
    try testing.expectEqual(@as(usize, 0), p.pad_left);
}

test "сложение сведённого голоса с тишиной колонок не меняет голос" {
    // Колонки молчат — в файле должен остаться ровно голос, без скидки.
    const voice = [_]i16{ 100, -200, 300 };
    const quiet = [_]i16{ 0, 0, 0 };
    var out: [3]i16 = undefined;
    _ = mix(&voice, &quiet, &out);
    try testing.expectEqualSlices(i16, &voice, &out);
}
