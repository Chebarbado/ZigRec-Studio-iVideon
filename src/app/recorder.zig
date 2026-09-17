//! Движок записи: захват, курсор, кодирование, пауза.
//!
//! Задачи #18 и #19. Раньше цикл записи жил прямо в командной строке; окну он
//! нужен таким же, но управляемым извне и работающим в своём потоке, иначе
//! окно перестаёт отзываться на время записи.
//!
//! Пауза не рвёт файл. Кадры во время паузы просто не берутся, а время
//! простоя вычитается из меток: иначе в готовом видео получится дыра длиной
//! в паузу, где ничего не происходит.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const capture = @import("../capture/capture.zig");
const capture_types = @import("../capture/capture_types.zig");
const cursor = @import("../capture/cursor.zig");
const encode = @import("../file/encode.zig");
const source = @import("../capture/source.zig");
const mp4 = @import("../file/mp4.zig");
const audio = @import("../sound/audio.zig");
const errors = @import("../errors.zig");

pub const Rect = capture_types.Rect;

pub const State = enum {
    idle,
    recording,
    paused,
    stopping,

    pub fn label(self: State) []const u8 {
        return switch (self) {
            .idle => "готов",
            .recording => "идёт запись",
            .paused => "пауза",
            .stopping => "останавливаюсь",
        };
    }
};

pub const Settings = struct {
    fps: u32 = 30,
    preset: encode.Preset = .text_ui,
    bitrate_kbps: ?u32 = null,
    gop: u32 = 60,
    cursor: bool = true,
    clicks: bool = true,
    monitor: u32 = 0,
    /// Писать ли звук с микрофона в файл.
    sound: bool = false,
    /// Писать ли системный звук — то, что идёт в колонки.
    system_sound: bool = false,
};

/// Счёт времени с учётом пауз.
///
/// Вынесено отдельно и покрыто тестами: ошибка здесь не роняет программу,
/// а тихо портит все записи — время в файле разъезжается с тем, что было
/// на экране, и это замечают уже при монтаже.
pub const Clock = struct {
    started_ns: u64 = 0,
    paused_total_ns: u64 = 0,
    paused_at_ns: ?u64 = null,

    pub fn start(self: *Clock, now_ns: u64) void {
        self.* = .{ .started_ns = now_ns };
    }

    pub fn pause(self: *Clock, now_ns: u64) void {
        if (self.paused_at_ns == null) self.paused_at_ns = now_ns;
    }

    pub fn @"resume"(self: *Clock, now_ns: u64) void {
        if (self.paused_at_ns) |at| {
            self.paused_total_ns += now_ns -| at;
            self.paused_at_ns = null;
        }
    }

    pub fn isPaused(self: Clock) bool {
        return self.paused_at_ns != null;
    }

    /// Время кадра от начала записи, без учёта пауз.
    pub fn frameTime(self: Clock, now_ns: u64) u64 {
        return (now_ns -| self.started_ns) -| self.paused_total_ns;
    }

    /// Сколько записано по часам записи (то, что видит человек на таймере).
    pub fn elapsed(self: Clock, now_ns: u64) u64 {
        if (self.paused_at_ns) |at| return (at -| self.started_ns) -| self.paused_total_ns;
        return self.frameTime(now_ns);
    }
};

/// Имя файла по шаблону. `%d` — дата, `%t` — время, `%n` — порядковый номер.
pub fn buildName(buf: []u8, template: []const u8, stamp: DateTime, counter: u32) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        if (template[i] != '%' or i + 1 >= template.len) {
            try w.writeByte(template[i]);
            continue;
        }
        i += 1;
        switch (template[i]) {
            'd' => try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ stamp.year, stamp.month, stamp.day }),
            't' => try w.print("{d:0>2}-{d:0>2}-{d:0>2}", .{ stamp.hour, stamp.minute, stamp.second }),
            'n' => try w.print("{d:0>3}", .{counter}),
            '%' => try w.writeByte('%'),
            else => {
                try w.writeByte('%');
                try w.writeByte(template[i]);
            },
        }
    }
    return w.buffered();
}

pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,

    pub fn now() DateTime {
        if (builtin.os.tag != .windows) return .{ .year = 2026, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 };
        var st: win32.c.SYSTEMTIME = undefined;
        win32.c.GetLocalTime(&st);
        return .{
            .year = st.wYear,
            .month = @intCast(st.wMonth),
            .day = @intCast(st.wDay),
            .hour = @intCast(st.wHour),
            .minute = @intCast(st.wMinute),
            .second = @intCast(st.wSecond),
        };
    }
};

/// Что показывает окно, пока идёт запись.
pub const Progress = struct {
    state: State = .idle,
    frames: u64 = 0,
    elapsed_ns: u64 = 0,
    dropped: u64 = 0,
    /// Звуковых отсчётов ушло в файл.
    audio_samples: u64 = 0,
    /// Звук просили, но он не поднялся: текст причины лежит в `message`.
    sound_failed: bool = false,
    backend: capture.Backend = .auto,
    area: Rect = .{ .width = 0, .height = 0 },
    /// Заполняется, когда запись закончилась сама или с ошибкой.
    message: [256]u8 = @splat(0),
    message_len: usize = 0,

    pub fn message_text(self: *const Progress) []const u8 {
        return self.message[0..self.message_len];
    }
};

/// Запись в своём потоке. Окно только просит начать, приостановить и закончить.
///
/// Общее состояние — атомарные значения, без замка. Замок здесь был бы не
/// только лишним, но и неудобным: в Zig 0.16 `Io.Mutex` требует передавать
/// интерфейс ввода-вывода в каждый захват, а делить нам нужно всего несколько
/// счётчиков и два флага. Текст сообщения публикуется по правилу «сначала
/// байты, потом длина с release»: читатель, увидевший длину, увидит и байты.
pub const Recorder = struct {
    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,

    want_stop: std.atomic.Value(bool) = .init(false),
    want_pause: std.atomic.Value(bool) = .init(false),

    state_raw: std.atomic.Value(u8) = .init(@intFromEnum(State.idle)),
    frames: std.atomic.Value(u64) = .init(0),
    elapsed_ns: std.atomic.Value(u64) = .init(0),
    dropped: std.atomic.Value(u64) = .init(0),
    backend_raw: std.atomic.Value(u8) = .init(0),
    area_w: std.atomic.Value(u32) = .init(0),
    area_h: std.atomic.Value(u32) = .init(0),
    audio_samples: std.atomic.Value(u64) = .init(0),
    sound_failed: std.atomic.Value(bool) = .init(false),

    message: [256]u8 = @splat(0),
    message_len: std.atomic.Value(usize) = .init(0),

    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Recorder {
        return .{ .allocator = allocator };
    }

    pub fn state(self: *Recorder) State {
        return @enumFromInt(self.state_raw.load(.acquire));
    }

    fn setState(self: *Recorder, s: State) void {
        self.state_raw.store(@intFromEnum(s), .release);
    }

    pub fn isBusy(self: *Recorder) bool {
        return self.state() != .idle;
    }

    pub fn snapshot(self: *Recorder) Progress {
        var p = Progress{
            .state = self.state(),
            .frames = self.frames.load(.monotonic),
            .elapsed_ns = self.elapsed_ns.load(.monotonic),
            .dropped = self.dropped.load(.monotonic),
            .backend = @enumFromInt(self.backend_raw.load(.monotonic)),
            .area = .{ .width = self.area_w.load(.monotonic), .height = self.area_h.load(.monotonic) },
            .audio_samples = self.audio_samples.load(.monotonic),
            .sound_failed = self.sound_failed.load(.monotonic),
        };
        const n = self.message_len.load(.acquire);
        p.message_len = n;
        @memcpy(p.message[0..n], self.message[0..n]);
        return p;
    }

    pub fn start(self: *Recorder, path: []const u8, src: source.Source, settings: Settings) !void {
        if (self.isBusy()) return error.AlreadyRecording;
        if (path.len > self.path_buf.len) return error.PathTooLong;
        @memcpy(self.path_buf[0..path.len], path);
        self.path_len = path.len;

        self.want_stop.store(false, .release);
        self.want_pause.store(false, .release);
        self.frames.store(0, .monotonic);
        self.elapsed_ns.store(0, .monotonic);
        self.dropped.store(0, .monotonic);
        self.audio_samples.store(0, .monotonic);
        self.sound_failed.store(false, .monotonic);
        self.message_len.store(0, .release);
        self.setState(.recording);

        self.thread = std.Thread.spawn(.{}, run, .{ self, src, settings }) catch |err| {
            self.setState(.idle);
            return err;
        };
    }

    pub fn pause(self: *Recorder) void {
        // Переключает только окно, из одного потока, поэтому чтения и записи
        // достаточно: гонки за флаг тут нет.
        const now = self.want_pause.load(.acquire);
        self.want_pause.store(!now, .release);
    }

    pub fn stop(self: *Recorder) void {
        self.want_stop.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn setMessage(self: *Recorder, text: []const u8) void {
        const n = @min(text.len, self.message.len);
        @memcpy(self.message[0..n], text[0..n]);
        self.message_len.store(n, .release);
    }

    fn run(self: *Recorder, src: source.Source, settings: Settings) void {
        self.loop(src, settings) catch |err| {
            var buf: [128]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "запись прервана: {s}", .{@errorName(err)}) catch "запись прервана";
            self.setMessage(text);
        };
        self.setState(.idle);
    }

    fn loop(self: *Recorder, src: source.Source, settings: Settings) !void {
        const path = self.path_buf[0..self.path_len];

        var cap = try capture.Capturer.open(self.allocator, .{ .output = settings.monitor });
        defer cap.deinit();
        const screen = cap.frameSize();
        const area = try source.resolve(src, screen);

        // Звук поднимаем ДО создания файла: писатель принимает новые потоки
        // только до начала записи, и решить «пишем ли звук» задним числом
        // уже нельзя.
        var sound = audio.Feeder{
            .sources = .{ .microphone = settings.sound, .system = settings.system_sound },
        };
        defer sound.deinit(self.allocator);
        const origin_ns = win32.nowNs();
        if (settings.sound or settings.system_sound) sound.start(self.allocator, origin_ns);
        if (sound.failure != null or sound.system_failure != null) self.sound_failed.store(true, .monotonic);

        var enc = try encode.Writer.create(path, area.width, area.height, .{
            .fps = settings.fps,
            .preset = settings.preset,
            .bitrate_kbps = settings.bitrate_kbps,
            .gop = settings.gop,
            .audio = sound.encoderSettings(),
        });
        var finished = false;
        errdefer if (!finished) enc.abort();

        var painter = cursor.Painter.init(self.allocator, .{ .draw = settings.cursor, .clicks = settings.clicks });
        defer painter.deinit();
        const out_stride = area.width * 4;
        const canvas: ?[]u8 = if (settings.cursor)
            try self.allocator.alloc(u8, @as(usize, out_stride) * area.height)
        else
            null;
        defer if (canvas) |b| self.allocator.free(b);

        var clock = Clock{};
        clock.start(origin_ns);
        var current = area;

        self.backend_raw.store(@intFromEnum(cap.backend()), .monotonic);
        self.area_w.store(area.width, .monotonic);
        self.area_h.store(area.height, .monotonic);

        while (!self.want_stop.load(.acquire)) {
            const now = win32.nowNs();
            const want_pause = self.want_pause.load(.acquire);
            if (want_pause != clock.isPaused()) {
                if (want_pause) clock.pause(now) else clock.@"resume"(now);
                self.setState(if (want_pause) .paused else .recording);
            }
            if (clock.isPaused()) {
                win32.c.Sleep(30);
                continue;
            }

            const frame = (try cap.next(100)) orelse {
                self.elapsed_ns.store(clock.elapsed(win32.nowNs()), .monotonic);
                continue;
            };

            if (src.isWindow()) {
                if (source.resolve(src, screen)) |now_area| {
                    if (now_area.x != current.x or now_area.y != current.y) {
                        current.x = now_area.x;
                        current.y = now_area.y;
                        current = current.clampTo(screen.width, screen.height);
                        current.width = area.width;
                        current.height = area.height;
                    }
                } else |_| {}
            }

            const view = capture_types.cropView(frame.pixels, frame.stride, current);
            var pixels = view;
            var pixels_stride = frame.stride;
            if (canvas) |buf| {
                var row: u32 = 0;
                while (row < area.height) : (row += 1) {
                    const from = @as(usize, row) * frame.stride;
                    if (from + out_stride > view.len) break;
                    @memcpy(buf[@as(usize, row) * out_stride ..][0..out_stride], view[from..][0..out_stride]);
                }
                painter.poll(frame.timestamp_ns);
                painter.paint(
                    buf,
                    out_stride,
                    .{ .width = area.width, .height = area.height },
                    screen.x + current.x,
                    screen.y + current.y,
                    frame.timestamp_ns,
                );
                pixels = buf;
                pixels_stride = out_stride;
            }

            try enc.writeFrame(pixels, pixels_stride, clock.frameTime(frame.timestamp_ns));
            cap.release();

            try sound.drain(&enc);
            self.audio_samples.store(sound.written, .monotonic);

            _ = self.frames.fetchAdd(1, .monotonic);
            self.elapsed_ns.store(clock.elapsed(win32.nowNs()), .monotonic);
            self.dropped.store(cap.stats().dropped, .monotonic);
        }

        self.setState(.stopping);

        // Хвост звука: между последним кадром и остановкой ещё лежат отсчёты,
        // и без этого запись кончалась бы тишиной длиной в кадр.
        try sound.finish(&enc);
        self.audio_samples.store(sound.written, .monotonic);

        const summary = try enc.finish();
        finished = true;
        // moov в начало: своя перекладка файла, ей нужен интерфейс ввода-вывода.
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        _ = mp4.makeFastStart(threaded.io(), self.allocator, path) catch false;

        var sound_buf: [128]u8 = undefined;
        const sound_text: []const u8 = if (sound.failure) |err|
            std.fmt.bufPrint(&sound_buf, ", БЕЗ ЗВУКА: {s}", .{errors.short(err)}) catch ", без звука"
        else if (sound.active())
            std.fmt.bufPrint(&sound_buf, ", звук {d:.1} с", .{sound.seconds()}) catch ", со звуком"
        else
            "";

        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "готово: {d} кадров, {d:.1} с{s}, файл {s}", .{
            summary.frames,
            @as(f64, @floatFromInt(summary.duration_ns)) / @as(f64, std.time.ns_per_s),
            sound_text,
            std.fs.path.basename(path),
        }) catch "готово";
        self.setMessage(text);
    }
};

// ---------------------------------------------------------------- тесты

test "часы: без пауз время идёт как есть" {
    var clk = Clock{};
    clk.start(1000);
    try std.testing.expectEqual(@as(u64, 500), clk.frameTime(1500));
}

test "часы: пауза вычитается из времени кадров" {
    var clk = Clock{};
    clk.start(0);
    clk.pause(1000);
    clk.@"resume"(3000); // простояли 2000
    try std.testing.expectEqual(@as(u64, 2000), clk.frameTime(4000));
}

test "часы: во время паузы таймер стоит" {
    var clk = Clock{};
    clk.start(0);
    clk.pause(1000);
    try std.testing.expect(clk.isPaused());
    try std.testing.expectEqual(@as(u64, 1000), clk.elapsed(5000));
    clk.@"resume"(5000);
    try std.testing.expect(!clk.isPaused());
    try std.testing.expectEqual(@as(u64, 1000), clk.elapsed(5000));
}

test "часы: несколько пауз складываются" {
    var clk = Clock{};
    clk.start(0);
    clk.pause(100);
    clk.@"resume"(200);
    clk.pause(300);
    clk.@"resume"(500);
    // Простояли 100 + 200 = 300.
    try std.testing.expectEqual(@as(u64, 700), clk.frameTime(1000));
}

test "часы: повторная пауза не сдвигает точку" {
    var clk = Clock{};
    clk.start(0);
    clk.pause(100);
    clk.pause(200);
    clk.@"resume"(300);
    try std.testing.expectEqual(@as(u64, 200), clk.paused_total_ns);
}

test "имя файла по шаблону" {
    var buf: [128]u8 = undefined;
    const stamp = DateTime{ .year = 2026, .month = 9, .day = 10, .hour = 3, .minute = 7, .second = 5 };
    try std.testing.expectEqualStrings(
        "zigrec-2026-09-10-03-07-05.mp4",
        try buildName(&buf, "zigrec-%d-%t.mp4", stamp, 1),
    );
    try std.testing.expectEqualStrings(
        "снимок-007.mp4",
        try buildName(&buf, "снимок-%n.mp4", stamp, 7),
    );
    try std.testing.expectEqualStrings("100%.mp4", try buildName(&buf, "100%%.mp4", stamp, 1));
    try std.testing.expectEqualStrings("%z.mp4", try buildName(&buf, "%z.mp4", stamp, 1));
}

test "состояния подписаны по-русски" {
    try std.testing.expectEqualStrings("идёт запись", State.recording.label());
    try std.testing.expectEqualStrings("пауза", State.paused.label());
}
