//! Проба микрофона: записать пять секунд и прослушать.
//!
//! Задача #22. Индикатор показывает, что микрофон живой, но не показывает,
//! как он звучит: гул, эхо, «бубнит в подушку» — это слышно только ушами.
//! Проба: пять секунд пишем, потом отдаём в колонки, и человек слышит
//! себя до записи, а не после.
//!
//! Здесь — ход пробы без окна и без звука: состояния, отсчёт времени,
//! слова для строки состояния. Это проверяется тестами целиком; окно
//! только дёргает переходы по таймеру и кормит отсчёты.
const std = @import("std");
const lang = @import("../lang.zig");

/// Сколько пишем. Пять секунд: хватает на фразу, не надоедает ждать.
pub const seconds: u64 = 5;
pub const record_ns: u64 = seconds * std.time.ns_per_s;
/// Сколько держим итог в строке состояния, прежде чем вернуть обычную.
pub const show_result_ns: u64 = 8 * std.time.ns_per_s;
/// Тише этого считаем, что микрофон молчал: −50 дБ — это шум пустой комнаты.
pub const silent_peak: f32 = 0.00316;

pub const State = enum {
    idle,
    recording,
    playing,
    /// Сыграно; итог висит в строке состояния, пока не забудем.
    done,
    /// Записалось ничего или не с чего было: итог тоже висит.
    failed,
};

/// Что окну сделать по такту.
pub const Step = enum {
    nothing,
    /// Пять секунд прошли: остановить микрофон и отдать записанное.
    stop_recording,
    /// Итог показан достаточно: вернуть обычную строку состояния.
    forget,
};

pub const Probe = struct {
    state: State = .idle,
    /// Когда началось текущее состояние.
    since_ns: u64 = 0,
    /// Сколько отсчётов набралось и какой был пик.
    samples: usize = 0,
    peak: f32 = 0,
    /// Почему не вышло — словами.
    why: []const u8 = "",

    pub fn busy(self: *const Probe) bool {
        return self.state == .recording or self.state == .playing;
    }

    pub fn start(self: *Probe, now_ns: u64) void {
        self.* = .{ .state = .recording, .since_ns = now_ns };
    }

    /// Такт: сказать окну, пора ли что-то делать.
    pub fn tick(self: *const Probe, now_ns: u64) Step {
        const elapsed = now_ns -| self.since_ns;
        return switch (self.state) {
            .recording => if (elapsed >= record_ns) .stop_recording else .nothing,
            .done, .failed => if (elapsed >= show_result_ns) .forget else .nothing,
            else => .nothing,
        };
    }

    /// Ещё отсчёты от микрофона.
    pub fn feed(self: *Probe, chunk: []const i16) void {
        self.samples += chunk.len;
        for (chunk) |s| {
            const a: f32 = @abs(@as(f32, @floatFromInt(s))) / 32768.0;
            if (a > self.peak) self.peak = a;
        }
    }

    /// Микрофон остановлен: решить, есть что слушать.
    pub fn recorded(self: *Probe, now_ns: u64) void {
        self.since_ns = now_ns;
        if (self.samples == 0) {
            self.state = .failed;
            self.why = lang.t("микрофон не дал ни одного отсчёта");
        } else if (self.peak < silent_peak) {
            // Слушать тишину незачем; сказать о ней — надо.
            self.state = .failed;
            self.why = lang.t("записалась тишина: проверьте, тот ли микрофон выбран");
        } else {
            self.state = .playing;
        }
    }

    /// Не вышло поднять микрофон или колонки.
    pub fn fail(self: *Probe, now_ns: u64, why: []const u8) void {
        self.state = .failed;
        self.since_ns = now_ns;
        self.why = why;
    }

    /// Колонки отзвучали.
    pub fn played(self: *Probe, now_ns: u64) void {
        self.state = .done;
        self.since_ns = now_ns;
    }

    pub fn forget(self: *Probe) void {
        self.* = .{};
    }

    /// Пик в децибелах относительно полной шкалы.
    pub fn peakDb(self: *const Probe) f32 {
        if (self.peak <= 0) return -100;
        return 20 * std.math.log10(self.peak);
    }

    /// Строка состояния для окна.
    pub fn status(self: *const Probe, buf: []u8, now_ns: u64) []const u8 {
        return switch (self.state) {
            .idle => "",
            .recording => blk: {
                const elapsed = now_ns -| self.since_ns;
                const left = (record_ns -| elapsed + std.time.ns_per_s - 1) / std.time.ns_per_s;
                break :blk lang.print(buf, "проба: говорите… ещё {d} с", .{left}) catch lang.t("проба: говорите…");
            },
            .playing => lang.print(buf, "проба: слушайте, что записалось (пик {d:.0} дБ)", .{self.peakDb()}) catch lang.t("проба: слушайте"),
            .done => lang.print(buf, "проба сыграна: пик {d:.0} дБ{s}", .{
                self.peakDb(),
                if (self.peak >= 0.99) lang.t(", ПЕРЕГРУЗ — отодвиньте микрофон") else "",
            }) catch lang.t("проба сыграна"),
            .failed => lang.print(buf, "проба не удалась: {s}", .{self.why}) catch lang.t("проба не удалась"),
        };
    }
};

// ---------------------------------------------------------------- тесты

const testing = std.testing;
const sec = std.time.ns_per_s;

test "проба идёт пять секунд и просит остановить микрофон ровно тогда" {
    var p = Probe{};
    p.start(100 * sec);
    try testing.expect(p.busy());
    try testing.expectEqual(Step.nothing, p.tick(100 * sec));
    try testing.expectEqual(Step.nothing, p.tick(104 * sec + sec / 2));
    try testing.expectEqual(Step.stop_recording, p.tick(105 * sec));
}

test "отсчёты считаются, пик — самый громкий" {
    var p = Probe{};
    p.start(0);
    p.feed(&[_]i16{ 0, 100, -3000, 200 });
    p.feed(&[_]i16{ 50, 50 });
    try testing.expectEqual(@as(usize, 6), p.samples);
    try testing.expectApproxEqAbs(@as(f32, 3000.0 / 32768.0), p.peak, 0.0001);
}

test "после записи: есть звук — слушаем, тишина или пусто — не удалась" {
    var p = Probe{};
    p.start(0);
    p.feed(&[_]i16{ 0, 5000, 0 });
    p.recorded(5 * sec);
    try testing.expectEqual(State.playing, p.state);

    var quiet = Probe{};
    quiet.start(0);
    quiet.feed(&[_]i16{ 1, -1, 2 });
    quiet.recorded(5 * sec);
    try testing.expectEqual(State.failed, quiet.state);
    try testing.expect(std.mem.indexOf(u8, quiet.why, "тишина") != null);

    var empty = Probe{};
    empty.start(0);
    empty.recorded(5 * sec);
    try testing.expectEqual(State.failed, empty.state);
}

test "итог висит восемь секунд, потом забывается" {
    var p = Probe{};
    p.start(0);
    p.feed(&[_]i16{ 0, 5000, 0 });
    p.recorded(5 * sec);
    p.played(9 * sec);
    try testing.expectEqual(State.done, p.state);
    try testing.expect(!p.busy());
    try testing.expectEqual(Step.nothing, p.tick(10 * sec));
    try testing.expectEqual(Step.forget, p.tick(17 * sec));
    p.forget();
    try testing.expectEqual(State.idle, p.state);
    var small: [8]u8 = undefined;
    try testing.expectEqualStrings("", p.status(&small, 0));
}

test "слова состояния: обратный отсчёт, пик, перегруз, причина" {
    var buf: [160]u8 = undefined;
    var p = Probe{};
    p.start(0);
    try testing.expectEqualStrings("проба: говорите… ещё 5 с", p.status(&buf, 0));
    try testing.expectEqualStrings("проба: говорите… ещё 3 с", p.status(&buf, 2 * sec + sec / 2));
    p.feed(&[_]i16{ 0, 16384 });
    p.recorded(5 * sec);
    try testing.expectEqualStrings("проба: слушайте, что записалось (пик -6 дБ)", p.status(&buf, 5 * sec));
    p.played(10 * sec);
    try testing.expectEqualStrings("проба сыграна: пик -6 дБ", p.status(&buf, 10 * sec));

    var loud = Probe{};
    loud.start(0);
    loud.feed(&[_]i16{32767});
    loud.recorded(5 * sec);
    loud.played(10 * sec);
    try testing.expect(std.mem.indexOf(u8, loud.status(&buf, 10 * sec), "ПЕРЕГРУЗ") != null);

    var bad = Probe{};
    bad.fail(0, "нет колонок");
    try testing.expectEqualStrings("проба не удалась: нет колонок", bad.status(&buf, 0));
}
