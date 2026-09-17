//! Сведение звука проекта в один поток отсчётов.
//!
//! Задачи #61 и #62. Нарисованная кривая громкости, которая ничего не меняет
//! в звуке, — это не кривая громкости, а картинка. Здесь она превращается
//! в числа: каждая звуковая дорожка читается, умножается на свою громкость
//! и складывается с остальными.
//!
//! **Здесь нет ни одного обращения к Windows.** Исходники приходят уже
//! раскодированными, отсчётами. Так всё сведение целиком проверяется
//! тестами на выдуманных исходниках: подали ровный тон, нарисовали спуск —
//! и проверили, что в готовой смеси он именно такой, а не «примерно такой».
//!
//! **Громкость считается не на каждом отсчёте.** Кривая на сорока восьми
//! тысячах отсчётов в секунду обходилась бы в миллиард сравнений на десять
//! минут записи. Считаем её на границах коротких блоков и тянем между ними
//! прямую: ступенька в громкости слышна щелчком, а прямая — нет.
const std = @import("std");
const timeline = @import("timeline.zig");
const volume = @import("../sound/volume.zig");

/// Раскодированный исходник: моно, отсчёты от минус единицы до единицы.
///
/// Моно нарочно: сведение решает вопрос громкости, а не расположения звука
/// в пространстве. Стерео добавит второй столбец чисел и ни одного нового
/// решения, поэтому оно будет отдельной задачей, а не довеском к этой.
pub const SourceAudio = struct {
    rate: u32 = 48_000,
    samples: []const f32 = &.{},
};

/// Через сколько отсчётов пересчитывается громкость.
///
/// Двести пятьдесят шесть отсчётов — это пять миллисекунд на сорока восьми
/// килогерцах. Кривая громкости не успевает измениться за это время
/// настолько, чтобы прямая между границами блока отличалась от неё на слух.
pub const gain_block: usize = 256;

/// Сколько отсчётов займёт весь проект.
pub fn totalSamples(project: *const timeline.Project, rate: u32) usize {
    return nsToSamples(project.durationNs(), rate);
}

pub fn nsToSamples(ns: u64, rate: u32) usize {
    return @intCast(ns * rate / std.time.ns_per_s);
}

pub fn samplesToNs(samples: usize, rate: u32) u64 {
    return @as(u64, samples) * std.time.ns_per_s / rate;
}

/// Свести звуковые дорожки проекта в `out`.
///
/// `out` заполняется целиком: то, что не покрыто клипами, становится
/// тишиной, а не остаётся мусором от прошлого вызова.
pub fn mix(
    project: *const timeline.Project,
    rate: u32,
    sources: []const SourceAudio,
    out: []i16,
) void {
    @memset(out, 0);
    if (rate == 0 or out.len == 0) return;

    for (project.trackList(), 0..) |track, track_index| {
        _ = track_index;
        if (track.kind != .audio) continue;
        // Заглушённая дорожка молчит. Проверяем здесь, а не множителем:
        // иначе она всё равно читалась бы и складывалась, только с нулём.
        if (track.muted) continue;

        for (track.list()) |clip| {
            if (clip.source >= sources.len) continue;
            const src = sources[clip.source];
            if (src.samples.len == 0 or src.rate == 0) continue;

            const from = @min(nsToSamples(clip.at_ns, rate), out.len);
            const to = @min(nsToSamples(clip.endsAt(), rate), out.len);

            var at = from;
            while (at < to) {
                const block_end = @min(at + gain_block, to);
                const g0 = volume.factor(dbAt(&track, clip, samplesToNs(at, rate)));
                const g1 = volume.factor(dbAt(&track, clip, samplesToNs(block_end, rate)));
                const span = block_end - at;

                var k = at;
                while (k < block_end) : (k += 1) {
                    const src_at = sourceIndex(clip, src, rate, k);
                    if (src_at >= src.samples.len) break;
                    // Прямая между границами блока: ступенька слышна щелчком.
                    const part = @as(f32, @floatFromInt(k - at)) / @as(f32, @floatFromInt(span));
                    const gain = g0 + (g1 - g0) * part;
                    out[k] = addClamped(out[k], src.samples[src_at] * gain);
                }
                at = block_end;
            }
        }
    }
}

/// Какой отсчёт исходника приходится на этот отсчёт готовой смеси.
fn sourceIndex(clip: timeline.Clip, src: SourceAudio, rate: u32, out_at: usize) usize {
    const when_ns = samplesToNs(out_at, rate);
    // Клип мог начаться между отсчётами: считаем от его начала, а не
    // от начала дорожки, иначе накапливается сдвиг на длинном проекте.
    const inside_ns = when_ns -| clip.at_ns;
    return nsToSamples(clip.in_ns + inside_ns, src.rate);
}

/// Громкость дорожки вместе с кривой и громкостью клипа.
fn dbAt(track: *const timeline.Track, clip: timeline.Clip, at_ns: u64) volume.Db10 {
    var total = volume.sum(track.gain_db10, clip.gain_db10);
    if (track.curve_on and !track.curve.empty()) {
        total = volume.sum(total, track.curve.valueAt(at_ns));
    }
    return total;
}

/// Сложить с тем, что уже лежит, не дав сумме завернуться.
///
/// Без прижатия две громкие дорожки складываются в переполнение, и вместо
/// громкого звука выходит треск — причём ровно на тех местах, которые
/// человек и хотел услышать.
fn addClamped(already: i16, add: f32) i16 {
    const sum = @as(f32, @floatFromInt(already)) + add * 32767.0;
    return @intFromFloat(std.math.clamp(sum, -32768.0, 32767.0));
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;
const sec = std.time.ns_per_s;
const test_rate: u32 = 48_000;

/// Ровный тон на всю длину: по нему видно, что сделала громкость.
fn steady(allocator: std.mem.Allocator, seconds: f32, level: f32) ![]f32 {
    const n: usize = @intFromFloat(seconds * @as(f32, @floatFromInt(test_rate)));
    const out = try allocator.alloc(f32, n);
    for (out, 0..) |*v, i| {
        const phase = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(test_rate)) * 440.0 * 2 * std.math.pi;
        v.* = @sin(phase) * level;
    }
    return out;
}

/// Пик готовой смеси на отрезке — в долях единицы.
///
/// Каждая сторона меряется своим пределом: вниз шкала уходит на один шаг
/// дальше, чем вверх, и деление отрицательного края на положительный предел
/// даёт «пик больше единицы» на совершенно исправном звуке.
fn peakBetween(out: []const i16, from_s: f32, to_s: f32) f32 {
    const from: usize = @intFromFloat(from_s * @as(f32, @floatFromInt(test_rate)));
    const to: usize = @min(@as(usize, @intFromFloat(to_s * @as(f32, @floatFromInt(test_rate)))), out.len);
    var peak: f32 = 0;
    var i = from;
    while (i < to) : (i += 1) {
        const s = @as(f32, @floatFromInt(out[i]));
        const v = if (s < 0) -s / 32768.0 else s / 32767.0;
        if (v > peak) peak = v;
    }
    return peak;
}

fn project1() !*timeline.Project {
    const p = try testing.allocator.create(timeline.Project);
    p.* = .{};
    _ = try p.addSource("тон.wav", 10 * sec);
    _ = try p.addTrack(.audio, "Звук");
    try p.place(0, 0, 0, 10 * sec);
    return p;
}

test "без правок смесь повторяет исходник" {
    const p = try project1();
    defer testing.allocator.destroy(p);

    const tone = try steady(testing.allocator, 10, 0.5);
    defer testing.allocator.free(tone);
    const out = try testing.allocator.alloc(i16, totalSamples(p, test_rate));
    defer testing.allocator.free(out);

    mix(p, test_rate, &.{.{ .rate = test_rate, .samples = tone }}, out);
    try testing.expectApproxEqAbs(@as(f32, 0.5), peakBetween(out, 1, 9), 0.01);
}

test "громкость дорожки слышна в готовой смеси" {
    const p = try project1();
    defer testing.allocator.destroy(p);
    try p.setTrackGain(0, -60); // вдвое тише

    const tone = try steady(testing.allocator, 10, 0.5);
    defer testing.allocator.free(tone);
    const out = try testing.allocator.alloc(i16, totalSamples(p, test_rate));
    defer testing.allocator.free(out);

    mix(p, test_rate, &.{.{ .rate = test_rate, .samples = tone }}, out);
    try testing.expectApproxEqAbs(@as(f32, 0.25), peakBetween(out, 1, 9), 0.01);
}

test "кривая громкости слышна там, где нарисована" {
    // Это главная проверка обеих задач: нарисованная линия, которая ничего
    // не меняет в звуке, — это картинка, а не громкость.
    const p = try project1();
    defer testing.allocator.destroy(p);
    _ = try p.addCurvePoint(0, 0, 0); // в начале как записано
    _ = try p.addCurvePoint(0, 10 * sec, -200); // к концу на двадцать децибел тише

    const tone = try steady(testing.allocator, 10, 0.5);
    defer testing.allocator.free(tone);
    const out = try testing.allocator.alloc(i16, totalSamples(p, test_rate));
    defer testing.allocator.free(out);

    mix(p, test_rate, &.{.{ .rate = test_rate, .samples = tone }}, out);

    // В начале — как записано.
    try testing.expectApproxEqAbs(@as(f32, 0.5), peakBetween(out, 0, 0.2), 0.02);
    // На середине — минус десять децибел, это примерно втрое тише.
    try testing.expectApproxEqAbs(@as(f32, 0.158), peakBetween(out, 4.9, 5.1), 0.02);
    // В конце — минус двадцать, вдесятеро тише.
    try testing.expectApproxEqAbs(@as(f32, 0.05), peakBetween(out, 9.8, 10), 0.02);
}

test "выключенная кривая на звук не влияет" {
    const p = try project1();
    defer testing.allocator.destroy(p);
    _ = try p.addCurvePoint(0, 0, -400);
    try p.setCurveOn(0, false);

    const tone = try steady(testing.allocator, 10, 0.5);
    defer testing.allocator.free(tone);
    const out = try testing.allocator.alloc(i16, totalSamples(p, test_rate));
    defer testing.allocator.free(out);

    mix(p, test_rate, &.{.{ .rate = test_rate, .samples = tone }}, out);
    try testing.expectApproxEqAbs(@as(f32, 0.5), peakBetween(out, 1, 9), 0.01);
}

test "заглушённая дорожка молчит" {
    const p = try project1();
    defer testing.allocator.destroy(p);
    try p.setMuted(0, true);

    const tone = try steady(testing.allocator, 10, 0.5);
    defer testing.allocator.free(tone);
    const out = try testing.allocator.alloc(i16, totalSamples(p, test_rate));
    defer testing.allocator.free(out);

    mix(p, test_rate, &.{.{ .rate = test_rate, .samples = tone }}, out);
    try testing.expectEqual(@as(f32, 0), peakBetween(out, 0, 10));
}

test "тишина там, где клипа нет" {
    const p = try testing.allocator.create(timeline.Project);
    defer testing.allocator.destroy(p);
    p.* = .{};
    _ = try p.addSource("тон.wav", 10 * sec);
    _ = try p.addTrack(.audio, "Звук");
    // Клип стоит со второй по четвёртую секунду.
    try p.place(0, 0, 2 * sec, 2 * sec);

    const tone = try steady(testing.allocator, 10, 0.5);
    defer testing.allocator.free(tone);
    const out = try testing.allocator.alloc(i16, totalSamples(p, test_rate));
    defer testing.allocator.free(out);

    mix(p, test_rate, &.{.{ .rate = test_rate, .samples = tone }}, out);
    try testing.expectEqual(@as(f32, 0), peakBetween(out, 0, 1.9));
    try testing.expectApproxEqAbs(@as(f32, 0.5), peakBetween(out, 2.1, 3.9), 0.01);
}

test "две дорожки складываются и не переполняются" {
    const p = try testing.allocator.create(timeline.Project);
    defer testing.allocator.destroy(p);
    p.* = .{};
    _ = try p.addSource("тон.wav", 4 * sec);
    _ = try p.addTrack(.audio, "Раз");
    _ = try p.addTrack(.audio, "Два");
    try p.place(0, 0, 0, 4 * sec);
    try p.place(1, 0, 0, 4 * sec);

    // Два громких тона в сумме дали бы больше единицы.
    const tone = try steady(testing.allocator, 4, 0.8);
    defer testing.allocator.free(tone);
    const out = try testing.allocator.alloc(i16, totalSamples(p, test_rate));
    defer testing.allocator.free(out);

    mix(p, test_rate, &.{.{ .rate = test_rate, .samples = tone }}, out);
    // Сумма упёрлась в предел, а не завернулась в треск.
    try testing.expect(peakBetween(out, 1, 3) > 0.99);
    try testing.expect(peakBetween(out, 1, 3) <= 1.0);
}

test "видеодорожка в звук не попадает" {
    const p = try testing.allocator.create(timeline.Project);
    defer testing.allocator.destroy(p);
    p.* = .{};
    _ = try p.addSource("видео.mp4", 4 * sec);
    _ = try p.addTrack(.video, "Видео");
    try p.place(0, 0, 0, 4 * sec);

    const tone = try steady(testing.allocator, 4, 0.5);
    defer testing.allocator.free(tone);
    const out = try testing.allocator.alloc(i16, totalSamples(p, test_rate));
    defer testing.allocator.free(out);

    mix(p, test_rate, &.{.{ .rate = test_rate, .samples = tone }}, out);
    try testing.expectEqual(@as(f32, 0), peakBetween(out, 0, 4));
}

test "клип берёт свой кусок исходника, а не его начало" {
    const p = try testing.allocator.create(timeline.Project);
    defer testing.allocator.destroy(p);
    p.* = .{};
    _ = try p.addSource("тон.wav", 10 * sec);
    _ = try p.addTrack(.audio, "Звук");
    try p.place(0, 0, 0, 10 * sec);
    // Отрезаем первые пять секунд: клип должен показывать вторую половину.
    try p.trim(0, 0, true, 5 * sec);

    // Исходник: первые пять секунд тихие, вторые — громкие.
    const tone = try testing.allocator.alloc(f32, 10 * test_rate);
    defer testing.allocator.free(tone);
    for (tone, 0..) |*v, i| {
        const loud = i >= 5 * test_rate;
        const phase = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(test_rate)) * 440.0 * 2 * std.math.pi;
        v.* = @sin(phase) * (if (loud) @as(f32, 0.8) else @as(f32, 0.1));
    }

    const out = try testing.allocator.alloc(i16, totalSamples(p, test_rate));
    defer testing.allocator.free(out);
    mix(p, test_rate, &.{.{ .rate = test_rate, .samples = tone }}, out);

    // Клип стоит с пятой секунды и показывает громкую половину.
    try testing.expectApproxEqAbs(@as(f32, 0.8), peakBetween(out, 6, 9), 0.02);
}

test "исходник с другой частотой не ломает сведение" {
    const p = try project1();
    defer testing.allocator.destroy(p);

    // Исходник на 24 кГц: вдвое меньше отсчётов на ту же длину.
    const half: u32 = 24_000;
    const n = 10 * half;
    const tone = try testing.allocator.alloc(f32, n);
    defer testing.allocator.free(tone);
    for (tone, 0..) |*v, i| {
        const phase = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(half)) * 440.0 * 2 * std.math.pi;
        v.* = @sin(phase) * 0.5;
    }

    const out = try testing.allocator.alloc(i16, totalSamples(p, test_rate));
    defer testing.allocator.free(out);
    mix(p, test_rate, &.{.{ .rate = half, .samples = tone }}, out);
    try testing.expectApproxEqAbs(@as(f32, 0.5), peakBetween(out, 1, 9), 0.02);
}

test "чужой номер исходника не роняет сведение" {
    const p = try testing.allocator.create(timeline.Project);
    defer testing.allocator.destroy(p);
    p.* = .{};
    _ = try p.addSource("нет.wav", 4 * sec);
    _ = try p.addTrack(.audio, "Звук");
    try p.place(0, 0, 0, 4 * sec);

    const out = try testing.allocator.alloc(i16, totalSamples(p, test_rate));
    defer testing.allocator.free(out);
    // Исходников не передали вовсе.
    mix(p, test_rate, &.{}, out);
    try testing.expectEqual(@as(f32, 0), peakBetween(out, 0, 4));
}
