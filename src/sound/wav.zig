//! Чтение WAV — чтобы проверять звук файлами, а не живым микрофоном.
//!
//! Живой микрофон для проверки не годится: он у каждого свой, шумит по-разному
//! и в тишине даёт то минус 55, то минус 60 децибел. Проверка, которая зависит
//! от того, кто и как дышит рядом, ничего не доказывает.
//!
//! Поэтому уровень меряется на **известном сигнале**: синус заданной амплитуды
//! из файла или из генератора. Тогда «минус 20 децибел» — это проверяемое
//! число, а не впечатление.
//!
//! Разбираем ровно то, что нужно: несжатый PCM (целые 8, 16, 24, 32 бита
//! и вещественные 32) — то, что отдаёт и `ffmpeg`, и Windows.
const std = @import("std");

pub const Error = error{
    /// Не WAV: нет заголовка RIFF/WAVE.
    NotWav,
    /// Файл обрывается посреди заголовка или данных.
    Truncated,
    /// Сжатый или экзотический формат.
    Unsupported,
};

pub const Format = enum(u16) {
    pcm = 1,
    float = 3,
    extensible = 0xFFFE,
    _,
};

pub const Info = struct {
    sample_rate: u32,
    channels: u16,
    bits: u16,
    format: Format,
    /// Смещение и длина куска данных в исходном буфере.
    data_offset: usize,
    data_len: usize,

    pub fn frameCount(self: Info) usize {
        const bytes_per_frame = @as(usize, self.channels) * (self.bits / 8);
        if (bytes_per_frame == 0) return 0;
        return self.data_len / bytes_per_frame;
    }

    pub fn durationSeconds(self: Info) f64 {
        if (self.sample_rate == 0) return 0;
        return @as(f64, @floatFromInt(self.frameCount())) / @as(f64, @floatFromInt(self.sample_rate));
    }
};

/// Разобрать заголовок. Идём по кускам, а не считаем смещения: между `fmt`
/// и `data` часто лежат чужие куски (`LIST`, `fact`), и жёсткие смещения
/// ломаются на первом же файле из чужой программы.
pub fn parse(bytes: []const u8) Error!Info {
    if (bytes.len < 12) return Error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) return Error.NotWav;

    var offset: usize = 12;
    var info: ?Info = null;
    var sample_rate: u32 = 0;
    var channels: u16 = 0;
    var bits: u16 = 0;
    var format: Format = .pcm;

    while (offset + 8 <= bytes.len) {
        const id = bytes[offset..][0..4];
        const size = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little);
        const body = offset + 8;
        if (body > bytes.len) return Error.Truncated;

        if (std.mem.eql(u8, id, "fmt ")) {
            if (body + 16 > bytes.len) return Error.Truncated;
            format = @enumFromInt(std.mem.readInt(u16, bytes[body..][0..2], .little));
            channels = std.mem.readInt(u16, bytes[body + 2 ..][0..2], .little);
            sample_rate = std.mem.readInt(u32, bytes[body + 4 ..][0..4], .little);
            bits = std.mem.readInt(u16, bytes[body + 14 ..][0..2], .little);
        } else if (std.mem.eql(u8, id, "data")) {
            const available = bytes.len - body;
            const len = @min(@as(usize, size), available);
            info = .{
                .sample_rate = sample_rate,
                .channels = channels,
                .bits = bits,
                .format = format,
                .data_offset = body,
                .data_len = len,
            };
            break;
        }
        // Куски выровнены по чётной границе.
        offset = body + size + (size & 1);
    }

    const got = info orelse return Error.Truncated;
    if (got.channels == 0 or got.sample_rate == 0) return Error.NotWav;
    switch (got.bits) {
        8, 16, 24, 32 => {},
        else => return Error.Unsupported,
    }
    return got;
}

/// Отсчёт номер `index` первого канала, приведённый к диапазону -1…1.
pub fn sampleAt(bytes: []const u8, info: Info, index: usize) f32 {
    const bytes_per_sample = info.bits / 8;
    const stride = @as(usize, info.channels) * bytes_per_sample;
    const at = info.data_offset + index * stride;
    if (at + bytes_per_sample > bytes.len) return 0;

    return switch (info.bits) {
        8 => (@as(f32, @floatFromInt(bytes[at])) - 128.0) / 128.0,
        16 => @as(f32, @floatFromInt(std.mem.readInt(i16, bytes[at..][0..2], .little))) / 32768.0,
        24 => blk: {
            const raw: i32 = @as(i32, bytes[at]) | (@as(i32, bytes[at + 1]) << 8) | (@as(i32, @as(i8, @bitCast(bytes[at + 2]))) << 16);
            break :blk @as(f32, @floatFromInt(raw)) / 8388608.0;
        },
        32 => if (info.format == .float)
            @bitCast(std.mem.readInt(u32, bytes[at..][0..4], .little))
        else
            @as(f32, @floatFromInt(std.mem.readInt(i32, bytes[at..][0..4], .little))) / 2147483648.0,
        else => 0,
    };
}

/// Пик и среднеквадратичное по всему файлу.
pub const Measure = struct {
    peak: f32 = 0,
    rms: f32 = 0,
    frames: usize = 0,

    pub fn dbfs(self: Measure) f32 {
        if (self.peak <= 0.00003) return -90;
        return 20 * std.math.log10(self.peak);
    }

    pub fn rmsDbfs(self: Measure) f32 {
        if (self.rms <= 0.00003) return -90;
        return 20 * std.math.log10(self.rms);
    }
};

pub fn measure(bytes: []const u8, info: Info) Measure {
    const frames = info.frameCount();
    var peak: f32 = 0;
    var sum: f64 = 0;
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const v = sampleAt(bytes, info, i);
        const a = @abs(v);
        if (a > peak) peak = a;
        sum += @as(f64, v) * @as(f64, v);
    }
    const rms: f32 = if (frames == 0) 0 else @floatCast(@sqrt(sum / @as(f64, @floatFromInt(frames))));
    return .{ .peak = peak, .rms = rms, .frames = frames };
}

// ---------------------------------------------------------------- тесты

/// Собрать WAV в памяти: 16 бит, один канал.
fn buildWav(comptime frames: usize, gen: fn (usize) i16) [44 + frames * 2]u8 {
    var out: [44 + frames * 2]u8 = undefined;
    const data_len: u32 = frames * 2;
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], 36 + data_len, .little);
    @memcpy(out[8..12], "WAVE");
    @memcpy(out[12..16], "fmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, out[22..24], 1, .little); // моно
    std.mem.writeInt(u32, out[24..28], 48000, .little);
    std.mem.writeInt(u32, out[28..32], 48000 * 2, .little);
    std.mem.writeInt(u16, out[32..34], 2, .little);
    std.mem.writeInt(u16, out[34..36], 16, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], data_len, .little);
    for (0..frames) |i| std.mem.writeInt(i16, out[44 + i * 2 ..][0..2], gen(i), .little);
    return out;
}

fn silence(_: usize) i16 {
    return 0;
}

fn halfScaleSine(i: usize) i16 {
    const t = @as(f32, @floatFromInt(i)) / 48000.0;
    return @intFromFloat(@sin(t * 440.0 * std.math.tau) * 16384.0);
}

fn fullScale(i: usize) i16 {
    return if (i % 2 == 0) 32767 else -32768;
}

test "разбор заголовка: частота, каналы, разрядность" {
    const data = buildWav(480, silence);
    const info = try parse(&data);
    try std.testing.expectEqual(@as(u32, 48000), info.sample_rate);
    try std.testing.expectEqual(@as(u16, 1), info.channels);
    try std.testing.expectEqual(@as(u16, 16), info.bits);
    try std.testing.expectEqual(@as(usize, 480), info.frameCount());
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), info.durationSeconds(), 0.0001);
}

test "тишина меряется как минус девяносто" {
    const data = buildWav(480, silence);
    const info = try parse(&data);
    const m = measure(&data, info);
    try std.testing.expectEqual(@as(f32, -90), m.dbfs());
}

test "половина шкалы — минус шесть децибел, синус даёт минус девять по среднему" {
    const data = buildWav(4800, halfScaleSine);
    const info = try parse(&data);
    const m = measure(&data, info);
    try std.testing.expectApproxEqAbs(@as(f32, -6.02), m.dbfs(), 0.2);
    // Среднеквадратичное синуса на 3 децибела ниже пика.
    try std.testing.expectApproxEqAbs(@as(f32, -9.03), m.rmsDbfs(), 0.3);
}

test "полная шкала — ноль децибел" {
    const data = buildWav(64, fullScale);
    const info = try parse(&data);
    const m = measure(&data, info);
    try std.testing.expectApproxEqAbs(@as(f32, 0), m.dbfs(), 0.01);
}

test "не WAV — понятная ошибка, а не мусор" {
    try std.testing.expectError(Error.NotWav, parse("это не звук, а текст"));
    try std.testing.expectError(Error.Truncated, parse("RIFF"));
}

test "чужие куски между fmt и data не мешают" {
    var data: [44 + 12 + 8]u8 = undefined;
    @memcpy(data[0..4], "RIFF");
    std.mem.writeInt(u32, data[4..8], @intCast(data.len - 8), .little);
    @memcpy(data[8..12], "WAVE");
    @memcpy(data[12..16], "fmt ");
    std.mem.writeInt(u32, data[16..20], 16, .little);
    std.mem.writeInt(u16, data[20..22], 1, .little);
    std.mem.writeInt(u16, data[22..24], 1, .little);
    std.mem.writeInt(u32, data[24..28], 44100, .little);
    std.mem.writeInt(u32, data[28..32], 88200, .little);
    std.mem.writeInt(u16, data[32..34], 2, .little);
    std.mem.writeInt(u16, data[34..36], 16, .little);
    // Чужой кусок LIST длиной 4.
    @memcpy(data[36..40], "LIST");
    std.mem.writeInt(u32, data[40..44], 4, .little);
    @memcpy(data[44..48], "INFO");
    @memcpy(data[48..52], "data");
    std.mem.writeInt(u32, data[52..56], 8, .little);
    @memset(data[56..], 0);

    const info = try parse(&data);
    try std.testing.expectEqual(@as(u32, 44100), info.sample_rate);
    try std.testing.expectEqual(@as(usize, 4), info.frameCount());
}
