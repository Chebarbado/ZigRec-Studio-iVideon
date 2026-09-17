//! Рисование курсора из слоя событий: стрелка и вспышка клика.
//!
//! Эпик #87. Курсор из слоя (#88) — это данные: где и когда. Как его
//! показать — решается здесь, одинаково для окна редактора (#90) и для
//! экспорта (#91): стрелка своих очертаний, а не системная форма, и
//! кольцо вспышки на клике. Всё — чистая растеризация в BGRA и точки
//! многоугольника для GDI; проверяется тестами по пикселям.
const std = @import("std");

pub const Point = struct { x: i32, y: i32 };

/// Очертания стрелки в единицах масштаба 1: остриё в (0,0).
/// Семь точек, как у классической стрелки Windows, только своя.
pub const arrow_shape = [_]Point{
    .{ .x = 0, .y = 0 },
    .{ .x = 0, .y = 16 },
    .{ .x = 4, .y = 12 },
    .{ .x = 7, .y = 18 },
    .{ .x = 10, .y = 17 },
    .{ .x = 7, .y = 11 },
    .{ .x = 12, .y = 11 },
};

/// Точки стрелки с остриём в (`x`, `y`), увеличенные в `scale` раз.
pub fn arrowPoints(x: i32, y: i32, scale: i32) [arrow_shape.len]Point {
    var out: [arrow_shape.len]Point = undefined;
    for (arrow_shape, 0..) |p, i| {
        out[i] = .{ .x = x + p.x * scale, .y = y + p.y * scale };
    }
    return out;
}

/// Внутри ли точка многоугольника (правило чёт-нечет).
fn inside(poly: []const Point, px: i32, py: i32) bool {
    var hit = false;
    var j = poly.len - 1;
    for (poly, 0..) |a, i| {
        const b = poly[j];
        if ((a.y > py) != (b.y > py)) {
            const t = @as(f32, @floatFromInt(py - a.y)) / @as(f32, @floatFromInt(b.y - a.y));
            const cx = @as(f32, @floatFromInt(a.x)) + t * @as(f32, @floatFromInt(b.x - a.x));
            if (@as(f32, @floatFromInt(px)) < cx) hit = !hit;
        }
        j = i;
    }
    return hit;
}

fn put(dst: []u8, stride: usize, w: u32, h: u32, x: i32, y: i32, bgra: [4]u8) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(w)) or y >= @as(i32, @intCast(h))) return;
    const at = @as(usize, @intCast(y)) * stride + @as(usize, @intCast(x)) * 4;
    if (at + 4 > dst.len) return;
    @memcpy(dst[at .. at + 4], &bgra);
}

pub const white = [4]u8{ 255, 255, 255, 255 };
pub const black = [4]u8{ 0, 0, 0, 255 };

/// Нарисовать стрелку в кадр BGRA: белая с чёрной каймой в одну точку.
pub fn arrow(dst: []u8, stride: usize, w: u32, h: u32, x: i32, y: i32, scale: i32) void {
    const s = @max(scale, 1);
    const poly = arrowPoints(x, y, s);
    const x0 = x - 1;
    const y0 = y - 1;
    const x1 = x + 13 * s + 1;
    const y1 = y + 19 * s + 1;
    var py = y0;
    while (py <= y1) : (py += 1) {
        var px = x0;
        while (px <= x1) : (px += 1) {
            if (inside(&poly, px, py)) {
                // Кайма: точка внутри, у которой сосед снаружи.
                const edge = !inside(&poly, px - 1, py) or !inside(&poly, px + 1, py) or
                    !inside(&poly, px, py - 1) or !inside(&poly, px, py + 1);
                put(dst, stride, w, h, px, py, if (edge) black else white);
            }
        }
    }
}

/// Кольцо вспышки клика: радиус `r`, толщина две точки, цвет `bgra`,
/// сила 0…255 смешивается с тем, что под ним.
pub fn ring(dst: []u8, stride: usize, w: u32, h: u32, x: i32, y: i32, r: i32, bgra: [4]u8, strength: u32) void {
    if (strength == 0 or r <= 0) return;
    var py = y - r - 1;
    while (py <= y + r + 1) : (py += 1) {
        var px = x - r - 1;
        while (px <= x + r + 1) : (px += 1) {
            const dx = px - x;
            const dy = py - y;
            const d2 = dx * dx + dy * dy;
            const outer = (r + 1) * (r + 1);
            const inner = (r - 1) * (r - 1);
            if (d2 > outer or d2 < inner) continue;
            if (px < 0 or py < 0 or px >= @as(i32, @intCast(w)) or py >= @as(i32, @intCast(h))) continue;
            const at = @as(usize, @intCast(py)) * stride + @as(usize, @intCast(px)) * 4;
            if (at + 4 > dst.len) continue;
            var k: usize = 0;
            while (k < 3) : (k += 1) {
                const was: u32 = dst[at + k];
                dst[at + k] = @intCast((was * (255 - strength) + @as(u32, bgra[k]) * strength) / 255);
            }
        }
    }
}

/// Сила вспышки по времени после клика: 255 сразу, 0 через `life_ns`.
pub fn flashStrength(since_ns: u64, life_ns: u64) u32 {
    if (since_ns >= life_ns or life_ns == 0) return 0;
    return @intCast(255 - since_ns * 255 / life_ns);
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;

fn pixel(buf: []const u8, stride: usize, x: usize, y: usize) [4]u8 {
    return buf[y * stride + x * 4 ..][0..4].*;
}

test "стрелка закрашивает остриё и тело, а вокруг ничего не трогает" {
    var buf: [64 * 64 * 4]u8 = @splat(7);
    arrow(&buf, 64 * 4, 64, 64, 20, 20, 1);
    // У острия — чёрная кайма (сама вершина многоугольника может лечь
    // по любую сторону от границы, поэтому смотрим рядом с ней), чуть
    // ниже по оси — белое тело.
    var black_near = false;
    var dy: usize = 20;
    while (dy <= 22) : (dy += 1) {
        var dx: usize = 20;
        while (dx <= 22) : (dx += 1) {
            if (std.mem.eql(u8, &pixel(&buf, 256, dx, dy), &black)) black_near = true;
        }
    }
    try testing.expect(black_near);
    try testing.expectEqual(white, pixel(&buf, 256, 22, 26));
    // Далеко от стрелки — как было.
    try testing.expectEqual([4]u8{ 7, 7, 7, 7 }, pixel(&buf, 256, 5, 5));
    try testing.expectEqual([4]u8{ 7, 7, 7, 7 }, pixel(&buf, 256, 60, 60));
}

test "стрелка у края кадра не пишет за край" {
    var buf: [16 * 16 * 4]u8 = @splat(0);
    arrow(&buf, 16 * 4, 16, 16, 12, 10, 2);
    arrow(&buf, 16 * 4, 16, 16, -5, -5, 1);
    // Не упало — и это уже проверка; точка стрелки внутри кадра закрашена
    // (кайма или тело — обе с полной альфой), а сама вершина — нет:
    // вершина многоугольника лежит по любую сторону от границы.
    try testing.expect(pixel(&buf, 64, 13, 13)[3] == 255);
}

test "кольцо вспышки смешивается с фоном и гаснет по времени" {
    var buf: [40 * 40 * 4]u8 = @splat(0);
    ring(&buf, 160, 40, 40, 20, 20, 6, .{ 0, 0, 255, 255 }, 255);
    try testing.expectEqual([4]u8{ 0, 0, 255, 0 }, pixel(&buf, 160, 26, 20));
    // Центр кольца не тронут.
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, pixel(&buf, 160, 20, 20));
    // Половинная сила — половинный красный.
    var buf2: [40 * 40 * 4]u8 = @splat(0);
    ring(&buf2, 160, 40, 40, 20, 20, 6, .{ 0, 0, 255, 255 }, 128);
    try testing.expect(pixel(&buf2, 160, 26, 20)[2] > 120 and pixel(&buf2, 160, 26, 20)[2] < 136);
    try testing.expectEqual(@as(u32, 255), flashStrength(0, 300));
    try testing.expectEqual(@as(u32, 0), flashStrength(300, 300));
    try testing.expect(flashStrength(150, 300) > 120 and flashStrength(150, 300) < 135);
}

test "точки стрелки масштабируются от острия" {
    const p = arrowPoints(100, 50, 3);
    try testing.expectEqual(@as(i32, 100), p[0].x);
    try testing.expectEqual(@as(i32, 50), p[0].y);
    try testing.expectEqual(@as(i32, 100 + 36), p[6].x);
    try testing.expectEqual(@as(i32, 50 + 48), p[1].y);
}
