//! Съём событий во время записи: что пишем в слой (#89) и когда.
//!
//! Раз в кадр окно записи спрашивает, где указатель, какие кнопки и
//! клавиши нажаты, какое окно активно, — и отдаёт сюда. Здесь решается,
//! что из этого стало событием: нажатие — только переход «не была — стала»,
//! смена окна — только когда заголовок другой, область — когда сдвинулась.
//! Решение чистое и проверяется тестами на выдуманных состояниях; Windows
//! спрашивается только в `sampleNow`.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;
const types = @import("capture_types.zig");
const events = @import("../file/events.zig");

pub const Rect = types.Rect;

pub const Buttons = struct {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
};

/// Что известно об этом мгновении.
pub const Sample = struct {
    at_ns: u64,
    cursor: ?events.Point = null,
    buttons: Buttons = .{},
    /// Коды клавиш, нажатых сейчас.
    keys: []const u8 = &.{},
    /// Заголовок активного окна.
    title: []const u8 = "",
    /// Область записи в координатах стола.
    area: Rect,
};

pub const Tap = struct {
    buttons: Buttons = .{},
    keys: [256]bool = @splat(false),
    title: [events.max_title]u8 = @splat(0),
    title_len: usize = 0,
    area: ?Rect = null,
    last: ?events.Point = null,

    /// Записать то, что изменилось.
    pub fn record(self: *Tap, ev: *events.Writer, s: Sample) !void {
        if (self.area == null or !sameRect(self.area.?, s.area)) {
            try ev.area(s.at_ns, s.area.x, s.area.y, s.area.width, s.area.height);
            self.area = s.area;
        }
        if (s.cursor) |p| {
            try ev.move(s.at_ns, p.x, p.y);
            self.last = p;
        }
        const at = s.cursor orelse self.last orelse events.Point{ .x = 0, .y = 0 };
        try self.button(ev, s.at_ns, .left, self.buttons.left, s.buttons.left, at);
        try self.button(ev, s.at_ns, .right, self.buttons.right, s.buttons.right, at);
        try self.button(ev, s.at_ns, .middle, self.buttons.middle, s.buttons.middle, at);
        self.buttons = s.buttons;

        // Клавиши: нажатие — переход из «не была» в «стала»; отпускание
        // в слой не пишем, оно никому не нужно, а строк удвоило бы.
        var now: [256]bool = @splat(false);
        for (s.keys) |code| {
            now[code] = true;
            if (!self.keys[code]) try ev.key(s.at_ns, code);
        }
        self.keys = now;

        if (!std.mem.eql(u8, s.title, self.title[0..self.title_len])) {
            try ev.focus(s.at_ns, s.title);
            self.title_len = @min(s.title.len, self.title.len);
            @memcpy(self.title[0..self.title_len], s.title[0..self.title_len]);
        }
    }

    fn button(self: *Tap, ev: *events.Writer, at_ns: u64, which: events.Button, was: bool, now: bool, at: events.Point) !void {
        _ = self;
        if (now and !was) try ev.down(at_ns, which, at.x, at.y);
        if (was and !now) try ev.up(at_ns, which, at.x, at.y);
    }

    fn sameRect(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
    }

    /// Спросить Windows и записать. `cursor` даёт вызывающий: он его уже
    /// спрашивал ради рисования.
    pub fn sampleNow(self: *Tap, ev: *events.Writer, at_ns: u64, cursor: ?events.Point, area: Rect) !void {
        if (builtin.os.tag != .windows) return;
        var keys_buf: [64]u8 = undefined;
        var n: usize = 0;
        // Кнопки мыши — отдельно; клавиши с 8 (Backspace) по 254.
        var code: u32 = 8;
        while (code < 255 and n < keys_buf.len) : (code += 1) {
            if (code == c.VK_LBUTTON or code == c.VK_RBUTTON or code == c.VK_MBUTTON) continue;
            if (isDown(@intCast(code))) {
                keys_buf[n] = @intCast(code);
                n += 1;
            }
        }
        var title_buf: [events.max_title]u8 = undefined;
        const title = foregroundTitle(&title_buf);
        try self.record(ev, .{
            .at_ns = at_ns,
            .cursor = cursor,
            .buttons = .{
                .left = isDown(c.VK_LBUTTON),
                .right = isDown(c.VK_RBUTTON),
                .middle = isDown(c.VK_MBUTTON),
            },
            .keys = keys_buf[0..n],
            .title = title,
            .area = area,
        });
    }

    fn isDown(vk: c_int) bool {
        return (c.GetAsyncKeyState(vk) & @as(c_short, @bitCast(@as(u16, 0x8000)))) != 0;
    }

    fn foregroundTitle(buf: []u8) []const u8 {
        const h = c.GetForegroundWindow() orelse return "";
        var wide: [256]u16 = undefined;
        const n = c.GetWindowTextW(h, &wide, wide.len);
        if (n <= 0) return "";
        const len = std.unicode.utf16LeToUtf8(buf, wide[0..@intCast(n)]) catch return "";
        return buf[0..len];
    }
};

// ---------------------------------------------------------------- тесты

const testing = std.testing;
const ms = std.time.ns_per_ms;

test "в слой идут только переходы: нажатие, смена окна, сдвиг области" {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var ev = try events.Writer.init(&w);
    var tap = Tap{};
    const area = Rect{ .x = 10, .y = 20, .width = 640, .height = 360 };

    try tap.record(&ev, .{ .at_ns = 0, .cursor = .{ .x = 100, .y = 100 }, .title = "Блокнот", .area = area });
    // Ничего не изменилось — только указатель тот же: строк не прибавилось.
    try tap.record(&ev, .{ .at_ns = 33 * ms, .cursor = .{ .x = 100, .y = 100 }, .title = "Блокнот", .area = area });
    // Нажали левую и клавишу A, окно то же.
    try tap.record(&ev, .{ .at_ns = 66 * ms, .cursor = .{ .x = 110, .y = 100 }, .buttons = .{ .left = true }, .keys = &[_]u8{0x41}, .title = "Блокнот", .area = area });
    // Держим: ни нажатия, ни клавиши снова.
    try tap.record(&ev, .{ .at_ns = 99 * ms, .cursor = .{ .x = 110, .y = 100 }, .buttons = .{ .left = true }, .keys = &[_]u8{0x41}, .title = "Блокнот", .area = area });
    // Отпустили, окно сменилось, область сдвинулась.
    try tap.record(&ev, .{ .at_ns = 132 * ms, .cursor = null, .title = "Проводник", .area = .{ .x = 50, .y = 20, .width = 640, .height = 360 } });

    var got = try events.read(testing.allocator, w.buffered());
    defer got.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), got.count(.area));
    try testing.expectEqual(@as(usize, 2), got.count(.move));
    try testing.expectEqual(@as(usize, 1), got.count(.down));
    try testing.expectEqual(@as(usize, 1), got.count(.up));
    try testing.expectEqual(@as(usize, 1), got.count(.key));
    try testing.expectEqual(@as(usize, 2), got.count(.focus));
    // Отпускание без указателя в кадре — по последнему известному месту.
    const l = got.list();
    var up_x: i32 = -1;
    for (l) |e| if (e.kind == .up) {
        up_x = e.x;
    };
    try testing.expectEqual(@as(i32, 110), up_x);
}

test "клавиша, отпущенная и нажатая снова, пишется дважды" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var ev = try events.Writer.init(&w);
    var tap = Tap{};
    const area = Rect{ .x = 0, .y = 0, .width = 100, .height = 100 };
    try tap.record(&ev, .{ .at_ns = 0, .keys = &[_]u8{0x20}, .area = area });
    try tap.record(&ev, .{ .at_ns = 1 * ms, .keys = &.{}, .area = area });
    try tap.record(&ev, .{ .at_ns = 2 * ms, .keys = &[_]u8{0x20}, .area = area });
    var got = try events.read(testing.allocator, w.buffered());
    defer got.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), got.count(.key));
}
