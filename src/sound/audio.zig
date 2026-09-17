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
//! Задача #20 добавила второй источник — системный звук. Оба источника идут
//! в одну дорожку: каждый со своим временем старта по общим часам, и тот,
//! кто начался позже, получает тишину спереди. Сведение — в `blend`, здесь
//! только очереди и порядок вызовов.
//!
//! **Чего здесь пока нет** и что остаётся в #21: несколько дорожек в одном
//! файле и коррекция накапливающегося дрейфа на длинной записи.
const std = @import("std");
const encode = @import("../file/encode.zig");
const mic = @import("mic.zig");
const track_mod = @import("track.zig");
const blend = @import("blend.zig");
const drift = @import("drift.zig");
const win32 = @import("../win32.zig");

pub const Source = enum { microphone, system_loopback };

pub const Format = struct {
    sample_rate: u32 = 48_000,
    channels: u8 = 2,
};

/// Какие источники писать.
pub const Sources = struct {
    microphone: bool = true,
    system: bool = false,
    /// Врозь: микрофон и система — две дорожки в файле, а не одна сведённая.
    /// Так их можно потом разводить в редакторе и в плеере переключать.
    separate: bool = false,
};

/// Подача звука в файл. Живёт ровно столько же, сколько запись.
pub const Feeder = struct {
    settings: encode.AudioSettings = .{},
    sources: Sources = .{},
    track: ?*track_mod.Track = null,
    capture: ?*mic.Capture = null,
    /// Какой микрофон брать: номер устройства у Windows, пусто — по умолчанию.
    mic_device: []const u8 = "",
    /// Второй источник — системный звук. `null`, если его не просили
    /// или он не поднялся.
    system_track: ?*track_mod.Track = null,
    system_capture: ?*mic.Capture = null,
    /// Тишина спереди у того, кто начался позже.
    pad_mic: blend.Padded = .{},
    pad_sys: blend.Padded = .{},
    /// Известна ли разница стартов. До неё сводить нечего.
    pads_known: bool = false,
    /// Вторая дорожка — когда пишем врозь: своё смещение и свой счёт.
    written2: u64 = 0,
    offset2_ns: u64 = 0,
    offset2_known: bool = false,
    /// Правка дрейфа: часы устройства против счёта отсчётов (#21).
    corrector: drift.Corrector = .{},
    /// Сколько отсчётов вставлено и выброшено ради дрейфа — для отчёта.
    drift_inserted: u64 = 0,
    drift_dropped: u64 = 0,
    /// Звук просили, но он не поднялся. Причина — словами, для человека.
    failure: ?anyerror = null,
    /// Системный звук просили, но он не поднялся. Отдельно от микрофона:
    /// один источник может отвалиться, а второй — писаться.
    system_failure: ?anyerror = null,
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
        if (self.sources.microphone) {
            self.startOne(allocator, .microphone);
        }
        if (self.sources.system) {
            self.startOne(allocator, .system);
        }
    }

    /// Поднять один источник. Не возвращает ошибку: если его нет, запись
    /// всё равно должна состояться — без него, и об этом говорится словами.
    fn startOne(self: *Feeder, allocator: std.mem.Allocator, kind: mic.Kind) void {
        const t = allocator.create(track_mod.Track) catch |err| {
            self.noteFailure(kind, err);
            return;
        };
        t.* = .{};
        const m = allocator.create(mic.Capture) catch |err| {
            allocator.destroy(t);
            self.noteFailure(kind, err);
            return;
        };
        m.* = .{ .kind = kind, .track = t, .track_rate = self.settings.sample_rate };
        if (kind == .microphone) m.useDevice(self.mic_device);

        if (m.start()) {
            // Ждём, пока поток захвата поднимется и скажет, что вышло.
            // Иначе мы заведём в файле звуковой поток, в который потом
            // нечего будет писать, и получится mp4 с немой дорожкой —
            // хуже, чем честный файл без дорожки вовсе.
            win32.c.Sleep(250);
            if (m.failure) |err| {
                self.noteFailure(kind, err);
                m.stop();
                allocator.destroy(m);
                allocator.destroy(t);
                return;
            }
            switch (kind) {
                .microphone => {
                    self.track = t;
                    self.capture = m;
                },
                .system => {
                    self.system_track = t;
                    self.system_capture = m;
                },
            }
            return;
        } else |err| {
            self.noteFailure(kind, err);
            allocator.destroy(m);
            allocator.destroy(t);
        }
    }

    fn noteFailure(self: *Feeder, kind: mic.Kind, err: anyerror) void {
        switch (kind) {
            .microphone => self.failure = err,
            .system => self.system_failure = err,
        }
    }

    /// Пишется ли звук на самом деле — хоть с одного источника.
    pub fn active(self: *const Feeder) bool {
        return self.track != null or self.system_track != null;
    }

    /// Пишется ли системный звук.
    pub fn systemActive(self: *const Feeder) bool {
        return self.system_track != null;
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

    /// Настройки второй дорожки: только когда оба источника живы и их
    /// просили писать врозь.
    pub fn encoderSettings2(self: *const Feeder) ?encode.AudioSettings {
        return if (self.writesSeparately()) self.settings else null;
    }

    /// Пишем ли два источника двумя дорожками.
    pub fn writesSeparately(self: *const Feeder) bool {
        return self.sources.separate and self.track != null and self.system_track != null;
    }

    /// Время второй дорожки — со своим смещением.
    fn timestampFor2(self: *const Feeder, written: u64) u64 {
        return self.offset2_ns + written * std.time.ns_per_s / @max(self.settings.sample_rate, 1);
    }

    /// Забрать накопленное и отдать в файл. Зовётся из потока записи.
    pub fn drain(self: *Feeder, enc: *encode.Writer) !void {
        // Два источника врозь — две дорожки; два вместе — сводим; один —
        // отдаём как есть.
        if (self.writesSeparately()) {
            try self.drainSeparate(enc);
            return;
        }
        if (self.track != null and self.system_track != null) return self.drainBoth(enc);
        const t = self.track orelse self.system_track orelse return;
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
        try self.correctDrift(t, enc, .first);
        while (true) {
            const n = t.pop(&self.buf);
            if (n == 0) break;
            try enc.writeAudio(self.buf[0..n], self.timestampFor(self.written));
            self.written += n;
        }
    }

    /// Две дорожки: микрофон в первую, система во вторую, каждая со своим
    /// смещением от начала записи. Сводить нечего — сводит потом редактор.
    fn drainSeparate(self: *Feeder, enc: *encode.Writer) !void {
        const a = self.track.?;
        const b = self.system_track.?;
        if (!self.offset_known) {
            const started = a.start_ns.load(.acquire);
            if (started != 0) {
                self.offset_ns = started -| self.origin_ns;
                self.offset_known = true;
            }
        }
        if (!self.offset2_known) {
            const started = b.start_ns.load(.acquire);
            if (started != 0) {
                self.offset2_ns = started -| self.origin_ns;
                self.offset2_known = true;
            }
        }
        if (self.offset_known) {
            try self.correctDrift(a, enc, .first);
            while (true) {
                const n = a.pop(&self.buf);
                if (n == 0) break;
                try enc.writeAudioTo(.first, self.buf[0..n], self.timestampFor(self.written));
                self.written += n;
            }
        }
        if (self.offset2_known) {
            try self.correctDrift(b, enc, .second);
            while (true) {
                const n = b.pop(&self.buf);
                if (n == 0) break;
                try enc.writeAudioTo(.second, self.buf[0..n], self.timestampFor2(self.written2));
                self.written2 += n;
            }
        }
    }

    /// Поправить дрейф одной дорожки перед очередным сливом.
    ///
    /// Сравниваем время по отсчётам с временем устройства. Отстали —
    /// пишем тишину, обогнали — выбрасываем из очереди. Понемногу за раз:
    /// правило шага — в `drift`, и оно проверено тестами на десяти минутах.
    fn correctDrift(self: *Feeder, t: *track_mod.Track, enc: *encode.Writer, which: encode.Writer.Which) !void {
        const elapsed = t.deviceElapsedNs();
        if (elapsed == 0) return;
        const written = if (which == .first) self.written else self.written2;
        // Сравниваем с тем, что уже забрали ИЗ очереди, плюс то, что в ней
        // ещё лежит: оно тоже «насчитано» устройством.
        const counted = written + t.available();
        const a = self.corrector.adjust(counted, self.settings.sample_rate, elapsed);
        if (a.insert > 0) {
            var zeros: [64]i16 = @splat(0);
            const n = @min(a.insert, zeros.len);
            const ts = if (which == .first) self.timestampFor(self.written) else self.timestampFor2(self.written2);
            try enc.writeAudioTo(which, zeros[0..n], ts);
            if (which == .first) self.written += n else self.written2 += n;
            self.drift_inserted += n;
        } else if (a.drop > 0) {
            var bin: [64]i16 = undefined;
            const n = t.pop(bin[0..@min(a.drop, bin.len)]);
            self.drift_dropped += n;
        }
    }

    /// Свести микрофон и систему в одну дорожку.
    ///
    /// Ждём, пока оба источника отдадут первый кусок: только тогда известно,
    /// кто начался позже и на сколько. Сводить раньше значило бы гадать.
    fn drainBoth(self: *Feeder, enc: *encode.Writer) !void {
        const a = self.track.?;
        const b = self.system_track.?;
        if (!self.pads_known) {
            const sa = a.start_ns.load(.acquire);
            const sb = b.start_ns.load(.acquire);
            if (sa == 0 or sb == 0) return;
            const pad = blend.padFor(sa, sb, self.settings.sample_rate);
            self.pad_mic = .{ .pad_left = pad.a };
            self.pad_sys = .{ .pad_left = pad.b };
            self.pads_known = true;
            // Дорожка начинается с того, кто начался раньше.
            self.offset_ns = @min(sa, sb) -| self.origin_ns;
            self.offset_known = true;
        }

        var mic_buf: [4096]i16 = undefined;
        var sys_buf: [4096]i16 = undefined;
        while (true) {
            const can = @min(
                @min(self.pad_mic.ready(a.available()), self.pad_sys.ready(b.available())),
                mic_buf.len,
            );
            if (can == 0) break;

            takeInto(a, &self.pad_mic, mic_buf[0..can]);
            takeInto(b, &self.pad_sys, sys_buf[0..can]);
            const n = blend.mix(mic_buf[0..can], sys_buf[0..can], &self.buf);
            try enc.writeAudio(self.buf[0..n], self.timestampFor(self.written));
            self.written += n;
        }
    }

    /// Взять ровно `out.len` отсчётов: сперва тишину спереди, потом очередь.
    fn takeInto(t: *track_mod.Track, pad: *blend.Padded, out: []i16) void {
        const parts = pad.split(out.len);
        @memset(out[0..parts.zeros], 0);
        const got = t.pop(out[parts.zeros..]);
        // Очередь обещала столько по `available`, но на всякий случай
        // добиваем нулями: недостача лучше мусора.
        if (got < parts.real) @memset(out[parts.zeros + got ..], 0);
    }

    /// Остановить захват и дописать хвост.
    ///
    /// Без этого запись кончалась бы тишиной: между последним кадром и
    /// остановкой в очереди ещё лежат отсчёты.
    pub fn finish(self: *Feeder, enc: *encode.Writer) !void {
        if (self.capture) |m| m.stop();
        if (self.system_capture) |m| m.stop();
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
        if (self.system_capture) |m| {
            m.stop();
            allocator.destroy(m);
            self.system_capture = null;
        }
        if (self.system_track) |t| {
            allocator.destroy(t);
            self.system_track = null;
        }
    }

    /// Сколько секунд ушло во вторую дорожку.
    pub fn seconds2(self: *const Feeder) f64 {
        return @as(f64, @floatFromInt(self.written2)) /
            @as(f64, @floatFromInt(@max(self.settings.sample_rate, 1)));
    }

    /// Сколько секунд звука ушло в файл.
    pub fn seconds(self: *const Feeder) f64 {
        return @as(f64, @floatFromInt(self.written)) /
            @as(f64, @floatFromInt(@max(self.settings.sample_rate, 1)));
    }

    /// Сколько отсчётов потерялось из-за переполнения очереди — с обоих
    /// источников: потеря есть потеря, откуда бы ни пришла.
    pub fn dropped(self: *const Feeder) u64 {
        var n: u64 = 0;
        if (self.track) |t| n += t.dropped.load(.monotonic);
        if (self.system_track) |t| n += t.dropped.load(.monotonic);
        return n;
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

test "по умолчанию пишется микрофон, а система — только по просьбе" {
    const s = Sources{};
    try std.testing.expect(s.microphone);
    try std.testing.expect(!s.system);
}

test "отвалившийся системный звук не отменяет микрофон, и наоборот" {
    // Один источник может не подняться, второй — писаться. Запись должна
    // состояться с тем, что есть, и сказать словами, чего нет.
    var f = Feeder{};
    f.system_failure = error.NoSpeakers;
    var t = @import("track.zig").Track{};
    f.track = &t;
    try std.testing.expect(f.active());
    try std.testing.expect(!f.systemActive());
    try std.testing.expect(f.encoderSettings() != null);
    f.track = null;
    try std.testing.expect(!f.active());
}

test "врозь пишется только когда живы оба источника" {
    var f = Feeder{ .sources = .{ .system = true, .separate = true } };
    try std.testing.expect(!f.writesSeparately());
    try std.testing.expect(f.encoderSettings2() == null);

    var a = @import("track.zig").Track{};
    var b = @import("track.zig").Track{};
    f.track = &a;
    f.system_track = &b;
    try std.testing.expect(f.writesSeparately());
    try std.testing.expect(f.encoderSettings2() != null);

    // Без просьбы «врозь» те же два источника сводятся в одну дорожку.
    f.sources.separate = false;
    try std.testing.expect(!f.writesSeparately());
    try std.testing.expect(f.encoderSettings2() == null);
}

test "вторая дорожка считает своё время от своего старта" {
    var f = Feeder{};
    f.offset2_ns = 70 * std.time.ns_per_ms;
    try std.testing.expectEqual(@as(u64, 70 * std.time.ns_per_ms), f.timestampFor2(0));
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s + 70 * std.time.ns_per_ms), f.timestampFor2(48_000));
    f.written2 = 24_000;
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), f.seconds2(), 0.0001);
}
