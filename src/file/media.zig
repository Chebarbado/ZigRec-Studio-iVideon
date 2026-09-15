//! Что за файл и что в нём: один вход для всех форматов, которые мы открываем.
//!
//! Задача #44. Пока программа открывала только то, что записала сама,
//! редактор проверить нечем: нет ни чужого файла с двумя звуковыми дорожками,
//! ни `.mp3` рядом с видео. Поэтому чтение идёт раньше правки.
//!
//! **Формат определяется по содержимому, а не по расширению.** Расширение
//! врёт: `.mp4` бывает у чего угодно, а у нужного файла его может не быть
//! вовсе. Смотрим подпись в первых байтах.
//!
//! Разбираем только заголовок — столько, сколько нужно таймлайну: длительность,
//! дорожки, их вид, кодек, размер кадра. Декодировать здесь нечего: чтобы
//! показать полосу дорожки, картинка не нужна.
const std = @import("std");
const probe = @import("probe.zig");
const gif_mod = @import("gif.zig");
const wav = @import("../sound/wav.zig");

pub const Error = error{
    /// Ни одна подпись не подошла.
    Unknown,
    /// Подпись своя, а дальше файл обрывается.
    Truncated,
    /// Формат узнан, но внутри не то, что мы умеем.
    Unsupported,
};

pub const Format = enum {
    mp4,
    mov,
    avi,
    wav,
    mp3,
    flac,
    ogg,
    midi,
    gif,

    pub fn label(self: Format) []const u8 {
        return switch (self) {
            .mp4 => "MP4",
            .mov => "QuickTime MOV",
            .avi => "AVI",
            .wav => "WAV",
            .mp3 => "MP3",
            .flac => "FLAC",
            .ogg => "OGG",
            .midi => "MIDI",
            .gif => "GIF",
        };
    }

    /// Бывает ли в таком файле картинка. У звуковых форматов — нет,
    /// и таймлайну незачем искать в них видеодорожку.
    pub fn mayHaveVideo(self: Format) bool {
        return switch (self) {
            .mp4, .mov, .avi, .gif => true,
            .wav, .mp3, .flac, .ogg, .midi => false,
        };
    }
};

pub const Kind = probe.Kind;
pub const max_tracks = probe.max_tracks;

pub const Track = struct {
    kind: Kind = .audio,
    /// Как называть кодек человеку.
    codec: []const u8 = "неизвестно",
    duration_ns: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    sample_rate: u32 = 0,
    channels: u16 = 0,
    /// Кадров в секунду; у звука ноль.
    fps: f64 = 0,

    pub fn seconds(self: Track) f64 {
        return @as(f64, @floatFromInt(self.duration_ns)) / @as(f64, std.time.ns_per_s);
    }
};

pub const Info = struct {
    format: Format,
    duration_ns: u64 = 0,
    tracks: [max_tracks]Track = @splat(.{}),
    count: usize = 0,

    pub fn list(self: *const Info) []const Track {
        return self.tracks[0..self.count];
    }

    pub fn seconds(self: *const Info) f64 {
        return @as(f64, @floatFromInt(self.duration_ns)) / @as(f64, std.time.ns_per_s);
    }

    fn add(self: *Info, track: Track) void {
        if (self.count >= max_tracks) return;
        self.tracks[self.count] = track;
        self.count += 1;
        self.duration_ns = @max(self.duration_ns, track.duration_ns);
    }
};

/// Узнать формат по первым байтам.
///
/// Порядок проверок не случаен: подписи с точным положением идут раньше тех,
/// что ищутся перебором. `.mp3` без тега опознаётся по первому кадру, и это
/// самая слабая примета — поэтому она последняя.
pub fn detect(data: []const u8) Error!Format {
    if (data.len < 12) return Error.Truncated;

    if (std.mem.eql(u8, data[0..4], "RIFF")) {
        if (std.mem.eql(u8, data[8..12], "WAVE")) return .wav;
        if (std.mem.eql(u8, data[8..12], "AVI ")) return .avi;
        return Error.Unsupported;
    }
    if (gif_mod.looksLikeGif(data)) return .gif;
    if (std.mem.eql(u8, data[0..4], "fLaC")) return .flac;
    if (std.mem.eql(u8, data[0..4], "OggS")) return .ogg;
    if (std.mem.eql(u8, data[0..4], "MThd")) return .midi;

    // У mp4 и mov подпись на четвёртом байте, внутри бокса `ftyp`.
    if (std.mem.eql(u8, data[4..8], "ftyp")) {
        const brand = data[8..12];
        if (std.mem.eql(u8, brand, "qt  ")) return .mov;
        return .mp4;
    }

    // Тег ID3 стоит перед звуком и сам по себе значит mp3.
    if (std.mem.eql(u8, data[0..3], "ID3")) return .mp3;

    // Голый mp3: ищем первый кадр в начале файла.
    if (findMpegFrame(data, 0, @min(data.len, 8192)) != null) return .mp3;

    return Error.Unknown;
}

// ------------------------------------------------------------------ MPEG

/// Таблицы битрейта и частоты для MPEG-1/2 Layer III — те, что нужны, чтобы
/// узнать длину кадра. Ноль означает «запрещённое значение».
const mpeg_bitrate_v1_l3 = [16]u32{ 0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0 };
const mpeg_bitrate_v2_l3 = [16]u32{ 0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0 };
const mpeg_rate_v1 = [4]u32{ 44100, 48000, 32000, 0 };

const MpegFrame = struct {
    at: usize,
    length: usize,
    sample_rate: u32,
    channels: u16,
    /// Отсчётов в кадре: у Layer III это 1152, у MPEG-2 — 576.
    samples: u32,
};

/// Найти кадр MPEG audio начиная с `from`.
///
/// Кадр начинается с одиннадцати единиц подряд. Одной подписи мало: в любом
/// файле такое сочетание встречается случайно, поэтому проверяем ещё и поля —
/// запрещённые значения битрейта и частоты отсекают ложные находки.
fn findMpegFrame(data: []const u8, from: usize, until: usize) ?MpegFrame {
    var at = from;
    const stop = @min(until, data.len -| 4);
    while (at < stop) : (at += 1) {
        if (data[at] != 0xFF or (data[at + 1] & 0xE0) != 0xE0) continue;

        const version_bits = (data[at + 1] >> 3) & 0x03;
        const layer_bits = (data[at + 1] >> 1) & 0x03;
        if (version_bits == 1) continue; // зарезервировано
        if (layer_bits == 0) continue; // зарезервировано

        const bitrate_index = (data[at + 2] >> 4) & 0x0F;
        const rate_index = (data[at + 2] >> 2) & 0x03;
        if (bitrate_index == 0 or bitrate_index == 15) continue;
        if (rate_index == 3) continue;

        const is_v1 = version_bits == 3;
        const kbps = if (is_v1) mpeg_bitrate_v1_l3[bitrate_index] else mpeg_bitrate_v2_l3[bitrate_index];
        if (kbps == 0) continue;

        var rate = mpeg_rate_v1[rate_index];
        if (!is_v1) rate /= 2;
        if (version_bits == 0) rate /= 2; // MPEG 2.5
        if (rate == 0) continue;

        const padding: u32 = (data[at + 2] >> 1) & 0x01;
        const samples: u32 = if (is_v1) 1152 else 576;
        const length = samples / 8 * kbps * 1000 / rate + padding;
        if (length < 24) continue;

        const mode = (data[at + 3] >> 6) & 0x03;
        return .{
            .at = at,
            .length = length,
            .sample_rate = rate,
            .channels = if (mode == 3) 1 else 2,
            .samples = samples,
        };
    }
    return null;
}

/// Где кончается тег ID3v2, если он есть.
fn skipId3(data: []const u8) usize {
    if (data.len < 10 or !std.mem.eql(u8, data[0..3], "ID3")) return 0;
    // Размер записан семибитными группами: старший бит каждого байта не в счёт.
    const size = (@as(usize, data[6] & 0x7F) << 21) |
        (@as(usize, data[7] & 0x7F) << 14) |
        (@as(usize, data[8] & 0x7F) << 7) |
        @as(usize, data[9] & 0x7F);
    return @min(10 + size, data.len);
}

fn readMp3(data: []const u8) Error!Info {
    const start = skipId3(data);
    const first = findMpegFrame(data, start, data.len) orelse return Error.Unsupported;

    // Идём по кадрам и считаем их. Длительность по числу кадров точнее, чем
    // «размер поделить на битрейт»: у файла с переменным битрейтом второе
    // врёт тем сильнее, чем длиннее файл.
    var count: u64 = 0;
    var at = first.at;
    while (at + 4 <= data.len) {
        const frame = findMpegFrame(data, at, @min(at + 8, data.len)) orelse {
            const next = findMpegFrame(data, at, data.len) orelse break;
            at = next.at;
            continue;
        };
        count += 1;
        at += frame.length;
    }

    var info = Info{ .format = .mp3 };
    const total_samples = count * first.samples;
    info.add(.{
        .kind = .audio,
        .codec = "MP3",
        .duration_ns = total_samples * std.time.ns_per_s / @max(first.sample_rate, 1),
        .sample_rate = first.sample_rate,
        .channels = first.channels,
    });
    return info;
}

// ------------------------------------------------------------------ FLAC

fn readFlac(data: []const u8) Error!Info {
    // Сразу за подписью идёт блок STREAMINFO: четыре байта заголовка блока,
    // затем 34 байта самих сведений.
    if (data.len < 4 + 4 + 18) return Error.Truncated;
    const body = data[8..];

    const rate: u32 = (@as(u32, body[10]) << 12) | (@as(u32, body[11]) << 4) | (@as(u32, body[12]) >> 4);
    const channels: u16 = @as(u16, (body[12] >> 1) & 0x07) + 1;
    // Поля лежат не по байтовым границам: частота занимает 20 бит, каналы 3,
    // разрядность 5, и только потом идут 36 бит числа отсчётов. Отсчитать их
    // на байт раньше — получить длительность в двое суток вместо десяти
    // секунд; ровно это и поймал тест.
    const total: u64 = (@as(u64, body[13] & 0x0F) << 32) |
        (@as(u64, body[14]) << 24) |
        (@as(u64, body[15]) << 16) |
        (@as(u64, body[16]) << 8) |
        @as(u64, body[17]);

    var info = Info{ .format = .flac };
    info.add(.{
        .kind = .audio,
        .codec = "FLAC",
        .duration_ns = if (rate == 0) 0 else total * std.time.ns_per_s / rate,
        .sample_rate = rate,
        .channels = channels,
    });
    return info;
}

// ------------------------------------------------------------------- OGG

fn readOgg(data: []const u8) Error!Info {
    // Длительность лежит в позиции последней страницы: это номер последнего
    // отсчёта. Частоту берём из заголовка Vorbis или Opus в первой странице.
    var rate: u32 = 0;
    var channels: u16 = 0;
    var codec: []const u8 = "OGG";

    if (std.mem.indexOf(u8, data[0..@min(data.len, 4096)], "vorbis")) |at| {
        // За словом идёт версия (4 байта), каналы (1), частота (4).
        if (at + 6 + 9 <= data.len) {
            channels = data[at + 6 + 4];
            rate = std.mem.readInt(u32, data[at + 6 + 5 ..][0..4], .little);
            codec = "Vorbis";
        }
    } else if (std.mem.indexOf(u8, data[0..@min(data.len, 4096)], "OpusHead")) |at| {
        if (at + 8 + 8 <= data.len) {
            channels = data[at + 8 + 1];
            rate = std.mem.readInt(u32, data[at + 8 + 4 ..][0..4], .little);
            codec = "Opus";
        }
    }

    // Ищем последнюю страницу с конца: подпись `OggS`, затем через шесть
    // байт — позиция.
    var granule: u64 = 0;
    var at: usize = data.len -| 4;
    while (at > 0) : (at -= 1) {
        if (!std.mem.eql(u8, data[at..][0..4], "OggS")) continue;
        if (at + 14 > data.len) continue;
        granule = std.mem.readInt(u64, data[at + 6 ..][0..8], .little);
        break;
    }

    var info = Info{ .format = .ogg };
    info.add(.{
        .kind = .audio,
        .codec = codec,
        .duration_ns = if (rate == 0) 0 else granule * std.time.ns_per_s / rate,
        .sample_rate = rate,
        .channels = channels,
    });
    return info;
}

// ------------------------------------------------------------------ MIDI

fn readMidi(data: []const u8) Error!Info {
    if (data.len < 14) return Error.Truncated;
    const tracks = std.mem.readInt(u16, data[10..12], .big);

    var info = Info{ .format = .midi };
    // У MIDI нет ни частоты, ни длительности в заголовке: длительность
    // считается проигрыванием событий. Показываем дорожки как есть —
    // редактору этого хватает, чтобы их расставить.
    var i: u16 = 0;
    while (i < tracks and i < max_tracks) : (i += 1) {
        info.add(.{ .kind = .audio, .codec = "MIDI" });
    }
    if (info.count == 0) return Error.Unsupported;
    return info;
}

// ------------------------------------------------------------------- AVI

fn readAvi(data: []const u8) Error!Info {
    var info = Info{ .format = .avi };

    // `avih` в списке `hdrl`: микросекунды на кадр и число кадров.
    var micros_per_frame: u32 = 0;
    var total_frames: u32 = 0;
    if (std.mem.indexOf(u8, data, "avih")) |at| {
        if (at + 8 + 24 <= data.len) {
            micros_per_frame = std.mem.readInt(u32, data[at + 8 ..][0..4], .little);
            total_frames = std.mem.readInt(u32, data[at + 8 + 16 ..][0..4], .little);
        }
    }
    const file_ns: u64 = @as(u64, micros_per_frame) * total_frames * 1000;

    // Каждая дорожка описана парой `strh` (что это) и `strf` (подробности).
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, data, at, "strh")) |found| {
        at = found + 4;
        if (found + 8 + 12 > data.len) break;
        const kind_tag = data[found + 8 ..][0..4];

        const scale = std.mem.readInt(u32, data[found + 8 + 20 ..][0..4], .little);
        const rate = std.mem.readInt(u32, data[found + 8 + 24 ..][0..4], .little);
        const length = std.mem.readInt(u32, data[found + 8 + 32 ..][0..4], .little);
        const per_second: f64 = if (scale == 0) 0 else @as(f64, @floatFromInt(rate)) / @as(f64, @floatFromInt(scale));
        const secs: f64 = if (per_second == 0) 0 else @as(f64, @floatFromInt(length)) / per_second;
        const dur_ns: u64 = @intFromFloat(secs * @as(f64, std.time.ns_per_s));

        if (std.mem.eql(u8, kind_tag, "vids")) {
            var track = Track{
                .kind = .video,
                .codec = "видео",
                .duration_ns = if (dur_ns > 0) dur_ns else file_ns,
                .fps = per_second,
            };
            // Размер кадра — в `strf` следом, это BITMAPINFOHEADER.
            if (std.mem.indexOfPos(u8, data, found, "strf")) |sf| {
                if (sf + 8 + 12 <= data.len) {
                    track.width = std.mem.readInt(u32, data[sf + 8 + 4 ..][0..4], .little);
                    track.height = std.mem.readInt(u32, data[sf + 8 + 8 ..][0..4], .little);
                }
            }
            info.add(track);
        } else if (std.mem.eql(u8, kind_tag, "auds")) {
            var track = Track{
                .kind = .audio,
                .codec = "звук",
                .duration_ns = if (dur_ns > 0) dur_ns else file_ns,
            };
            if (std.mem.indexOfPos(u8, data, found, "strf")) |sf| {
                if (sf + 8 + 8 <= data.len) {
                    track.channels = std.mem.readInt(u16, data[sf + 8 + 2 ..][0..2], .little);
                    track.sample_rate = std.mem.readInt(u32, data[sf + 8 + 4 ..][0..4], .little);
                }
            }
            info.add(track);
        }
    }

    if (info.count == 0) return Error.Unsupported;
    if (info.duration_ns == 0) info.duration_ns = file_ns;
    return info;
}

// ------------------------------------------------------------------- WAV

fn readWav(data: []const u8) Error!Info {
    const got = wav.parse(data) catch return Error.Unsupported;
    var info = Info{ .format = .wav };
    info.add(.{
        .kind = .audio,
        .codec = if (got.format == .float) "WAV (веществ.)" else "WAV (PCM)",
        .duration_ns = @intFromFloat(got.durationSeconds() * @as(f64, std.time.ns_per_s)),
        .sample_rate = got.sample_rate,
        .channels = got.channels,
    });
    return info;
}

// --------------------------------------------------------------- mp4 и mov

fn readBoxes(data: []const u8, format: Format) Error!Info {
    const got = probe.parse(data) catch |err| return switch (err) {
        probe.Error.Truncated => Error.Truncated,
        else => Error.Unsupported,
    };

    var info = Info{ .format = format, .duration_ns = got.duration_ns };
    for (got.list()) |t| {
        info.add(.{
            .kind = t.kind,
            .codec = t.codecLabel(),
            .duration_ns = t.duration_ns,
            .width = t.width,
            .height = t.height,
            .fps = t.fps(),
        });
    }
    if (info.count == 0) return Error.Unsupported;
    return info;
}

/// Разобрать файл из буфера: сначала формат, потом его дорожки.
pub fn parse(data: []const u8) Error!Info {
    return switch (try detect(data)) {
        .mp4 => readBoxes(data, .mp4),
        .mov => readBoxes(data, .mov),
        .avi => readAvi(data),
        .wav => readWav(data),
        .mp3 => readMp3(data),
        .flac => readFlac(data),
        .ogg => readOgg(data),
        .midi => readMidi(data),
        .gif => readGif(data),
    };
}

/// Что в GIF: размер холста, число кадров и общая длительность петли.
///
/// Разбираем целиком, а не заголовок: в GIF нет оглавления, и узнать,
/// сколько в нём кадров и сколько это по времени, можно только пройдя
/// его до конца. Зато после этого известно всё и точно.
fn readGif(data: []const u8) Error!Info {
    // Считаем без выделения памяти под кадры: здесь нужны только числа.
    const counted = gif_mod.measure(data) catch |err| return switch (err) {
        gif_mod.Error.NotGif => Error.Unknown,
        gif_mod.Error.Truncated => Error.Truncated,
        else => Error.Unsupported,
    };

    var out = Info{ .format = .gif };
    out.add(.{
        .kind = .video,
        .codec = "GIF (LZW)",
        .duration_ns = counted.total_ns,
        .width = counted.width,
        .height = counted.height,
        .fps = if (counted.total_ns > 0)
            @as(f64, @floatFromInt(counted.frames)) /
                (@as(f64, @floatFromInt(counted.total_ns)) / @as(f64, std.time.ns_per_s))
        else
            0,
    });
    return out;
}

/// Сколько головы файла обычно хватает, чтобы узнать, что внутри.
///
/// Восемь мегабайт: в них помещается оглавление часовой записи. Число
/// подобрано не на глаз — оглавление mp4 растёт примерно по килобайту
/// на секунду видео, и восьми мегабайт хватает на два часа с запасом.
pub const head_limit: usize = 8 << 20;

/// Прочитать файл с диска и разобрать.
///
/// Сначала пробуем обойтись головой файла: полутарагигабайтную запись
/// незачем поднимать в память целиком ради того, чтобы узнать её длину
/// и дорожки. Если в голове оглавления не оказалось — читаем целиком.
///
/// Оглавление бывает и в хвосте: так пишут те, кто не переносит `moov`
/// в начало. Мы своё переносим, но чужие файлы бывают всякие, и отказывать
/// им нельзя.
pub fn read(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Info {
    if (readHead(io, allocator, path)) |quick| {
        if (usable(quick)) return quick;
    } else |_| {}

    // У mp4 оглавление бывает и в хвосте: так пишут те, кто не переносит
    // `moov` в начало. Идём к нему по цепочке боксов — это несколько чтений
    // по шестнадцать байт, а не полтораста мегабайт середины.
    if (peekFormat(io, path)) |format| {
        if (format == .mp4 or format == .mov) {
            if (readMoovOnly(io, allocator, path, format)) |quick| {
                if (usable(quick)) return quick;
            } else |_| {}
        }
    } else |_| {}

    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 31));
    defer allocator.free(data);
    return parse(data);
}

/// Узнать формат по первым байтам, не читая файл.
pub fn peekFormat(io: std.Io, path: []const u8) !Format {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var scratch: [512]u8 = undefined;
    var reader = file.reader(io, &scratch);
    var head: [64]u8 = undefined;
    const got = try reader.interface.readSliceShort(&head);
    return detect(head[0..got]);
}

/// Больше этого оглавление mp4 не бывает.
///
/// Шестьдесят четыре мегабайта — это оглавление многочасовой записи
/// с мелкими кусками. Больше — признак того, что мы читаем не оглавление,
/// а приняли за него что-то другое.
const max_moov: u64 = 64 << 20;

/// Дойти до `moov` по цепочке боксов и прочитать только его.
///
/// Боксы верхнего уровня идут подряд, и каждый называет свою длину.
/// Значит, до оглавления можно дошагать, читая по шестнадцать байт
/// на шаг, — и не трогать самую тяжёлую часть файла, картинку и звук.
fn readMoovOnly(io: std.Io, allocator: std.mem.Allocator, path: []const u8, format: Format) !Info {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var scratch: [4096]u8 = undefined;
    var reader = file.reader(io, &scratch);
    const size = try reader.getSize();

    var at: u64 = 0;
    // Боксов верхнего уровня в mp4 единицы. Ограничение — от испорченного
    // файла, в котором длина бокса нулевая и шаг не двигается с места.
    var guard: usize = 0;
    while (at + 8 <= size and guard < 256) : (guard += 1) {
        try reader.seekTo(at);
        var head: [16]u8 = undefined;
        const got = try reader.interface.readSliceShort(&head);
        if (got < 8) break;

        var length: u64 = std.mem.readInt(u32, head[0..4], .big);
        const name = head[4..8];
        if (length == 1) {
            if (got < 16) break;
            length = std.mem.readInt(u64, head[8..16], .big);
        }
        if (length == 0) length = size - at;
        if (length < 8 or at + length > size) break;

        if (std.mem.eql(u8, name, "moov")) {
            if (length > max_moov) return Error.Unsupported;
            const buf = try allocator.alloc(u8, @intCast(length));
            defer allocator.free(buf);
            try reader.seekTo(at);
            const read_len = try reader.interface.readSliceShort(buf);
            if (read_len < length) return Error.Truncated;
            // Разбираем один бокс: внутри него все ссылки свои, и ничего
            // из остального файла ему не нужно.
            return readBoxes(buf[0..read_len], format);
        }

        at += length;
    }
    return Error.Unsupported;
}

/// Годится ли разбор по голове: дорожки нашлись и длительность известна.
fn usable(info: Info) bool {
    return info.count > 0 and info.duration_ns > 0;
}

/// Разобрать только начало файла.
pub fn readHead(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Info {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    // Буфер чтения и место под данные — разные вещи. Отдать читателю тот же
    // кусок памяти, в который он же и читает, значит получить кашу: он
    // складывает туда своё.
    const head = try allocator.alloc(u8, head_limit);
    defer allocator.free(head);
    var scratch: [64 * 1024]u8 = undefined;

    var reader = file.reader(io, &scratch);
    // `readSliceShort` честно отдаёт, сколько прочиталось: короткий файл —
    // не ошибка, а просто короткий файл.
    const got = try reader.interface.readSliceShort(head);
    if (got == 0) return Error.Truncated;
    return parse(head[0..got]);
}

/// Объяснение ошибки словами — для окна и для командной строки.
pub fn explain(err: anyerror) []const u8 {
    return switch (err) {
        Error.Unknown => "формат файла не узнан: это не видео и не звук из тех, что мы открываем",
        Error.Truncated => "файл обрывается на заголовке: скорее всего, он скопирован не до конца",
        Error.Unsupported => "формат узнан, но внутри то, чего мы пока не умеем",
        else => "файл не читается",
    };
}

// ---------------------------------------------------------------- тесты

fn riff(kind: []const u8, body: []const u8, buf: []u8) []const u8 {
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], @intCast(4 + body.len), .little);
    @memcpy(buf[8..12], kind);
    @memcpy(buf[12..][0..body.len], body);
    return buf[0 .. 12 + body.len];
}

test "формат узнаётся по содержимому, а не по расширению" {
    var buf: [64]u8 = @splat(0);

    try std.testing.expectEqual(Format.wav, try detect(riff("WAVE", "fmt ", &buf)));
    try std.testing.expectEqual(Format.avi, try detect(riff("AVI ", "hdrl", &buf)));

    try std.testing.expectEqual(Format.flac, try detect("fLaC" ++ [_]u8{0} ** 40));
    try std.testing.expectEqual(Format.ogg, try detect("OggS" ++ [_]u8{0} ** 40));
    try std.testing.expectEqual(Format.midi, try detect("MThd" ++ [_]u8{0} ** 40));
    try std.testing.expectEqual(Format.mp3, try detect("ID3\x04\x00\x00" ++ [_]u8{0} ** 40));

    try std.testing.expectEqual(Format.mp4, try detect([_]u8{ 0, 0, 0, 24 } ++ "ftypisom" ++ [_]u8{0} ** 20));
    try std.testing.expectEqual(Format.mov, try detect([_]u8{ 0, 0, 0, 24 } ++ "ftypqt  " ++ [_]u8{0} ** 20));
}

test "чужой файл не притворяется своим" {
    try std.testing.expectError(Error.Unknown, detect("просто текст, довольно длинный, чтобы хватило байтов"));
    try std.testing.expectError(Error.Truncated, detect("кор"));
    // RIFF бывает не только у звука и видео.
    var buf: [64]u8 = @splat(0);
    try std.testing.expectError(Error.Unsupported, detect(riff("CDDA", "fmt ", &buf)));
}

test "FLAC: частота, каналы, длительность из STREAMINFO" {
    var data: [8 + 34]u8 = @splat(0);
    @memcpy(data[0..4], "fLaC");
    data[4] = 0x80; // последний блок, тип STREAMINFO
    data[7] = 34;

    const body = data[8..];
    // 44100 Гц, два канала, 441000 отсчётов — ровно десять секунд.
    // Раскладываем по тем же битовым границам, что и разбор: частота 20 бит,
    // каналы 3 бита, разрядность 5, затем 36 бит числа отсчётов.
    const rate: u32 = 44100;
    body[10] = @intCast(rate >> 12);
    body[11] = @intCast((rate >> 4) & 0xFF);
    body[12] = @intCast(((rate & 0x0F) << 4) | (1 << 1)); // каналы: 1+1 = 2
    const total: u64 = 441000;
    body[13] = @intCast((total >> 32) & 0x0F);
    body[14] = @intCast((total >> 24) & 0xFF);
    body[15] = @intCast((total >> 16) & 0xFF);
    body[16] = @intCast((total >> 8) & 0xFF);
    body[17] = @intCast(total & 0xFF);

    const info = try parse(&data);
    try std.testing.expectEqual(Format.flac, info.format);
    try std.testing.expectEqual(@as(usize, 1), info.list().len);
    const t = info.list()[0];
    try std.testing.expectEqual(@as(u32, 44100), t.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), t.channels);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), t.seconds(), 0.001);
}

test "MIDI: сколько дорожек в заголовке, столько и показываем" {
    var data: [14]u8 = @splat(0);
    @memcpy(data[0..4], "MThd");
    std.mem.writeInt(u32, data[4..8], 6, .big);
    std.mem.writeInt(u16, data[8..10], 1, .big); // формат
    std.mem.writeInt(u16, data[10..12], 4, .big); // дорожек
    std.mem.writeInt(u16, data[12..14], 480, .big);

    const info = try parse(&data);
    try std.testing.expectEqual(Format.midi, info.format);
    try std.testing.expectEqual(@as(usize, 4), info.list().len);
    for (info.list()) |t| try std.testing.expectEqual(Kind.audio, t.kind);
}

test "MP3: кадры считаются, длительность из их числа" {
    // Три кадра MPEG-1 Layer III, 128 кбит/с, 44100 Гц.
    const frame_len: usize = 1152 / 8 * 128 * 1000 / 44100; // 417
    var data: [3 * 418]u8 = @splat(0);
    var at: usize = 0;
    var made: usize = 0;
    while (made < 3) : (made += 1) {
        data[at] = 0xFF;
        data[at + 1] = 0xFB; // MPEG-1, Layer III, без защиты
        data[at + 2] = 0x90; // битрейт 128, частота 44100, без добивки
        data[at + 3] = 0x00; // стерео
        at += frame_len;
    }

    const info = try parse(data[0 .. frame_len * 3]);
    try std.testing.expectEqual(Format.mp3, info.format);
    const t = info.list()[0];
    try std.testing.expectEqual(@as(u32, 44100), t.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), t.channels);
    // Три кадра по 1152 отсчёта — 0.078 секунды.
    try std.testing.expectApproxEqAbs(@as(f64, 3.0 * 1152.0 / 44100.0), t.seconds(), 0.002);
}

test "MP3 с тегом ID3: тег пропускается, кадры находятся" {
    const frame_len: usize = 1152 / 8 * 128 * 1000 / 44100;
    var data: [10 + 40 + 2 * 418]u8 = @splat(0);
    @memcpy(data[0..3], "ID3");
    data[3] = 4;
    // Размер тега 40 байт, семибитными группами.
    data[9] = 40;

    var at: usize = 50;
    var made: usize = 0;
    while (made < 2) : (made += 1) {
        data[at] = 0xFF;
        data[at + 1] = 0xFB;
        data[at + 2] = 0x90;
        data[at + 3] = 0x00;
        at += frame_len;
    }

    const info = try parse(data[0..at]);
    try std.testing.expectEqual(Format.mp3, info.format);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 * 1152.0 / 44100.0), info.list()[0].seconds(), 0.002);
}

test "случайные единицы в мусоре не считаются кадром mp3" {
    // Подпись есть, а поля запрещённые: битрейт 15, частота 3.
    var data: [64]u8 = @splat(0);
    data[0] = 0xFF;
    data[1] = 0xFB;
    data[2] = 0xFC;
    data[3] = 0x00;
    try std.testing.expectError(Error.Unknown, detect(&data));
}

test "AVI: видео и звук порознь, с размером кадра и частотой" {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(std.testing.allocator);
    const a = std.testing.allocator;

    // avih: 40000 мкс на кадр (25 в секунду), 250 кадров — десять секунд.
    try body.appendSlice(a, "avih");
    try body.appendSlice(a, &[_]u8{ 56, 0, 0, 0 });
    var avih: [56]u8 = @splat(0);
    std.mem.writeInt(u32, avih[0..4], 40000, .little);
    std.mem.writeInt(u32, avih[16..20], 250, .little);
    try body.appendSlice(a, &avih);

    // Видеодорожка.
    try body.appendSlice(a, "strh");
    try body.appendSlice(a, &[_]u8{ 56, 0, 0, 0 });
    var strh: [56]u8 = @splat(0);
    @memcpy(strh[0..4], "vids");
    std.mem.writeInt(u32, strh[20..24], 1, .little); // scale
    std.mem.writeInt(u32, strh[24..28], 25, .little); // rate
    std.mem.writeInt(u32, strh[32..36], 250, .little); // length
    try body.appendSlice(a, &strh);

    try body.appendSlice(a, "strf");
    try body.appendSlice(a, &[_]u8{ 40, 0, 0, 0 });
    var strf: [40]u8 = @splat(0);
    std.mem.writeInt(u32, strf[4..8], 640, .little);
    std.mem.writeInt(u32, strf[8..12], 480, .little);
    try body.appendSlice(a, &strf);

    // Звуковая дорожка.
    try body.appendSlice(a, "strh");
    try body.appendSlice(a, &[_]u8{ 56, 0, 0, 0 });
    var strh2: [56]u8 = @splat(0);
    @memcpy(strh2[0..4], "auds");
    std.mem.writeInt(u32, strh2[20..24], 1, .little);
    std.mem.writeInt(u32, strh2[24..28], 25, .little);
    std.mem.writeInt(u32, strh2[32..36], 250, .little);
    try body.appendSlice(a, &strh2);

    try body.appendSlice(a, "strf");
    try body.appendSlice(a, &[_]u8{ 18, 0, 0, 0 });
    var strf2: [18]u8 = @splat(0);
    std.mem.writeInt(u16, strf2[2..4], 2, .little);
    std.mem.writeInt(u32, strf2[4..8], 48000, .little);
    try body.appendSlice(a, &strf2);

    const buf = try a.alloc(u8, 12 + body.items.len);
    defer a.free(buf);
    const file = riff("AVI ", body.items, buf);

    const info = try parse(file);
    try std.testing.expectEqual(Format.avi, info.format);
    try std.testing.expectEqual(@as(usize, 2), info.list().len);

    const v = info.list()[0];
    try std.testing.expectEqual(Kind.video, v.kind);
    try std.testing.expectEqual(@as(u32, 640), v.width);
    try std.testing.expectEqual(@as(u32, 480), v.height);
    try std.testing.expectApproxEqAbs(@as(f64, 25.0), v.fps, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), v.seconds(), 0.01);

    const s = info.list()[1];
    try std.testing.expectEqual(Kind.audio, s.kind);
    try std.testing.expectEqual(@as(u32, 48000), s.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), s.channels);
}

test "у звуковых форматов картинки не ищут" {
    try std.testing.expect(Format.mp4.mayHaveVideo());
    try std.testing.expect(Format.mov.mayHaveVideo());
    try std.testing.expect(Format.avi.mayHaveVideo());
    try std.testing.expect(!Format.mp3.mayHaveVideo());
    try std.testing.expect(!Format.flac.mayHaveVideo());
    try std.testing.expect(!Format.midi.mayHaveVideo());
}

test "ошибки объясняются словами" {
    for ([_]anyerror{ Error.Unknown, Error.Truncated, Error.Unsupported }) |e| {
        try std.testing.expect(explain(e).len > 20);
    }
}
