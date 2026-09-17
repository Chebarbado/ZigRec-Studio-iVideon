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

fn playSource(source: Source, seconds: f32) Error!void {
    if (builtin.os.tag != .windows) return Error.Unsupported;

    _ = c.CoInitializeEx(null, c.COINIT_MULTITHREADED);
    defer c.CoUninitialize();

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
    defer _ = client.?.lpVtbl.*.Release.?(@ptrCast(client.?));

    var format: [*c]c.WAVEFORMATEX = null;
    if (win32.failed(client.?.lpVtbl.*.GetMixFormat.?(client.?, &format))) return Error.BadFormat;
    defer c.CoTaskMemFree(format);

    const rate = format.*.nSamplesPerSec;
    const channels: usize = format.*.nChannels;
    const is_float = format.*.wFormatTag == c.WAVE_FORMAT_IEEE_FLOAT or
        (format.*.wFormatTag == c.WAVE_FORMAT_EXTENSIBLE and format.*.wBitsPerSample == 32);
    if (!is_float and format.*.wBitsPerSample != 16) return Error.BadFormat;

    // Буфер на полсекунды: нам не нужна малая задержка, нужна надёжность —
    // стенд не должен заикаться оттого, что система придержала поток.
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
    defer _ = render.?.lpVtbl.*.Release.?(@ptrCast(render.?));

    const total: usize = @intFromFloat(seconds * @as(f32, @floatFromInt(rate)));
    var written: usize = 0;

    // Заполняем буфер до старта: иначе первые миллисекунды — тишина
    // и щелчок, а стенд меряет как раз начало.
    try fill(render.?, buffer_frames, &written, total, source, rate, channels, is_float);
    if (win32.failed(client.?.lpVtbl.*.Start.?(client.?))) return Error.Failed;
    defer _ = client.?.lpVtbl.*.Stop.?(client.?);

    while (written < total) {
        var padding: c.UINT32 = 0;
        if (win32.failed(client.?.lpVtbl.*.GetCurrentPadding.?(client.?, &padding))) return Error.Failed;
        const room = buffer_frames - padding;
        if (room == 0) {
            c.Sleep(5);
            continue;
        }
        try fill(render.?, room, &written, total, source, rate, channels, is_float);
    }
    // Дать буферу дозвучать: остановка сразу срезала бы хвост последнего
    // всплеска, и стенд счёл бы его короче задуманного.
    const tail_ms: u32 = @intCast(@as(u64, buffer_frames) * 1000 / @max(rate, 1) + 50);
    c.Sleep(tail_ms);
}

/// Положить в устройство до `frames` кадров плана, начиная с `written`.
fn fill(
    render: *c.IAudioRenderClient,
    frames: c.UINT32,
    written: *usize,
    total: usize,
    source: Source,
    rate: u32,
    channels: usize,
    is_float: bool,
) Error!void {
    const want: usize = @min(@as(usize, frames), total - written.*);
    if (want == 0) return;

    var data: [*c]c.BYTE = undefined;
    if (win32.failed(render.lpVtbl.*.GetBuffer.?(render, @intCast(want), &data))) return Error.Failed;

    var i: usize = 0;
    while (i < want) : (i += 1) {
        const v = source.sampleAt(written.* + i, rate);
        if (is_float) {
            const out: [*]f32 = @ptrCast(@alignCast(data));
            for (0..channels) |ch| out[i * channels + ch] = v;
        } else {
            const out: [*]i16 = @ptrCast(@alignCast(data));
            const s: i16 = @intFromFloat(std.math.clamp(v * 32767.0, -32768.0, 32767.0));
            for (0..channels) |ch| out[i * channels + ch] = s;
        }
    }
    if (win32.failed(render.lpVtbl.*.ReleaseBuffer.?(render, @intCast(want), 0))) return Error.Failed;
    written.* += want;
}

/// Объяснение словами.
pub fn explain(err: anyerror) []const u8 {
    return switch (err) {
        Error.NoSpeakers => "нет устройства вывода",
        Error.BadFormat => "устройство вывода отдаёт формат, который мы не понимаем",
        Error.Unsupported => "вывод звука работает только в Windows",
        else => "вывод звука не удался",
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
