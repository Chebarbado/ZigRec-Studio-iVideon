//! Прочитать звук файла целиком, отсчётами.
//!
//! Задачи #61 и #62. Сведение работает с готовыми отсчётами и про файлы
//! ничего не знает — это и позволяет проверить его тестами целиком.
//! Значит, кто-то должен превратить файл в отсчёты; этим занят этот модуль.
//!
//! **Читаем в память целиком.** Минута моно на сорока восьми килогерцах —
//! это одиннадцать мегабайт: для сведения, которое и так держит всю смесь
//! в памяти, это не цена. Потоковое чтение понадобится, когда сведение
//! научится писать длинные файлы кусками, и тогда же и появится.
//!
//! **Сводим каналы средним.** У стерео говорят в оба, и взять первый канал
//! значит иногда получить тишину при слышимом звуке — эта же ошибка уже
//! была бы в рисовании волны, если бы её там не заметили.
const std = @import("std");
const lang = @import("../lang.zig");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;
const mixdown = @import("../edit/mixdown.zig");

pub const Error = error{
    /// Здесь нет звуковой дорожки или её не раскодировать.
    NoAudio,
    /// Media Foundation не поднялась.
    StartupFailed,
    /// Не на этой системе.
    Unsupported,
    OutOfMemory,
};

/// Прочитанный звук. Отсчёты принадлежат вызывающему.
pub const Audio = struct {
    rate: u32 = 48_000,
    samples: []f32 = &.{},

    pub fn deinit(self: *Audio, allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
        self.samples = &.{};
    }

    pub fn durationNs(self: Audio) u64 {
        if (self.rate == 0) return 0;
        return @as(u64, self.samples.len) * std.time.ns_per_s / self.rate;
    }

    /// То же самое, но в виде, который понимает сведение.
    pub fn forMix(self: Audio) mixdown.SourceAudio {
        return .{ .rate = self.rate, .samples = self.samples };
    }
};

pub fn read(allocator: std.mem.Allocator, path: []const u8) Error!Audio {
    if (builtin.os.tag != .windows) return Error.Unsupported;

    _ = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED | c.COINIT_DISABLE_OLE1DDE);
    if (win32.failed(c.MFStartup(c.MF_VERSION, c.MFSTARTUP_FULL))) return Error.StartupFailed;
    defer _ = c.MFShutdown();

    var wide: [std.fs.max_path_bytes]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, path) catch return Error.NoAudio;
    wide[n] = 0;

    var reader: ?*c.IMFSourceReader = null;
    if (win32.failed(c.MFCreateSourceReaderFromURL(@ptrCast(&wide), null, &reader))) return Error.NoAudio;
    defer _ = reader.?.lpVtbl.*.Release.?(@ptrCast(reader.?));
    const r = reader.?;

    // Картинку не трогаем вовсе: ради звука раскодировать видео — это
    // минуты вместо секунд.
    _ = r.lpVtbl.*.SetStreamSelection.?(r, c.MF_SOURCE_READER_ALL_STREAMS, 0);
    _ = r.lpVtbl.*.SetStreamSelection.?(r, c.MF_SOURCE_READER_FIRST_AUDIO_STREAM, 1);

    var want: ?*c.IMFMediaType = null;
    if (win32.failed(c.MFCreateMediaType(&want))) return Error.NoAudio;
    defer _ = want.?.lpVtbl.*.Release.?(@ptrCast(want.?));
    const w = want.?;
    _ = w.lpVtbl.*.SetGUID.?(w, &c.MF_MT_MAJOR_TYPE, &c.MFMediaType_Audio);
    _ = w.lpVtbl.*.SetGUID.?(w, &c.MF_MT_SUBTYPE, &c.MFAudioFormat_Float);
    if (win32.failed(r.lpVtbl.*.SetCurrentMediaType.?(r, c.MF_SOURCE_READER_FIRST_AUDIO_STREAM, null, w))) {
        return Error.NoAudio;
    }

    // Сколько каналов и какая частота вышли на самом деле: просить моно
    // можно, но дают не всегда, и считать надо по тому, что дали.
    var actual: ?*c.IMFMediaType = null;
    if (win32.failed(r.lpVtbl.*.GetCurrentMediaType.?(r, c.MF_SOURCE_READER_FIRST_AUDIO_STREAM, &actual))) {
        return Error.NoAudio;
    }
    defer _ = actual.?.lpVtbl.*.Release.?(@ptrCast(actual.?));
    var channels: c.UINT32 = 1;
    var rate: c.UINT32 = 48_000;
    _ = actual.?.lpVtbl.*.GetUINT32.?(actual.?, &c.MF_MT_AUDIO_NUM_CHANNELS, &channels);
    _ = actual.?.lpVtbl.*.GetUINT32.?(actual.?, &c.MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate);
    if (channels == 0) channels = 1;
    if (rate == 0) rate = 48_000;

    var out: std.ArrayList(f32) = .empty;
    errdefer out.deinit(allocator);

    while (true) {
        var flags: c.DWORD = 0;
        var sample: ?*c.IMFSample = null;
        var stream: c.DWORD = 0;
        var timestamp: c.LONGLONG = 0;
        if (win32.failed(r.lpVtbl.*.ReadSample.?(
            r,
            c.MF_SOURCE_READER_FIRST_AUDIO_STREAM,
            0,
            &stream,
            &flags,
            &timestamp,
            &sample,
        ))) break;
        if (flags & c.MF_SOURCE_READERF_ENDOFSTREAM != 0) break;
        const got = sample orelse continue;
        defer _ = got.lpVtbl.*.Release.?(@ptrCast(got));

        var buffer: ?*c.IMFMediaBuffer = null;
        if (win32.failed(got.lpVtbl.*.ConvertToContiguousBuffer.?(got, &buffer))) continue;
        defer _ = buffer.?.lpVtbl.*.Release.?(@ptrCast(buffer.?));

        var data: [*c]u8 = undefined;
        var length: c.DWORD = 0;
        if (win32.failed(buffer.?.lpVtbl.*.Lock.?(buffer.?, &data, null, &length))) continue;

        const floats: [*]const f32 = @ptrCast(@alignCast(data));
        const count = length / 4;
        var i: usize = 0;
        while (i + channels <= count) : (i += channels) {
            var sum: f32 = 0;
            var ch: usize = 0;
            while (ch < channels) : (ch += 1) sum += floats[i + ch];
            out.append(allocator, sum / @as(f32, @floatFromInt(channels))) catch {
                _ = buffer.?.lpVtbl.*.Unlock.?(buffer.?);
                return Error.OutOfMemory;
            };
        }
        _ = buffer.?.lpVtbl.*.Unlock.?(buffer.?);
    }

    if (out.items.len == 0) {
        out.deinit(allocator);
        return Error.NoAudio;
    }
    return .{ .rate = rate, .samples = try out.toOwnedSlice(allocator) };
}

/// Объяснение словами — для окна.
pub fn explain(err: anyerror) []const u8 {
    return switch (err) {
        Error.NoAudio => lang.t("в этом файле нет звука или он не раскодируется"),
        Error.StartupFailed => lang.t("не поднялась подсистема мультимедиа Windows"),
        Error.Unsupported => lang.t("чтение звука работает только в Windows"),
        Error.OutOfMemory => lang.t("не хватило памяти на звук этого файла"),
        else => lang.t("звук не читается"),
    };
}

// ---------------------------------------------------------------- тесты

test "прочитанный звук умеет назвать свою длину" {
    // Само чтение проверяется стендом на настоящем файле: подделать здесь
    // Media Foundation нечем, а врать зелёным тестом хуже, чем не проверять.
    var audio = Audio{ .rate = 48_000, .samples = &.{} };
    try std.testing.expectEqual(@as(u64, 0), audio.durationNs());

    var samples: [48_000]f32 = @splat(0);
    audio.samples = &samples;
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s), audio.durationNs());

    // И отдаётся сведению тем же, чем прочитан.
    try std.testing.expectEqual(audio.rate, audio.forMix().rate);
    try std.testing.expectEqual(audio.samples.len, audio.forMix().samples.len);
}

test "нулевая частота не делит на ноль" {
    const audio = Audio{ .rate = 0, .samples = &.{} };
    try std.testing.expectEqual(@as(u64, 0), audio.durationNs());
}
