//! Коррекция дрейфа звука на длинной записи.
//!
//! Задача #21. Время звука в файле считается по числу отсчётов: у звука шаг
//! известен точно, а часы дрожат. Но «точно» — по часам звуковой карты,
//! а кадры идут по часам процессора. Часы эти разные, и за десять минут
//! разница набегает на десятки миллисекунд: звук уезжает от картинки —
//! медленно, незаметно в начале и слышно к концу.
//!
//! Здесь — правило, как это чинить: сравнить время по отсчётам с временем
//! устройства и, когда разница больше допуска, добавить тишину или выкинуть
//! отсчёты — понемногу, чтобы не щёлкало. Ни одного обращения к Windows:
//! правило проверяется тестами целиком.
const std = @import("std");

/// Что сделать с очередным куском: сколько тишины вставить, сколько
/// отсчётов выбросить. Одновременно и то и другое не бывает.
pub const Adjust = struct {
    insert: usize = 0,
    drop: usize = 0,

    pub fn none(self: Adjust) bool {
        return self.insert == 0 and self.drop == 0;
    }
};

pub const Corrector = struct {
    /// Разница, начиная с которой чиним. Пять миллисекунд: меньше не слышно,
    /// а чинить каждую мелочь значит дёргать звук без причины.
    tolerance_ns: u64 = 5 * std.time.ns_per_ms,
    /// Самый большой шаг правки за раз, в отсчётах. Одна миллисекунда:
    /// вставленная или выброшенная миллисекунда не слышна, а десять —
    /// уже щелчок.
    max_step: usize = 48,

    /// Насколько звук по отсчётам отстал от часов устройства (положительно)
    /// или обогнал их (отрицательно).
    pub fn driftNs(written: u64, rate: u32, device_elapsed_ns: u64) i64 {
        if (rate == 0) return 0;
        const by_count: i64 = @intCast(written * std.time.ns_per_s / rate);
        return @as(i64, @intCast(device_elapsed_ns)) - by_count;
    }

    /// Что сделать с очередным куском.
    ///
    /// Отстали — вставляем тишину, чтобы догнать; обогнали — выбрасываем.
    /// Шаг ограничен: лучше догонять несколько кусков подряд, чем щёлкнуть.
    pub fn adjust(self: Corrector, written: u64, rate: u32, device_elapsed_ns: u64) Adjust {
        const drift = driftNs(written, rate, device_elapsed_ns);
        const tol: i64 = @intCast(self.tolerance_ns);
        if (drift > tol) {
            const need: usize = @intCast(@as(u64, @intCast(drift)) * rate / std.time.ns_per_s);
            return .{ .insert = @min(need, self.max_step) };
        }
        if (drift < -tol) {
            const need: usize = @intCast(@as(u64, @intCast(-drift)) * rate / std.time.ns_per_s);
            return .{ .drop = @min(need, self.max_step) };
        }
        return .{};
    }
};

// ---------------------------------------------------------------- тесты

const testing = std.testing;
const sec = std.time.ns_per_s;
const ms = std.time.ns_per_ms;

test "без дрейфа ничего не трогаем" {
    const c = Corrector{};
    // Ровно секунда по отсчётам и ровно секунда по устройству.
    try testing.expect(c.adjust(48_000, 48_000, sec).none());
    try testing.expectEqual(@as(i64, 0), Corrector.driftNs(48_000, 48_000, sec));
}

test "мелкая разница внутри допуска не чинится" {
    // Дёргать звук из-за трёх миллисекунд — значит дёргать его без причины.
    const c = Corrector{};
    try testing.expect(c.adjust(48_000, 48_000, sec + 3 * ms).none());
    try testing.expect(c.adjust(48_000, 48_000, sec - 3 * ms).none());
}

test "отстали — вставляем тишину, но не больше шага" {
    const c = Corrector{};
    // Устройство ушло на двадцать миллисекунд вперёд: догонять надо 960
    // отсчётов, но за раз — только шаг.
    const a = c.adjust(48_000, 48_000, sec + 20 * ms);
    try testing.expectEqual(@as(usize, 48), a.insert);
    try testing.expectEqual(@as(usize, 0), a.drop);
}

test "обогнали — выбрасываем, но не больше шага" {
    const c = Corrector{};
    const a = c.adjust(48_000, 48_000, sec - 20 * ms);
    try testing.expectEqual(@as(usize, 48), a.drop);
    try testing.expectEqual(@as(usize, 0), a.insert);
}

test "дрейф чинится шагом, а не рывком" {
    // Шесть миллисекунд — это 288 отсчётов, больше шага в миллисекунду.
    // Вставить их разом значило бы щёлкнуть; вставляем шаг, а остальное
    // догоним на следующих кусках. Первый заход теста ждал все 288 —
    // и противоречил собственному правилу.
    const c = Corrector{};
    const a = c.adjust(48_000, 48_000, sec + 6 * ms);
    try testing.expectEqual(@as(usize, 48), a.insert);
    // А дрейф меньше шага чинится ровно на свою величину: 5.5 мс — это
    // 264 отсчёта, но допуск 5 мс, значит правим на всё, что сверх нуля,
    // ограничив шагом.
    const b = c.adjust(48_000, 48_000, sec + 5 * ms + ms / 2);
    try testing.expectEqual(@as(usize, 48), b.insert);
}

test "за десять минут дрейф в двадцать миллисекунд догоняется" {
    // Критерий задачи: рассинхрон меньше 20 мс на десятиминутной записи.
    // Изображаем устройство, чьи часы идут на 0.005% быстрее, и кормим
    // корректор кусками по 20 мс; к концу разница должна быть в допуске.
    const c = Corrector{};
    const rate: u32 = 48_000;
    var written: u64 = 0;
    var device_ns: u64 = 0;
    const chunk: u64 = 960; // 20 мс
    var inserted: u64 = 0;
    var i: u64 = 0;
    while (i < 600 * 50) : (i += 1) {
        // Устройство за тот же кусок насчитало чуть больше времени.
        device_ns += chunk * sec / rate + chunk * sec / rate / 20_000;
        // Сперва учитываем кусок, потом сравниваем — как в подаче, где
        // считается всё, что устройство уже отдало. Первый заход теста
        // сравнивал ДО учёта куска, отставал на кусок всегда и вставлял
        // тишину на каждом шаге.
        written += chunk;
        const a = c.adjust(written, rate, device_ns);
        written += a.insert;
        written -= a.drop;
        inserted += a.insert;
    }
    const left = Corrector.driftNs(written, rate, device_ns);
    try testing.expect(left > -20 * @as(i64, ms));
    try testing.expect(left < 20 * @as(i64, ms));
    // Правка была: без неё разница вышла бы за допуск.
    try testing.expect(inserted > 0);
    // А без коррекции набежало бы тридцать миллисекунд.
    const raw = Corrector.driftNs(600 * 50 * chunk, rate, device_ns);
    try testing.expect(raw > 20 * @as(i64, ms));
}

test "нулевая частота не делит на ноль" {
    const c = Corrector{};
    try testing.expect(c.adjust(100, 0, sec).none());
}
