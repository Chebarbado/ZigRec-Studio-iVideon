//! Очередь звуковых отсчётов между потоком захвата и потоком записи.
//!
//! Задача #40. Микрофон отдаёт отсчёты в своём потоке, а в файл их пишет поток
//! записи — тот же, что пишет кадры. Писать в контейнер из двух потоков нельзя,
//! поэтому между ними очередь: захват кладёт, запись забирает.
//!
//! Без замка, один писатель и один читатель. Замок здесь стоил бы дороже
//! самой работы: кусок звука — это несколько сотен отсчётов, и брать под них
//! системный объект синхронизации сорок раз в секунду незачем.
//!
//! Переполнение **считается, а не замалчивается**. Если поток записи почему-то
//! встал, звук потеряется — и человек должен об этом узнать из отчёта, а не
//! обнаружить дыру в готовом файле.
const std = @import("std");

/// Четыре секунды при 48 кГц. Поток записи забирает отсчёты тридцать раз
/// в секунду, так что запас здесь стократный: он на случай, когда система
/// придержала наш поток, а не на обычный ход дела.
pub const capacity: usize = 48_000 * 4;

pub const Track = struct {
    data: [capacity]i16 = @splat(0),
    read_at: std.atomic.Value(usize) = .init(0),
    write_at: std.atomic.Value(usize) = .init(0),
    /// Сколько отсчётов не поместилось.
    dropped: std.atomic.Value(u64) = .init(0),
    /// Время первого положенного отсчёта по тем же часам, что у кадров.
    /// Ноль — звук ещё не пошёл.
    start_ns: std.atomic.Value(u64) = .init(0),

    pub fn reset(self: *Track) void {
        self.read_at.store(0, .release);
        self.write_at.store(0, .release);
        self.dropped.store(0, .release);
        self.start_ns.store(0, .release);
    }

    /// Сколько отсчётов лежит и ждёт.
    pub fn available(self: *const Track) usize {
        return self.write_at.load(.acquire) -| self.read_at.load(.acquire);
    }

    /// Положить кусок. Вызывает только поток захвата.
    ///
    /// `at_ns` — время первого отсчёта куска. Запоминается только один раз,
    /// на самом первом куске: дальше время считается по числу отсчётов, потому
    /// что у звука шаг известен точно, а часы дрожат.
    pub fn push(self: *Track, samples: []const i16, at_ns: u64) void {
        if (samples.len == 0) return;
        const w = self.write_at.load(.monotonic);
        if (w == 0) self.start_ns.store(at_ns, .release);

        const r = self.read_at.load(.acquire);
        const free = capacity - (w -| r);
        if (samples.len > free) {
            _ = self.dropped.fetchAdd(samples.len - free, .monotonic);
        }
        const take = @min(samples.len, free);
        for (0..take) |i| {
            self.data[(w + i) % capacity] = samples[i];
        }
        self.write_at.store(w + take, .release);
    }

    /// Забрать, сколько поместится. Вызывает только поток записи.
    pub fn pop(self: *Track, out: []i16) usize {
        const r = self.read_at.load(.monotonic);
        const w = self.write_at.load(.acquire);
        const take = @min(out.len, w -| r);
        for (0..take) |i| {
            out[i] = self.data[(r + i) % capacity];
        }
        self.read_at.store(r + take, .release);
        return take;
    }
};

// ---------------------------------------------------------------- тесты

test "что положили, то и забрали, в том же порядке" {
    var t = Track{};
    t.push(&[_]i16{ 1, 2, 3, 4 }, 1000);
    try std.testing.expectEqual(@as(usize, 4), t.available());

    var out: [8]i16 = undefined;
    try std.testing.expectEqual(@as(usize, 4), t.pop(&out));
    try std.testing.expectEqualSlices(i16, &[_]i16{ 1, 2, 3, 4 }, out[0..4]);
    try std.testing.expectEqual(@as(usize, 0), t.available());
}

test "время запоминается по первому куску, а не по последнему" {
    var t = Track{};
    t.push(&[_]i16{1}, 5000);
    t.push(&[_]i16{2}, 9999);
    try std.testing.expectEqual(@as(u64, 5000), t.start_ns.load(.acquire));
}

test "кольцо переживает переход через конец буфера" {
    var t = Track{};
    var out: [1024]i16 = undefined;
    // Прокручиваем очередь мимо конца буфера несколько раз.
    var round: usize = 0;
    while (round < 300) : (round += 1) {
        var chunk: [1000]i16 = undefined;
        for (&chunk, 0..) |*v, i| v.* = @intCast((round + i) % 1000);
        t.push(&chunk, 0);
        const n = t.pop(&out);
        try std.testing.expectEqual(@as(usize, 1000), n);
        for (0..n) |i| try std.testing.expectEqual(@as(i16, @intCast((round + i) % 1000)), out[i]);
    }
    try std.testing.expectEqual(@as(u64, 0), t.dropped.load(.monotonic));
}

test "переполнение считается, а не молчит" {
    var t = Track{};
    const big = try std.testing.allocator.alloc(i16, capacity + 500);
    defer std.testing.allocator.free(big);
    @memset(big, 7);
    t.push(big, 0);
    // Вошло ровно столько, сколько есть места; остальное посчитано потерянным.
    try std.testing.expectEqual(capacity, t.available());
    try std.testing.expectEqual(@as(u64, 500), t.dropped.load(.monotonic));
}

test "пустая очередь отдаёт ноль, а не мусор" {
    var t = Track{};
    var out: [16]i16 = undefined;
    try std.testing.expectEqual(@as(usize, 0), t.pop(&out));
    try std.testing.expectEqual(@as(usize, 0), t.available());
}

test "сброс возвращает очередь к началу" {
    var t = Track{};
    t.push(&[_]i16{ 1, 2, 3 }, 777);
    t.reset();
    try std.testing.expectEqual(@as(usize, 0), t.available());
    try std.testing.expectEqual(@as(u64, 0), t.start_ns.load(.acquire));
    // После сброса время снова возьмётся с первого куска.
    t.push(&[_]i16{9}, 42);
    try std.testing.expectEqual(@as(u64, 42), t.start_ns.load(.acquire));
}

test "забираем по частям — порядок не рвётся" {
    var t = Track{};
    t.push(&[_]i16{ 10, 20, 30, 40, 50 }, 0);
    var small: [2]i16 = undefined;
    try std.testing.expectEqual(@as(usize, 2), t.pop(&small));
    try std.testing.expectEqualSlices(i16, &[_]i16{ 10, 20 }, &small);
    try std.testing.expectEqual(@as(usize, 2), t.pop(&small));
    try std.testing.expectEqualSlices(i16, &[_]i16{ 30, 40 }, &small);
    try std.testing.expectEqual(@as(usize, 1), t.pop(&small));
    try std.testing.expectEqual(@as(i16, 50), small[0]);
}
