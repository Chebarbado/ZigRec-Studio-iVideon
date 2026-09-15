//! Известный звук для проверки: тишина со всплесками в назначенные моменты.
//!
//! Задача #40. Проверять звуковую дорожку живым микрофоном нельзя: он у каждого
//! свой, и «вроде слышно» ничего не доказывает. Поэтому в стенд подаётся сигнал
//! с заранее известным рисунком, а из готового mp4 он вынимается сторонним
//! декодером и меряется.
//!
//! Рисунок нарочно простой: тишина, короткий всплеск ровно на первой секунде,
//! ещё один ровно на второй. По уровню видно, что звук не потерялся и не
//! исказился; по моментам всплесков — что он не разъехался с видео. Второй
//! всплеск нужен, чтобы отличить постоянный сдвиг (звук начался позже) от
//! накапливающегося дрейфа (звук идёт с другой скоростью).
const std = @import("std");

pub const Burst = struct {
    /// Когда начинается, от начала записи.
    at_ns: u64,
    /// Сколько длится.
    len_ns: u64,
    frequency_hz: f32 = 1000,
    /// Амплитуда 0…1. По умолчанию половина шкалы — это минус шесть децибел.
    amplitude: f32 = 0.5,
};

/// Расписание всплесков. Между ними — тишина.
pub const Plan = struct {
    bursts: []const Burst,

    /// Отсчёт номер `index` при заданной частоте дискретизации.
    pub fn sampleAt(self: Plan, index: usize, rate: u32) f32 {
        const t_ns = @as(u64, index) * std.time.ns_per_s / @max(rate, 1);
        for (self.bursts) |b| {
            if (t_ns < b.at_ns or t_ns >= b.at_ns + b.len_ns) continue;
            const inside_ns = t_ns - b.at_ns;
            const t = @as(f32, @floatFromInt(inside_ns)) / @as(f32, std.time.ns_per_s);
            // Края всплеска сглажены: резкий обрыв даёт щелчок по всему спектру,
            // и после кодирования его размазывает так, что момент начала
            // становится не найти. Мы же собираемся мерить именно момент.
            const fade = fadeAt(inside_ns, b.len_ns);
            return @sin(t * b.frequency_hz * std.math.tau) * b.amplitude * fade;
        }
        return 0;
    }

    /// Наибольшая амплитуда расписания — то, что должно получиться на выходе.
    pub fn peak(self: Plan) f32 {
        var top: f32 = 0;
        for (self.bursts) |b| top = @max(top, b.amplitude);
        return top;
    }
};

/// Плавные края всплеска: пять миллисекунд на подъём и столько же на спад.
fn fadeAt(inside_ns: u64, len_ns: u64) f32 {
    const edge_ns: u64 = 5 * std.time.ns_per_ms;
    if (len_ns <= edge_ns * 2) return 1;
    if (inside_ns < edge_ns) {
        return @as(f32, @floatFromInt(inside_ns)) / @as(f32, @floatFromInt(edge_ns));
    }
    const left = len_ns - inside_ns;
    if (left < edge_ns) {
        return @as(f32, @floatFromInt(left)) / @as(f32, @floatFromInt(edge_ns));
    }
    return 1;
}

/// Найти моменты начала всплесков в записанном сигнале.
///
/// Ищем не отдельный громкий отсчёт, а место, где сигнал стал громким
/// и остался таким: одиночный щелчок кодировщика не должен сойти за всплеск.
///
/// `hold_samples` — сколько отсчётов подряд должны быть выше порога.
/// Возвращает число найденных всплесков; их моменты кладёт в `out` в наносекундах.
pub fn findOnsets(
    samples: []const f32,
    rate: u32,
    threshold: f32,
    hold_samples: usize,
    out: []u64,
) usize {
    if (rate == 0 or out.len == 0) return 0;
    var found: usize = 0;
    var i: usize = 0;
    var inside = false;
    // Сколько отсчётов подряд под порогом считаем концом всплеска. Синус
    // пересекает ноль дважды за период, и без этого запаса каждый период
    // читался бы как новый всплеск.
    const gap_needed = @max(rate / 100, 1);
    var quiet: usize = 0;

    while (i < samples.len) : (i += 1) {
        const loud = @abs(samples[i]) >= threshold;
        if (inside) {
            if (loud) {
                quiet = 0;
            } else {
                quiet += 1;
                if (quiet >= gap_needed) inside = false;
            }
            continue;
        }
        if (!loud) continue;

        // Проверяем, что громко не один отсчёт.
        var held: usize = 0;
        var j = i;
        while (j < samples.len and held < hold_samples) : (j += 1) {
            if (@abs(samples[j]) >= threshold) held += 1;
        }
        if (held < hold_samples) continue;

        out[found] = @as(u64, i) * std.time.ns_per_s / rate;
        found += 1;
        inside = true;
        quiet = 0;
        if (found == out.len) break;
    }
    return found;
}

/// Расписание для стенда: два всплеска по сто миллисекунд, на первой
/// и на второй секунде.
pub fn benchPlan() Plan {
    const S = struct {
        const bursts = [_]Burst{
            .{ .at_ns = 1 * std.time.ns_per_s, .len_ns = 100 * std.time.ns_per_ms },
            .{ .at_ns = 2 * std.time.ns_per_s, .len_ns = 100 * std.time.ns_per_ms },
        };
    };
    return .{ .bursts = &S.bursts };
}

// ---------------------------------------------------------------- тесты

test "между всплесками — тишина" {
    const plan = benchPlan();
    const rate: u32 = 48_000;
    // Половина секунды: до первого всплеска.
    try std.testing.expectEqual(@as(f32, 0), plan.sampleAt(rate / 2, rate));
    // Полторы секунды: между всплесками.
    try std.testing.expectEqual(@as(f32, 0), plan.sampleAt(rate + rate / 2, rate));
}

test "во всплеске сигнал есть и не превышает заданной амплитуды" {
    const plan = benchPlan();
    const rate: u32 = 48_000;
    var top: f32 = 0;
    // Середина первого всплеска, где сглаживание краёв уже не мешает.
    var i: usize = rate + rate / 50;
    while (i < rate + rate / 20) : (i += 1) top = @max(top, @abs(plan.sampleAt(i, rate)));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), top, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), plan.peak(), 0.0001);
}

test "измеритель находит всплески там, где их поставили" {
    // Пара «поставили — нашли» проверяет сразу обе половины: и генератор,
    // и измеритель. Если разойдутся — расходится и этот тест.
    const rate: u32 = 48_000;
    const plan = benchPlan();
    var samples: [rate * 3]f32 = undefined;
    for (&samples, 0..) |*v, i| v.* = plan.sampleAt(i, rate);

    var onsets: [4]u64 = undefined;
    const n = findOnsets(&samples, rate, 0.1, 32, &onsets);
    try std.testing.expectEqual(@as(usize, 2), n);

    const tolerance_ns: u64 = 3 * std.time.ns_per_ms;
    try std.testing.expect(onsets[0] > 1 * std.time.ns_per_s -| tolerance_ns);
    try std.testing.expect(onsets[0] < 1 * std.time.ns_per_s + tolerance_ns);
    try std.testing.expect(onsets[1] > 2 * std.time.ns_per_s -| tolerance_ns);
    try std.testing.expect(onsets[1] < 2 * std.time.ns_per_s + tolerance_ns);
}

test "тишина не даёт ложных всплесков" {
    const samples: [4800]f32 = @splat(0);
    var onsets: [4]u64 = undefined;
    try std.testing.expectEqual(@as(usize, 0), findOnsets(&samples, 48_000, 0.1, 32, &onsets));
}

test "одиночный щелчок не считается всплеском" {
    // Кодировщик может дать одиночный выброс; он не должен сойти за сигнал.
    var samples: [4800]f32 = @splat(0);
    samples[1000] = 0.9;
    var onsets: [4]u64 = undefined;
    try std.testing.expectEqual(@as(usize, 0), findOnsets(&samples, 48_000, 0.1, 32, &onsets));
}

test "сдвиг сигнала виден измерителю как сдвиг" {
    // Проверяем, что измеритель вообще способен поймать рассинхрон: если
    // сдвинуть сигнал на 50 мс, он должен показать те же 50 мс.
    const rate: u32 = 48_000;
    const plan = benchPlan();
    const shift = rate / 20; // 50 мс
    var samples: [rate * 3]f32 = @splat(0);
    var i: usize = shift;
    while (i < samples.len) : (i += 1) samples[i] = plan.sampleAt(i - shift, rate);

    var onsets: [4]u64 = undefined;
    const n = findOnsets(&samples, rate, 0.1, 32, &onsets);
    try std.testing.expectEqual(@as(usize, 2), n);
    const offset = onsets[0] - 1 * std.time.ns_per_s;
    try std.testing.expect(offset > 45 * std.time.ns_per_ms);
    try std.testing.expect(offset < 55 * std.time.ns_per_ms);
}

test "края всплеска сглажены, а не обрублены" {
    const plan = benchPlan();
    const rate: u32 = 48_000;
    // Самое начало всплеска — заметно тише середины.
    const at_start = @abs(plan.sampleAt(rate + 20, rate));
    var middle: f32 = 0;
    var i: usize = rate + rate / 50;
    while (i < rate + rate / 25) : (i += 1) middle = @max(middle, @abs(plan.sampleAt(i, rate)));
    try std.testing.expect(at_start < middle);
}
