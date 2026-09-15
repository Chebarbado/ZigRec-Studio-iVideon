//! Местный порт, через который окном можно управлять снаружи.
//!
//! Задача #41. Сюда стучится мост `zigrec mcp`, а через него — Claude Code.
//! Разговор идёт теми же строками JSON-RPC, что и по протоколу MCP: мост
//! получается почти трубой, и вся смысловая часть остаётся в одном месте.
//!
//! **Сервер не поднимается сам.** Слушать порт программа начинает только
//! тогда, когда человек нажал кнопку. Программа, которая открывает порт
//! молча, — это не то, что стоит ставить на рабочую машину.
//!
//! По умолчанию слушаем `127.0.0.1`: наружу порт не выходит сам собой.
//! Адрес можно сменить — вплоть до `0.0.0.0` и IPv6, — но об этом окно
//! говорит прямо: открытый наружу порт человек должен увидеть, а не узнать
//! потом и от кого-то другого.
//!
//! Главное решение здесь — **исполняет всё поток окна, а не поток сервера**.
//! Поток сервера только принимает соединение, разбирает строку и передаёт
//! просьбу окну через `SendMessage`, который ждёт ответа. Иначе запись
//! запускалась бы из одного потока, а останавливалась из другого, и рано
//! или поздно они встретились бы на середине.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const mcp = @import("mcp.zig");
const listen = @import("listen.zig");
const c = win32.c;
const net = std.Io.net;

/// Порт по умолчанию. Выбран из частного диапазона, рядом с теми, что уже
/// заняты соседними поделками в этом хозяйстве.
pub const default_port: u16 = 15599;

/// Сколько разговоров ведём одновременно. Больше и не нужно: собеседников
/// у нас один-два, а без предела забытые соединения копились бы молча.
pub const max_talks: u32 = 8;

/// Сообщение окну: «исполни просьбу». В `lParam` лежит указатель на `Call`.
pub const wm_control = c.WM_APP + 2;

/// Просьба и место под ответ. Живёт на стеке потока сервера всё время,
/// пока `SendMessage` не вернётся, — поэтому указатель на неё безопасен.
pub const Call = struct {
    request: mcp.Request,
    /// Куда окно кладёт ответ словами.
    out: []u8,
    /// Сколько букв положило.
    written: usize = 0,
    /// Просьба не исполнилась.
    failed: bool = false,

    pub fn answer(self: *Call) []const u8 {
        return self.out[0..self.written];
    }

    /// Записать ответ. Не влезло — обрезаем: лучше короткий ответ,
    /// чем ни одного.
    pub fn say(self: *Call, text: []const u8) void {
        const n = @min(text.len, self.out.len);
        @memcpy(self.out[0..n], text[0..n]);
        self.written = n;
    }
};

pub const Error = error{
    /// Порт занят: чаще всего второй копией той же программы.
    PortBusy,
    /// Поток не завёлся.
    ThreadFailed,
    Unsupported,
    /// Адрес не разобрался.
    BadAddress,
};

/// Состояние сервера — то, что показывает лампочка.
pub const State = enum {
    off,
    listening,
    failed,
};

pub const Server = struct {
    port: u16 = default_port,
    /// На каком адресе слушаем.
    address: [listen.max_text]u8 = @splat(0),
    address_len: usize = 0,
    hwnd: c.HWND = null,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    listening: std.atomic.Value(bool) = .init(false),
    /// Что пошло не так. Показывается словами, а не кодом.
    failure: ?anyerror = null,
    /// Сколько просьб исполнено. Видно, что сервер не просто открыт,
    /// а им действительно пользуются.
    served: std.atomic.Value(u64) = .init(0),
    /// Сколько разговоров идёт прямо сейчас.
    talking: std.atomic.Value(u32) = .init(0),

    pub fn state(self: *const Server) State {
        if (self.listening.load(.acquire)) return .listening;
        if (self.failure != null) return .failed;
        return .off;
    }

    /// Адрес, на котором слушаем. Пусто — значит умолчание.
    pub fn listenAddress(self: *const Server) []const u8 {
        if (self.address_len == 0) return listen.default_text;
        return self.address[0..self.address_len];
    }

    /// Адрес с портом, как это принято показывать.
    pub fn where(self: *const Server, buf: []u8) []const u8 {
        return listen.write(buf, self.listenAddress(), self.port);
    }

    pub fn start(self: *Server, hwnd: c.HWND, port: u16) Error!void {
        return self.startAt(hwnd, listen.default_text, port);
    }

    pub fn startAt(self: *Server, hwnd: c.HWND, address: []const u8, port: u16) Error!void {
        if (builtin.os.tag != .windows) return Error.Unsupported;
        // Негодный адрес не берём: слушать по нему нечего, а молча
        // подставить свой значило бы соврать про то, где мы слушаем.
        if (!listen.valid(address)) return Error.BadAddress;
        const n = @min(address.len, self.address.len);
        @memcpy(self.address[0..n], address[0..n]);
        self.address_len = n;
        if (self.running.load(.acquire)) return;
        self.hwnd = hwnd;
        self.port = port;
        self.failure = null;
        self.served.store(0, .monotonic);
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
            self.running.store(false, .release);
            return Error.ThreadFailed;
        };
    }

    pub fn stop(self: *Server) void {
        if (!self.running.load(.acquire)) return;
        self.running.store(false, .release);
        // Приём соединений ждёт клиента и сам по себе не проснётся.
        // Будим его собственным подключением — это надёжнее, чем закрывать
        // сокет из чужого потока в тот момент, когда он в нём же и ждёт.
        knock(self.listenAddress(), self.port);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.listening.store(false, .release);
    }

    pub fn isRunning(self: *const Server) bool {
        return self.running.load(.acquire);
    }

    fn run(self: *Server) void {
        self.serve() catch |err| {
            self.failure = err;
        };
        self.listening.store(false, .release);
        self.running.store(false, .release);
    }

    fn serve(self: *Server) !void {
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var addr = listen.parse(self.listenAddress(), self.port) catch return Error.BadAddress;
        addr.setPort(self.port);
        var server = addr.listen(io, .{ .reuse_address = true }) catch {
            return Error.PortBusy;
        };
        defer server.deinit(io);
        self.listening.store(true, .release);

        while (self.running.load(.acquire)) {
            const stream = server.accept(io) catch break;
            if (!self.running.load(.acquire)) {
                stream.close(io);
                break;
            }
            // Разговор уходит в свой поток. Пока он шёл в этом, один клиент,
            // подключившийся и замолчавший, держал всех: приём соединений
            // до него просто не доходил. Поймано на себе.
            if (self.talking.load(.acquire) >= max_talks) {
                stream.close(io);
                continue;
            }
            const conn = std.heap.page_allocator.create(Conn) catch {
                stream.close(io);
                continue;
            };
            conn.* = .{ .server = self, .stream = stream };
            const t = std.Thread.spawn(.{}, Conn.run, .{conn}) catch {
                std.heap.page_allocator.destroy(conn);
                stream.close(io);
                continue;
            };
            // Поток живёт сам по себе: ждать его здесь значило бы вернуть
            // ту же беду, от которой уходим.
            t.detach();
            _ = self.talking.fetchAdd(1, .monotonic);
        }

        // Ждём, пока разговоры закончатся сами: их потоки держат сокеты,
        // и закрывать порт под ними нельзя.
        var waited: u32 = 0;
        while (self.talking.load(.acquire) > 0 and waited < 50) : (waited += 1) {
            c.Sleep(20);
        }
    }

    /// Один разговор в своём потоке.
    const Conn = struct {
        server: *Server,
        stream: net.Stream,

        fn run(self: *Conn) void {
            var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
            defer threaded.deinit();
            const io = threaded.io();

            self.server.talk(io, self.stream) catch {};
            self.stream.close(io);
            _ = self.server.talking.fetchSub(1, .monotonic);
            std.heap.page_allocator.destroy(self);
        }
    };

    /// Один разговор: строка запроса — строка ответа, пока клиент не ушёл.
    fn talk(self: *Server, io: std.Io, stream: net.Stream) !void {
        var in_buf: [16 * 1024]u8 = undefined;
        var out_buf: [64 * 1024]u8 = undefined;
        var reader = stream.reader(io, &in_buf);
        var writer = stream.writer(io, &out_buf);

        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();

        while (self.running.load(.acquire)) {
            // Именно `takeDelimiter`, а не `...Exclusive`: тот останавливается
            // перед переводом строки и оставляет его в потоке, и следующая
            // строка приходит пустой.
            const line = (reader.interface.takeDelimiter('\n') catch break) orelse break;
            if (line.len == 0) continue;
            _ = arena_state.reset(.retain_capacity);

            var session = mcp.parse(arena_state.allocator(), line);
            defer session.deinit();
            const got = session.result;

            if (got.fault) |fault| {
                try mcp.writeFault(&writer.interface, got.id, fault);
                try writer.interface.writeByte('\n');
                try writer.interface.flush();
                continue;
            }
            const request = got.request orelse continue;
            // Уведомление ответа не требует и не должно его получить:
            // лишний ответ строгий клиент считает ошибкой протокола.
            if (request == .initialized) continue;

            try self.answer(&writer.interface, got.id, request);
            try writer.interface.writeByte('\n');
            try writer.interface.flush();
            _ = self.served.fetchAdd(1, .monotonic);
        }
    }

    fn answer(self: *Server, w: *std.Io.Writer, id: ?mcp.Id, request: mcp.Request) !void {
        switch (request) {
            .initialize => return mcp.writeInitialize(w, id, @import("../version.zig").VERSION),
            .list_tools => return mcp.writeToolList(w, id),
            .initialized => return,
            else => {},
        }

        // Всё остальное умеет только окно: у него запись, настройки и экран.
        var text: [8 * 1024]u8 = undefined;
        var call = Call{ .request = request, .out = &text };
        _ = c.SendMessageW(self.hwnd, wm_control, 0, @bitCast(@intFromPtr(&call)));
        return mcp.writeToolText(w, id, call.answer(), call.failed);
    }
};

/// Постучаться в собственный порт, чтобы разбудить ожидание соединения.
/// Куда стучаться, чтобы разбудить своё же ожидание входящего.
///
/// По тому же адресу, что и слушаем, — иначе на IPv6 или на другом
/// сетевом имени стук уйдёт в пустоту, и сервер останется висеть
/// в ожидании до конца работы программы.
///
/// Исключение — «слушаем всех»: по такому адресу не соединяются,
/// он означает «любой мой», и стучаться надо в петлю на себя.
pub fn knockAddress(address: []const u8) []const u8 {
    const scope = listen.scopeOf(address) catch return "127.0.0.1";
    if (scope != .any) return address;
    // У «всех» две записи, и петля у каждой своя.
    return if (std.mem.indexOfScalar(u8, address, ':') != null) "::1" else "127.0.0.1";
}

fn knock(address: []const u8, port: u16) void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var addr = listen.parse(knockAddress(address), port) catch return;
    addr.setPort(port);
    const stream = addr.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch return;
    stream.close(io);
}

// ---------------------------------------------------------------- тесты

test "лампочка: выключен, слушает, не завёлся" {
    var s = Server{};
    try std.testing.expectEqual(State.off, s.state());

    s.failure = error.PortBusy;
    try std.testing.expectEqual(State.failed, s.state());

    // Слушает — сильнее прошлой беды: если поднялся, лампочка зелёная.
    s.listening.store(true, .release);
    try std.testing.expectEqual(State.listening, s.state());
}

test "ответ обрезается, а не выходит за буфер" {
    var small: [8]u8 = undefined;
    var call = Call{ .request = .status, .out = &small };
    call.say("это заведомо длиннее восьми байт");
    try std.testing.expectEqual(@as(usize, 8), call.answer().len);
}

test "короткий ответ помещается целиком" {
    var buf: [64]u8 = undefined;
    var call = Call{ .request = .status, .out = &buf };
    call.say("готов");
    try std.testing.expectEqualStrings("готов", call.answer());
    try std.testing.expect(!call.failed);
}

test "порт по умолчанию не из общеизвестных" {
    // Порты ниже 1024 требуют прав и заняты системой; наш — из частного
    // диапазона, и его не отберут.
    try std.testing.expect(default_port > 1024);
}

test "стучимся туда же, где слушаем" {
    // Иначе на IPv6 стук уйдёт в пустоту, и сервер останется висеть
    // в ожидании входящего до конца работы программы.
    try std.testing.expectEqualStrings("127.0.0.1", knockAddress("127.0.0.1"));
    try std.testing.expectEqualStrings("::1", knockAddress("::1"));
    try std.testing.expectEqualStrings("192.168.1.5", knockAddress("192.168.1.5"));
}

test "по «всем» не соединяются: стучимся в петлю той же семьи" {
    try std.testing.expectEqualStrings("127.0.0.1", knockAddress("0.0.0.0"));
    try std.testing.expectEqualStrings("::1", knockAddress("::"));
}

test "негодный адрес не мешает достучаться" {
    // Сервер по нему всё равно не поднялся бы, но и падать тут незачем.
    try std.testing.expectEqualStrings("127.0.0.1", knockAddress("чепуха"));
}

test "у нового сервера адрес — умолчание" {
    var s = Server{};
    try std.testing.expectEqualStrings(listen.default_text, s.listenAddress());
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("127.0.0.1:15599", s.where(&buf));
}
