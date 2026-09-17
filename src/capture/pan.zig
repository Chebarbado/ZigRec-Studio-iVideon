//! Автопанорама: область записи едет за курсором.
//!
//! Задача #29. Когда пишут область меньше экрана, курсор то и дело
//! уходит за её край, и в записи остаётся пустое место, где что-то
//! происходило. Область может ехать за ним сама — но не дёргаясь: в центре
//! есть зона, где курсор ничего не двигает, а сдвиг ограничен по
//! скорости, чтобы зрителя не укачивало. Чистая арифметика, тесты.
const std = @import("std");
const types = @import("capture_types.zig");
pub const Rect = types.Rect;

pub const Follower = struct {
    /// Доля области по центру, внутри которой курсор область не двигает:
    /// половина ширины и высоты. Меньше — область ездит за каждым движением.
    dead_zone: f32 = 0.5,
    /// Самая большая скорость сдвига, точек в секунду. Тысяча двести —
    /// экран за полторы секунды: успевает за мышью, не укачивает.
    max_speed: f32 = 1200,
    /// Положение области — дробное, чтобы медленный ход не застревал
    /// на целых точках.
    x: f32 = 0,
    y: f32 = 0,

    pub fn init(area: Rect) Follower {
        return .{ .x = @floatFromInt(area.x), .y = @floatFromInt(area.y) };
    }

    /// Куда ставить область после `dt_ns` с курсором в (`cx`, `cy`).
    ///
    /// Курсор внутри мёртвой зоны — область стоит. Снаружи — область
    /// едет так, чтобы курсор оказался на границе зоны, но не быстрее
    /// `max_speed`. За край экрана область не выходит.
    pub fn update(self: *Follower, cx: i32, cy: i32, area_w: u32, area_h: u32, screen_w: u32, screen_h: u32, dt_ns: u64) Rect {
        const w: f32 = @floatFromInt(area_w);
        const h: f32 = @floatFromInt(area_h);
        const zone_w = w * self.dead_zone;
        const zone_h = h * self.dead_zone;
        const zone_left = self.x + (w - zone_w) / 2;
        const zone_top = self.y + (h - zone_h) / 2;
        const zone_right = zone_left + zone_w;
        const zone_bottom = zone_top + zone_h;

        const fx: f32 = @floatFromInt(cx);
        const fy: f32 = @floatFromInt(cy);
        var want_dx: f32 = 0;
        var want_dy: f32 = 0;
        if (fx < zone_left) want_dx = fx - zone_left else if (fx > zone_right) want_dx = fx - zone_right;
        if (fy < zone_top) want_dy = fy - zone_top else if (fy > zone_bottom) want_dy = fy - zone_bottom;

        const budget = self.max_speed * @as(f32, @floatFromInt(dt_ns)) / @as(f32, std.time.ns_per_s);
        const dist = @sqrt(want_dx * want_dx + want_dy * want_dy);
        if (dist > 0) {
            const k = if (dist > budget) budget / dist else 1.0;
            self.x += want_dx * k;
            self.y += want_dy * k;
        }

        // К краю экрана — прижать, а не вывалиться за него.
        const max_x = @as(f32, @floatFromInt(screen_w)) - w;
        const max_y = @as(f32, @floatFromInt(screen_h)) - h;
        self.x = std.math.clamp(self.x, 0, @max(max_x, 0));
        self.y = std.math.clamp(self.y, 0, @max(max_y, 0));
        return .{ .x = @intFromFloat(@round(self.x)), .y = @intFromFloat(@round(self.y)), .width = area_w, .height = area_h };
    }
};

// ---------------------------------------------------------------- тесты

const testing = std.testing;
const ms = std.time.ns_per_ms;

test "курсор в центральной зоне — область стоит" {
    var f = Follower.init(.{ .x = 100, .y = 100, .width = 400, .height = 300 });
    // Зона: x 200…400, y 175…325.
    const r = f.update(300, 250, 400, 300, 1920, 1080, 33 * ms);
    try testing.expectEqual(@as(i32, 100), r.x);
    try testing.expectEqual(@as(i32, 100), r.y);
    const edge = f.update(400, 325, 400, 300, 1920, 1080, 33 * ms);
    try testing.expectEqual(@as(i32, 100), edge.x);
    try testing.expectEqual(@as(i32, 100), edge.y);
}

test "курсор за зоной — область едет к нему, но не быстрее предела" {
    var f = Follower.init(.{ .x = 100, .y = 100, .width = 400, .height = 300 });
    // Курсор в 1000 — на 600 правее края зоны; за 33 мс при 1200 т/с можно сдвинуться на ~40.
    const r = f.update(1000, 250, 400, 300, 1920, 1080, 33 * ms);
    try testing.expect(r.x > 100 and r.x <= 141);
    try testing.expectEqual(@as(i32, 100), r.y);
    // Через секунду — уже догнала: курсор на правом краю зоны.
    var i: usize = 0;
    var last = r;
    while (i < 40) : (i += 1) last = f.update(1000, 250, 400, 300, 1920, 1080, 33 * ms);
    // Зона: x от last.x+100 до last.x+300; курсор 1000 → last.x = 700.
    try testing.expectEqual(@as(i32, 700), last.x);
}

test "область не выходит за край экрана" {
    var f = Follower.init(.{ .x = 1500, .y = 700, .width = 400, .height = 300 });
    var i: usize = 0;
    var last: Rect = undefined;
    while (i < 100) : (i += 1) last = f.update(1919, 1079, 400, 300, 1920, 1080, 33 * ms);
    try testing.expectEqual(@as(i32, 1520), last.x);
    try testing.expectEqual(@as(i32, 780), last.y);
    // И к нулю тоже прижимается.
    i = 0;
    while (i < 100) : (i += 1) last = f.update(0, 0, 400, 300, 1920, 1080, 33 * ms);
    try testing.expectEqual(@as(i32, 0), last.x);
    try testing.expectEqual(@as(i32, 0), last.y);
}

test "нулевое время — нулевой сдвиг, размер области не меняется" {
    var f = Follower.init(.{ .x = 100, .y = 100, .width = 400, .height = 300 });
    const r = f.update(1900, 1000, 400, 300, 1920, 1080, 0);
    try testing.expectEqual(@as(i32, 100), r.x);
    try testing.expectEqual(@as(u32, 400), r.width);
    try testing.expectEqual(@as(u32, 300), r.height);
}

test "по диагонали скорость та же, что по прямой" {
    var f = Follower.init(.{ .x = 0, .y = 0, .width = 400, .height = 300 });
    const r = f.update(1000, 1000, 400, 300, 1920, 1080, 100 * ms);
    // Бюджет 120 точек на всю длину сдвига, а не на каждую ось.
    const moved = @sqrt(@as(f32, @floatFromInt(r.x * r.x + r.y * r.y)));
    try testing.expect(moved <= 121 and moved >= 118);
}
