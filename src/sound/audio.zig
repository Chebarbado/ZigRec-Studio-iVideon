//! Звуковая дорожка записи: от микрофона до файла.
//!
//! Задача #40, первый шаг эпика #6. Здесь собрано всё, что нужно, чтобы звук
//! попал в mp4: захват в своём потоке, очередь между потоками, метки времени.
//!
//! Слой отдельный, потому что пользователей у него двое — окно и командная
//! строка. Требование цели: две формы на одном движке. Если бы каждая форма
//! сливала звук по-своему, они разошлись бы на первой же правке, и «в окне
//! звук есть, а из консоли нет» стало бы вопросом времени.
//!
//! **Чего здесь пока нет** и что остаётся в #20 и #21: системный звук через
//! loopback, несколько дорожек в одном файле и коррекция накапливающегося
//! дрейфа на длинной записи.
const std = @import("std");
const encode = @import("../file/encode.zig");
const mic = @import("mic.zig");
const track_mod = @import("track.zig");
const win32 = @import("../win32.zig");

pub const Source = enum { microphone, system_loopback };

pub const Format = struct {
    sample_rate: u32 = 48_000,
    channels: u8 = 2,
};

/// Подача звука в файл. Живёт ровно столько же, сколько запись.
pub const Feeder = struct {
    settings: encode.AudioSettings = .{},
    track: ?*track_mod.Track = null,
    capture: ?*mic.Capture = null,
    /// Звук просили, но он не поднялся. Причина — словами, для человека.
    failure: ?anyerror = null,
    /// Сколько отсчётов уже ушло в файл.
    written: u64 = 0,
    /// На сколько звук начался позже видео.
    offset_ns: u64 = 0,
    offset_known: bool = false,
    /// Начало записи по тем же часам, что у кадров.
    origin_ns: u64 = 0,
    buf: [8192]i16 = undefined,

    /// Поднять захват. Не возвращает ошибку: если микрофона нет, запись
    /// экрана всё равно должна состояться — просто без звука, и об этом
    /// говорится словами. Терять готовое видео из-за микрофона нельзя.
    pub fn start(self: *Feeder, allocator: std.mem.Allocator, origin_ns: u64) void {
        self.origin_ns = origin_ns;
        const t = allocator.create(track_mod.Track) catch |err| {
            self.failure = err;
            return;
        };
        t.* = .{};
        const m = allocator.create(mic.Capture) catch |err| {
            allocator.destroy(t);
            self.failure = err;
            return;
        };
        m.* = .{ .track = t, .track_rate = self.settings.sample_rate };

        if (m.start()) {
            // Ждём, пока поток захвата поднимется и скажет, что вышло.
            // Иначе мы заведём в файле звуковой поток, в который потом
            // нечего будет писать, и получится mp4 с немой дорожкой —
            // хуже, чем честный файл без дорожки вовсе.
            win32.c.Sleep(250);
            if (m.failure) |err| {
                self.failure = err;
                m.stop();
                allocator.destroy(m);
                allocator.destroy(t);
                return;
            }
            self.track = t;
            self.capture = m;
            return;
        } else |err| {
            self.failure = err;
            allocator.destroy(m);
            allocator.destroy(t);
        }
    }

    /// Пишется ли звук на самом деле.
    pub fn active(self: *const Feeder) bool {
        return self.track != null;
    }

    /// Метка времени очередного куска — от начала записи, тем же счётом,
    /// что и у кадров.
    fn timestampFor(self: *const Feeder, written: u64) u64 {
        return self.offset_ns + written * std.time.ns_per_s / @max(self.settings.sample_rate, 1);
    }

    /// Настройки для писателя: `null`, если звука не будет.
    pub fn encoderSettings(self: *const Feeder) ?encode.AudioSettings {
        return if (self.active()) self.settings else null;
    }

    /// Забрать накопленное и отдать в файл. Зовётся из потока записи.
    pub fn drain(self: *Feeder, enc: *encode.Writer) !void {
        const t = self.track orelse return;
        if (!self.offset_known) {
            const started = t.start_ns.load(.acquire);
            if (started == 0) return;
            // Один раз узнаём, на сколько звук начался позже видео. Дальше
            // время считается по числу отсчётов: у звука шаг известен точно,
            // и брать время из часов значило бы вносить дрожание там,
            // где его нет.
            self.offset_ns = started -| self.origin_ns;
            self.offset_known = true;
        }
        while (true) {
            const n = t.pop(&self.buf);
            if (n == 0) break;
            try enc.writeAudio(self.buf[0..n], self.timestampFor(self.written));
            self.written += n;
        }
    }

    /// Остановить захват и дописать хвост.
    ///
    /// Без этого запись кончалась бы тишиной: между последним кадром и
    /// остановкой в очереди ещё лежат отсчёты.
    pub fn finish(self: *Feeder, enc: *encode.Writer) !void {
        if (self.capture) |m| m.stop();
        try self.drain(enc);
    }

    pub fn deinit(self: *Feeder, allocator: std.mem.Allocator) void {
        if (self.capture) |m| {
            m.stop();
            allocator.destroy(m);
            self.capture = null;
        }
        if (self.track) |t| {
            allocator.destroy(t);
            self.track = null;
        }
    }

    /// Сколько секунд звука ушло в файл.
    pub fn seconds(self: *const Feeder) f64 {
        return @as(f64, @floatFromInt(self.written)) /
            @as(f64, @floatFromInt(@max(self.settings.sample_rate, 1)));
    }

    /// Сколько отсчётов потерялось из-за переполнения очереди.
    pub fn dropped(self: *const Feeder) u64 {
        const t = self.track orelse return 0;
        return t.dropped.load(.monotonic);
    }
};

test "умолчание звука: 48 кГц стерео" {
    const f = Format{};
    try std.testing.expectEqual(@as(u32, 48_000), f.sample_rate);
    try std.testing.expectEqual(@as(u8, 2), f.channels);
}

test "не поднявшийся звук не отменяет запись" {
    // Подача, которая не завелась, ведёт себя как «звука нет»: писателю
    // отдаётся null, и файл пишется без звуковой дорожки. Видео важнее.
    var f = Feeder{};
    f.failure = error.NoMicrophone;
    try std.testing.expect(!f.active());
    try std.testing.expect(f.encoderSettings() == null);
    try std.testing.expectEqual(@as(f64, 0), f.seconds());
    try std.testing.expectEqual(@as(u64, 0), f.dropped());
}

test "секунды считаются по числу отсчётов, а не по часам" {
    var f = Feeder{};
    f.written = 48_000;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), f.seconds(), 0.0001);
    f.written = 24_000;
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), f.seconds(), 0.0001);
}

test "метки времени идут ровным шагом от начала записи" {
    // Главное правило синхронности: время звука считается по числу отсчётов,
    // а не по часам. Часы дрожат, шаг звука — нет.
    var f = Feeder{};
    f.offset_ns = 0;
    try std.testing.expectEqual(@as(u64, 0), f.timestampFor(0));
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s), f.timestampFor(48_000));
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s / 2), f.timestampFor(24_000));
}

test "запоздавший звук встаёт в файле на своё место, а не в ноль" {
    // Микрофон поднимается не мгновенно. Если это время не учесть, звук
    // окажется раньше, чем был на самом деле, — и разъедется с картинкой
    // ровно на задержку запуска.
    var f = Feeder{};
    f.offset_ns = 40 * std.time.ns_per_ms;
    try std.testing.expectEqual(@as(u64, 40 * std.time.ns_per_ms), f.timestampFor(0));
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s + 40 * std.time.ns_per_ms), f.timestampFor(48_000));
}

test "шаг меток не накапливает ошибку на длинной записи" {
    // Десять минут при 48 кГц: метка последнего отсчёта должна совпасть
    // с десятью минутами с точностью до микросекунды, иначе к концу часовой
    // записи звук уедет на слышимое время.
    var f = Feeder{};
    const ten_minutes: u64 = 600;
    const samples = 48_000 * ten_minutes;
    const got = f.timestampFor(samples);
    const want = ten_minutes * std.time.ns_per_s;
    const off = if (got > want) got - want else want - got;
    try std.testing.expect(off < std.time.ns_per_us);
}
