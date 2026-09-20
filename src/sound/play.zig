//! Вывод звука в колонки через WASAPI — для стендов.
//!
//! Задача #20. Захват системного звука нечем проверить, если ничего
//! не играет: loopback молчит вместе с колонками. Стенду нужен известный
//! сигнал, который он сам и проиграет, — тогда пойманное можно сверить
//! с задуманным числом, а не на слух.
//!
//! Это не плеер для человека: ни громкости, ни выбора устройства, ни пауз.
//! Ровно столько, сколько нужно, чтобы отдать план всплесков в устройство
//! вывода по умолчанию и дождаться конца.
const std = @import("std");
const lang = @import("../lang.zig");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const tone = @import("tone.zig");
const c = win32.c;

pub const Error = error{
    /// Устройства вывода нет.
    NoSpeakers,
    /// Устройство есть, но формат его не наш.
    BadFormat,
    Unsupported,
    Failed,
};

/// Откуда брать отсчёты: план всплесков стенда или записанные отсчёты.
pub const Source = union(enum) {
    plan: tone.Plan,
    samples: struct { data: []const i16, rate: u32 },

    /// Отсчёт номер `i` при частоте устройства `rate`.
    ///
    /// Записанное может быть в другой частоте, чем устройство: берём
    /// ближайший отсчёт. Для пробы на слух этого достаточно.
    pub fn sampleAt(self: Source, i: usize, rate: u32) f32 {
        return switch (self) {
            .plan => |p| p.sampleAt(i, rate),
            .samples => |s| blk: {
                const at: usize = @intCast(@as(u64, i) * s.rate / @max(rate, 1));
                if (at >= s.data.len) break :blk 0;
                break :blk @as(f32, @floatFromInt(s.data[at])) / 32768.0;
            },
        };
    }
};

/// Проиграть план всплесков целиком и вернуться, когда он отзвучал.
///
/// `seconds` — сколько всего играть, включая тишину до и после всплесков:
/// план говорит, когда всплески, но не говорит, когда кончается запись.
pub fn playPlan(plan: tone.Plan, seconds: f32) Error!void {
    return playSource(.{ .plan = plan }, seconds);
}

/// Проиграть записанные отсчёты (моно, `rate` Гц) и вернуться, когда
/// отзвучали. Для пробы микрофона (#22).
pub fn playSamples(samples: []const i16, rate: u32) Error!void {
    const seconds = @as(f32, @floatFromInt(samples.len)) / @as(f32, @floatFromInt(@max(rate, 1)));
    return playSource(.{ .samples = .{ .data = samples, .rate = rate } }, seconds);
}

/// Устройство вывода по умолчанию, открытое и готовое принимать отсчёты.
///
/// Общее для стендов и плеера редактора (#23): открыть, подать, узнать,
/// сколько ещё лежит в буфере. Живёт в потоке, который его открыл:
/// COM инициализируется здесь же.
pub const Renderer = struct {
    client: *c.IAudioClient,
    render: *c.IAudioRenderClient,
    format: [*c]c.WAVEFORMATEX,
    rate: u32,
    channels: usize,
    is_float: bool,
    buffer_frames: u32,

    pub fn open() Error!Renderer {
        if (builtin.os.tag != .windows) return Error.Unsupported;
        _ = c.CoInitializeEx(null, c.COINIT_MULTITHREADED);
        errdefer c.CoUninitialize();

        var enumerator: ?*c.IMMDeviceEnumerator = null;
        if (win32.failed(c.CoCreateInstance(
            &c.CLSID_MMDeviceEnumerator,
            null,
            c.CLSCTX_ALL,
            &c.IID_IMMDeviceEnumerator,
            @ptrCast(&enumerator),
        ))) return Error.NoSpeakers;
        defer _ = enumerator.?.lpVtbl.*.Release.?(@ptrCast(enumerator.?));

        var device: ?*c.IMMDevice = null;
        if (win32.failed(enumerator.?.lpVtbl.*.GetDefaultAudioEndpoint.?(
            enumerator.?,
            c.eRender,
            c.eConsole,
            &device,
        ))) return Error.NoSpeakers;
        defer _ = device.?.lpVtbl.*.Release.?(@ptrCast(device.?));

        var client: ?*c.IAudioClient = null;
        if (win32.failed(device.?.lpVtbl.*.Activate.?(
            device.?,
            &c.IID_IAudioClient,
            c.CLSCTX_ALL,
            null,
            @ptrCast(&client),
        ))) return Error.NoSpeakers;
        errdefer _ = client.?.lpVtbl.*.Release.?(@ptrCast(client.?));

        var format: [*c]c.WAVEFORMATEX = null;
        if (win32.failed(client.?.lpVtbl.*.GetMixFormat.?(client.?, &format))) return Error.BadFormat;
        errdefer c.CoTaskMemFree(format);

        const is_float = format.*.wFormatTag == c.WAVE_FORMAT_IEEE_FLOAT or
            (format.*.wFormatTag == c.WAVE_FORMAT_EXTENSIBLE and format.*.wBitsPerSample == 32);
        if (!is_float and format.*.wBitsPerSample != 16) return Error.BadFormat;

        // Буфер на полсекунды: нам не нужна малая задержка, нужна надёжность —
        // ни стенд, ни плеер не должны заикаться оттого, что система
        // придержала поток.
        const buffer_duration: c.REFERENCE_TIME = 5_000_000;
        if (win32.failed(client.?.lpVtbl.*.Initialize.?(
            client.?,
            c.AUDCLNT_SHAREMODE_SHARED,
            0,
            buffer_duration,
            0,
            format,
            null,
        ))) return Error.BadFormat;

        var buffer_frames: c.UINT32 = 0;
        if (win32.failed(client.?.lpVtbl.*.GetBufferSize.?(client.?, &buffer_frames))) return Error.Failed;

        var render: ?*c.IAudioRenderClient = null;
        if (win32.failed(client.?.lpVtbl.*.GetService.?(
            client.?,
            &c.IID_IAudioRenderClient,
            @ptrCast(&render),
        ))) return Error.Failed;

        return .{
            .client = client.?,
            .render = render.?,
            .format = format,
            .rate = format.*.nSamplesPerSec,
            .channels = format.*.nChannels,
            .is_float = is_float,
            .buffer_frames = buffer_frames,
        };
    }

    pub fn close(self: *Renderer) void {
        _ = self.render.lpVtbl.*.Release.?(self.render);
        _ = self.client.lpVtbl.*.Release.?(self.client);
        c.CoTaskMemFree(self.format);
        c.CoUninitialize();
    }

    pub fn start(self: *Renderer) Error!void {
        if (win32.failed(self.client.lpVtbl.*.Start.?(self.client))) return Error.Failed;
    }

    pub fn stop(self: *Renderer) void {
        _ = self.client.lpVtbl.*.Stop.?(self.client);
    }

    /// Сколько кадров ещё лежит в буфере и не сыграно.
    pub fn padding(self: *Renderer) Error!u32 {
        var value: c.UINT32 = 0;
        if (win32.failed(self.client.lpVtbl.*.GetCurrentPadding.?(self.client, &value))) return Error.Failed;
        return value;
    }

    /// Сколько кадров сейчас влезет.
    pub fn room(self: *const Renderer, padding_now: u32) usize {
        return self.buffer_frames -| padding_now;
    }

    /// Отдать моно-отсчёты (−1…1): каждый — во все каналы. Не больше,
    /// чем влезает.
    pub fn writeMono(self: *Renderer, samples: []const f32) Error!void {
        if (samples.len == 0) return;
        var data: [*c]c.BYTE = undefined;
        if (win32.failed(self.render.lpVtbl.*.GetBuffer.?(self.render, @intCast(samples.len), &data))) return Error.Failed;
        for (samples, 0..) |v, i| {
            if (self.is_float) {
                const out: [*]f32 = @ptrCast(@alignCast(data));
                for (0..self.channels) |ch| out[i * self.channels + ch] = v;
            } else {
                const out: [*]i16 = @ptrCast(@alignCast(data));
                const s16: i16 = @intFromFloat(std.math.clamp(v * 32767.0, -32768.0, 32767.0));
                for (0..self.channels) |ch| out[i * self.channels + ch] = s16;
            }
        }
        if (win32.failed(self.render.lpVtbl.*.ReleaseBuffer.?(self.render, @intCast(samples.len), 0))) return Error.Failed;
    }

    /// Сколько ждать, чтобы буфер дозвучал: остановка сразу срезала бы хвост.
    pub fn tailMs(self: *const Renderer) u32 {
        return @intCast(@as(u64, self.buffer_frames) * 1000 / @max(self.rate, 1) + 50);
    }
};

fn playSource(source: Source, seconds: f32) Error!void {
    var out = try Renderer.open();
    defer out.close();

    const total: usize = @intFromFloat(seconds * @as(f32, @floatFromInt(out.rate)));
    var written: usize = 0;
    var chunk: [4096]f32 = undefined;

    // Заполняем буфер до старта: иначе первые миллисекунды — тишина
    // и щелчок, а стенд меряет как раз начало.
    try fillFrom(&out, &chunk, &written, total, source);
    try out.start();
    defer out.stop();

    while (written < total) {
        const padding = try out.padding();
        if (out.room(padding) == 0) {
            c.Sleep(5);
            continue;
        }
        try fillFrom(&out, &chunk, &written, total, source);
    }
    // Дать буферу дозвучать: остановка сразу срезала бы хвост последнего
    // всплеска, и стенд счёл бы его короче задуманного.
    c.Sleep(out.tailMs());
}

/// Положить в устройство столько, сколько влезает, начиная с `written`.
fn fillFrom(out: *Renderer, chunk: []f32, written: *usize, total: usize, source: Source) Error!void {
    while (written.* < total) {
        const padding = try out.padding();
        const want = @min(@min(out.room(padding), chunk.len), total - written.*);
        if (want == 0) return;
        for (chunk[0..want], 0..) |*v, i| v.* = source.sampleAt(written.* + i, out.rate);
        try out.writeMono(chunk[0..want]);
        written.* += want;
    }
}

/// Объяснение словами.
pub fn explain(err: anyerror) []const u8 {
    return switch (err) {
        Error.NoSpeakers => lang.t("нет устройства вывода"),
        Error.BadFormat => lang.t("устройство вывода отдаёт формат, который мы не понимаем"),
        Error.Unsupported => lang.t("вывод звука работает только в Windows"),
        else => lang.t("вывод звука не удался"),
    };
}

// ---------------------------------------------------------------- тесты

test "план в отсчётах: столько, сколько просят секунд" {
    // Само воспроизведение проверяется стендом на настоящем устройстве;
    // здесь только арифметика длины, которую можно посчитать без колонок.
    const rate: u32 = 48_000;
    const total: usize = @intFromFloat(3.0 * @as(f32, @floatFromInt(rate)));
    try std.testing.expectEqual(@as(usize, 144_000), total);
}

test "записанные отсчёты отдаются в частоте устройства ближайшим отсчётом" {
    const data = [_]i16{ 0, 16384, -16384, 32767 };
    const src = Source{ .samples = .{ .data = &data, .rate = 4 } };
    // Та же частота — отсчёт в отсчёт.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), src.sampleAt(1, 4), 0.001);
    // Устройство вдвое быстрее — каждый отсчёт повторяется дважды.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), src.sampleAt(2, 8), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), src.sampleAt(3, 8), 0.001);
    // За концом — тишина, а не чтение за краем.
    try std.testing.expectEqual(@as(f32, 0), src.sampleAt(100, 4));
}
