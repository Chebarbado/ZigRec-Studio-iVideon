//! Экспорт проекта в mp4: без перекодирования, где можно, и с ним, где нельзя.
//!
//! Задача #27. Сжатые кадры H.264 из исходника можно переложить в новый
//! файл как есть — быстро и без потери качества, — но только если каждый
//! клип начинается с ключевого кадра (#24) и все клипы из одного файла:
//! у разных файлов разные параметры потока, а середина группы кадров без
//! начала не раскодируется. Тогда путь второй: раскодировать кадры и
//! закодировать заново тем же кодировщиком, что у записи.
//!
//! Решение, какой путь, — чистое правило `plan` с тестами; звук в обоих
//! путях сводится из всех незаглушённых дорожек и пишется AAC.
const std = @import("std");
const lang = @import("../lang.zig");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;
const timeline = @import("../edit/timeline.zig");
const mixdown = @import("../edit/mixdown.zig");
const keyframes = @import("keyframes.zig");
const player = @import("player.zig");
const encode = @import("encode.zig");
const media = @import("media.zig");
const mp4 = @import("mp4.zig");
const events = @import("events.zig");
const cursor_paint = @import("../capture/cursor_paint.zig");
const annot_paint = @import("../capture/annot_paint.zig");

pub const Error = error{
    Unsupported,
    StartupFailed,
    /// На видеодорожках пусто — экспортировать нечего.
    NothingToExport,
    NoVideo,
    CreateFailed,
    FormatRejected,
    ReadFailed,
    WriteFailed,
    OutOfMemory,
};

pub const Mode = enum {
    /// Сжатые кадры перекладываются как есть.
    passthrough,
    /// Кадры раскодируются и кодируются заново.
    reencode,

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .passthrough => lang.t("без перекодирования"),
            .reencode => lang.t("с перекодированием"),
        };
    }
};

/// Насколько начало клипа может отстоять от ключевого кадра, чтобы
/// считаться «на нём»: полкадра при 30 к/с. Дальше — уже другой кадр.
pub const key_tolerance_ns: u64 = 16 * std.time.ns_per_ms;

pub const Plan = struct {
    mode: Mode = .reencode,
    /// Курсор из слоя впечатывается — значит, без перекодирования нельзя.
    burns_cursor: bool = false,
    /// Аннотации есть — тоже впечатываются, тоже перекодирование (#28).
    burns_annotations: bool = false,
    /// Сколько видеоклипов пойдёт в файл.
    clips: usize = 0,
    /// Сколько из них начинаются не с ключевого кадра.
    off_key: usize = 0,
    /// Сколько разных исходников у видеоклипов.
    sources: usize = 0,
    /// Первая (верхняя незаглушённая) видеодорожка.
    track: ?usize = null,
};

/// Верхняя незаглушённая видеодорожка с клипами: её и экспортируем.
/// Верхняя — то, что видит зритель в редакторе.
pub fn videoTrack(project: *const timeline.Project) ?usize {
    for (project.trackList(), 0..) |track, i| {
        if (track.kind == .video and !track.muted and track.count > 0) return i;
    }
    return null;
}

/// Слои событий исходников: по ячейке на исходник, `null` — слоя нет.
pub const Layers = []const ?events.Events;

/// Решить, каким путём идти. `keys` — ключевые кадры каждого исходника
/// (пустой список — ключевых не знаем, значит без перекодирования нельзя).
/// `layers` и `burn` — впечатывать ли курсор из слоя (#91): если есть что
/// впечатать, кадры придётся раскодировать.
pub fn plan(project: *const timeline.Project, keys: []const []const u64) Plan {
    return planWith(project, keys, &.{}, false);
}

pub fn planWith(project: *const timeline.Project, keys: []const []const u64, layers: Layers, burn: bool) Plan {
    var out = Plan{};
    const track_index = videoTrack(project) orelse return out;
    out.track = track_index;
    const track = project.tracks[track_index];
    var seen: [timeline.max_sources]bool = @splat(false);
    for (track.list()) |clip| {
        out.clips += 1;
        if (clip.source < seen.len and !seen[clip.source]) {
            seen[clip.source] = true;
            out.sources += 1;
        }
        const list: []const u64 = if (clip.source < keys.len) keys[clip.source] else &.{};
        if (keyframes.nearest(list, clip.in_ns, key_tolerance_ns) == null) out.off_key += 1;
        if (burn and clip.source < layers.len and layers[clip.source] != null) out.burns_cursor = true;
    }
    out.burns_annotations = project.annotations.count > 0;
    out.mode = if (out.clips > 0 and out.off_key == 0 and out.sources == 1 and !out.burns_cursor and !out.burns_annotations) .passthrough else .reencode;
    return out;
}

pub const Summary = struct {
    mode: Mode = .reencode,
    frames: u64 = 0,
    duration_ns: u64 = 0,
    audio_samples: u64 = 0,
};

/// Звук для сведения: по исходнику на ячейку, как в редакторе.
pub const AudioSources = []const mixdown.SourceAudio;

/// Экспортировать проект в `out_path`.
///
/// `keys` — ключевые кадры исходников, `audio` — их звук (пустой срез —
/// без звука). Отчёт о ходе — в `say`, если дан.
pub fn run(
    allocator: std.mem.Allocator,
    project: *const timeline.Project,
    keys: []const []const u64,
    audio: AudioSources,
    out_path: []const u8,
) Error!Summary {
    return runWith(allocator, project, keys, audio, &.{}, false, out_path);
}

/// То же, с курсором из слоя: `layers` по исходникам, `burn` — впечатывать.
pub fn runWith(
    allocator: std.mem.Allocator,
    project: *const timeline.Project,
    keys: []const []const u64,
    audio: AudioSources,
    layers: Layers,
    burn: bool,
    out_path: []const u8,
) Error!Summary {
    if (builtin.os.tag != .windows) return Error.Unsupported;
    const decided = planWith(project, keys, layers, burn);
    const track_index = decided.track orelse return Error.NothingToExport;
    return switch (decided.mode) {
        .passthrough => passthrough(allocator, project, track_index, audio, out_path),
        .reencode => reencode(allocator, project, track_index, audio, if (burn) layers else &.{}, out_path),
    };
}

/// Впечатать курсор из слоя в кадр: стрелка и вспышка клика. Координаты
/// стола переводятся в кадр по области, действовавшей в этот момент;
/// кадр бывает чуть другого размера, чем область (чётные стороны у DXGI) —
/// пересчитываем пропорцией.
pub fn burnCursor(layer: *const events.Events, inside_ns: u64, pixels: []u8, stride: usize, width: u32, height: u32) void {
    const at = layer.cursorAt(inside_ns) orelse return;
    const area = layer.areaAt(inside_ns) orelse return;
    if (area.w <= 0 or area.h <= 0) return;
    const fx = @divTrunc((at.x - area.x) * @as(i32, @intCast(width)), area.w);
    const fy = @divTrunc((at.y - area.y) * @as(i32, @intCast(height)), area.h);
    const flash_life: u64 = 300 * std.time.ns_per_ms;
    if (layer.recentDown(inside_ns, flash_life)) |d| {
        const strength = cursor_paint.flashStrength(inside_ns - d.at_ns, flash_life);
        const r: i32 = 10 + @as(i32, @intCast((255 - strength) / 20));
        cursor_paint.ring(pixels, stride, width, height, fx, fy, r, .{ 0x40, 0x40, 0xFF, 0xFF }, strength);
    }
    cursor_paint.arrow(pixels, stride, width, height, fx, fy, 1);
}

// ------------------------------------------------------------ звук

const audio_rate: u32 = 48_000;

/// Свести и отдать весь звук проекта писателю: кусками по четверти
/// секунды, каждый со своей меткой времени.
fn writeAudio(project: *const timeline.Project, audio: AudioSources, writer: *encode.Writer) Error!u64 {
    if (audio.len == 0) return 0;
    const total = mixdown.totalSamples(project, audio_rate);
    var chunk: [12_000]i16 = undefined;
    var at: usize = 0;
    var written: u64 = 0;
    while (at < total) {
        const n = @min(chunk.len, total - at);
        mixdown.mixAt(project, audio_rate, audio, at, chunk[0..n]);
        writer.writeAudio(chunk[0..n], mixdown.samplesToNs(at, audio_rate)) catch return Error.WriteFailed;
        at += n;
        written += n;
    }
    return written;
}

// ------------------------------------------------------------ с перекодированием

fn reencode(
    allocator: std.mem.Allocator,
    project: *const timeline.Project,
    track_index: usize,
    audio: AudioSources,
    layers: Layers,
    out_path: []const u8,
) Error!Summary {
    const track = project.tracks[track_index];
    const sources = project.sourceList();
    const first = track.list()[0];
    if (first.source >= sources.len) return Error.NoVideo;

    // Размер и частота — по первому клипу: файл один, а исходники бывают
    // разные; остальные подгоняются декодером под этот размер.
    var opened = player.Player.openScaled(allocator, sources[first.source].fullPath(), 0, 0) catch return Error.NoVideo;
    defer opened.close();
    const width = opened.width;
    const height = opened.height;
    const fps = fpsOf(allocator, sources[first.source].fullPath());
    const frame_ns: u64 = std.time.ns_per_s / @max(fps, 1);

    var settings = encode.Settings{ .fps = fps, .preset = .video };
    if (audio.len > 0) settings.audio = .{ .sample_rate = audio_rate, .channels = 1 };
    var writer = encode.Writer.create(out_path, width, height, settings) catch return Error.CreateFailed;
    errdefer writer.abort();

    var summary = Summary{ .mode = .reencode };
    var current: u16 = first.source;
    for (track.list()) |clip| {
        if (clip.source >= sources.len) continue;
        if (clip.source != current) {
            opened.close();
            opened = player.Player.openScaled(allocator, sources[clip.source].fullPath(), width, height) catch return Error.NoVideo;
            current = clip.source;
            // Кодировщик принимает кадры одного размера; другой исходник
            // другого размера — честный отказ, а не рассыпанная картинка.
            if (opened.width != width or opened.height != height) return Error.FormatRejected;
        }
        var inside: u64 = clip.in_ns;
        const end = clip.in_ns + clip.len_ns;
        while (inside < end) : (inside += frame_ns) {
            opened.showAt(inside) catch return Error.ReadFailed;
            if (clip.source < layers.len) {
                if (layers[clip.source]) |*layer| burnCursor(layer, inside, opened.pixels, opened.stride, opened.width, opened.height);
            }
            const at_ns = clip.at_ns + (inside - clip.in_ns);
            // Аннотации живут на времени проекта, а не файла.
            annot_paint.paintFrame(opened.pixels, opened.stride, opened.width, opened.height, project.annotations.list(), at_ns);
            writer.writeFrame(opened.pixels, @intCast(opened.stride), at_ns) catch return Error.WriteFailed;
            summary.frames += 1;
            summary.duration_ns = at_ns + frame_ns;
        }
    }
    summary.audio_samples = try writeAudio(project, audio, &writer);
    _ = writer.finish() catch return Error.WriteFailed;
    return summary;
}

fn fpsOf(allocator: std.mem.Allocator, path: []const u8) u32 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const info = media.read(threaded.io(), allocator, path) catch return 30;
    for (info.list()) |t| {
        if (t.fps > 0.5) return @intFromFloat(@round(t.fps));
    }
    return 30;
}

// ------------------------------------------------------------ без перекодирования

/// Сжатые кадры из читателя — в писатель с тем же типом потока.
fn passthrough(
    allocator: std.mem.Allocator,
    project: *const timeline.Project,
    track_index: usize,
    audio: AudioSources,
    out_path: []const u8,
) Error!Summary {
    const track = project.tracks[track_index];
    const sources = project.sourceList();
    const first = track.list()[0];
    if (first.source >= sources.len) return Error.NoVideo;
    const path = sources[first.source].fullPath();

    _ = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED | c.COINIT_DISABLE_OLE1DDE);
    if (win32.failed(c.MFStartup(c.MF_VERSION, c.MFSTARTUP_FULL))) return Error.StartupFailed;
    defer _ = c.MFShutdown();

    // Читатель без обработки видео: отдаёт сжатые кадры как лежат.
    var wide: [std.fs.max_path_bytes]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, path) catch return Error.NoVideo;
    wide[n] = 0;
    var reader: ?*c.IMFSourceReader = null;
    if (win32.failed(c.MFCreateSourceReaderFromURL(@ptrCast(&wide), null, &reader))) return Error.NoVideo;
    defer _ = reader.?.lpVtbl.*.Release.?(@ptrCast(reader.?));
    const r = reader.?;
    _ = r.lpVtbl.*.SetStreamSelection.?(r, c.MF_SOURCE_READER_ALL_STREAMS, 0);
    _ = r.lpVtbl.*.SetStreamSelection.?(r, c.MF_SOURCE_READER_FIRST_VIDEO_STREAM, 1);

    var native: ?*c.IMFMediaType = null;
    if (win32.failed(r.lpVtbl.*.GetNativeMediaType.?(r, c.MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &native))) return Error.NoVideo;
    defer _ = native.?.lpVtbl.*.Release.?(@ptrCast(native.?));
    if (win32.failed(r.lpVtbl.*.SetCurrentMediaType.?(r, c.MF_SOURCE_READER_FIRST_VIDEO_STREAM, null, native.?))) return Error.NoVideo;

    // Писатель: поток с тем же типом на выходе и на входе — кадры идут мимо
    // кодировщика.
    var attrs: ?*c.IMFAttributes = null;
    if (win32.failed(c.MFCreateAttributes(&attrs, 2))) return Error.CreateFailed;
    defer _ = attrs.?.lpVtbl.*.Release.?(@ptrCast(attrs.?));
    _ = attrs.?.lpVtbl.*.SetGUID.?(attrs.?, &c.MF_TRANSCODE_CONTAINERTYPE, &c.MFTranscodeContainerType_MPEG4);
    // Без этого писатель придерживает поток под частоту кадров: шесть
    // секунд видео перекладывались две минуты.
    _ = attrs.?.lpVtbl.*.SetUINT32.?(attrs.?, &c.MF_SINK_WRITER_DISABLE_THROTTLING, 1);
    var out_wide: [std.fs.max_path_bytes]u16 = undefined;
    const on = std.unicode.utf8ToUtf16Le(&out_wide, out_path) catch return Error.CreateFailed;
    out_wide[on] = 0;
    var sink: ?*c.IMFSinkWriter = null;
    if (win32.failed(c.MFCreateSinkWriterFromURL(@ptrCast(&out_wide), null, attrs, &sink))) return Error.CreateFailed;
    const w = sink.?;
    var finalized = false;
    defer if (!finalized) {
        _ = w.lpVtbl.*.Release.?(@ptrCast(w));
    };

    var stream: c.DWORD = 0;
    if (win32.failed(w.lpVtbl.*.AddStream.?(w, native.?, &stream))) return Error.FormatRejected;
    if (win32.failed(w.lpVtbl.*.SetInputMediaType.?(w, stream, native.?, null))) return Error.FormatRejected;

    var audio_stream: ?c.DWORD = null;
    if (audio.len > 0) audio_stream = addAudioStream(w) catch null;

    if (win32.failed(w.lpVtbl.*.BeginWriting.?(w))) return Error.WriteFailed;

    var summary = Summary{ .mode = .passthrough };
    for (track.list()) |clip| {
        try copyClip(r, w, stream, clip, &summary);
    }

    if (audio_stream) |as| {
        summary.audio_samples = try writeAudioRaw(project, audio, w, as);
    }

    finalized = true;
    const hres = w.lpVtbl.*.Finalize.?(w);
    _ = w.lpVtbl.*.Release.?(@ptrCast(w));
    if (win32.failed(hres)) return Error.WriteFailed;

    // `moov` в начало — как у записи: файл начинает играть, не скачавшись.
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    _ = mp4.makeFastStart(threaded.io(), allocator, out_path) catch {};
    return summary;
}

/// Переложить сжатые кадры одного клипа, сдвинув время на место клипа.
fn copyClip(r: *c.IMFSourceReader, w: *c.IMFSinkWriter, stream: c.DWORD, clip: timeline.Clip, summary: *Summary) Error!void {
    var pos = std.mem.zeroes(c.PROPVARIANT);
    // Время источника — в сотнях наносекунд.
    pos.unnamed_0.unnamed_0.vt = c.VT_I8;
    pos.unnamed_0.unnamed_0.unnamed_0.hVal.QuadPart = @intCast(win32.nsTo100ns(clip.in_ns));
    if (win32.failed(r.lpVtbl.*.SetCurrentPosition.?(r, &c.GUID_NULL, &pos))) return Error.ReadFailed;

    // Первый кадр после перемотки — ключевой, с которого читатель начал;
    // по плану это и есть начало клипа. Время считаем от него, а не от
    // `in_ns`: часы читателя и часы таблиц могут расходиться на список
    // правок файла (#24), а кадры должны лечь встык с нулём клипа.
    var base: ?u64 = null;
    while (true) {
        var flags: c.DWORD = 0;
        var sample: ?*c.IMFSample = null;
        var when_100: c.LONGLONG = 0;
        if (win32.failed(r.lpVtbl.*.ReadSample.?(r, c.MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, null, &flags, &when_100, &sample))) return Error.ReadFailed;
        if ((flags & c.MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
            if (sample) |s| _ = s.lpVtbl.*.Release.?(@ptrCast(s));
            break;
        }
        const s = sample orelse continue;
        defer _ = s.lpVtbl.*.Release.?(@ptrCast(s));
        const when_ns: u64 = @intCast(@max(when_100, 0) * 100);
        const start = base orelse when_ns;
        base = start;
        const inside = when_ns -| start;
        if (inside >= clip.len_ns) break;
        const at_ns = clip.at_ns + inside;
        _ = s.lpVtbl.*.SetSampleTime.?(s, win32.nsTo100ns(at_ns));
        if (win32.failed(w.lpVtbl.*.WriteSample.?(w, stream, s))) return Error.WriteFailed;
        summary.frames += 1;
        var dur_100: c.LONGLONG = 0;
        _ = s.lpVtbl.*.GetSampleDuration.?(s, &dur_100);
        summary.duration_ns = at_ns + @as(u64, @intCast(@max(dur_100, 0) * 100));
    }
}

/// Поток AAC на своём писателе: тот же рецепт, что у записи.
fn addAudioStream(w: *c.IMFSinkWriter) Error!c.DWORD {
    var out_type: ?*c.IMFMediaType = null;
    if (win32.failed(c.MFCreateMediaType(&out_type))) return Error.FormatRejected;
    defer _ = out_type.?.lpVtbl.*.Release.?(@ptrCast(out_type.?));
    const t = out_type.?;
    _ = t.lpVtbl.*.SetGUID.?(t, &c.MF_MT_MAJOR_TYPE, &c.MFMediaType_Audio);
    _ = t.lpVtbl.*.SetGUID.?(t, &c.MF_MT_SUBTYPE, &c.MFAudioFormat_AAC);
    _ = t.lpVtbl.*.SetUINT32.?(t, &c.MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    _ = t.lpVtbl.*.SetUINT32.?(t, &c.MF_MT_AUDIO_SAMPLES_PER_SECOND, audio_rate);
    _ = t.lpVtbl.*.SetUINT32.?(t, &c.MF_MT_AUDIO_NUM_CHANNELS, 1);
    _ = t.lpVtbl.*.SetUINT32.?(t, &c.MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 12_000);
    _ = t.lpVtbl.*.SetUINT32.?(t, &c.MF_MT_AAC_PAYLOAD_TYPE, 0);
    var stream: c.DWORD = 0;
    if (win32.failed(w.lpVtbl.*.AddStream.?(w, t, &stream))) return Error.FormatRejected;

    var in_type: ?*c.IMFMediaType = null;
    if (win32.failed(c.MFCreateMediaType(&in_type))) return Error.FormatRejected;
    defer _ = in_type.?.lpVtbl.*.Release.?(@ptrCast(in_type.?));
    const i = in_type.?;
    _ = i.lpVtbl.*.SetGUID.?(i, &c.MF_MT_MAJOR_TYPE, &c.MFMediaType_Audio);
    _ = i.lpVtbl.*.SetGUID.?(i, &c.MF_MT_SUBTYPE, &c.MFAudioFormat_PCM);
    _ = i.lpVtbl.*.SetUINT32.?(i, &c.MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    _ = i.lpVtbl.*.SetUINT32.?(i, &c.MF_MT_AUDIO_SAMPLES_PER_SECOND, audio_rate);
    _ = i.lpVtbl.*.SetUINT32.?(i, &c.MF_MT_AUDIO_NUM_CHANNELS, 1);
    _ = i.lpVtbl.*.SetUINT32.?(i, &c.MF_MT_AUDIO_BLOCK_ALIGNMENT, 2);
    _ = i.lpVtbl.*.SetUINT32.?(i, &c.MF_MT_AUDIO_AVG_BYTES_PER_SECOND, audio_rate * 2);
    _ = i.lpVtbl.*.SetUINT32.?(i, &c.MF_MT_ALL_SAMPLES_INDEPENDENT, 1);
    if (win32.failed(w.lpVtbl.*.SetInputMediaType.?(w, stream, i, null))) return Error.FormatRejected;
    return stream;
}

/// Свести звук и отдать сырым PCM в поток писателя.
fn writeAudioRaw(project: *const timeline.Project, audio: AudioSources, w: *c.IMFSinkWriter, stream: c.DWORD) Error!u64 {
    const total = mixdown.totalSamples(project, audio_rate);
    var chunk: [12_000]i16 = undefined;
    var at: usize = 0;
    while (at < total) {
        const n: usize = @min(chunk.len, total - at);
        mixdown.mixAt(project, audio_rate, audio, at, chunk[0..n]);

        var buf: ?*c.IMFMediaBuffer = null;
        if (win32.failed(c.MFCreateMemoryBuffer(@intCast(n * 2), &buf))) return Error.OutOfMemory;
        defer _ = buf.?.lpVtbl.*.Release.?(@ptrCast(buf.?));
        var data: [*c]c.BYTE = null;
        if (win32.failed(buf.?.lpVtbl.*.Lock.?(buf.?, &data, null, null))) return Error.WriteFailed;
        @memcpy(data[0 .. n * 2], std.mem.sliceAsBytes(chunk[0..n]));
        _ = buf.?.lpVtbl.*.Unlock.?(buf.?);
        _ = buf.?.lpVtbl.*.SetCurrentLength.?(buf.?, @intCast(n * 2));

        var sample: ?*c.IMFSample = null;
        if (win32.failed(c.MFCreateSample(&sample))) return Error.OutOfMemory;
        defer _ = sample.?.lpVtbl.*.Release.?(@ptrCast(sample.?));
        _ = sample.?.lpVtbl.*.AddBuffer.?(sample.?, buf.?);
        _ = sample.?.lpVtbl.*.SetSampleTime.?(sample.?, win32.nsTo100ns(mixdown.samplesToNs(at, audio_rate)));
        _ = sample.?.lpVtbl.*.SetSampleDuration.?(sample.?, win32.nsTo100ns(mixdown.samplesToNs(n, audio_rate)));
        if (win32.failed(w.lpVtbl.*.WriteSample.?(w, stream, sample.?))) return Error.WriteFailed;
        at += n;
    }
    return total;
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;
const sec = std.time.ns_per_s;

/// Проект — в куче: на стеке потока тестов ему не место (см. timeline).
fn project2(keys_ok: bool, two_sources: bool) !*timeline.Project {
    const p = try testing.allocator.create(timeline.Project);
    p.* = .{};
    const a = try p.addSource("a.mp4", 60 * sec);
    const b = try p.addSource("b.mp4", 60 * sec);
    const vt = try p.addTrack(.video, "видео");
    try p.place(vt, a, 0, 10 * sec);
    try p.place(vt, if (two_sources) b else a, 10 * sec, 10 * sec);
    if (!keys_ok) p.tracks[vt].clips[1].in_ns = 21 * sec + 500 * std.time.ns_per_ms;
    return p;
}

test "клипы с ключевых кадров одного файла — без перекодирования" {
    const p = try project2(true, false);
    defer testing.allocator.destroy(p);
    const keys_a = [_]u64{ 0, 2 * sec, 4 * sec, 6 * sec, 8 * sec, 10 * sec, 20 * sec };
    const keys = [_][]const u64{ &keys_a, &.{} };
    const got = plan(p, &keys);
    try testing.expectEqual(Mode.passthrough, got.mode);
    try testing.expectEqual(@as(usize, 2), got.clips);
    try testing.expectEqual(@as(usize, 0), got.off_key);
    try testing.expectEqual(@as(usize, 1), got.sources);
}

test "клип не с ключевого — перекодирование; два файла — тоже" {
    const off = try project2(false, false);
    defer testing.allocator.destroy(off);
    const keys_a = [_]u64{ 0, 2 * sec, 4 * sec, 6 * sec, 8 * sec, 10 * sec, 20 * sec };
    const keys = [_][]const u64{ &keys_a, &keys_a };
    const got = plan(off, &keys);
    try testing.expectEqual(Mode.reencode, got.mode);
    try testing.expectEqual(@as(usize, 1), got.off_key);

    const two = try project2(true, true);
    defer testing.allocator.destroy(two);
    const got2 = plan(two, &keys);
    try testing.expectEqual(Mode.reencode, got2.mode);
    try testing.expectEqual(@as(usize, 2), got2.sources);
}

test "ключевых не знаем — без перекодирования нельзя" {
    const p = try project2(true, false);
    defer testing.allocator.destroy(p);
    const keys = [_][]const u64{ &.{}, &.{} };
    try testing.expectEqual(Mode.reencode, plan(p, &keys).mode);
}

test "начало клипа в полкадра от ключевого — ещё на нём, дальше — нет" {
    const p = try project2(true, false);
    defer testing.allocator.destroy(p);
    const keys_a = [_]u64{ 0, 10 * sec, 20 * sec };
    const keys = [_][]const u64{ &keys_a, &.{} };
    p.tracks[0].clips[1].in_ns = 10 * sec + 10 * std.time.ns_per_ms;
    try testing.expectEqual(Mode.passthrough, plan(p, &keys).mode);
    p.tracks[0].clips[1].in_ns = 10 * sec + 40 * std.time.ns_per_ms;
    try testing.expectEqual(Mode.reencode, plan(p, &keys).mode);
}

test "видеодорожка для экспорта — верхняя незаглушённая с клипами" {
    const p = try testing.allocator.create(timeline.Project);
    defer testing.allocator.destroy(p);
    p.* = .{};
    const a = try p.addSource("a.mp4", 60 * sec);
    const empty = try p.addTrack(.video, "пусто");
    const muted = try p.addTrack(.video, "выкл");
    const good = try p.addTrack(.video, "видео");
    try p.place(muted, a, 0, 10 * sec);
    try p.place(good, a, 0, 10 * sec);
    p.tracks[muted].muted = true;
    _ = empty;
    try testing.expectEqual(@as(?usize, good), videoTrack(p));
    const none = try testing.allocator.create(timeline.Project);
    defer testing.allocator.destroy(none);
    none.* = .{};
    try testing.expectEqual(@as(usize, 0), plan(none, &.{}).clips);
}

test "у каждого пути есть подпись" {
    try testing.expect(Mode.passthrough.label().len > 0);
    try testing.expect(Mode.reencode.label().len > 0);
}

test "курсор из слоя заставляет перекодировать, без слоя — как раньше" {
    const p = try project2(true, false);
    defer testing.allocator.destroy(p);
    const keys_a = [_]u64{ 0, 2 * sec, 4 * sec, 6 * sec, 8 * sec, 10 * sec, 20 * sec };
    const keys = [_][]const u64{ &keys_a, &.{} };
    var layer = try events.read(testing.allocator, "zigrec-events 1\n0 area 0 0 100 100\n0 move 5 5\n");
    defer layer.deinit(testing.allocator);
    const layers = [_]?events.Events{ layer, null };
    try testing.expectEqual(Mode.passthrough, planWith(p, &keys, &layers, false).mode);
    try testing.expectEqual(Mode.reencode, planWith(p, &keys, &layers, true).mode);
    try testing.expect(planWith(p, &keys, &layers, true).burns_cursor);
    // Слоя нет — впечатывать нечего, путь прежний.
    const none = [_]?events.Events{ null, null };
    try testing.expectEqual(Mode.passthrough, planWith(p, &keys, &none, true).mode);
}

test "впечатанный курсор оказывается в кадре там, где был в слое" {
    var layer = try events.read(testing.allocator, "zigrec-events 1\n0 area 100 50 200 100\n0 move 150 80\n500000000 down L 150 80\n");
    defer layer.deinit(testing.allocator);
    // Кадр вдвое больше области: курсор (150,80) → (100,60).
    var buf: [400 * 200 * 4]u8 = @splat(0);
    burnCursor(&layer, 100 * std.time.ns_per_ms, &buf, 400 * 4, 400, 200);
    var white_near = false;
    var y: usize = 60;
    while (y < 70) : (y += 1) {
        var x: usize = 100;
        while (x < 108) : (x += 1) {
            if (buf[(y * 400 + x) * 4] == 255) white_near = true;
        }
    }
    try testing.expect(white_near);
    // Сразу после клика — кольцо: красное на радиусе ~10 слева от курсора,
    // где стрелка его не закрывает (справа и снизу лежит сама стрелка).
    var buf2: [400 * 200 * 4]u8 = @splat(0);
    burnCursor(&layer, 510 * std.time.ns_per_ms, &buf2, 400 * 4, 400, 200);
    try testing.expect(buf2[(60 * 400 + 90) * 4 + 2] > 200);
}

test "аннотации в проекте заставляют перекодировать" {
    const p = try project2(true, false);
    defer testing.allocator.destroy(p);
    const keys_a = [_]u64{ 0, 2 * sec, 4 * sec, 6 * sec, 8 * sec, 10 * sec, 20 * sec };
    const keys = [_][]const u64{ &keys_a, &.{} };
    try testing.expectEqual(Mode.passthrough, plan(p, &keys).mode);
    _ = try p.addAnnotation(.{ .at_ns = sec, .len_ns = sec, .kind = .text, .x = 100, .y = 100 });
    const got = plan(p, &keys);
    try testing.expectEqual(Mode.reencode, got.mode);
    try testing.expect(got.burns_annotations);
}
