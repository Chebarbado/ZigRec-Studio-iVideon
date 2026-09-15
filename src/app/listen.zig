//! На каком адресе слушать сервер MCP.
//!
//! Задача #66. Умолчание — `127.0.0.1`: программа не должна открывать порт
//! наружу по своей воле. Но это не должно быть единственной возможностью:
//! Claude Code может работать на другой машине, в виртуалке или в контейнере,
//! и тогда нужен либо `0.0.0.0`, либо конкретный адрес этой машины.
//!
//! **Про открытый наружу порт надо говорить прямо.** Человек, поставивший
//! `0.0.0.0`, должен узнать об этом из окна, а не потом и от кого-то другого.
//! Поэтому здесь есть не только разбор адреса, но и ответ на вопрос
//! «виден ли он из сети».
//!
//! IPv6 — наравне с IPv4, а не «тоже»: `::1`, `::`, и запись с портом
//! в квадратных скобках, как это принято везде.
const std = @import("std");
const net = std.Io.net;

/// Что слушать, если ничего не выбрано.
pub const default_text = "127.0.0.1";

/// Больше этого адрес не бывает: самый длинный IPv6 с областью — 45 знаков.
pub const max_text = 48;

pub const Error = error{
    /// Это не адрес.
    BadAddress,
};

/// Кого пускает такой адрес.
pub const Scope = enum {
    /// Только эту машину.
    loopback,
    /// Все, кто дотянется по сети.
    any,
    /// Один определённый адрес этой машины.
    specific,

    pub fn label(self: Scope) []const u8 {
        return switch (self) {
            .loopback => "только эта машина",
            .any => "видно из сети",
            .specific => "один адрес этой машины",
        };
    }
};

/// Разобрать адрес. Порт нужен потому, что его хранит тот же тип.
pub fn parse(text: []const u8, port: u16) Error!net.IpAddress {
    const clean = std.mem.trim(u8, text, " \t");
    if (clean.len == 0) return Error.BadAddress;
    return net.IpAddress.parse(clean, port) catch Error.BadAddress;
}

/// Годится ли такая строка как адрес.
pub fn valid(text: []const u8) bool {
    _ = parse(text, 1) catch return false;
    return true;
}

/// Кого пускает адрес.
///
/// Считаем по самому адресу, а не по его написанию: `0.0.0.0`, `::`
/// и `0:0:0:0:0:0:0:0` — одно и то же, и говорить о них надо одинаково.
pub fn scopeOf(text: []const u8) Error!Scope {
    const addr = try parse(text, 1);
    return switch (addr) {
        .ip4 => |a| {
            // Вся сеть 127.x.x.x — это петля на себя, а не только 127.0.0.1.
            if (a.bytes[0] == 127) return .loopback;
            if (std.mem.allEqual(u8, &a.bytes, 0)) return .any;
            return .specific;
        },
        .ip6 => |a| {
            if (std.mem.allEqual(u8, &a.bytes, 0)) return .any;
            // `::1` — это пятнадцать нулей и единица.
            if (std.mem.allEqual(u8, a.bytes[0..15], 0) and a.bytes[15] == 1) return .loopback;
            return .specific;
        },
    };
}

/// Виден ли порт из сети при таком адресе.
///
/// Всё, кроме петли на себя, считаем видным: даже конкретный адрес машины
/// доступен соседям по сети, и молчать об этом нельзя.
pub fn opensToNetwork(text: []const u8) bool {
    const scope = scopeOf(text) catch return false;
    return scope != .loopback;
}

/// Записать «адрес и порт» так, как это принято показывать.
///
/// У IPv6 адрес берут в квадратные скобки: без них двоеточия адреса
/// не отличить от двоеточия перед портом.
pub fn write(buf: []u8, text: []const u8, port: u16) []const u8 {
    const addr = parse(text, port) catch return "";
    var w = std.Io.Writer.fixed(buf);
    addr.format(&w) catch return "";
    return w.buffered();
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;

test "обычные адреса разбираются" {
    try testing.expect(valid("127.0.0.1"));
    try testing.expect(valid("0.0.0.0"));
    try testing.expect(valid("192.168.1.5"));
    try testing.expect(valid("::1"));
    try testing.expect(valid("::"));
    try testing.expect(valid("2001:db8::1"));
    // Пробелы по краям человек ставит не нарочно.
    try testing.expect(valid("  127.0.0.1  "));
}

test "не адрес — не берём" {
    try testing.expect(!valid(""));
    try testing.expect(!valid("   "));
    try testing.expect(!valid("локалхост"));
    try testing.expect(!valid("127.0.0"));
    try testing.expect(!valid("256.1.1.1"));
    try testing.expect(!valid("1.2.3.4.5"));
    try testing.expect(!valid(":::"));
    try testing.expectError(Error.BadAddress, parse("никакой", 15599));
}

test "кого пускает адрес" {
    try testing.expectEqual(Scope.loopback, try scopeOf("127.0.0.1"));
    try testing.expectEqual(Scope.loopback, try scopeOf("127.1.2.3"));
    try testing.expectEqual(Scope.loopback, try scopeOf("::1"));
    try testing.expectEqual(Scope.any, try scopeOf("0.0.0.0"));
    try testing.expectEqual(Scope.any, try scopeOf("::"));
    try testing.expectEqual(Scope.specific, try scopeOf("192.168.1.5"));
    try testing.expectEqual(Scope.specific, try scopeOf("2001:db8::1"));
}

test "про выход наружу говорим обо всём, кроме петли на себя" {
    // Даже конкретный адрес машины доступен соседям по сети.
    try testing.expect(!opensToNetwork("127.0.0.1"));
    try testing.expect(!opensToNetwork("::1"));
    try testing.expect(opensToNetwork("0.0.0.0"));
    try testing.expect(opensToNetwork("::"));
    try testing.expect(opensToNetwork("192.168.1.5"));
    // Негодный адрес наружу не открывает: слушать по нему всё равно нечего.
    try testing.expect(!opensToNetwork("чепуха"));
}

test "запись адреса с портом" {
    var buf: [max_text + 8]u8 = undefined;
    try testing.expectEqualStrings("127.0.0.1:15599", write(&buf, "127.0.0.1", 15599));
    try testing.expectEqualStrings("0.0.0.0:80", write(&buf, "0.0.0.0", 80));
    // У IPv6 адрес берут в скобки: иначе двоеточий не различить.
    try testing.expectEqualStrings("[::1]:15599", write(&buf, "::1", 15599));
    try testing.expectEqualStrings("[::]:15599", write(&buf, "::", 15599));
}

test "разные записи одного нуля значат одно и то же" {
    // `::` и `0:0:0:0:0:0:0:0` — один адрес, и говорить о них надо одинаково.
    try testing.expectEqual(Scope.any, try scopeOf("0:0:0:0:0:0:0:0"));
    try testing.expectEqual(try scopeOf("::"), try scopeOf("0:0:0:0:0:0:0:0"));
}

test "умолчание годное и никого наружу не пускает" {
    try testing.expect(valid(default_text));
    try testing.expect(!opensToNetwork(default_text));
    try testing.expectEqual(Scope.loopback, try scopeOf(default_text));
}

test "у каждой области есть подпись" {
    for ([_]Scope{ .loopback, .any, .specific }) |s| {
        try testing.expect(s.label().len > 0);
    }
}
