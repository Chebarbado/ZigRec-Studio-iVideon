//! Уголок MCP: состояние сервера видно всегда и занимает угол, а не ряд.
//!
//! Задача #64. Про сервер MCP смотрят раз в день, а места он занимал целый
//! ряд посреди окна — рядом с тем, чем пользуются каждую минуту. Уголок
//! в правом нижнем углу говорит то же самое тремя элементами: точка, надпись
//! и кнопка.
//!
//! Что показывать при каком состоянии — чистый счёт, поэтому живёт отдельно
//! от Windows и проверяется тестами. Ошибка здесь не роняет программу:
//! она врёт человеку про то, открыт ли порт, — а это как раз то, про что
//! врать нельзя.
const std = @import("std");
const control = @import("control.zig");
const listen = @import("listen.zig");
const lang = @import("../lang.zig");

/// Цвет точки. Записан как BGR: так его ждёт Windows.
pub const Color = struct {
    pub const off: u32 = 0x00A8A8A8;
    pub const listening: u32 = 0x0040C040;
    pub const failed: u32 = 0x004040E0;
    /// Слушает, но виден из сети — про это цветом же и предупреждаем.
    pub const exposed: u32 = 0x0020A0F0;
};

/// Что показывать в уголке.
pub const Look = struct {
    dot: u32 = Color.off,
    /// Короткая надпись рядом с точкой.
    text: []const u8 = "MCP off",
    /// Подпись на кнопке.
    button: []const u8 = "▶",
    /// Виден ли порт из сети — от этого зависит, предупреждать ли.
    exposed: bool = false,
};

/// Из чего складывается вид уголка.
pub const Facts = struct {
    state: control.State = .off,
    address: []const u8 = listen.default_text,
    /// По какому адресу до нас достучаться снаружи, если слушаем «на всех»
    /// (#86). Пусто или равно адресу — показываем сам адрес.
    reach: []const u8 = "",
    port: u16 = 15599,
    /// Поднимается или уже поднят.
    running: bool = false,
    /// Сколько просьб обслужено.
    served: u64 = 0,
    /// Почему не завёлся — словами, если известно.
    why: []const u8 = "",
};

/// Собрать вид уголка.
///
/// Надпись короткая нарочно: угол окна — не место для объяснений. Но она
/// обязана нести то, ради чего на неё смотрят: где слушаем, сколько раз
/// к нам обратились и почему не вышло.
pub fn look(buf: []u8, f: Facts) Look {
    return switch (f.state) {
        .listening => blk: {
            const out_to_net = listen.opensToNetwork(f.address);
            var where_buf: [listen.max_text + 8]u8 = undefined;
            // «0.0.0.0:15599» человеку на другой машине не набрать: вместо
            // него — адрес интерфейса, и стрелка перед ним говорит, что это
            // не то, что задано, а то, куда стучаться.
            const shown = if (f.reach.len > 0 and !std.mem.eql(u8, f.reach, f.address)) f.reach else f.address;
            const arrow: []const u8 = if (shown.ptr != f.address.ptr) "→" else "";
            var addr_buf: [listen.max_text + 8]u8 = undefined;
            const where = std.fmt.bufPrint(&where_buf, "{s}{s}", .{ arrow, listen.write(&addr_buf, shown, f.port) }) catch "";
            // Число просьб показываем, только когда они были: ноль
            // не сообщает ничего, а место занимает.
            const text = if (f.served > 0)
                std.fmt.bufPrint(buf, "MCP {s} · {d}", .{ where, f.served }) catch lang.t("MCP слушает")
            else
                std.fmt.bufPrint(buf, "MCP {s}", .{where}) catch lang.t("MCP слушает");
            break :blk .{
                .dot = if (out_to_net) Color.exposed else Color.listening,
                .text = text,
                .button = "■",
                .exposed = out_to_net,
            };
        },
        .failed => .{
            .dot = Color.failed,
            .text = if (f.why.len > 0)
                lang.print(buf, "MCP не завёлся: {s}", .{f.why}) catch lang.t("MCP не завёлся")
            else
                lang.t("MCP не завёлся"),
            .button = "▶",
        },
        .off => .{
            .dot = Color.off,
            // Пока поднимается — говорим об этом: «выключен» в этот момент
            // было бы неправдой.
            .text = if (f.running) lang.t("MCP поднимается") else "MCP off",
            .button = if (f.running) "■" else "▶",
        },
    };
}

/// Можно ли щёлкнуть по надписи в уголке, чтобы попасть в настройки.
///
/// Задача #82. Адрес показан там, куда смотрят, когда что-то не сходится:
/// «а на каком порту он слушает?». Следующее действие после этого взгляда —
/// поменять порт, и путь к нему не должен лежать через другой конец окна.
///
/// Щёлкать есть по чему, только пока сервер слушает: тогда в надписи адрес.
/// «MCP off» и «не завёлся» — не адреса, и рука над ними обещала бы то,
/// чего нет.
pub fn addressClickable(f: Facts) bool {
    return f.state == .listening;
}

/// Короткая справка по кнопке «?».
pub const help_text =
    "Сервер MCP даёт Claude Code управлять записью: начать, остановить, " ++
    "узнать состояние, перечислить мониторы.\r\n\r\n" ++
    "Пока сервер выключен, порт закрыт и наружу ничего не смотрит. " ++
    "Включается только этой кнопкой: программа, молча открывающая порт, — " ++
    "не то, что стоит ставить на рабочую машину.\r\n\r\n" ++
    "Адрес и порт меняются в настройках. Умолчание 127.0.0.1 пускает " ++
    "только эту машину; 0.0.0.0 откроет порт всей сети.";

// ---------------------------------------------------------------- тесты

const testing = std.testing;

test "выключенный сервер говорит, что он выключен" {
    var buf: [64]u8 = undefined;
    const got = look(&buf, .{ .state = .off });
    try testing.expectEqualStrings("MCP off", got.text);
    try testing.expectEqual(Color.off, got.dot);
    try testing.expectEqualStrings("▶", got.button);
    try testing.expect(!got.exposed);
}

test "работающий сервер показывает настоящий адрес" {
    var buf: [64]u8 = undefined;
    const got = look(&buf, .{ .state = .listening, .running = true });
    try testing.expectEqualStrings("MCP 127.0.0.1:15599", got.text);
    try testing.expectEqual(Color.listening, got.dot);
    // Пока работает, кнопка предлагает остановить.
    try testing.expectEqualStrings("■", got.button);
}

test "IPv6 показывается в скобках, как принято" {
    var buf: [64]u8 = undefined;
    const got = look(&buf, .{ .state = .listening, .address = "::1", .running = true });
    try testing.expectEqualStrings("MCP [::1]:15599", got.text);
}

test "открытый наружу порт отличается цветом" {
    // Про это врать нельзя: человек должен видеть, что порт виден из сети,
    // не вчитываясь в надпись.
    var buf: [64]u8 = undefined;
    const open = look(&buf, .{ .state = .listening, .address = "0.0.0.0", .running = true });
    try testing.expect(open.exposed);
    try testing.expectEqual(Color.exposed, open.dot);

    var buf2: [64]u8 = undefined;
    const closed = look(&buf2, .{ .state = .listening, .running = true });
    try testing.expect(!closed.exposed);
    try testing.expect(closed.dot != open.dot);
}

test "не завёлся — красным, словами и с причиной" {
    var buf: [64]u8 = undefined;
    const plain = look(&buf, .{ .state = .failed });
    try testing.expectEqual(Color.failed, plain.dot);
    try testing.expect(std.mem.indexOf(u8, plain.text, "не завёлся") != null);

    // Причина важнее краткости: без неё человеку нечего делать.
    var buf2: [64]u8 = undefined;
    const why = look(&buf2, .{ .state = .failed, .why = "порт занят" });
    try testing.expect(std.mem.indexOf(u8, why.text, "порт занят") != null);
}

test "число просьб показывается, только когда они были" {
    var buf: [64]u8 = undefined;
    const quiet = look(&buf, .{ .state = .listening, .running = true });
    try testing.expectEqualStrings("MCP 127.0.0.1:15599", quiet.text);

    var buf2: [64]u8 = undefined;
    const busy = look(&buf2, .{ .state = .listening, .running = true, .served = 12 });
    try testing.expectEqualStrings("MCP 127.0.0.1:15599 · 12", busy.text);
}

test "пока поднимается — не говорим, что выключен" {
    var buf: [64]u8 = undefined;
    const got = look(&buf, .{ .state = .off, .running = true });
    try testing.expect(!std.mem.eql(u8, got.text, "MCP off"));
    try testing.expectEqualStrings("■", got.button);
}

test "у каждого состояния есть надпись и подпись на кнопке" {
    var buf: [64]u8 = undefined;
    for ([_]control.State{ .off, .listening, .failed }) |state| {
        const got = look(&buf, .{ .state = state });
        try testing.expect(got.text.len > 0);
        try testing.expect(got.button.len > 0);
    }
}

test "справка говорит и про закрытый порт, и про 0.0.0.0" {
    try testing.expect(std.mem.indexOf(u8, help_text, "порт закрыт") != null);
    try testing.expect(std.mem.indexOf(u8, help_text, "0.0.0.0") != null);
}

test "по адресу можно щёлкнуть, только пока сервер слушает" {
    // «MCP off» — не адрес: рука над ним обещала бы то, чего нет.
    try std.testing.expect(addressClickable(.{ .state = .listening }));
    try std.testing.expect(!addressClickable(.{ .state = .off }));
    try std.testing.expect(!addressClickable(.{ .state = .off, .running = true }));
    try std.testing.expect(!addressClickable(.{ .state = .failed, .why = "порт занят" }));
}

test "при «всех» в углу — адрес, по которому стучаться, со стрелкой" {
    var buf: [96]u8 = undefined;
    const got = look(&buf, .{ .state = .listening, .address = "0.0.0.0", .reach = "192.168.1.5", .port = 15599, .running = true });
    try testing.expectEqualStrings("MCP →192.168.1.5:15599", got.text);
    // Красный «виден из сети» при этом остаётся: слушаем-то на всех.
    try testing.expect(got.exposed);
    // Петля: стрелки нет, адрес свой.
    var buf2: [96]u8 = undefined;
    const home = look(&buf2, .{ .state = .listening, .address = "127.0.0.1", .reach = "127.0.0.1", .port = 15599, .running = true });
    try testing.expectEqualStrings("MCP 127.0.0.1:15599", home.text);
    // Интерфейсов не нашлось — показываем как есть, без стрелки.
    var buf3: [96]u8 = undefined;
    const bare = look(&buf3, .{ .state = .listening, .address = "0.0.0.0", .port = 15599, .running = true });
    try testing.expectEqualStrings("MCP 0.0.0.0:15599", bare.text);
}

/// Самая длинная надпись угла: по ней стенд меряет, влезает ли она.
pub const longest_text = "MCP →255.255.255.255:65535 · 9999";

test "самая длинная надпись угла и вправду самая длинная из возможных" {
    var buf: [96]u8 = undefined;
    const got = look(&buf, .{ .state = .listening, .address = "0.0.0.0", .reach = "255.255.255.255", .port = 65535, .served = 9999, .running = true });
    try testing.expectEqualStrings(longest_text, got.text);
}
