//! Слой событий: курсор, кнопки, клавиши, окна — со временем, отдельно от кадров.
//!
//! Задача #88 (эпик #87). Курсор, впечатанный в кадр, потом не убрать, не
//! перекрасить и не увеличить. Слой хранит не картинку, а данные: где был
//! указатель, когда и чем щёлкнули, какая клавиша нажата, какое окно было
//! активно. Рисовать по ним можно как угодно и когда угодно — при показе,
//! при экспорте, разными стилями.
//!
//! Файл текстовый, строка на событие, время в наносекундах от начала
//! записи: читается глазами, `grep`-ом и Python-ом (`tools/check_events.py`
//! — сторонний читатель). Первая строка — `zigrec-events 1`.
const std = @import("std");

pub const magic = "zigrec-events";
pub const version: u32 = 1;

/// Расширение файла слоя рядом с записью: `запись.mp4` → `запись.events`.
pub const extension = ".events";

pub const Button = enum(u8) {
    left = 'L',
    right = 'R',
    middle = 'M',

    pub fn letter(self: Button) u8 {
        return @intFromEnum(self);
    }

    pub fn fromLetter(ch: u8) ?Button {
        return switch (ch) {
            'L' => .left,
            'R' => .right,
            'M' => .middle,
            else => null,
        };
    }
};

pub const Kind = enum {
    /// Область записи в координатах стола: x y ш в. Пишется в начале
    /// и при каждом сдвиге (окно, автопанорама).
    area,
    /// Указатель: x y.
    move,
    /// Кнопка нажата / отпущена: кнопка x y.
    down,
    up,
    /// Колесо: шаг x y.
    wheel,
    /// Клавиша нажата: код виртуальной клавиши.
    key,
    /// Активное окно сменилось: заголовок.
    focus,
    /// Шаблон аннотации, поставленный горячей клавишей при записи (#28):
    /// x y (тысячные доли области), длительность в мс — в `w`, цвет — в `h`,
    /// текст — остаток строки.
    text,
};

pub const max_title = 120;

pub const Point = struct { x: i32, y: i32 };

pub const Event = struct {
    at_ns: u64 = 0,
    kind: Kind = .move,
    x: i32 = 0,
    y: i32 = 0,
    /// Ширина и высота — у `area`; шаг колеса — в `w` у `wheel`; код клавиши — у `key`.
    w: i32 = 0,
    h: i32 = 0,
    button: Button = .left,
    title: [max_title]u8 = @splat(0),
    title_len: usize = 0,

    pub fn text(self: *const Event) []const u8 {
        return self.title[0..self.title_len];
    }
};

pub const Error = error{
    NotEvents,
    TooNew,
    Malformed,
    OutOfMemory,
};

// ---------------------------------------------------------------- запись

/// Писатель: строки идут в любой `std.Io.Writer`, а время — как дали.
///
/// Одинаковые подряд `move` не пишутся: указатель стоит — строки не нужны.
pub const Writer = struct {
    out: *std.Io.Writer,
    last_x: i32 = std.math.minInt(i32),
    last_y: i32 = std.math.minInt(i32),
    count: u64 = 0,

    pub fn init(out: *std.Io.Writer) !Writer {
        try out.print("{s} {d}\n", .{ magic, version });
        return .{ .out = out };
    }

    pub fn area(self: *Writer, at_ns: u64, x: i32, y: i32, w: u32, h: u32) !void {
        try self.out.print("{d} area {d} {d} {d} {d}\n", .{ at_ns, x, y, w, h });
        self.count += 1;
    }

    pub fn move(self: *Writer, at_ns: u64, x: i32, y: i32) !void {
        if (x == self.last_x and y == self.last_y) return;
        self.last_x = x;
        self.last_y = y;
        try self.out.print("{d} move {d} {d}\n", .{ at_ns, x, y });
        self.count += 1;
    }

    pub fn down(self: *Writer, at_ns: u64, button: Button, x: i32, y: i32) !void {
        try self.out.print("{d} down {c} {d} {d}\n", .{ at_ns, button.letter(), x, y });
        self.count += 1;
    }

    pub fn up(self: *Writer, at_ns: u64, button: Button, x: i32, y: i32) !void {
        try self.out.print("{d} up {c} {d} {d}\n", .{ at_ns, button.letter(), x, y });
        self.count += 1;
    }

    pub fn wheel(self: *Writer, at_ns: u64, delta: i32, x: i32, y: i32) !void {
        try self.out.print("{d} wheel {d} {d} {d}\n", .{ at_ns, delta, x, y });
        self.count += 1;
    }

    pub fn key(self: *Writer, at_ns: u64, code: u32) !void {
        try self.out.print("{d} key {d}\n", .{ at_ns, code });
        self.count += 1;
    }

    pub fn text(self: *Writer, at_ns: u64, x_mille: i32, y_mille: i32, len_ms: i32, colour: i32, words: []const u8) !void {
        try self.out.print("{d} text {d} {d} {d} {d} ", .{ at_ns, x_mille, y_mille, len_ms, colour });
        for (words[0..@min(words.len, max_title)]) |ch| {
            try self.out.writeByte(if (ch == '\n' or ch == '\r') ' ' else ch);
        }
        try self.out.writeByte('\n');
        self.count += 1;
    }

    pub fn focus(self: *Writer, at_ns: u64, title: []const u8) !void {
        // Заголовок — остаток строки; перевод строки внутри него сломал бы
        // файл, поэтому заменяем пробелом.
        try self.out.print("{d} focus ", .{at_ns});
        for (title[0..@min(title.len, max_title)]) |ch| {
            try self.out.writeByte(if (ch == '\n' or ch == '\r') ' ' else ch);
        }
        try self.out.writeByte('\n');
        self.count += 1;
    }
};

// ---------------------------------------------------------------- чтение

pub const Events = struct {
    items: std.ArrayList(Event) = .empty,

    pub fn deinit(self: *Events, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    pub fn list(self: *const Events) []const Event {
        return self.items.items;
    }

    /// Где был указатель в момент `at_ns`: последний `move` не позже него.
    pub fn cursorAt(self: *const Events, at_ns: u64) ?Point {
        var found: ?Event = null;
        for (self.items.items) |e| {
            if (e.at_ns > at_ns) break;
            if (e.kind == .move or e.kind == .down or e.kind == .up) found = e;
        }
        const e = found orelse return null;
        return .{ .x = e.x, .y = e.y };
    }

    /// Область записи, действовавшая в момент `at_ns`.
    pub fn areaAt(self: *const Events, at_ns: u64) ?Event {
        var found: ?Event = null;
        for (self.items.items) |e| {
            if (e.at_ns > at_ns) break;
            if (e.kind == .area) found = e;
        }
        return found;
    }

    /// Последнее нажатие не позже `at_ns`, если оно было не раньше `within_ns` назад:
    /// по нему рисуют вспышку клика.
    pub fn recentDown(self: *const Events, at_ns: u64, within_ns: u64) ?Event {
        var found: ?Event = null;
        for (self.items.items) |e| {
            if (e.at_ns > at_ns) break;
            if (e.kind == .down) found = e;
        }
        const e = found orelse return null;
        if (at_ns - e.at_ns > within_ns) return null;
        return e;
    }

    /// Сколько событий такого рода.
    pub fn count(self: *const Events, kind: Kind) usize {
        var n: usize = 0;
        for (self.items.items) |e| {
            if (e.kind == kind) n += 1;
        }
        return n;
    }
};

fn parseI32(text: ?[]const u8) ?i32 {
    return std.fmt.parseInt(i32, text orelse return null, 10) catch null;
}

/// Прочитать слой из текста. Незнакомое слово — пропускаем: слой от новой
/// версии должен читаться старой хотя бы частично. Время, идущее назад, —
/// порча файла.
pub fn read(allocator: std.mem.Allocator, data: []const u8) Error!Events {
    var lines = std.mem.splitScalar(u8, data, '\n');
    const head = std.mem.trimEnd(u8, lines.next() orelse return Error.NotEvents, "\r ");
    var head_parts = std.mem.splitScalar(u8, head, ' ');
    if (!std.mem.eql(u8, head_parts.next() orelse "", magic)) return Error.NotEvents;
    const got = std.fmt.parseInt(u32, head_parts.next() orelse "0", 10) catch return Error.Malformed;
    if (got > version) return Error.TooNew;

    var out = Events{};
    errdefer out.deinit(allocator);
    var last_ns: u64 = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r ");
        if (line.len == 0) continue;
        var parts = std.mem.splitScalar(u8, line, ' ');
        const at_ns = std.fmt.parseInt(u64, parts.next() orelse continue, 10) catch return Error.Malformed;
        if (at_ns < last_ns) return Error.Malformed;
        last_ns = at_ns;
        const word = parts.next() orelse continue;
        var e = Event{ .at_ns = at_ns };
        if (std.mem.eql(u8, word, "area")) {
            e.kind = .area;
            e.x = parseI32(parts.next()) orelse return Error.Malformed;
            e.y = parseI32(parts.next()) orelse return Error.Malformed;
            e.w = parseI32(parts.next()) orelse return Error.Malformed;
            e.h = parseI32(parts.next()) orelse return Error.Malformed;
        } else if (std.mem.eql(u8, word, "move")) {
            e.kind = .move;
            e.x = parseI32(parts.next()) orelse return Error.Malformed;
            e.y = parseI32(parts.next()) orelse return Error.Malformed;
        } else if (std.mem.eql(u8, word, "down") or std.mem.eql(u8, word, "up")) {
            e.kind = if (word[0] == 'd') .down else .up;
            const b = parts.next() orelse return Error.Malformed;
            e.button = Button.fromLetter(if (b.len > 0) b[0] else 0) orelse return Error.Malformed;
            e.x = parseI32(parts.next()) orelse return Error.Malformed;
            e.y = parseI32(parts.next()) orelse return Error.Malformed;
        } else if (std.mem.eql(u8, word, "wheel")) {
            e.kind = .wheel;
            e.w = parseI32(parts.next()) orelse return Error.Malformed;
            e.x = parseI32(parts.next()) orelse return Error.Malformed;
            e.y = parseI32(parts.next()) orelse return Error.Malformed;
        } else if (std.mem.eql(u8, word, "key")) {
            e.kind = .key;
            e.w = parseI32(parts.next()) orelse return Error.Malformed;
        } else if (std.mem.eql(u8, word, "text")) {
            e.kind = .text;
            e.x = parseI32(parts.next()) orelse return Error.Malformed;
            e.y = parseI32(parts.next()) orelse return Error.Malformed;
            e.w = parseI32(parts.next()) orelse return Error.Malformed;
            e.h = parseI32(parts.next()) orelse return Error.Malformed;
            const rest = parts.rest();
            e.title_len = @min(rest.len, max_title);
            @memcpy(e.title[0..e.title_len], rest[0..e.title_len]);
        } else if (std.mem.eql(u8, word, "focus")) {
            e.kind = .focus;
            const rest = parts.rest();
            e.title_len = @min(rest.len, max_title);
            @memcpy(e.title[0..e.title_len], rest[0..e.title_len]);
        } else {
            continue;
        }
        out.items.append(allocator, e) catch return Error.OutOfMemory;
    }
    return out;
}

/// Имя файла слоя для записи: расширение меняется на `.events`.
pub fn sidecarPath(buf: []u8, media_path: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, media_path, '.') orelse media_path.len;
    // Точка в имени папки, а не файла, — не расширение.
    const slash = std.mem.lastIndexOfAny(u8, media_path, "\\/") orelse 0;
    const stem = if (dot > slash) media_path[0..dot] else media_path;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ stem, extension }) catch media_path;
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;
const ms = std.time.ns_per_ms;

test "записанное читается обратно событие в событие" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var ev = try Writer.init(&w);
    try ev.area(0, 100, 50, 640, 360);
    try ev.move(10 * ms, 120, 80);
    try ev.move(20 * ms, 120, 80); // тот же — не пишется
    try ev.move(30 * ms, 130, 90);
    try ev.down(40 * ms, .left, 130, 90);
    try ev.up(60 * ms, .left, 130, 90);
    try ev.wheel(70 * ms, -120, 130, 90);
    try ev.key(80 * ms, 65);
    try ev.focus(90 * ms, "Блокнот — заметки\nвторая строка");
    try testing.expectEqual(@as(u64, 8), ev.count);

    var got = try read(testing.allocator, w.buffered());
    defer got.deinit(testing.allocator);
    const l = got.list();
    try testing.expectEqual(@as(usize, 8), l.len);
    try testing.expectEqual(Kind.area, l[0].kind);
    try testing.expectEqual(@as(i32, 640), l[0].w);
    try testing.expectEqual(Kind.move, l[1].kind);
    try testing.expectEqual(@as(u64, 30 * ms), l[2].at_ns);
    try testing.expectEqual(Button.left, l[3].button);
    try testing.expectEqual(Kind.up, l[4].kind);
    try testing.expectEqual(@as(i32, -120), l[5].w);
    try testing.expectEqual(@as(i32, 65), l[6].w);
    try testing.expectEqualStrings("Блокнот — заметки вторая строка", l[7].text());
}

test "указатель, область и вспышка клика по времени" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var ev = try Writer.init(&w);
    try ev.area(0, 0, 0, 800, 600);
    try ev.move(100 * ms, 10, 10);
    try ev.move(200 * ms, 20, 20);
    try ev.down(250 * ms, .right, 20, 20);
    try ev.area(300 * ms, 40, 0, 800, 600);
    var got = try read(testing.allocator, w.buffered());
    defer got.deinit(testing.allocator);

    try testing.expect(got.cursorAt(50 * ms) == null);
    try testing.expectEqual(@as(i32, 10), got.cursorAt(150 * ms).?.x);
    try testing.expectEqual(@as(i32, 20), got.cursorAt(1000 * ms).?.y);
    try testing.expectEqual(@as(i32, 0), got.areaAt(200 * ms).?.x);
    try testing.expectEqual(@as(i32, 40), got.areaAt(300 * ms).?.x);
    try testing.expect(got.recentDown(300 * ms, 100 * ms) != null);
    try testing.expect(got.recentDown(600 * ms, 100 * ms) == null);
    try testing.expectEqual(@as(usize, 2), got.count(.area));
}

test "чужой файл, будущая версия, обратное время — словами" {
    try testing.expectError(Error.NotEvents, read(testing.allocator, "просто текст\n"));
    try testing.expectError(Error.TooNew, read(testing.allocator, "zigrec-events 99\n"));
    try testing.expectError(Error.Malformed, read(testing.allocator, "zigrec-events 1\n500 move 1 1\n400 move 2 2\n"));
    try testing.expectError(Error.Malformed, read(testing.allocator, "zigrec-events 1\n5 down X 1 1\n"));
    // Незнакомое слово пропускается, переводы строк Windows не мешают.
    var got = try read(testing.allocator, "zigrec-events 1\r\n5 gesture круг\r\n6 move 1 2\r\n");
    defer got.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), got.list().len);
}

test "имя файла слоя — рядом с записью, с тем же именем" {
    var buf: [300]u8 = undefined;
    try testing.expectEqualStrings("D:\\видео\\запись.events", sidecarPath(&buf, "D:\\видео\\запись.mp4"));
    try testing.expectEqualStrings("D:\\в.идео\\запись.events", sidecarPath(&buf, "D:\\в.идео\\запись"));
    try testing.expectEqualStrings("a.events", sidecarPath(&buf, "a.gif"));
}

test "шаблон аннотации пишется словом text и читается со всеми полями" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var ev = try Writer.init(&w);
    try ev.text(700 * ms, 250, 400, 3000, 2, "Шаг");
    var got = try read(testing.allocator, w.buffered());
    defer got.deinit(testing.allocator);
    const e = got.list()[0];
    try testing.expectEqual(Kind.text, e.kind);
    try testing.expectEqual(@as(i32, 250), e.x);
    try testing.expectEqual(@as(i32, 3000), e.w);
    try testing.expectEqual(@as(i32, 2), e.h);
    try testing.expectEqualStrings("Шаг", e.text());
}
