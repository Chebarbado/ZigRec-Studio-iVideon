//! Пересчёт частоты дискретизации и сведение каналов в один.
//!
//! Задача #40. Микрофон отдаёт то, что удобно ему: 44100 или 48000, один канал
//! или восемь, целые или вещественные отсчёты. Кодировщик AAC принимает узкий
//! набор частот. Между ними нужен пересчёт.
//!
//! Взята линейная интерполяция. Для речи с микрофона этого достаточно:
//! слышимая разница с честным полосовым пересчётом начинается там, где есть
//! что терять выше десяти килогерц, а у микрофона там уже нет ничего, кроме
//! шума. Зато она считается в один проход и не требует ни памяти под ядро,
//! ни задержки на его длину.
//!
//! Пересчёт **потоковый**: куски приходят с устройства как попало, и позиция
//! внутри входа должна переживать границу куска. Иначе на каждом стыке
//! появлялся бы щелчок — по одному на каждые десять миллисекунд записи.
const std = @import("std");

/// Свести кадр из нескольких каналов в один отсчёт.
///
/// Среднее, а не первый канал: у гарнитур бывает, что говорят в один канал,
/// а второй молчит, и «взять первый» иногда означает «взять тишину».
pub fn downmix(frame: []const f32) f32 {
    if (frame.len == 0) return 0;
    var sum: f32 = 0;
    for (frame) |v| sum += v;
    return sum / @as(f32, @floatFromInt(frame.len));
}

/// Отсчёт -1…1 в целый шестнадцатибитный.
///
/// Прижимаем к границам: вещественный отсчёт с микрофона может чуть выйти
/// за единицу, и без прижатия он завернулся бы из плюса в минус — то есть
/// громкий звук звучал бы как треск.
pub fn toI16(value: f32) i16 {
    const scaled = std.math.clamp(value, -1.0, 1.0) * 32767.0;
    return @intFromFloat(@round(scaled));
}

pub const Resampler = struct {
    src_rate: u32,
    dst_rate: u32,
    /// Позиция внутри входного потока, в отсчётах. Дробная часть — то, что
    /// переносится через границу куска.
    position: f64 = 0,
    /// Последний отсчёт предыдущего куска: с ним интерполируется первый
    /// отсчёт следующего, иначе на стыке рвётся волна.
    last: f32 = 0,
    /// Был ли уже хоть один кусок. До первого интерполировать не с чем.
    primed: bool = false,

    pub fn init(src_rate: u32, dst_rate: u32) Resampler {
        return .{ .src_rate = @max(src_rate, 1), .dst_rate = @max(dst_rate, 1) };
    }

    /// Нужен ли пересчёт вообще. Когда частоты совпадают, отсчёты идут как есть:
    /// незачем прогонять их через интерполяцию, которая на равных частотах
    /// только накапливает ошибку округления.
    pub fn isIdentity(self: Resampler) bool {
        return self.src_rate == self.dst_rate;
    }

    /// Сколько выходных отсчётов даст кусок такой длины. Оценка сверху:
    /// по ней выделяют буфер.
    pub fn maxOut(self: Resampler, src_len: usize) usize {
        const ratio = @as(f64, @floatFromInt(self.dst_rate)) / @as(f64, @floatFromInt(self.src_rate));
        return @as(usize, @intFromFloat(@ceil(@as(f64, @floatFromInt(src_len)) * ratio))) + 2;
    }

    /// Пересчитать кусок. Возвращает число записанных выходных отсчётов.
    ///
    /// `out` должен быть не меньше `maxOut(src.len)`: иначе кусок войдёт
    /// не целиком, а остаток входа будет потерян.
    ///
    /// Внутри работаем не с самим куском, а с «склейкой»: последний отсчёт
    /// прошлого куска, а за ним весь этот. Только так на стыке есть с чем
    /// интерполировать. Без склейки последний отсчёт куска интерполировался
    /// сам с собой — по щелчку на каждые десять миллисекунд записи, и это
    /// поймал тест «поток не рвётся на границе кусков».
    pub fn process(self: *Resampler, src: []const f32, out: []f32) usize {
        if (src.len == 0) return 0;
        if (self.isIdentity()) {
            const n = @min(src.len, out.len);
            @memcpy(out[0..n], src[0..n]);
            self.last = src[src.len - 1];
            self.primed = true;
            return n;
        }

        if (!self.primed) {
            // В самом начале потока предыдущего отсчёта нет. Берём первый:
            // это удлиняет запись на один входной отсчёт — двадцать микросекунд
            // при 48 кГц, то есть в тысячу раз меньше слышимого.
            self.last = src[0];
            self.position = 0;
            self.primed = true;
        }

        const step = @as(f64, @floatFromInt(self.src_rate)) / @as(f64, @floatFromInt(self.dst_rate));
        const limit = @as(f64, @floatFromInt(src.len));
        var written: usize = 0;
        while (written < out.len and self.position < limit) {
            const index: usize = @intFromFloat(@floor(self.position));
            const frac: f32 = @floatCast(self.position - @floor(self.position));
            // Склейка: нулевой отсчёт — хвост прошлого куска.
            const a: f32 = if (index == 0) self.last else src[index - 1];
            const b: f32 = src[index];
            out[written] = a + (b - a) * frac;
            written += 1;
            self.position += step;
        }

        // Переносим остаток позиции на следующий кусок: там нулевым отсчётом
        // склейки станет последний отсчёт этого.
        self.position -= limit;
        self.last = src[src.len - 1];
        return written;
    }
};

// ---------------------------------------------------------------- тесты

test "сведение каналов: среднее, а не первый канал" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), downmix(&[_]f32{ 1.0, 0.0 }), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), downmix(&[_]f32{ 0.25, 0.25, 0.25, 0.25 }), 0.0001);
    // Молчащий второй канал не должен обнулить голос из первого целиком,
    // но и не должен быть выброшен.
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), downmix(&[_]f32{ 0.8, 0.0 }), 0.0001);
    try std.testing.expectEqual(@as(f32, 0), downmix(&[_]f32{}));
}

test "перевод в целые: полная шкала и прижатие к границам" {
    try std.testing.expectEqual(@as(i16, 0), toI16(0));
    try std.testing.expectEqual(@as(i16, 32767), toI16(1.0));
    try std.testing.expectEqual(@as(i16, -32767), toI16(-1.0));
    // Выход за единицу прижимается, а не заворачивается: иначе громкий
    // звук превратился бы в треск.
    try std.testing.expectEqual(@as(i16, 32767), toI16(1.7));
    try std.testing.expectEqual(@as(i16, -32767), toI16(-9.0));
}

test "равные частоты: отсчёты проходят как есть" {
    var r = Resampler.init(48_000, 48_000);
    try std.testing.expect(r.isIdentity());
    const src = [_]f32{ 0.1, -0.2, 0.3, -0.4 };
    var out: [8]f32 = undefined;
    const n = r.process(&src, &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualSlices(f32, &src, out[0..4]);
}

test "вдвое ниже частота — вдвое меньше отсчётов" {
    var r = Resampler.init(48_000, 24_000);
    var src: [480]f32 = @splat(0);
    for (&src, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 0.01);
    var out: [512]f32 = undefined;
    const n = r.process(&src, &out);
    try std.testing.expectEqual(@as(usize, 240), n);
}

test "вдвое выше частота — вдвое больше отсчётов" {
    var r = Resampler.init(24_000, 48_000);
    var src: [240]f32 = @splat(0);
    for (&src, 0..) |*v, i| v.* = @sin(@as(f32, @floatFromInt(i)) * 0.01);
    var out: [600]f32 = undefined;
    const n = r.process(&src, &out);
    try std.testing.expectEqual(@as(usize, 480), n);
}

test "постоянный сигнал остаётся постоянным" {
    // Интерполяция не должна ничего добавлять там, где нечего добавлять.
    var r = Resampler.init(44_100, 48_000);
    const src: [441]f32 = @splat(0.5);
    var out: [600]f32 = undefined;
    const n = r.process(&src, &out);
    try std.testing.expect(n > 400);
    for (out[0..n]) |v| try std.testing.expectApproxEqAbs(@as(f32, 0.5), v, 0.0001);
}

test "поток не рвётся на границе кусков" {
    // Главная опасность потокового пересчёта: на каждом стыке кусков — щелчок.
    // Считаем один и тот же сигнал целиком и по кускам, и сравниваем.
    const src_rate: u32 = 44_100;
    const dst_rate: u32 = 48_000;
    var whole_src: [4410]f32 = undefined;
    for (&whole_src, 0..) |*v, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(src_rate));
        v.* = @sin(t * 440.0 * std.math.tau) * 0.5;
    }

    var r1 = Resampler.init(src_rate, dst_rate);
    var whole_out: [6000]f32 = undefined;
    const whole_n = r1.process(&whole_src, &whole_out);

    var r2 = Resampler.init(src_rate, dst_rate);
    var piece_out: [6000]f32 = undefined;
    var piece_n: usize = 0;
    var at: usize = 0;
    while (at < whole_src.len) {
        const end = @min(at + 441, whole_src.len);
        piece_n += r2.process(whole_src[at..end], piece_out[piece_n..]);
        at = end;
    }

    // Разбиение на куски не должно менять ничего: ни числа отсчётов,
    // ни самих отсчётов. Допуск — только на округление f64.
    try std.testing.expectEqual(whole_n, piece_n);
    for (0..whole_n) |i| {
        try std.testing.expectApproxEqAbs(whole_out[i], piece_out[i], 0.00001);
    }
}

test "пересчёт не наращивает и не гасит громкость" {
    // Синус половинной амплитуды после пересчёта должен остаться половинным.
    const src_rate: u32 = 44_100;
    var src: [4410]f32 = undefined;
    for (&src, 0..) |*v, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(src_rate));
        v.* = @sin(t * 1000.0 * std.math.tau) * 0.5;
    }
    var r = Resampler.init(src_rate, 48_000);
    var out: [6000]f32 = undefined;
    const n = r.process(&src, &out);

    var peak: f32 = 0;
    for (out[0..n]) |v| peak = @max(peak, @abs(v));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), peak, 0.01);
}
