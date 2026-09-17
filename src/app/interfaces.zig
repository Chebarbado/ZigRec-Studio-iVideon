//! Адреса этой машины: на чём можно слушать сервер MCP.
//!
//! Задача #86. Адрес прослушивания набирался руками: «127.0.0.1» помнят все,
//! а вот адрес своего Wi-Fi — нет, и за ним шли в `ipconfig`. Здесь список
//! готовых вариантов: только эта машина, все интерфейсы и каждый адрес,
//! который у машины сейчас есть, с именем интерфейса.
//!
//! Правила сборки списка — чистые функции с тестами: им скармливают
//! придуманные интерфейсы. Windows спрашивается только в `list`.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;
const listen = @import("listen.zig");

/// Больше адресов на машине не бывает в разумной жизни: физические,
/// Wi-Fi, виртуальные и VPN — и на каждом по IPv4 и IPv6.
pub const max_entries = 24;
/// Имя интерфейса. Windows даёт «Ethernet 3» или «Подключение по локальной
/// сети», длиннее шестидесяти четырёх байт — редкость, и её обрежем.
pub const max_name = 64;

pub const Family = enum { ip4, ip6 };

/// Один адрес одного интерфейса.
pub const Entry = struct {
    text: [listen.max_text]u8 = @splat(0),
    text_len: usize = 0,
    name: [max_name]u8 = @splat(0),
    name_len: usize = 0,
    family: Family = .ip4,
    /// Провод или Wi-Fi, а не VPN и не виртуальный коммутатор. Такой адрес
    /// показываем первым и его же называем наружу: по VPN-адресу сосед по
    /// комнате не достучится.
    physical: bool = false,

    pub fn address(self: *const Entry) []const u8 {
        return self.text[0..self.text_len];
    }

    pub fn ifaceName(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Собрать запись руками: для тестов и стендов.
    pub fn make(text: []const u8, name: []const u8, family: Family) Entry {
        var e = Entry{ .family = family };
        e.text_len = @min(text.len, e.text.len);
        @memcpy(e.text[0..e.text_len], text[0..e.text_len]);
        e.name_len = @min(name.len, e.name.len);
        @memcpy(e.name[0..e.name_len], name[0..e.name_len]);
        return e;
    }
};

/// Откуда в списке взялась строка: от этого зависит, как её подписать.
pub const Kind = enum {
    /// Петля на себя: только эта машина.
    loopback,
    /// Все интерфейсы разом.
    any,
    /// Один адрес одного интерфейса.
    iface,
};

/// Строка для выбора.
pub const Choice = struct {
    address: []const u8,
    /// Имя интерфейса или пояснение.
    note: []const u8,
    kind: Kind,
    family: Family,

    /// Как показать в списке: адрес и через тире пояснение.
    pub fn write(self: Choice, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s} — {s}", .{ self.address, self.note }) catch self.address;
    }
};

/// Сколько строк бывает: четыре постоянных и по одной на адрес.
pub const max_choices = max_entries + 4;

/// Составить список для выбора.
///
/// Порядок — по тому, что выбирают чаще: сперва «только эта машина» и
/// «все интерфейсы» (IPv4), потом адреса интерфейсов, IPv4 раньше IPv6,
/// и в конце те же две строки для IPv6. Петли из найденного выкидываются:
/// они уже есть постоянными строками, а дважды один адрес путает.
pub fn choices(out: *[max_choices]Choice, found: []const Entry) []Choice {
    var n: usize = 0;
    out[n] = .{ .address = "127.0.0.1", .note = "только эта машина", .kind = .loopback, .family = .ip4 };
    n += 1;
    out[n] = .{ .address = "0.0.0.0", .note = "все интерфейсы этой машины", .kind = .any, .family = .ip4 };
    n += 1;
    for ([_]Family{ .ip4, .ip6 }) |family| {
        // Два прохода: сперва провод и Wi-Fi, потом остальное.
        for ([_]bool{ true, false }) |wired| for (found) |*e| {
            if (e.family != family or e.physical != wired) continue;
            const scope = listen.scopeOf(e.address()) catch continue;
            if (scope != .specific) continue;
            if (n >= out.len - 2) break;
            // Один адрес на двух интерфейсах бывает у виртуальных сетей;
            // второй раз его не показываем.
            var seen = false;
            for (out[0..n]) |prev| {
                if (std.mem.eql(u8, prev.address, e.address())) seen = true;
            }
            if (seen) continue;
            out[n] = .{ .address = e.address(), .note = e.ifaceName(), .kind = .iface, .family = family };
            n += 1;
        };
    }
    out[n] = .{ .address = "::1", .note = "только эта машина, IPv6", .kind = .loopback, .family = .ip6 };
    n += 1;
    out[n] = .{ .address = "::", .note = "все интерфейсы, IPv6", .kind = .any, .family = .ip6 };
    n += 1;
    return out[0..n];
}

/// По какому адресу до нас достучаться снаружи, если слушаем «на всех».
///
/// «0.0.0.0:15599» в углу окна ничего не говорит человеку на другой машине:
/// ему нужен адрес, который он наберёт. Берём первый адрес интерфейса
/// той же семьи. Для конкретного адреса и петли ответ — сам адрес; если
/// интерфейсов нет — тоже сам адрес: врать нечем.
pub fn reachable(text: []const u8, found: []const Entry) []const u8 {
    const scope = listen.scopeOf(text) catch return text;
    if (scope != .any) return text;
    const want: Family = if (std.mem.indexOfScalar(u8, text, ':') != null) .ip6 else .ip4;
    for ([_]bool{ true, false }) |wired| for (found) |*e| {
        if (e.family != want or e.physical != wired) continue;
        const s = listen.scopeOf(e.address()) catch continue;
        if (s == .specific) return e.address();
    };
    return text;
}

// Записи `iphlpapi.h` translate-c отдаёт непрозрачными: в них безымянные
// объединения с битовыми полями. Ниже — те же записи с документированной
// раскладкой (только поля до нужных нам), где объединение «выравнивание
// или длина и номер» записано одним `u64`, а «флаги или биты» — одним
// `u32`. Смещения считает компилятор из типов полей, не мы.

/// `IP_ADAPTER_UNICAST_ADDRESS_LH`, начало.
const Unicast = extern struct {
    alignment: u64,
    next: ?*Unicast,
    /// `SOCKET_ADDRESS`: указатель и длина.
    sockaddr: ?*const Sockaddr,
    sockaddr_len: c_int,
};

/// `IP_ADAPTER_ADDRESSES_LH`, начало: до `OperStatus` включительно.
const Adapter = extern struct {
    alignment: u64,
    next: ?*Adapter,
    adapter_name: ?[*:0]u8,
    first_unicast: ?*Unicast,
    first_anycast: ?*anyopaque,
    first_multicast: ?*anyopaque,
    first_dns: ?*anyopaque,
    dns_suffix: ?[*:0]u16,
    description: ?[*:0]u16,
    friendly_name: ?[*:0]u16,
    physical_address: [8]u8,
    physical_address_len: u32,
    flags: u32,
    mtu: u32,
    if_type: u32,
    oper_status: u32,
};

/// `IF_TYPE_ETHERNET_CSMACD` и `IF_TYPE_IEEE80211`: провод и Wi-Fi.
const if_type_ethernet: u32 = 6;
const if_type_wifi: u32 = 71;

/// Общая голова любого `sockaddr`: семейство.
const Sockaddr = extern struct { family: u16 };
/// `sockaddr_in`: семейство, порт, четыре байта адреса, добивка.
const SockaddrIn = extern struct { family: u16, port: u16, addr: [4]u8, zero: [8]u8 };
/// `sockaddr_in6`: семейство, порт, поток, шестнадцать байт адреса, зона.
const SockaddrIn6 = extern struct { family: u16, port: u16, flow: u32, addr: [16]u8, scope: u32 };

const if_oper_status_up: u32 = 1;

extern "iphlpapi" fn GetAdaptersAddresses(
    family: c.ULONG,
    flags: c.ULONG,
    reserved: ?*anyopaque,
    addresses: ?*Adapter,
    size: *c.ULONG,
) callconv(.winapi) c.ULONG;

/// Спросить у Windows адреса интерфейсов, которые сейчас подняты.
///
/// Только те, что в работе (`IfOperStatusUp`): выключенный адаптер слушать
/// не выйдет, а показывать его — обещать то, чего нет. Адреса IPv6 вида
/// `fe80::` пропускаем: без номера зоны они не разбираются и не слушаются.
pub fn list(out: *[max_entries]Entry) []Entry {
    if (builtin.os.tag != .windows) return out[0..0];

    var buf: [64 * 1024]u8 align(8) = undefined;
    var size: c.ULONG = buf.len;
    const flags: c.ULONG = c.GAA_FLAG_SKIP_ANYCAST | c.GAA_FLAG_SKIP_MULTICAST | c.GAA_FLAG_SKIP_DNS_SERVER;
    const rc = GetAdaptersAddresses(c.AF_UNSPEC, flags, null, @ptrCast(@alignCast(&buf)), &size);
    if (rc != c.ERROR_SUCCESS) return out[0..0];

    var n: usize = 0;
    var adapter: ?*Adapter = @ptrCast(@alignCast(&buf));
    while (adapter) |a| : (adapter = a.next) {
        if (a.oper_status != if_oper_status_up) continue;
        // Имя — в UTF-16 от Windows; в списке оно нужно нашими буквами.
        var name_buf: [max_name]u8 = undefined;
        var name_len: usize = 0;
        if (a.friendly_name) |wide| {
            name_len = std.unicode.utf16LeToUtf8(&name_buf, std.mem.span(wide)) catch 0;
        }
        var uni: ?*Unicast = a.first_unicast;
        while (uni) |u| : (uni = u.next) {
            if (n >= out.len) return out[0..n];
            const sa = u.sockaddr orelse continue;
            var text: [listen.max_text]u8 = undefined;
            var w = std.Io.Writer.fixed(&text);
            const family: Family = switch (sa.family) {
                c.AF_INET => blk: {
                    const in4: *const SockaddrIn = @ptrCast(@alignCast(sa));
                    const b = in4.addr;
                    w.print("{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }) catch continue;
                    break :blk .ip4;
                },
                c.AF_INET6 => blk: {
                    const in6: *const SockaddrIn6 = @ptrCast(@alignCast(sa));
                    const b = in6.addr;
                    // fe80::/10 — только внутри звена, без зоны не годится.
                    if (b[0] == 0xfe and (b[1] & 0xc0) == 0x80) continue;
                    const addr = std.Io.net.Ip6Address{ .bytes = b, .port = 0 };
                    addr.format(&w) catch continue;
                    break :blk .ip6;
                },
                else => continue,
            };
            const written = w.buffered();
            // IPv6 пишется с портом в скобках — скобки и «:0» убираем.
            const plain = if (family == .ip6 and written.len > 3 and written[0] == '[')
                written[1 .. std.mem.lastIndexOfScalar(u8, written, ']') orelse written.len]
            else
                written;
            if (!listen.valid(plain)) continue;
            out[n] = Entry.make(plain, name_buf[0..name_len], family);
            // Hyper-V называет свой коммутатор «Ethernet» по типу — но
            // и он, и VPN у Windows идут тем же типом 6 или своим. Лучшего
            // признака у нас нет; вперёд идёт то, что Windows зовёт
            // проводом или Wi-Fi.
            out[n].physical = a.if_type == if_type_ethernet or a.if_type == if_type_wifi;
            n += 1;
        }
    }
    return out[0..n];
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;

fn physical(text: []const u8, name: []const u8, family: Family) Entry {
    var e = Entry.make(text, name, family);
    e.physical = true;
    return e;
}

fn fake() [5]Entry {
    return .{
        // VPN первым — как его и отдаёт Windows; в списке он всё равно
        // должен оказаться после провода.
        Entry.make("10.8.0.2", "VPN", .ip4),
        physical("192.168.1.5", "Ethernet", .ip4),
        Entry.make("127.0.0.1", "Loopback", .ip4),
        physical("2001:db8::7", "Ethernet", .ip6),
        Entry.make("192.168.1.5", "vEthernet", .ip4),
    };
}

test "провод и Wi-Fi идут раньше VPN, а наружу называется провод" {
    const found = fake();
    var out: [max_choices]Choice = undefined;
    const got = choices(&out, &found);
    try testing.expectEqualStrings("192.168.1.5", got[2].address);
    try testing.expectEqualStrings("10.8.0.2", got[3].address);
    try testing.expectEqualStrings("192.168.1.5", reachable("0.0.0.0", &found));
    // Провода нет — годится и VPN: лучше такой адрес, чем «0.0.0.0».
    const only_vpn = [_]Entry{Entry.make("10.8.0.2", "VPN", .ip4)};
    try testing.expectEqualStrings("10.8.0.2", reachable("0.0.0.0", &only_vpn));
}

test "список начинается с петли и «всех», потом адреса, IPv6 в конце" {
    var out: [max_choices]Choice = undefined;
    const found = fake();
    const got = choices(&out, &found);
    // 2 постоянных + 3 адреса (192.168.1.5 один раз, петля выкинута) + 2 IPv6.
    try testing.expectEqual(@as(usize, 7), got.len);
    try testing.expectEqualStrings("127.0.0.1", got[0].address);
    try testing.expectEqual(Kind.loopback, got[0].kind);
    try testing.expectEqualStrings("0.0.0.0", got[1].address);
    try testing.expectEqual(Kind.any, got[1].kind);
    try testing.expectEqualStrings("192.168.1.5", got[2].address);
    try testing.expectEqualStrings("Ethernet", got[2].note);
    try testing.expectEqualStrings("10.8.0.2", got[3].address);
    try testing.expectEqualStrings("2001:db8::7", got[4].address);
    try testing.expectEqual(Family.ip6, got[4].family);
    try testing.expectEqualStrings("::1", got[5].address);
    try testing.expectEqualStrings("::", got[6].address);
}

test "без интерфейсов остаются четыре постоянных строки" {
    var out: [max_choices]Choice = undefined;
    const got = choices(&out, &.{});
    try testing.expectEqual(@as(usize, 4), got.len);
    // Каждая постоянная строка — годный адрес: выбрать можно всё, что видно.
    for (got) |ch| try testing.expect(listen.valid(ch.address));
}

test "один адрес на двух интерфейсах показывается один раз" {
    var out: [max_choices]Choice = undefined;
    const found = fake();
    const got = choices(&out, &found);
    var times: usize = 0;
    for (got) |ch| {
        if (std.mem.eql(u8, ch.address, "192.168.1.5")) times += 1;
    }
    try testing.expectEqual(@as(usize, 1), times);
}

test "строка списка — адрес и пояснение через тире" {
    var out: [max_choices]Choice = undefined;
    const got = choices(&out, &.{});
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("127.0.0.1 — только эта машина", got[0].write(&buf));
}

test "при «всех» наружу называем первый адрес той же семьи" {
    const found = fake();
    try testing.expectEqualStrings("192.168.1.5", reachable("0.0.0.0", &found));
    try testing.expectEqualStrings("2001:db8::7", reachable("::", &found));
    // Конкретный адрес и петля — сами себе ответ.
    try testing.expectEqualStrings("10.8.0.2", reachable("10.8.0.2", &found));
    try testing.expectEqualStrings("127.0.0.1", reachable("127.0.0.1", &found));
    // Интерфейсов нет — врать нечем: остаётся как есть.
    try testing.expectEqualStrings("0.0.0.0", reachable("0.0.0.0", &.{}));
    // Чепуха остаётся чепухой, а не падает.
    try testing.expectEqualStrings("чепуха", reachable("чепуха", &found));
}

test "список не переполняется, когда адресов больше места" {
    var many: [max_entries + 8]Entry = undefined;
    for (&many, 0..) |*e, i| {
        var text: [24]u8 = undefined;
        const t = std.fmt.bufPrint(&text, "10.0.{d}.{d}", .{ i / 256, i % 256 }) catch unreachable;
        e.* = Entry.make(t, "x", .ip4);
    }
    var out: [max_choices]Choice = undefined;
    const got = choices(&out, &many);
    try testing.expect(got.len <= max_choices);
    // Две строки IPv6 в конце остаются на месте при любом наплыве.
    try testing.expectEqualStrings("::", got[got.len - 1].address);
}

test "на этой машине список читается и всё в нём — годные адреса" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var out: [max_entries]Entry = undefined;
    const got = list(&out);
    for (got) |*e| {
        try testing.expect(listen.valid(e.address()));
        // Петлю Windows тоже отдаёт — это не ошибка, её отсеивает choices.
        try testing.expect(e.address().len > 0);
    }
}
