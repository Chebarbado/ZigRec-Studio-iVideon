//! Форма звуковой волны для полосы дорожки.
//!
//! Задача #24. «Отдельные звуковые дорожки видно» — это не полоска с именем
//! файла, а волна: по ней сразу читается, где речь, где пауза и где тишина.
//! Резать по волне можно глазами, а без неё приходится угадывать.
//!
//! Волна считается один раз при открытии файла и хранится **огибающей**,
//! а не отсчётами: на экране у дорожки от силы тысяча точек по ширине,
//! и держать ради них сотни мегабайт звука незачем. В каждом столбце
//! запоминаем самый громкий отсчёт — так пик не теряется, даже когда
//! в один столбец попадает минута записи.
//!
//! Раскладка по столбцам — чистый счёт и проверяется тестами. Декодирование
//! отдано Media Foundation: она уже умеет все форматы, которые мы открываем,
//! и своего декодера тут заводить незачем.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;

pub const Error = error{
    /// Файл не открылся или в нём нет звука.
    NoAudio,
    /// Media Foundation не поднялась.
    StartupFailed,
    Unsupported,
    OutOfMemory,
};

/// Сколько столбцов держим на файл. Тысяча с небольшим — это больше, чем
/// пикселей у дорожки на любом разумном экране, и при этом всего четыре
/// килобайта на файл.
pub const buckets = 1024;

/// Огибающая: по столбцу на каждую долю файла.
pub const Envelope = struct {
    peak: [buckets]f32 = @splat(0),
    /// Длительность звука, по которой раскладывались столбцы.
    duration_ns: u64 = 0,
    /// Самое громкое место файла. По нему волна и нормируется.
    loudest: f32 = 0,
    /// Есть ли что показывать.
    ready: bool = false,

    /// Столбец для момента времени внутри файла.
    pub fn bucketAt(self: *const Envelope, when_ns: u64) usize {
        if (self.duration_ns == 0) return 0;
        const at = when_ns * buckets / self.duration_ns;
        return @min(at, buckets - 1);
    }

    /// Самый громкий отсчёт на отрезке — то, что рисуется одним столбцом
    /// на экране. Берём максимум, а не среднее: среднее сглаживает всплеск
    /// до невидимости, и короткий щелчок пропадает с картинки.
    pub fn peakBetween(self: *const Envelope, from_ns: u64, to_ns: u64) f32 {
        if (!self.ready or to_ns <= from_ns) return 0;
        const first = self.bucketAt(from_ns);
        const last = self.bucketAt(to_ns -| 1);
        var top: f32 = 0;
        var i = first;
        while (i <= last and i < buckets) : (i += 1) top = @max(top, self.peak[i]);
        return top;
    }

    /// Высота волны на отрезке, 0…1 — то, что рисуется.
    ///
    /// **Нормируем по самому громкому месту файла**, а не по полной шкале.
    /// Тихая запись в абсолютном масштабе даёт волну в один пиксель: видно,
    /// что дорожка есть, и больше ничего. Волна отвечает на вопрос «где речь,
    /// а где пауза»; на вопрос «насколько громко» отвечает индикатор уровня,
    /// и там децибелы настоящие.
    ///
    /// Тишина остаётся тишиной: у файла без звука `loudest` нулевой, и рисовать
    /// нечего. И внутри одного файла соотношение громкого и тихого сохраняется,
    /// поэтому пауза не превращается в речь.
    pub fn relativeBetween(self: *const Envelope, from_ns: u64, to_ns: u64) f32 {
        if (!self.ready or self.loudest <= 0) return 0;
        return @min(self.peakBetween(from_ns, to_ns) / self.loudest, 1.0);
    }
};

/// Накопитель: складывает отсчёты в столбцы по мере чтения файла.
///
/// Отдельно от чтения, потому что это и есть та часть, где можно ошибиться
/// молча: не туда разложить, потерять хвост, поделить на ноль.
pub const Builder = struct {
    envelope: Envelope = .{},
    /// Сколько отсчётов приходится на столбец.
    per_bucket: f64 = 0,
    /// Сколько отсчётов уже положено.
    seen: u64 = 0,

    pub fn init(total_samples: u64, duration_ns: u64) Builder {
        var b = Builder{};
        b.envelope.duration_ns = duration_ns;
        b.per_bucket = @as(f64, @floatFromInt(@max(total_samples, 1))) / @as(f64, buckets);
        return b;
    }

    pub fn push(self: *Builder, value: f32) void {
        const index_f = @as(f64, @floatFromInt(self.seen)) / @max(self.per_bucket, 1);
        const index: usize = @min(@as(usize, @intFromFloat(index_f)), buckets - 1);
        const a = @abs(value);
        if (a > self.envelope.peak[index]) self.envelope.peak[index] = a;
        self.seen += 1;
    }

    pub fn finish(self: *Builder) Envelope {
        // Пустой файл — не повод показывать полосу шума: пусть будет ровно
        // ничего, и это честнее нарисованной наугад волны.
        self.envelope.ready = self.seen > 0;
        var top: f32 = 0;
        for (self.envelope.peak) |v| top = @max(top, v);
        self.envelope.loudest = top;
        return self.envelope;
    }
};

/// Прочитать звук файла и сложить огибающую.
///
/// Декодирует Media Foundation: она открывает всё, что открываем мы, и своего
/// декодера тут заводить незачем. Формат просим один — 32-битный вещественный
/// моно: сводить каналы самим дешевле, чем разбирать чужую раскладку.
pub fn read(path: []const u8) Error!Envelope {
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

    // Видео не читаем вовсе: нам нужен только звук, а декодировать картинку
    // ради волны — это минуты вместо секунд.
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

    const duration_ns = durationOf(r);
    const total = duration_ns * rate / std.time.ns_per_s;
    var builder = Builder.init(@max(total, 1), duration_ns);

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
            // Сводим каналы средним: у стерео говорят в оба, и брать первый
            // значит иногда нарисовать тишину при слышимом звуке.
            var sum: f32 = 0;
            var ch: usize = 0;
            while (ch < channels) : (ch += 1) sum += floats[i + ch];
            builder.push(sum / @as(f32, @floatFromInt(channels)));
        }
        _ = buffer.?.lpVtbl.*.Unlock.?(buffer.?);
    }

    const done = builder.finish();
    if (!done.ready) return Error.NoAudio;
    return done;
}

/// Длительность файла по мнению самого источника.
fn durationOf(r: *c.IMFSourceReader) u64 {
    var value = std.mem.zeroes(c.PROPVARIANT);
    if (win32.failed(r.lpVtbl.*.GetPresentationAttribute.?(
        r,
        c.MF_SOURCE_READER_MEDIASOURCE,
        &c.MF_PD_DURATION,
        &value,
    ))) return 0;
    defer _ = c.PropVariantClear(&value);
    // Длительность приходит в сотнях наносекунд. Путь до поля длинный,
    // потому что в заголовке это вложенные безымянные объединения, и
    // translate-c называет их по порядку: union → struct → union → поле.
    return @as(u64, @intCast(value.unnamed_0.unnamed_0.unnamed_0.uhVal.QuadPart)) * 100;
}

// ---------------------------------------------------------------- тесты

const sec = std.time.ns_per_s;

test "столбцы раскладываются по всей длине, а не кучей в начале" {
    var b = Builder.init(buckets * 10, 10 * sec);
    var i: usize = 0;
    while (i < buckets * 10) : (i += 1) b.push(1.0);
    const e = b.finish();

    try std.testing.expect(e.ready);
    // Ни один столбец не остался пустым.
    for (e.peak) |v| try std.testing.expectApproxEqAbs(@as(f32, 1.0), v, 0.001);
}

test "в столбце остаётся самый громкий отсчёт, а не средний" {
    // Тишина с одним щелчком: среднее размазало бы его до невидимости.
    var b = Builder.init(1000, sec);
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        b.push(if (i == 500) 0.9 else 0.0);
    }
    const e = b.finish();

    var loudest: f32 = 0;
    for (e.peak) |v| loudest = @max(loudest, v);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), loudest, 0.001);
}

test "знак не теряется: отрицательный отсчёт так же громок" {
    var b = Builder.init(10, sec);
    b.push(-0.7);
    const e = b.finish();
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), e.peak[0], 0.001);
}

test "момент времени попадает в свой столбец" {
    var b = Builder.init(1000, 10 * sec);
    const e = b.finish();
    try std.testing.expectEqual(@as(usize, 0), e.bucketAt(0));
    try std.testing.expectEqual(@as(usize, buckets / 2), e.bucketAt(5 * sec));
    // За концом файла столбец не убегает за край.
    try std.testing.expectEqual(@as(usize, buckets - 1), e.bucketAt(100 * sec));
}

test "пик на отрезке берётся по всем задетым столбцам" {
    var b = Builder.init(buckets, 10 * sec);
    var i: usize = 0;
    while (i < buckets) : (i += 1) {
        b.push(if (i == buckets - 1) 0.8 else 0.1);
    }
    const e = b.finish();

    // Отрезок в начале — тихий.
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), e.peakBetween(0, sec), 0.01);
    // Отрезок, задевающий конец, — громкий.
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), e.peakBetween(9 * sec, 10 * sec), 0.01);
}

test "пустая огибающая не рисуется" {
    var b = Builder.init(1000, sec);
    const e = b.finish();
    try std.testing.expect(!e.ready);
    try std.testing.expectEqual(@as(f32, 0), e.peakBetween(0, sec));
}

test "нулевая длительность не делит на ноль" {
    const e = Envelope{};
    try std.testing.expectEqual(@as(usize, 0), e.bucketAt(5 * sec));
    try std.testing.expectEqual(@as(f32, 0), e.peakBetween(0, sec));
}

test "короткий файл: отсчётов меньше, чем столбцов" {
    // Столбцов тысяча, а отсчётов десять — раскладка не должна падать
    // и не должна оставлять мусор.
    var b = Builder.init(10, sec / 10);
    var i: usize = 0;
    while (i < 10) : (i += 1) b.push(0.5);
    const e = b.finish();
    try std.testing.expect(e.ready);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), e.peak[0], 0.001);
}

test "волна нормируется по самому громкому месту файла" {
    // Тихая запись: пик 0.02, то есть около минус тридцати четырёх децибел.
    // В абсолютном масштабе это волна в один пиксель — видно, что дорожка
    // есть, и больше ничего.
    var b = Builder.init(buckets, 10 * sec);
    var i: usize = 0;
    while (i < buckets) : (i += 1) {
        b.push(if (i < buckets / 2) 0.02 else 0.005);
    }
    const e = b.finish();

    try std.testing.expectApproxEqAbs(@as(f32, 0.02), e.loudest, 0.001);
    // Громкая половина рисуется во всю высоту.
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), e.relativeBetween(0, sec), 0.01);
    // Тихая — вчетверо ниже: соотношение внутри файла сохраняется,
    // пауза не превращается в речь.
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), e.relativeBetween(9 * sec, 10 * sec), 0.01);
}

test "тишина остаётся тишиной, а не растягивается до вида речи" {
    var b = Builder.init(buckets, sec);
    var i: usize = 0;
    while (i < buckets) : (i += 1) b.push(0.0);
    const e = b.finish();
    try std.testing.expectEqual(@as(f32, 0), e.loudest);
    try std.testing.expectEqual(@as(f32, 0), e.relativeBetween(0, sec));
}
