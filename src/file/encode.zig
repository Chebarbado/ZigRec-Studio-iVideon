//! Кодирование H.264 и контейнер mp4 через Media Foundation.
//!
//! Задача #16. Главное отличие от CamStudio: на выходе честный mp4, который
//! открывается везде, а не AVI со своим кодеком.
//!
//! Аппаратный кодировщик включается флагом `MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS`;
//! если его нет, Media Foundation тихо возьмёт программный, и запись всё равно
//! получится — просто дороже по процессору.
//!
//! `moov` должен лежать в начале файла, иначе браузер не начнёт играть mp4,
//! пока не скачает его целиком. Штатный ключ `MF_MPEG4SINK_MOOV_BEFORE_MDAT`
//! для этого не годится: с обычным писателем `Finalize` падает с
//! `E_ACCESSDENIED`, а с файлом, открытым на чтение и запись, ключ переносит
//! `moov` в начало, но НЕ сдвигает данные — получается файл, у которого
//! метаданные читаются, а картинка рассыпается. Проверено 10.09.2026.
//! Поэтому переносим сами, после закрытия файла: `mp4.makeFastStart`.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;

pub const Error = error{
    /// Media Foundation не поднялась.
    StartupFailed,
    /// Не создаётся писатель: обычно не тот путь или занятый файл.
    CreateFailed,
    /// Кодировщик не принял формат.
    FormatRejected,
    /// Сбой при записи кадра.
    WriteFailed,
    /// Сбой при закрытии файла: он остаётся недоигранным.
    FinalizeFailed,
    Unsupported,
    OutOfMemory,
};

/// Пресет качества. По умолчанию `text_ui`: скринкаст это почти статичная
/// картинка с мелким шрифтом, и чёткость букв важнее экономии битрейта.
pub const Preset = enum {
    /// Текст и интерфейс: высокое качество, редкие ключевые кадры.
    text_ui,
    /// Обычное видео: движение, средний битрейт.
    video,
    /// Максимум качества, размер не экономим.
    max,

    pub fn label(self: Preset) []const u8 {
        return switch (self) {
            .text_ui => "текст и интерфейс",
            .video => "видео",
            .max => "максимум",
        };
    }

    /// Битрейт под размер кадра и частоту. Считаем от числа пикселей в секунду,
    /// а не берём готовое число: 4K и 720p требуют разного на порядок.
    pub fn bitrateKbps(self: Preset, width: u32, height: u32, fps: u32) u32 {
        const pixels_per_sec = @as(u64, width) * @as(u64, height) * @as(u64, fps);
        const milli_bits_per_pixel: u64 = switch (self) {
            .text_ui => 60,
            .video => 100,
            .max => 200,
        };
        const kbps = pixels_per_sec * milli_bits_per_pixel / 1000 / 1000;
        return @intCast(std.math.clamp(kbps, 500, 200_000));
    }
};

/// Звуковая дорожка. Один канал: микрофон один, и стерео из него — это два
/// одинаковых канала и вдвое больше места на диске ни за что.
pub const AudioSettings = struct {
    sample_rate: u32 = 48_000,
    channels: u16 = 1,
    /// Битрейт AAC. 96 кбит/с для одного канала речи — с запасом: слышимая
    /// разница с вдвое большим начинается на музыке, а не на голосе.
    bitrate_kbps: u32 = 96,

    pub fn bytesPerSecond(self: AudioSettings) u32 {
        return self.bitrate_kbps * 1000 / 8;
    }

    /// Сколько байт занимает один кадр на входе кодировщика.
    pub fn blockAlign(self: AudioSettings) u32 {
        return @as(u32, self.channels) * 2;
    }
};

pub const Settings = struct {
    preset: Preset = .text_ui,
    fps: u32 = 30,
    /// Длина группы кадров. Резка в редакторе идёт по ключевым кадрам,
    /// поэтому слишком длинный GOP потом мешает резать без перекодирования.
    gop: u32 = 60,
    /// Перенести `moov` в начало файла после записи (см. заголовок модуля).
    faststart: bool = true,
    /// Битрейт вместо расчётного по пресету.
    bitrate_kbps: ?u32 = null,
    /// Звуковая дорожка. `null` — файл без звука.
    audio: ?AudioSettings = null,

    pub fn bitrate(self: Settings, width: u32, height: u32) u32 {
        return self.bitrate_kbps orelse self.preset.bitrateKbps(width, height, self.fps);
    }
};

/// Что получилось по итогам записи.
pub const Summary = struct {
    frames: u64 = 0,
    /// Длительность по меткам времени кадров.
    duration_ns: u64 = 0,
    bytes: u64 = 0,
    /// Сколько звуковых отсчётов ушло в файл.
    audio_samples: u64 = 0,
};

fn setSize(t: *c.IMFMediaType, key: *const c.GUID, w: u32, h: u32) c.HRESULT {
    return t.lpVtbl.*.SetUINT64.?(t, key, win32.pack2(w, h));
}

fn setRatio(t: *c.IMFMediaType, key: *const c.GUID, num: u32, den: u32) c.HRESULT {
    return t.lpVtbl.*.SetUINT64.?(t, key, win32.pack2(num, den));
}

/// Запись видеопотока в mp4.
pub const Writer = struct {
    width: u32,
    height: u32,
    settings: Settings,
    writer: *c.IMFSinkWriter = undefined,
    stream: c.DWORD = 0,
    /// Кадр придерживается до прихода следующего: только тогда известна его
    /// настоящая длительность. Иначе при переменной частоте кадров время в
    /// файле разъезжается с тем, что было на экране.
    pending: ?*c.IMFSample = null,
    pending_ns: u64 = 0,
    summary: Summary = .{},
    /// Номер звукового потока в контейнере, если звук пишется.
    audio_stream: ?c.DWORD = null,

    pub fn create(path: []const u8, width: u32, height: u32, settings: Settings) Error!Writer {
        if (builtin.os.tag != .windows) return Error.Unsupported;

        _ = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED | c.COINIT_DISABLE_OLE1DDE);
        if (win32.failed(c.MFStartup(c.MF_VERSION, c.MFSTARTUP_FULL))) return Error.StartupFailed;

        var attrs: ?*c.IMFAttributes = null;
        if (win32.failed(c.MFCreateAttributes(&attrs, 6))) return Error.CreateFailed;
        defer _ = attrs.?.lpVtbl.*.Release.?(@ptrCast(attrs.?));
        _ = attrs.?.lpVtbl.*.SetUINT32.?(attrs.?, &c.MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1);
        // Без этого писатель придерживает поток под частоту кадров, а нам нужно
        // отдать кадры так быстро, как они пришли с экрана.
        _ = attrs.?.lpVtbl.*.SetUINT32.?(attrs.?, &c.MF_SINK_WRITER_DISABLE_THROTTLING, 1);
        _ = attrs.?.lpVtbl.*.SetGUID.?(attrs.?, &c.MF_TRANSCODE_CONTAINERTYPE, &c.MFTranscodeContainerType_MPEG4);
        var path_buf: [std.fs.max_path_bytes]u16 = undefined;
        const wpath = std.unicode.utf8ToUtf16Le(&path_buf, path) catch return Error.CreateFailed;
        path_buf[wpath] = 0;
        const wpath_z: [*:0]const u16 = @ptrCast(&path_buf);

        var sink: ?*c.IMFSinkWriter = null;
        if (win32.failed(c.MFCreateSinkWriterFromURL(wpath_z, null, attrs, &sink))) return Error.CreateFailed;
        errdefer _ = sink.?.lpVtbl.*.Release.?(@ptrCast(sink.?));

        var self = Writer{ .width = width, .height = height, .settings = settings, .writer = sink.? };
        try self.configure();
        return self;
    }

    fn configure(self: *Writer) Error!void {
        // Выход: H.264.
        var out_type: ?*c.IMFMediaType = null;
        if (win32.failed(c.MFCreateMediaType(&out_type))) return Error.FormatRejected;
        defer _ = out_type.?.lpVtbl.*.Release.?(@ptrCast(out_type.?));
        const t = out_type.?;
        _ = t.lpVtbl.*.SetGUID.?(t, &c.MF_MT_MAJOR_TYPE, &c.MFMediaType_Video);
        _ = t.lpVtbl.*.SetGUID.?(t, &c.MF_MT_SUBTYPE, &c.MFVideoFormat_H264);
        _ = t.lpVtbl.*.SetUINT32.?(t, &c.MF_MT_AVG_BITRATE, self.settings.bitrate(self.width, self.height) * 1000);
        _ = t.lpVtbl.*.SetUINT32.?(t, &c.MF_MT_INTERLACE_MODE, c.MFVideoInterlace_Progressive);
        // eAVEncH264VProfile_High = 100: номер профиля из стандарта H.264,
        // самой константы в заголовках mingw нет.
        _ = t.lpVtbl.*.SetUINT32.?(t, &c.MF_MT_MPEG2_PROFILE, 100);
        _ = t.lpVtbl.*.SetUINT32.?(t, &c.MF_MT_MAX_KEYFRAME_SPACING, self.settings.gop);
        _ = setSize(t, &c.MF_MT_FRAME_SIZE, self.width, self.height);
        _ = setRatio(t, &c.MF_MT_FRAME_RATE, self.settings.fps, 1);
        _ = setRatio(t, &c.MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
        if (win32.failed(self.writer.lpVtbl.*.AddStream.?(self.writer, t, &self.stream))) return Error.FormatRejected;

        // Вход: BGRA, как отдают оба бэкенда захвата.
        var in_type: ?*c.IMFMediaType = null;
        if (win32.failed(c.MFCreateMediaType(&in_type))) return Error.FormatRejected;
        defer _ = in_type.?.lpVtbl.*.Release.?(@ptrCast(in_type.?));
        const i = in_type.?;
        _ = i.lpVtbl.*.SetGUID.?(i, &c.MF_MT_MAJOR_TYPE, &c.MFMediaType_Video);
        _ = i.lpVtbl.*.SetGUID.?(i, &c.MF_MT_SUBTYPE, &c.MFVideoFormat_RGB32);
        _ = i.lpVtbl.*.SetUINT32.?(i, &c.MF_MT_INTERLACE_MODE, c.MFVideoInterlace_Progressive);
        _ = setSize(i, &c.MF_MT_FRAME_SIZE, self.width, self.height);
        _ = setRatio(i, &c.MF_MT_FRAME_RATE, self.settings.fps, 1);
        _ = setRatio(i, &c.MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
        if (win32.failed(self.writer.lpVtbl.*.SetInputMediaType.?(self.writer, self.stream, i, null))) return Error.FormatRejected;

        if (self.settings.audio) |audio| try self.configureAudio(audio);

        if (win32.failed(self.writer.lpVtbl.*.BeginWriting.?(self.writer))) return Error.WriteFailed;
    }

    /// Второй поток в том же контейнере: звук в AAC.
    ///
    /// Оба потока добавляются до `BeginWriting`: после начала записи писатель
    /// новых потоков не принимает, и добавить звук «когда он появится» нельзя.
    /// Поэтому решение писать звук принимается при создании файла.
    fn configureAudio(self: *Writer, audio: AudioSettings) Error!void {
        var out_type: ?*c.IMFMediaType = null;
        if (win32.failed(c.MFCreateMediaType(&out_type))) return Error.FormatRejected;
        defer _ = out_type.?.lpVtbl.*.Release.?(@ptrCast(out_type.?));
        const t = out_type.?;
        _ = t.lpVtbl.*.SetGUID.?(t, &c.MF_MT_MAJOR_TYPE, &c.MFMediaType_Audio);
        _ = t.lpVtbl.*.SetGUID.?(t, &c.MF_MT_SUBTYPE, &c.MFAudioFormat_AAC);
        _ = t.lpVtbl.*.SetUINT32.?(t, &c.MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
        _ = t.lpVtbl.*.SetUINT32.?(t, &c.MF_MT_AUDIO_SAMPLES_PER_SECOND, audio.sample_rate);
        _ = t.lpVtbl.*.SetUINT32.?(t, &c.MF_MT_AUDIO_NUM_CHANNELS, audio.channels);
        _ = t.lpVtbl.*.SetUINT32.?(t, &c.MF_MT_AUDIO_AVG_BYTES_PER_SECOND, audio.bytesPerSecond());
        // Тип полезной нагрузки 0 — «сырой» AAC без заголовков ADTS: именно
        // такой ждёт контейнер mp4. С единицей получается файл, который
        // открывается, но звучит тишиной.
        _ = t.lpVtbl.*.SetUINT32.?(t, &c.MF_MT_AAC_PAYLOAD_TYPE, 0);

        var stream: c.DWORD = 0;
        if (win32.failed(self.writer.lpVtbl.*.AddStream.?(self.writer, t, &stream))) return Error.FormatRejected;

        var in_type: ?*c.IMFMediaType = null;
        if (win32.failed(c.MFCreateMediaType(&in_type))) return Error.FormatRejected;
        defer _ = in_type.?.lpVtbl.*.Release.?(@ptrCast(in_type.?));
        const i = in_type.?;
        _ = i.lpVtbl.*.SetGUID.?(i, &c.MF_MT_MAJOR_TYPE, &c.MFMediaType_Audio);
        _ = i.lpVtbl.*.SetGUID.?(i, &c.MF_MT_SUBTYPE, &c.MFAudioFormat_PCM);
        _ = i.lpVtbl.*.SetUINT32.?(i, &c.MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
        _ = i.lpVtbl.*.SetUINT32.?(i, &c.MF_MT_AUDIO_SAMPLES_PER_SECOND, audio.sample_rate);
        _ = i.lpVtbl.*.SetUINT32.?(i, &c.MF_MT_AUDIO_NUM_CHANNELS, audio.channels);
        _ = i.lpVtbl.*.SetUINT32.?(i, &c.MF_MT_AUDIO_BLOCK_ALIGNMENT, audio.blockAlign());
        _ = i.lpVtbl.*.SetUINT32.?(i, &c.MF_MT_AUDIO_AVG_BYTES_PER_SECOND, audio.sample_rate * audio.blockAlign());
        _ = i.lpVtbl.*.SetUINT32.?(i, &c.MF_MT_ALL_SAMPLES_INDEPENDENT, 1);
        if (win32.failed(self.writer.lpVtbl.*.SetInputMediaType.?(self.writer, stream, i, null))) return Error.FormatRejected;

        self.audio_stream = stream;
    }

    /// Отдать кусок звука. Отсчёты целые, чередующиеся по каналам.
    ///
    /// Метка времени — от начала записи, как у кадров. Длительность считается
    /// из числа отсчётов, а не из разницы меток: у звука длительность известна
    /// точно, и брать её из часов значило бы вносить дрожание там, где его нет.
    pub fn writeAudio(self: *Writer, samples: []const i16, timestamp_ns: u64) Error!void {
        if (builtin.os.tag != .windows) return Error.Unsupported;
        const audio = self.settings.audio orelse return;
        const stream = self.audio_stream orelse return;
        if (samples.len == 0) return;

        const bytes = samples.len * 2;
        var buf: ?*c.IMFMediaBuffer = null;
        if (win32.failed(c.MFCreateMemoryBuffer(@intCast(bytes), &buf))) return Error.OutOfMemory;
        defer _ = buf.?.lpVtbl.*.Release.?(@ptrCast(buf.?));

        var dst: [*c]u8 = undefined;
        if (win32.failed(buf.?.lpVtbl.*.Lock.?(buf.?, &dst, null, null))) return Error.WriteFailed;
        @memcpy(dst[0..bytes], std.mem.sliceAsBytes(samples));
        _ = buf.?.lpVtbl.*.Unlock.?(buf.?);
        _ = buf.?.lpVtbl.*.SetCurrentLength.?(buf.?, @intCast(bytes));

        var sample: ?*c.IMFSample = null;
        if (win32.failed(c.MFCreateSample(&sample))) return Error.OutOfMemory;
        defer _ = sample.?.lpVtbl.*.Release.?(@ptrCast(sample.?));
        _ = sample.?.lpVtbl.*.AddBuffer.?(sample.?, buf.?);
        _ = sample.?.lpVtbl.*.SetSampleTime.?(sample.?, win32.nsTo100ns(timestamp_ns));

        const frames = samples.len / @max(audio.channels, 1);
        const duration_ns = frames * std.time.ns_per_s / @max(audio.sample_rate, 1);
        _ = sample.?.lpVtbl.*.SetSampleDuration.?(sample.?, win32.nsTo100ns(duration_ns));

        if (win32.failed(self.writer.lpVtbl.*.WriteSample.?(self.writer, stream, sample.?))) return Error.WriteFailed;
        self.summary.audio_samples += frames;
    }

    /// Отдать кадр. `stride` может быть больше ширины: у DXGI строка выровнена.
    ///
    /// `timestamp_ns` — время **от начала записи**, а не показания часов.
    /// Писатель сам ничего не пересчитывает нарочно: пересчёт внутри писателя
    /// сдвигал бы видео к первому кадру, а звук остался бы на месте, и обе
    /// дорожки разъехались бы ровно на то время, что прошло между началом
    /// записи и первым пойманным кадром. Начало отсчёта одно, и задаёт его
    /// тот, кто пишет, — иначе дорожки не свести.
    pub fn writeFrame(self: *Writer, pixels: []const u8, stride: u32, timestamp_ns: u64) Error!void {
        if (builtin.os.tag != .windows) return Error.Unsupported;
        // Последняя строка может быть короче шага: так выглядит вырезанный
        // из большого кадра прямоугольник — там за концом строки уже чужие
        // пиксели, и требовать полный шаг на последней строке нельзя.
        const needed = @as(usize, stride) * (self.height - 1) + @as(usize, self.width) * 4;
        if (pixels.len < needed) return Error.WriteFailed;

        const dst_stride: u32 = self.width * 4;
        var buf: ?*c.IMFMediaBuffer = null;
        if (win32.failed(c.MFCreateMemoryBuffer(dst_stride * self.height, &buf))) return Error.OutOfMemory;
        defer _ = buf.?.lpVtbl.*.Release.?(@ptrCast(buf.?));

        var dst: [*c]u8 = undefined;
        if (win32.failed(buf.?.lpVtbl.*.Lock.?(buf.?, &dst, null, null))) return Error.WriteFailed;
        // Кадр переворачивается вверх ногами: для RGB32 Media Foundation ждёт
        // картинку снизу вверх, а захват отдаёт сверху вниз. Даём указатель на
        // последнюю строку и отрицательный шаг — MFCopyImage читает задом наперёд.
        // Поймано стендом: без этого таймкод после кодирования уезжал вниз кадра
        // и читался как мусор, хотя сам файл был исправен.
        const last_row = pixels.ptr + @as(usize, stride) * (self.height - 1);
        _ = c.MFCopyImage(
            dst,
            @intCast(dst_stride),
            last_row,
            -@as(i32, @intCast(stride)),
            dst_stride,
            self.height,
        );
        _ = buf.?.lpVtbl.*.Unlock.?(buf.?);
        _ = buf.?.lpVtbl.*.SetCurrentLength.?(buf.?, dst_stride * self.height);

        var sample: ?*c.IMFSample = null;
        if (win32.failed(c.MFCreateSample(&sample))) return Error.OutOfMemory;
        _ = sample.?.lpVtbl.*.AddBuffer.?(sample.?, buf.?);
        _ = sample.?.lpVtbl.*.SetSampleTime.?(sample.?, win32.nsTo100ns(timestamp_ns));

        // Предыдущий кадр теперь знает свою длительность — можно отдавать.
        if (self.pending) |prev| {
            const dur = timestamp_ns -| self.pending_ns;
            try self.flushPending(prev, dur);
        }
        self.pending = sample.?;
        self.pending_ns = timestamp_ns;
    }

    fn flushPending(self: *Writer, sample: *c.IMFSample, duration_ns: u64) Error!void {
        const nominal = std.time.ns_per_s / @max(self.settings.fps, 1);
        // Ноль длительности ломает таблицу времён в mp4; на всякий случай
        // подставляем номинальную длительность кадра.
        const dur = if (duration_ns == 0) nominal else duration_ns;
        _ = sample.lpVtbl.*.SetSampleDuration.?(sample, win32.nsTo100ns(dur));
        const hres = self.writer.lpVtbl.*.WriteSample.?(self.writer, self.stream, sample);
        _ = sample.lpVtbl.*.Release.?(@ptrCast(sample));
        self.pending = null;
        if (win32.failed(hres)) return Error.WriteFailed;
        self.summary.frames += 1;
        self.summary.duration_ns += dur;
    }

    /// Дописать последний кадр, закрыть файл и вернуть итог.
    pub fn finish(self: *Writer) Error!Summary {
        if (builtin.os.tag != .windows) return Error.Unsupported;
        if (self.pending) |prev| try self.flushPending(prev, 0);
        const hres = self.writer.lpVtbl.*.Finalize.?(self.writer);
        _ = self.writer.lpVtbl.*.Release.?(@ptrCast(self.writer));
        _ = c.MFShutdown();
        if (win32.failed(hres)) return Error.FinalizeFailed;
        return self.summary;
    }

    /// Бросить запись, не доводя файл до годного состояния.
    pub fn abort(self: *Writer) void {
        if (builtin.os.tag != .windows) return;
        if (self.pending) |p| {
            _ = p.lpVtbl.*.Release.?(@ptrCast(p));
            self.pending = null;
        }
        _ = self.writer.lpVtbl.*.Release.?(@ptrCast(self.writer));
        _ = c.MFShutdown();
    }
};

// ---------------------------------------------------------------- тесты

test "пресеты упорядочены по битрейту" {
    const w: u32 = 1920;
    const h: u32 = 1080;
    const fps: u32 = 60;
    try std.testing.expect(Preset.text_ui.bitrateKbps(w, h, fps) < Preset.video.bitrateKbps(w, h, fps));
    try std.testing.expect(Preset.video.bitrateKbps(w, h, fps) < Preset.max.bitrateKbps(w, h, fps));
}

test "битрейт не опускается ниже разумного минимума" {
    try std.testing.expectEqual(@as(u32, 500), Preset.text_ui.bitrateKbps(320, 240, 5));
}

test "битрейт не улетает вверх на больших экранах" {
    try std.testing.expect(Preset.max.bitrateKbps(7680, 4320, 120) <= 200_000);
}

test "явно заданный битрейт сильнее пресета" {
    const s = Settings{ .preset = .max, .bitrate_kbps = 3000 };
    try std.testing.expectEqual(@as(u32, 3000), s.bitrate(1920, 1080));
}

test "умолчания: пресет под текст, moov в начале" {
    const s = Settings{};
    try std.testing.expectEqual(Preset.text_ui, s.preset);
    try std.testing.expect(s.faststart);
}
