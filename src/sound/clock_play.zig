//! Воспроизведение звука с часами: время идёт по отданным в колонки отсчётам.
//!
//! Задача #23. Плеер редактора вёл время по часам процессора, а звука
//! не было вовсе. Когда звук есть, часы обязаны быть его: колонки
//! отдают отсчёты со своей скоростью, и если кадры идут по другим часам,
//! картинка и голос расходятся — медленно, но к концу заметно.
//!
//! Здесь поток, который держит устройство вывода сытым и считает, сколько
//! отсчётов оно уже съело. Откуда брать отсчёты — решает вызывающий через
//! `Feed`: плеер смешивает проект прямо на ходу, стенд подсовывает тон.
//! Само устройство — в `play.Renderer`, общем со стендами.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const play = @import("play.zig");
const c = win32.c;

pub const Error = play.Error;

/// Наполнить `out` отсчётами, начиная с `from` (в отсчётах от начала
/// проекта). Зовётся из потока звука: трогать окно оттуда нельзя.
pub const Feed = *const fn (userdata: ?*anyopaque, from: usize, out: []i16) void;

/// Часы по отсчётам: чистая арифметика, проверяется тестами.
pub const Clock = struct {
    /// Сколько отсчётов устройство уже съело.
    pub fn playedNs(played: usize, rate: u32) u64 {
        if (rate == 0) return 0;
        return @as(u64, played) * std.time.ns_per_s / rate;
    }

    /// Сколько съедено: отдано минус то, что ещё лежит в буфере.
    pub fn consumed(written: usize, padding: usize) usize {
        return written -| padding;
    }
};

pub const Player = struct {
    rate: u32 = 0,
    /// С какого отсчёта проекта начали.
    from: usize = 0,
    /// Сколько всего отсчётов в проекте: дальше играть нечего.
    total: usize = 0,
    feed: ?Feed = null,
    userdata: ?*anyopaque = null,
    /// Сколько отсчётов устройство съело с начала. Атомарно: пишет поток
    /// звука, читает окно.
    played: std.atomic.Value(usize) = .init(0),
    running: std.atomic.Value(bool) = .init(false),
    /// Дошли до конца проекта и всё отзвучало.
    ended: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    failure: ?Error = null,

    /// Пустить с отсчёта `from`. Возвращается сразу; ошибка устройства
    /// приходит через `failure` после старта потока.
    pub fn start(self: *Player, rate: u32, from: usize, total: usize, feed: Feed, userdata: ?*anyopaque) Error!void {
        if (builtin.os.tag != .windows) return Error.Unsupported;
        if (self.running.load(.acquire)) return;
        self.* = .{ .rate = rate, .from = from, .total = total, .feed = feed, .userdata = userdata };
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
            self.running.store(false, .release);
            return Error.Failed;
        };
    }

    pub fn stop(self: *Player) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn isRunning(self: *const Player) bool {
        return self.running.load(.acquire);
    }

    pub fn hasEnded(self: *const Player) bool {
        return self.ended.load(.acquire);
    }

    /// Сколько времени отзвучало с момента старта.
    pub fn playedNs(self: *const Player) u64 {
        return Clock.playedNs(self.played.load(.acquire), self.rate);
    }

    fn run(self: *Player) void {
        self.loop() catch |err| {
            self.failure = err;
        };
        self.running.store(false, .release);
    }

    fn loop(self: *Player) Error!void {
        var out = try play.Renderer.open();
        defer out.close();

        var mono: [8192]i16 = undefined;
        var as_float: [8192]f32 = undefined;
        var written: usize = 0;
        var wanted: usize = 0;

        // Первый кусок — до старта: иначе начало съедает тишина.
        try self.pump(&out, &mono, &as_float, &written, &wanted);
        try out.start();
        defer out.stop();

        while (self.running.load(.acquire)) {
            const padding = try out.padding();
            self.played.store(Clock.consumed(written, padding), .release);
            if (wanted >= self.total - @min(self.total, self.from)) {
                // Всё отдано; ждём, пока дозвучит, и выходим сами.
                if (padding == 0) {
                    self.ended.store(true, .release);
                    return;
                }
                c.Sleep(5);
                continue;
            }
            const room = out.room(padding);
            if (room < 480) {
                c.Sleep(3);
                continue;
            }
            try self.pump(&out, &mono, &as_float, &written, &wanted);
        }
    }

    /// Спросить у источника столько, сколько влезет, и отдать устройству.
    fn pump(self: *Player, out: *play.Renderer, mono: []i16, as_float: []f32, written: *usize, wanted: *usize) Error!void {
        const left = self.total - @min(self.total, self.from + wanted.*);
        const padding = try out.padding();
        const want = @min(@min(out.room(padding), mono.len), left);
        if (want == 0) return;
        @memset(mono[0..want], 0);
        if (self.feed) |feed| feed(self.userdata, self.from + wanted.*, mono[0..want]);
        // Частота проекта может не совпасть с частотой устройства —
        // тогда ближайший отсчёт, как в пробе микрофона.
        const src = play.Source{ .samples = .{ .data = mono[0..want], .rate = self.rate } };
        const dev_frames: usize = @intCast(@as(u64, want) * out.rate / @max(self.rate, 1));
        const frames = @max(@min(dev_frames, as_float.len), 1);
        for (as_float[0..frames], 0..) |*v, i| v.* = src.sampleAt(i, out.rate);
        try out.writeMono(as_float[0..frames]);
        written.* += frames;
        wanted.* += want;
    }
};

// ---------------------------------------------------------------- тесты

const testing = std.testing;

test "часы по отсчётам: съедено — это отдано минус буфер" {
    try testing.expectEqual(@as(usize, 0), Clock.consumed(0, 0));
    try testing.expectEqual(@as(usize, 4000), Clock.consumed(4800, 800));
    // Буфер больше отданного не бывает, но и падать из-за этого нельзя.
    try testing.expectEqual(@as(usize, 0), Clock.consumed(100, 800));
}

test "время идёт по частоте: 48000 отсчётов — секунда" {
    try testing.expectEqual(@as(u64, std.time.ns_per_s), Clock.playedNs(48_000, 48_000));
    try testing.expectEqual(@as(u64, std.time.ns_per_s / 2), Clock.playedNs(22_050, 44_100));
    try testing.expectEqual(@as(u64, 0), Clock.playedNs(1000, 0));
}

test "плеер по умолчанию стоит и ничего не сыграл" {
    const p = Player{};
    try testing.expect(!p.isRunning());
    try testing.expect(!p.hasEnded());
    try testing.expectEqual(@as(u64, 0), p.playedNs());
}
