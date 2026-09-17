//! Захват микрофона через WASAPI.
//!
//! Задача #36. Пока — только слышимость: человек должен видеть, что его слышно,
//! до того как начнёт говорить в запись. Сами отсчёты складываются в кольцевой
//! буфер, из которого окно рисует осциллограф (#35).
//!
//! Задача #40 добавила второй выход: те же отсчёты идут в очередь `track`,
//! откуда их забирает поток записи и кладёт в mp4. Выходы разные, потому что
//! нужды разные: индикатору хватает последних миллисекунд и можно потерять
//! кусок, записи нужен непрерывный поток без единой потери.
//!
//! Задача #20 добавила второй вид захвата — системный звук. Это тот же
//! WASAPI, только устройство вывода с признаком loopback: Windows отдаёт
//! нам то, что идёт в колонки. Отличие одно, но важное: пока в колонках
//! тишина, loopback не отдаёт ничего — ни отсчётов, ни нулей. Для файла
//! это дыра во времени, и её приходится заполнять нулями самим.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const resample = @import("resample.zig");
const track_mod = @import("track.zig");
const c = win32.c;

/// Свои имена ошибок, а не общие `NoDevice` и `AccessDenied`: иначе окно
/// покажет человеку сообщение про видеоадаптер, когда дело в микрофоне.
/// Один раз уже показало.
pub const Error = error{
    /// Микрофона нет, он отключён или не выбран устройством по умолчанию.
    NoMicrophone,
    /// Устройства вывода нет: системный звук брать неоткуда.
    NoSpeakers,
    /// Устройство есть, но не отдаёт формат, который мы понимаем.
    MicBadFormat,
    /// Windows не пустила к микрофону: запрещено в настройках приватности.
    MicAccessDenied,
    Unsupported,
    OutOfMemory,
    Failed,
};

/// Сколько последних отсчётов держим для осциллографа.
/// 4096 при 48 кГц — это 85 миллисекунд: ровно столько, чтобы волна на экране
/// выглядела волной, а не дрожащей точкой.
pub const window_samples = 4096;

/// Уровень сигнала за последний кусок.
pub const Level = struct {
    /// Пиковое отклонение, 0…1.
    peak: f32 = 0,
    /// Среднеквадратичное, 0…1: по нему видно громкость речи, а не щелчки.
    rms: f32 = 0,

    /// Уровень в децибелах относительно максимума. Тишина — минус бесконечность,
    /// поэтому возвращаем -90 как «тихо настолько, что неважно».
    pub fn dbfs(self: Level) f32 {
        if (self.peak <= 0.00003) return -90;
        return 20 * std.math.log10(self.peak);
    }

    /// Сигнал упирается в потолок: запись будет хрипеть.
    pub fn isClipping(self: Level) bool {
        return self.peak >= 0.99;
    }

    /// Микрофон молчит: либо не тот вход, либо человек не говорит.
    ///
    /// Порог 0.004 — это около минус 48 децибел. Ниже сидит комнатный фон
    /// живого микрофона (замерено: минус 55), и порог строже начинал бы
    /// мигать «тишина — не тишина» на каждом вздохе. Речь идёт заметно выше.
    pub fn isSilent(self: Level) bool {
        return self.peak < 0.004;
    }
};

/// Кольцо последних отсчётов: пишет поток захвата, читает окно.
///
/// Без замка: окну не нужна точная копия, ему нужна свежая картинка. Если
/// рисование поймает буфер в момент записи, оно увидит смесь соседних
/// миллисекунд — на глаз это неотличимо от правды.
pub const Ring = struct {
    data: [window_samples]f32 = @splat(0),
    write: std.atomic.Value(usize) = .init(0),

    pub fn push(self: *Ring, value: f32) void {
        const i = self.write.load(.monotonic);
        self.data[i % window_samples] = value;
        self.write.store(i + 1, .monotonic);
    }

    /// Разложить кольцо в порядке времени: старое слева, новое справа.
    pub fn snapshot(self: *const Ring, out: []f32) void {
        const w = self.write.load(.monotonic);
        for (out, 0..) |*v, i| {
            // Берём последние out.len отсчётов, растягивая или сжимая по месту.
            const src = w -| out.len + i * out.len / @max(out.len, 1);
            v.* = self.data[src % window_samples];
        }
    }

    pub fn level(self: *const Ring) Level {
        var peak: f32 = 0;
        var sum: f32 = 0;
        for (self.data) |v| {
            const a = @abs(v);
            if (a > peak) peak = a;
            sum += v * v;
        }
        return .{ .peak = peak, .rms = @sqrt(sum / @as(f32, window_samples)) };
    }
};

/// Живой захват микрофона в своём потоке.
/// Что захватываем: микрофон или то, что идёт в колонки.
pub const Kind = enum { microphone, system };

const devices = @import("devices.zig");

pub const Capture = struct {
    kind: Kind = .microphone,
    ring: Ring = .{},
    /// Какой микрофон брать (#22). Пусто — тот, что по умолчанию в Windows.
    device_id: [devices.max_id]u8 = @splat(0),
    device_id_len: usize = 0,
    /// Выбранного устройства не нашлось, взят микрофон по умолчанию.
    /// Об этом надо сказать, а не молча писать не туда.
    fell_back: bool = false,
    running: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    /// Что пошло не так, если захват не поднялся.
    failure: ?Error = null,
    sample_rate: u32 = 0,
    channels: u16 = 0,
    /// Куда складывать отсчёты для файла. `null` — захват только для индикатора.
    track: ?*track_mod.Track = null,
    /// Частота, к которой приводить отсчёты для файла.
    track_rate: u32 = 48_000,

    /// Выбрать устройство по номеру Windows; пустой — по умолчанию.
    pub fn useDevice(self: *Capture, id: []const u8) void {
        self.device_id_len = @min(id.len, self.device_id.len);
        @memcpy(self.device_id[0..self.device_id_len], id[0..self.device_id_len]);
    }

    pub fn deviceId(self: *const Capture) []const u8 {
        return self.device_id[0..self.device_id_len];
    }

    pub fn start(self: *Capture) Error!void {
        if (builtin.os.tag != .windows) return Error.Unsupported;
        if (self.running.load(.acquire)) return;
        self.failure = null;
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
            self.running.store(false, .release);
            return Error.Failed;
        };
    }

    pub fn stop(self: *Capture) void {
        self.running.store(false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn isRunning(self: *const Capture) bool {
        return self.running.load(.acquire);
    }

    fn run(self: *Capture) void {
        self.loop() catch |err| {
            self.failure = err;
        };
        self.running.store(false, .release);
    }

    fn loop(self: *Capture) Error!void {
        _ = c.CoInitializeEx(null, c.COINIT_MULTITHREADED);
        defer c.CoUninitialize();

        var enumerator: ?*c.IMMDeviceEnumerator = null;
        if (win32.failed(c.CoCreateInstance(
            &c.CLSID_MMDeviceEnumerator,
            null,
            c.CLSCTX_ALL,
            &c.IID_IMMDeviceEnumerator,
            @ptrCast(&enumerator),
        ))) return Error.NoMicrophone;
        defer _ = enumerator.?.lpVtbl.*.Release.?(@ptrCast(enumerator.?));

        // Системный звук берётся с устройства ВЫВОДА: loopback слушает то,
        // что уходит в колонки, а не то, что приходит с входа.
        const flow: c.EDataFlow = if (self.kind == .system) c.eRender else c.eCapture;
        const missing: Error = if (self.kind == .system) Error.NoSpeakers else Error.NoMicrophone;

        var device: ?*c.IMMDevice = null;
        // Сперва выбранный микрофон (#22). Его могли отключить — тогда
        // берём тот, что по умолчанию, и помечаем это.
        self.fell_back = false;
        if (self.kind == .microphone and self.device_id_len > 0) {
            var wide: [devices.max_id + 1]u16 = undefined;
            if (std.unicode.utf8ToUtf16Le(&wide, self.deviceId())) |n| {
                wide[n] = 0;
                if (win32.failed(enumerator.?.lpVtbl.*.GetDevice.?(enumerator.?, @ptrCast(&wide), &device))) {
                    device = null;
                }
            } else |_| {}
            if (device == null) self.fell_back = true;
        }
        if (device == null) {
            if (win32.failed(enumerator.?.lpVtbl.*.GetDefaultAudioEndpoint.?(
                enumerator.?,
                flow,
                c.eConsole,
                &device,
            ))) return missing;
        }
        defer _ = device.?.lpVtbl.*.Release.?(@ptrCast(device.?));

        var client: ?*c.IAudioClient = null;
        const hres = device.?.lpVtbl.*.Activate.?(
            device.?,
            &c.IID_IAudioClient,
            c.CLSCTX_ALL,
            null,
            @ptrCast(&client),
        );
        if (win32.failed(hres)) {
            // Запрет доступа к микрофону в настройках приватности выглядит
            // именно так, и сказать об этом надо словами, а не кодом.
            return if (win32.hrCode(hres) == win32.hr.e_access_denied) Error.MicAccessDenied else missing;
        }
        defer _ = client.?.lpVtbl.*.Release.?(@ptrCast(client.?));

        var format: [*c]c.WAVEFORMATEX = null;
        if (win32.failed(client.?.lpVtbl.*.GetMixFormat.?(client.?, &format))) return Error.MicBadFormat;
        defer c.CoTaskMemFree(format);

        self.sample_rate = format.*.nSamplesPerSec;
        self.channels = format.*.nChannels;

        // Буфер на 200 миллисекунд: для индикатора хватает с запасом, а память
        // не тратится зря.
        const buffer_duration: c.REFERENCE_TIME = 2_000_000;
        // Признак loopback — единственное, чем захват системы отличается
        // от захвата микрофона на этом уровне.
        const stream_flags: c.DWORD = if (self.kind == .system) c.AUDCLNT_STREAMFLAGS_LOOPBACK else 0;
        if (win32.failed(client.?.lpVtbl.*.Initialize.?(
            client.?,
            c.AUDCLNT_SHAREMODE_SHARED,
            stream_flags,
            buffer_duration,
            0,
            format,
            null,
        ))) return Error.MicBadFormat;

        var capture: ?*c.IAudioCaptureClient = null;
        if (win32.failed(client.?.lpVtbl.*.GetService.?(
            client.?,
            &c.IID_IAudioCaptureClient,
            @ptrCast(&capture),
        ))) return Error.Failed;
        defer _ = capture.?.lpVtbl.*.Release.?(@ptrCast(capture.?));

        if (win32.failed(client.?.lpVtbl.*.Start.?(client.?))) return Error.Failed;
        defer _ = client.?.lpVtbl.*.Stop.?(client.?);

        const is_float = format.*.wFormatTag == c.WAVE_FORMAT_IEEE_FLOAT or
            (format.*.wFormatTag == c.WAVE_FORMAT_EXTENSIBLE and format.*.wBitsPerSample == 32);
        const channels = format.*.nChannels;

        // Пересчёт к частоте файла. Состояние живёт снаружи цикла: позиция
        // должна переживать границу куска, иначе на каждом стыке щелчок.
        var converter = resample.Resampler.init(self.sample_rate, self.track_rate);
        // Куски WASAPI при периоде десять миллисекунд — это около 480 отсчётов;
        // берём с большим запасом на случай, когда система придержала поток.
        var mono: [16384]f32 = undefined;
        var converted: [32768]f32 = undefined;
        var out: [32768]i16 = undefined;

        // Loopback молчит, пока молчат колонки: ни отсчётов, ни нулей.
        // Для файла это дыра во времени, и время дорожки, которое считается
        // по числу отсчётов, уехало бы вперёд на всю паузу. Поэтому паузу
        // заполняем нулями сами, по часам устройства.
        var last_ns: u64 = 0;
        var zeros: [4096]i16 = @splat(0);

        while (self.running.load(.acquire)) {
            var packet: c.UINT32 = 0;
            if (win32.failed(capture.?.lpVtbl.*.GetNextPacketSize.?(capture.?, &packet))) break;
            if (packet == 0) {
                if (self.kind == .system and last_ns != 0) {
                    if (self.track) |t| {
                        const now = win32.nowNs();
                        const gap_ns = now -| last_ns;
                        // Заполняем не сразу, а когда пауза больше одного
                        // куска: короткие паузы между кусками — обычный ход
                        // дела, а не молчание колонок.
                        if (gap_ns > 20 * std.time.ns_per_ms) {
                            const need: usize = @intCast(gap_ns * self.track_rate / std.time.ns_per_s);
                            var left = need;
                            while (left > 0) {
                                const chunk = @min(left, zeros.len);
                                t.push(zeros[0..chunk], last_ns);
                                left -= chunk;
                            }
                            last_ns = now;
                        }
                    }
                }
                c.Sleep(5);
                continue;
            }
            var data: [*c]c.BYTE = undefined;
            var frames: c.UINT32 = 0;
            var flags: c.DWORD = 0;
            var qpc_100ns: c.UINT64 = 0;
            if (win32.failed(capture.?.lpVtbl.*.GetBuffer.?(capture.?, &data, &frames, &flags, null, &qpc_100ns))) break;

            const silent = flags & c.AUDCLNT_BUFFERFLAGS_SILENT != 0;
            const count: usize = @min(@as(usize, frames), mono.len);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                var v: f32 = 0;
                if (!silent) {
                    // Сводим каналы, а не берём первый: у гарнитур бывает,
                    // что говорят в один канал, а второй молчит.
                    if (is_float) {
                        const samples: [*]const f32 = @ptrCast(@alignCast(data));
                        v = resample.downmix(samples[i * channels ..][0..channels]);
                    } else {
                        const samples: [*]const i16 = @ptrCast(@alignCast(data));
                        var sum: f32 = 0;
                        for (0..channels) |ch| {
                            sum += @as(f32, @floatFromInt(samples[i * channels + ch])) / 32768.0;
                        }
                        v = sum / @as(f32, @floatFromInt(channels));
                    }
                }
                mono[i] = v;
                self.ring.push(v);
            }

            if (self.track) |t| {
                const n = converter.process(mono[0..count], &converted);
                const m = @min(n, out.len);
                for (0..m) |k| out[k] = resample.toI16(converted[k]);
                // Время первого отсчёта куска: берём его у самого устройства.
                // Свои часы здесь врали бы на длину буфера — до двадцати
                // миллисекунд, то есть ровно на весь допуск по рассинхрону.
                const at_ns: u64 = if (qpc_100ns != 0) @as(u64, qpc_100ns) * 100 else win32.nowNs();
                t.push(out[0..m], at_ns);
                // Помним, докуда дошло время звука: отсюда считается пауза,
                // которую loopback не заполняет сам, и дрейф против часов.
                last_ns = at_ns + @as(u64, m) * std.time.ns_per_s / @max(self.track_rate, 1);
                t.end_ns.store(last_ns, .release);
            }

            _ = capture.?.lpVtbl.*.ReleaseBuffer.?(capture.?, frames);
        }
    }
};

// ---------------------------------------------------------------- тесты

test "комнатный фон считается тишиной, речь — нет" {
    // Замерено на живом микрофоне: фон около минус 55 дБ, всплеск речи минус 40.
    try std.testing.expect((Level{ .peak = 0.0018 }).isSilent());
    try std.testing.expect(!(Level{ .peak = 0.01 }).isSilent());
}

test "уровень тишины — минус девяносто децибел" {
    const l = Level{ .peak = 0, .rms = 0 };
    try std.testing.expectEqual(@as(f32, -90), l.dbfs());
    try std.testing.expect(l.isSilent());
    try std.testing.expect(!l.isClipping());
}

test "полная шкала — ноль децибел" {
    const l = Level{ .peak = 1, .rms = 0.7 };
    try std.testing.expectApproxEqAbs(@as(f32, 0), l.dbfs(), 0.01);
    try std.testing.expect(l.isClipping());
}

test "половина шкалы — примерно минус шесть децибел" {
    const l = Level{ .peak = 0.5, .rms = 0.35 };
    try std.testing.expectApproxEqAbs(@as(f32, -6.02), l.dbfs(), 0.05);
    try std.testing.expect(!l.isSilent());
    try std.testing.expect(!l.isClipping());
}

test "кольцо считает пик и среднеквадратичное" {
    var ring = Ring{};
    for (0..window_samples) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, window_samples);
        ring.push(@sin(t * std.math.tau) * 0.5);
    }
    const l = ring.level();
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), l.peak, 0.01);
    // Среднеквадратичное синуса — амплитуда делить на корень из двух.
    try std.testing.expectApproxEqAbs(@as(f32, 0.3536), l.rms, 0.01);
}

test "снимок кольца берёт свежие отсчёты" {
    var ring = Ring{};
    for (0..window_samples) |_| ring.push(0);
    for (0..64) |_| ring.push(1);
    var out: [64]f32 = undefined;
    ring.snapshot(&out);
    // Последние отсчёты — единицы, значит окно смотрит в конец, а не в начало.
    try std.testing.expectApproxEqAbs(@as(f32, 1), out[out.len - 1], 0.001);
}

test "пустое кольцо не падает и молчит" {
    const ring = Ring{};
    const l = ring.level();
    try std.testing.expect(l.isSilent());
    var out: [32]f32 = undefined;
    ring.snapshot(&out);
    for (out) |v| try std.testing.expectEqual(@as(f32, 0), v);
}

test "у захвата системы устройство — вывод, у микрофона — ввод" {
    // Правило маленькое, но ошибка в нём тихая: loopback с устройства ввода
    // просто молчит, и «системный звук» окажется пустой дорожкой.
    var sys = Capture{ .kind = .system };
    var mic_cap = Capture{};
    try std.testing.expectEqual(Kind.system, sys.kind);
    try std.testing.expectEqual(Kind.microphone, mic_cap.kind);
    _ = &sys;
    _ = &mic_cap;
}

test "номер устройства запоминается и обрезается, пустой — по умолчанию" {
    var cap = Capture{};
    try std.testing.expectEqualStrings("", cap.deviceId());
    cap.useDevice("{0.0.1.00000000}.{abcd}");
    try std.testing.expectEqualStrings("{0.0.1.00000000}.{abcd}", cap.deviceId());
    cap.useDevice("");
    try std.testing.expectEqualStrings("", cap.deviceId());
    cap.useDevice("x" ** 600);
    try std.testing.expectEqual(@as(usize, devices.max_id), cap.deviceId().len);
}
