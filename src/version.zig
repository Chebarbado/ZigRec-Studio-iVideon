//! Единственный источник версии проекта.
//!
//! Четыре сегмента `A.B.C.D`, привязанные к уровням канбана:
//!
//!     L0 (миссия)    -> A   релизная веха: A+1, остальное в ноль
//!     L1 (эпик)      -> B   +0.1.0.0
//!     L2 (задача)    -> C   +0.0.1.0
//!     L3 (подзадача) -> D   +0.0.0.1
//!
//! Аддитивно: закрытие тикета поднимает только сегмент своего уровня, младшие
//! сегменты НЕ сбрасываются (`0.1.3.0` --L1--> `0.2.3.0`).
//!
//! Исключение — L0. Закрытие миссии это релиз, и версия становится чистым
//! релизным номером: путь `0.7.21.0` --L0--> `1.0.0.0`.
//!
//! Бампается в том же коммите, что и сам код. `VERSION_DATE` двигается вместе
//! с `VERSION`. Подробности: вики Versioning.
const std = @import("std");

pub const VERSION = "1.0.2.0";
/// Дата выпуска VERSION (ISO). Двигать вместе с VERSION.
pub const VERSION_DATE = "2026-09-20";

pub const Level = enum {
    l0,
    l1,
    l2,
    l3,

    pub fn parse(s: []const u8) ?Level {
        inline for (@typeInfo(Level).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(s, f.name)) return @field(Level, f.name);
        }
        return null;
    }
};

pub const ParseError = error{
    /// Сегментов не четыре.
    WrongSegmentCount,
    /// Сегмент пуст или содержит не только цифры.
    BadSegment,
    /// Сегмент не влезает в u16.
    SegmentTooBig,
};

/// Разобранная версия. Печатается через `std.fmt` как `A.B.C.D`.
pub const Version = struct {
    a: u16 = 0,
    b: u16 = 0,
    c: u16 = 0,
    d: u16 = 0,

    /// Максимальная длина текстового представления: 4 числа по 5 цифр и 3 точки.
    pub const max_len = 4 * 5 + 3;

    pub fn parse(text: []const u8) ParseError!Version {
        var it = std.mem.splitScalar(u8, text, '.');
        var seg: [4]u16 = .{ 0, 0, 0, 0 };
        var n: usize = 0;
        while (it.next()) |part| {
            if (n == 4) return ParseError.WrongSegmentCount;
            if (part.len == 0) return ParseError.BadSegment;
            for (part) |ch| {
                if (!std.ascii.isDigit(ch)) return ParseError.BadSegment;
            }
            seg[n] = std.fmt.parseInt(u16, part, 10) catch return ParseError.SegmentTooBig;
            n += 1;
        }
        if (n != 4) return ParseError.WrongSegmentCount;
        return .{ .a = seg[0], .b = seg[1], .c = seg[2], .d = seg[3] };
    }

    /// Версия после закрытия тикета уровня `level`.
    ///
    /// L0 обнуляет младшие сегменты, потому что это релиз, а не ещё один шаг:
    /// номер релиза должен читаться как номер релиза, а не тащить за собой
    /// счётчик задач предыдущего пути.
    pub fn bump(self: Version, level: Level) Version {
        return switch (level) {
            .l0 => .{ .a = self.a + 1 },
            .l1 => .{ .a = self.a, .b = self.b + 1, .c = self.c, .d = self.d },
            .l2 => .{ .a = self.a, .b = self.b, .c = self.c + 1, .d = self.d },
            .l3 => .{ .a = self.a, .b = self.b, .c = self.c, .d = self.d + 1 },
        };
    }

    /// Текст версии в переданный буфер (нужен минимум `max_len` байт).
    pub fn write(self: Version, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ self.a, self.b, self.c, self.d }) catch unreachable;
    }

    pub fn eql(self: Version, other: Version) bool {
        return self.a == other.a and self.b == other.b and self.c == other.c and self.d == other.d;
    }
};

/// Разобранная версия проекта. Ошибиться нельзя: строка проверяется тестом.
pub fn current() Version {
    return Version.parse(VERSION) catch unreachable;
}

// ---------------------------------------------------------------- тесты

test "версия проекта разбирается и печатается обратно тем же текстом" {
    const v = try Version.parse(VERSION);
    var buf: [Version.max_len]u8 = undefined;
    try std.testing.expectEqualStrings(VERSION, v.write(&buf));
}

test "дата версии выглядит как ISO-дата" {
    try std.testing.expectEqual(@as(usize, 10), VERSION_DATE.len);
    try std.testing.expectEqual(@as(u8, '-'), VERSION_DATE[4]);
    try std.testing.expectEqual(@as(u8, '-'), VERSION_DATE[7]);
    for (VERSION_DATE, 0..) |ch, i| {
        if (i == 4 or i == 7) continue;
        try std.testing.expect(std.ascii.isDigit(ch));
    }
}

test "бамп поднимает только свой сегмент, младшие не сбрасываются" {
    const v = try Version.parse("0.1.3.0");
    try std.testing.expect(v.bump(.l1).eql(.{ .a = 0, .b = 2, .c = 3, .d = 0 }));
    try std.testing.expect(v.bump(.l2).eql(.{ .a = 0, .b = 1, .c = 4, .d = 0 }));
    try std.testing.expect(v.bump(.l3).eql(.{ .a = 0, .b = 1, .c = 3, .d = 1 }));
}

test "закрытие миссии это релиз: младшие сегменты обнуляются" {
    const v = try Version.parse("0.7.21.0");
    try std.testing.expect(v.bump(.l0).eql(.{ .a = 1, .b = 0, .c = 0, .d = 0 }));
}

test "бампы независимы и накапливаются" {
    var v = try Version.parse("0.1.0.0");
    v = v.bump(.l2).bump(.l2).bump(.l3).bump(.l1);
    var buf: [Version.max_len]u8 = undefined;
    try std.testing.expectEqualStrings("0.2.2.1", v.write(&buf));
}

test "мусор не разбирается" {
    try std.testing.expectError(ParseError.WrongSegmentCount, Version.parse("1.2.3"));
    try std.testing.expectError(ParseError.WrongSegmentCount, Version.parse("1.2.3.4.5"));
    try std.testing.expectError(ParseError.BadSegment, Version.parse("1.2..4"));
    try std.testing.expectError(ParseError.BadSegment, Version.parse("1.2.x.4"));
    try std.testing.expectError(ParseError.BadSegment, Version.parse(""));
    try std.testing.expectError(ParseError.SegmentTooBig, Version.parse("1.2.3.99999"));
}

test "уровень разбирается из строки в любом регистре" {
    try std.testing.expectEqual(Level.l0, Level.parse("l0").?);
    try std.testing.expectEqual(Level.l3, Level.parse("L3").?);
    try std.testing.expect(Level.parse("l4") == null);
    try std.testing.expect(Level.parse("") == null);
}
