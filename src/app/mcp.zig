//! Разговор по протоколу MCP: запрос строкой — ответ строкой.
//!
//! Задача #41. Смысл в том, чтобы записью экрана можно было управлять не
//! только руками, но и из Claude Code: «сними это окно», «останови», «какой
//! получился файл».
//!
//! **Здесь нет ввода-вывода.** Ни сокетов, ни файлов, ни потоков: на входе
//! строка запроса, на выходе строка ответа. Только так протокол можно
//! проверять тестами, а не «запустить и посмотреть» — а требование цели
//! именно такое. Всё, что умеет разговаривать с миром, живёт снаружи.
//!
//! Обмен идёт по JSON-RPC 2.0. Из всего протокола нам нужны три метода:
//! рукопожатие, список инструментов и вызов инструмента.
const std = @import("std");

/// Версия протокола, о которой договариваемся при рукопожатии.
pub const protocol_version = "2024-11-05";

pub const server_name = "zigrec";

/// Что попросили сделать. Разбор отделён от исполнения: разобрать просьбу
/// можно и проверить тестами, а исполнить её умеет только тот, у кого есть
/// экран и кодировщик.
pub const Request = union(enum) {
    /// Рукопожатие.
    initialize,
    /// Клиент сообщает, что готов. Ответа не требует.
    initialized,
    /// Какие есть инструменты.
    list_tools,
    /// Начать запись.
    start: Start,
    /// Остановить запись и отдать файл.
    stop,
    /// Идёт ли запись, сколько кадров и секунд.
    status,
    /// Какие есть мониторы.
    monitors,
    /// Какие есть окна.
    windows,

    pub const Start = struct {
        /// Что снимать: весь монитор, прямоугольник или окно по заголовку.
        monitor: ?u32 = null,
        area: ?[]const u8 = null,
        window: ?[]const u8 = null,
        sound: bool = false,
        fps: ?u32 = null,
    };
};

/// Разобранный запрос вместе с его номером: номер надо вернуть в ответе,
/// иначе клиент не поймёт, на что ему ответили.
pub const Parsed = struct {
    /// Номер запроса. `null` — уведомление, отвечать не нужно.
    id: ?Id = null,
    request: ?Request = null,
    /// Что не так с запросом, если он не разобрался.
    fault: ?Fault = null,
};

/// Номер запроса бывает и числом, и строкой — возвращаем его тем же, чем он
/// пришёл. Подменять число строкой нельзя: строгий клиент такого ответа
/// не признает своим.
pub const Id = union(enum) {
    number: i64,
    text: []const u8,
};

pub const Fault = enum {
    parse_error,
    invalid_request,
    method_not_found,
    invalid_params,

    pub fn code(self: Fault) i32 {
        return switch (self) {
            .parse_error => -32700,
            .invalid_request => -32600,
            .method_not_found => -32601,
            .invalid_params => -32602,
        };
    }

    /// Текст ошибки — словами и по-русски: его читает человек в журнале.
    pub fn message(self: Fault) []const u8 {
        return switch (self) {
            .parse_error => "запрос не разобрался: это не JSON",
            .invalid_request => "это не запрос JSON-RPC",
            .method_not_found => "нет такого метода",
            .invalid_params => "не хватает или не годятся параметры",
        };
    }
};

/// Разобранный запрос вместе с документом, внутрь которого он ссылается.
///
/// Владение здесь не формальность. Заголовок окна и строковый номер запроса —
/// это срезы внутрь разобранного JSON. Освободить документ и вернуть срезы
/// на него значит вернуть указатели в чужую память; поймано падением тестов.
pub const Session = struct {
    doc: ?std.json.Parsed(std.json.Value) = null,
    result: Parsed = .{},

    pub fn deinit(self: *Session) void {
        if (self.doc) |d| d.deinit();
        self.doc = null;
    }
};

/// Разобрать входящую строку. Полученное надо освободить: `defer s.deinit()`.
pub fn parse(allocator: std.mem.Allocator, line: []const u8) Session {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        return .{ .result = .{ .fault = .parse_error } };
    };
    return .{ .doc = parsed, .result = parseValue(parsed.value) };
}

fn parseValue(root: std.json.Value) Parsed {
    if (root != .object) return .{ .fault = .invalid_request };
    const obj = root.object;

    var out = Parsed{};
    if (obj.get("id")) |raw| {
        out.id = switch (raw) {
            .integer => |n| Id{ .number = n },
            .string => |s| Id{ .text = s },
            else => null,
        };
    }

    const method_value = obj.get("method") orelse return .{ .id = out.id, .fault = .invalid_request };
    if (method_value != .string) return .{ .id = out.id, .fault = .invalid_request };
    const method = method_value.string;

    if (std.mem.eql(u8, method, "initialize")) {
        out.request = .initialize;
        return out;
    }
    if (std.mem.eql(u8, method, "notifications/initialized")) {
        out.request = .initialized;
        return out;
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        out.request = .list_tools;
        return out;
    }
    if (!std.mem.eql(u8, method, "tools/call")) {
        return .{ .id = out.id, .fault = .method_not_found };
    }

    const params = obj.get("params") orelse return .{ .id = out.id, .fault = .invalid_params };
    if (params != .object) return .{ .id = out.id, .fault = .invalid_params };
    const name_value = params.object.get("name") orelse return .{ .id = out.id, .fault = .invalid_params };
    if (name_value != .string) return .{ .id = out.id, .fault = .invalid_params };
    const name = name_value.string;

    const args: ?std.json.ObjectMap = blk: {
        const raw = params.object.get("arguments") orelse break :blk null;
        if (raw != .object) break :blk null;
        break :blk raw.object;
    };

    if (std.mem.eql(u8, name, tool_start)) {
        var start = Request.Start{};
        if (args) |a| {
            if (a.get("monitor")) |v| if (v == .integer and v.integer >= 0) {
                start.monitor = @intCast(v.integer);
            };
            if (a.get("area")) |v| if (v == .string) {
                start.area = v.string;
            };
            if (a.get("window")) |v| if (v == .string) {
                start.window = v.string;
            };
            if (a.get("sound")) |v| if (v == .bool) {
                start.sound = v.bool;
            };
            if (a.get("fps")) |v| if (v == .integer and v.integer > 0) {
                start.fps = @intCast(v.integer);
            };
        }
        // Источник должен быть один. Два сразу — это не «оба», это неясность,
        // и лучше сказать об этом сразу, чем снять не то.
        var sources: u8 = 0;
        if (start.area != null) sources += 1;
        if (start.window != null) sources += 1;
        if (sources > 1) return .{ .id = out.id, .fault = .invalid_params };
        out.request = .{ .start = start };
        return out;
    }
    if (std.mem.eql(u8, name, tool_stop)) {
        out.request = .stop;
        return out;
    }
    if (std.mem.eql(u8, name, tool_status)) {
        out.request = .status;
        return out;
    }
    if (std.mem.eql(u8, name, tool_monitors)) {
        out.request = .monitors;
        return out;
    }
    if (std.mem.eql(u8, name, tool_windows)) {
        out.request = .windows;
        return out;
    }
    return .{ .id = out.id, .fault = .method_not_found };
}

pub const tool_start = "start_recording";
pub const tool_stop = "stop_recording";
pub const tool_status = "recording_status";
pub const tool_monitors = "list_monitors";
pub const tool_windows = "list_windows";

/// Описание инструментов для клиента.
///
/// Описания на русском и по-человечески: их читает не программа, а модель,
/// и от того, насколько понятно написано, зависит, вызовет она нужное или нет.
pub const tools_json =
    \\[
    \\{"name":"start_recording",
    \\ "description":"Начать запись экрана в mp4. Записывает то самое окно Zig-Rec Studio, которое видит человек. Без параметров снимает весь экран.",
    \\ "inputSchema":{"type":"object","properties":{
    \\   "monitor":{"type":"integer","description":"Номер монитора; 0 — основной"},
    \\   "area":{"type":"string","description":"Прямоугольник рабочего стола: x,y,ширина,высота"},
    \\   "window":{"type":"string","description":"Часть заголовка окна; область поедет за окном"},
    \\   "sound":{"type":"boolean","description":"Писать ли звук с микрофона"},
    \\   "fps":{"type":"integer","description":"Кадров в секунду"}}}},
    \\{"name":"stop_recording",
    \\ "description":"Остановить запись и вернуть путь к готовому файлу mp4.",
    \\ "inputSchema":{"type":"object","properties":{}}},
    \\{"name":"recording_status",
    \\ "description":"Идёт ли запись: состояние, сколько кадров, сколько секунд, куда пишется.",
    \\ "inputSchema":{"type":"object","properties":{}}},
    \\{"name":"list_monitors",
    \\ "description":"Какие есть мониторы и их размеры.",
    \\ "inputSchema":{"type":"object","properties":{}}},
    \\{"name":"list_windows",
    \\ "description":"Какие есть видимые окна с заголовками.",
    \\ "inputSchema":{"type":"object","properties":{}}}
    \\]
;

/// Ответ на рукопожатие.
pub fn writeInitialize(w: *std.Io.Writer, id: ?Id, version: []const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(w, id);
    try w.print(
        ",\"result\":{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}}}}," ++
            "\"serverInfo\":{{\"name\":\"{s}\",\"version\":\"{s}\"}}}}}}",
        .{ protocol_version, server_name, version },
    );
}

pub fn writeToolList(w: *std.Io.Writer, id: ?Id) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(w, id);
    try w.writeAll(",\"result\":{\"tools\":");
    try writeOneLine(w, tools_json);
    try w.writeAll("}}");
}

/// Записать текст без переносов строк.
///
/// Список инструментов записан многострочным литералом — так его можно
/// читать. Но связь построчная: получатель читает до первого перевода
/// строки, и многострочный ответ доходит до него огрызком. Для JSON перенос
/// — законный пробел, поэтому убрать его можно без последствий; на месте
/// переноса остаётся отступ следующей строки, и слова не слипаются.
fn writeOneLine(w: *std.Io.Writer, text: []const u8) !void {
    var at: usize = 0;
    while (at < text.len) {
        const stop = std.mem.indexOfAnyPos(u8, text, at, "\r\n") orelse text.len;
        if (stop > at) try w.writeAll(text[at..stop]);
        at = stop + 1;
    }
}

/// Ответ инструмента — обычный текст. Модель читает его как текст, поэтому
/// он должен быть понятной фразой, а не набором полей.
pub fn writeToolText(w: *std.Io.Writer, id: ?Id, text: []const u8, failed: bool) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(w, id);
    try w.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(w, text);
    try w.print("}}],\"isError\":{s}}}}}", .{if (failed) "true" else "false"});
}

pub fn writeFault(w: *std.Io.Writer, id: ?Id, fault: Fault) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(w, id);
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{fault.code()});
    try writeJsonString(w, fault.message());
    try w.writeAll("}}");
}

fn writeId(w: *std.Io.Writer, id: ?Id) !void {
    const value = id orelse {
        try w.writeAll("null");
        return;
    };
    switch (value) {
        .number => |n| try w.print("{d}", .{n}),
        .text => |s| try writeJsonString(w, s),
    }
}

/// Строка в кавычках с экранированием.
///
/// Своё, а не готовое: тексты у нас русские и с переносами строк, и именно
/// на них ломается наивное «обернуть в кавычки». Один непроэкранированный
/// перенос — и клиент получает битый JSON вместо ответа.
pub fn writeJsonString(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0C => try w.writeAll("\\f"),
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
    try w.writeByte('"');
}

// ---------------------------------------------------------------- тесты

test "рукопожатие разбирается" {
    var s = parse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );
    defer s.deinit();
    try std.testing.expect(s.result.fault == null);
    try std.testing.expect(s.result.request.? == .initialize);
    try std.testing.expectEqual(@as(i64, 1), s.result.id.?.number);
}

test "уведомление о готовности не требует ответа" {
    var s = parse(std.testing.allocator,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );
    defer s.deinit();
    try std.testing.expect(s.result.request.? == .initialized);
    try std.testing.expect(s.result.id == null);
}

test "номер запроса возвращается тем же, чем пришёл" {
    // Строгий клиент не признает своим ответ, где число подменили строкой.
    var num = parse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":7,"method":"tools/list"}
    );
    defer num.deinit();
    try std.testing.expectEqual(@as(i64, 7), num.result.id.?.number);

    var txt = parse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":"abc","method":"tools/list"}
    );
    defer txt.deinit();
    try std.testing.expectEqualStrings("abc", txt.result.id.?.text);
}

test "строковый номер переживает разбор" {
    // Тот самый случай, на котором разбор падал: срез указывал внутрь
    // документа, а документ к этому времени был уже освобождён.
    var s = parse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":"запрос-1","method":"tools/list"}
    );
    defer s.deinit();
    // Буфер с запасом: список инструментов длинный, и коротким буфером
    // проверялся бы его размер, а не сохранность номера.
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeToolList(&w, s.result.id);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "запрос-1") != null);
}

test "вызов записи без параметров — весь экран" {
    var s = parse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"start_recording"}}
    );
    defer s.deinit();
    try std.testing.expect(s.result.fault == null);
    const start = s.result.request.?.start;
    try std.testing.expect(start.monitor == null);
    try std.testing.expect(start.area == null);
    try std.testing.expect(start.window == null);
    try std.testing.expect(!start.sound);
}

test "вызов записи с параметрами" {
    var s = parse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"start_recording",
        \\ "arguments":{"window":"Блокнот","sound":true,"fps":60}}}
    );
    defer s.deinit();
    try std.testing.expect(s.result.fault == null);
    const start = s.result.request.?.start;
    try std.testing.expectEqualStrings("Блокнот", start.window.?);
    try std.testing.expect(start.sound);
    try std.testing.expectEqual(@as(u32, 60), start.fps.?);
}

test "два источника сразу — это неясность, а не «оба»" {
    var s = parse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"start_recording",
        \\ "arguments":{"window":"Блокнот","area":"0,0,640,480"}}}
    );
    defer s.deinit();
    try std.testing.expectEqual(Fault.invalid_params, s.result.fault.?);
}

test "остальные инструменты разбираются" {
    var stop = parse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"stop_recording"}}
    );
    defer stop.deinit();
    try std.testing.expect(stop.result.request.? == .stop);

    var status = parse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"recording_status"}}
    );
    defer status.deinit();
    try std.testing.expect(status.result.request.? == .status);

    var mons = parse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_monitors"}}
    );
    defer mons.deinit();
    try std.testing.expect(mons.result.request.? == .monitors);

    var wins = parse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"list_windows"}}
    );
    defer wins.deinit();
    try std.testing.expect(wins.result.request.? == .windows);
}

test "битый JSON, не запрос и неизвестное имя — разные беды" {
    var bad = parse(std.testing.allocator, "это не json");
    defer bad.deinit();
    try std.testing.expectEqual(Fault.parse_error, bad.result.fault.?);

    var no_method = parse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":1}
    );
    defer no_method.deinit();
    try std.testing.expectEqual(Fault.invalid_request, no_method.result.fault.?);

    var wrong_method = parse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"чего-нибудь"}
    );
    defer wrong_method.deinit();
    try std.testing.expectEqual(Fault.method_not_found, wrong_method.result.fault.?);

    var wrong_tool = parse(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"полетели"}}
    );
    defer wrong_tool.deinit();
    try std.testing.expectEqual(Fault.method_not_found, wrong_tool.result.fault.?);
}

test "у каждой беды свой код по стандарту" {
    try std.testing.expectEqual(@as(i32, -32700), Fault.parse_error.code());
    try std.testing.expectEqual(@as(i32, -32600), Fault.invalid_request.code());
    try std.testing.expectEqual(@as(i32, -32601), Fault.method_not_found.code());
    try std.testing.expectEqual(@as(i32, -32602), Fault.invalid_params.code());
}

test "русский текст с переносом и кавычкой не ломает ответ" {
    // Наивная сборка строки ломается именно здесь: один непроэкранированный
    // перенос — и клиент получает битый JSON вместо ответа.
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const text_in = "готово: 30 кадров\nфайл \"снимок\".mp4";
    try writeToolText(&w, .{ .number = 1 }, text_in, false);
    const out = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\\"") != null);

    const back = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
    defer back.deinit();
    const text = back.value.object.get("result").?.object
        .get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expectEqualStrings(text_in, text);
}

test "ответ рукопожатия — годный JSON с версией протокола" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeInitialize(&w, .{ .number = 1 }, "0.1.19.0");

    const back = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    defer back.deinit();
    const result = back.value.object.get("result").?.object;
    try std.testing.expectEqualStrings(protocol_version, result.get("protocolVersion").?.string);
    try std.testing.expectEqualStrings("zigrec", result.get("serverInfo").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("0.1.19.0", result.get("serverInfo").?.object.get("version").?.string);
}

test "список инструментов — годный JSON, и в нём все пять" {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeToolList(&w, .{ .number = 2 });

    const back = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    defer back.deinit();
    const list = back.value.object.get("result").?.object.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 5), list.items.len);
    // У каждого инструмента должно быть человеческое описание: его читает
    // модель, и от него зависит, вызовет она нужное или нет.
    for (list.items) |item| {
        try std.testing.expect(item.object.get("name").?.string.len > 0);
        try std.testing.expect(item.object.get("description").?.string.len > 20);
        try std.testing.expect(item.object.get("inputSchema") != null);
    }
}

test "ответы уходят одной строкой" {
    // Связь построчная: получатель читает до первого перевода строки.
    // Многострочный ответ дошёл бы до него огрызком — поймано стендом,
    // который говорит с сервером по-настоящему, а не разбирает готовую строку.
    var buf: [8192]u8 = undefined;

    var w1 = std.Io.Writer.fixed(&buf);
    try writeToolList(&w1, .{ .number = 1 });
    try std.testing.expect(std.mem.indexOfAny(u8, w1.buffered(), "\r\n") == null);

    var w2 = std.Io.Writer.fixed(&buf);
    try writeInitialize(&w2, .{ .number = 1 }, "0.1.19.0");
    try std.testing.expect(std.mem.indexOfAny(u8, w2.buffered(), "\r\n") == null);

    var w3 = std.Io.Writer.fixed(&buf);
    try writeToolText(&w3, .{ .number = 1 }, "первая строка\nвторая строка", false);
    try std.testing.expect(std.mem.indexOfAny(u8, w3.buffered(), "\r\n") == null);

    var w4 = std.Io.Writer.fixed(&buf);
    try writeFault(&w4, .{ .number = 1 }, .parse_error);
    try std.testing.expect(std.mem.indexOfAny(u8, w4.buffered(), "\r\n") == null);
}

test "ответ об ошибке — годный JSON с кодом и словами" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeFault(&w, .{ .number = 9 }, .method_not_found);

    const back = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    defer back.deinit();
    const err = back.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32601), err.get("code").?.integer);
    try std.testing.expect(err.get("message").?.string.len > 0);
}
