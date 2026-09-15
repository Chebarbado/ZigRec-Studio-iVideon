//! Запись ZIP-архива.
//!
//! Задача #71. В стандартной библиотеке есть чтение ZIP, но нет записи,
//! а нам нужна именно запись: файл проекта `.zigrec` — это архив.
//!
//! **Почему ZIP, а не свой формат.** Архив открывается чем угодно: проводником
//! Windows, любым архиватором, двумя строками на питоне. Человек, которому
//! понадобилось заглянуть внутрь своего проекта, не должен для этого искать
//! нашу программу. Свой формат сэкономил бы сотню строк здесь и стоил бы
//! этой возможности.
//!
//! Пишем самый простой ZIP, какой бывает: без шифрования, без разбиения
//! на тома, без zip64. Проект с исходниками может перевалить за четыре
//! гигабайта — тогда мы честно отказываемся, а не пишем архив, который
//! потом никто не откроет.
const std = @import("std");
const flate = std.compress.flate;

/// Как сжат кусок.
pub const Method = enum(u16) {
    /// Как есть. Для того, что уже сжато, и для метки в начале архива.
    store = 0,
    /// Обычное сжатие ZIP.
    deflate = 8,
};

pub const Error = error{
    /// Архив не помещается в обычный ZIP.
    TooBig,
    /// Имени нет или оно слишком длинное.
    BadName,
};

/// Предел обычного ZIP. Дальше нужен zip64, а мы его не пишем.
pub const max_total: u64 = 0xFFFF_FFFF;
pub const max_entries: usize = 0xFFFF;
pub const max_name: usize = 0xFFFF;

const sig_local = [4]u8{ 'P', 'K', 3, 4 };
const sig_central = [4]u8{ 'P', 'K', 1, 2 };
const sig_end = [4]u8{ 'P', 'K', 5, 6 };

/// Признак «имена в UTF-8».
///
/// Без него проводник Windows читает русские имена в своей однобайтной
/// кодировке и показывает кракозябры. Бит одиннадцатый, и он здесь
/// обязателен: имена внутри наших архивов русские.
const flag_utf8: u16 = 1 << 11;

const Entry = struct {
    name: []const u8,
    method: Method,
    crc: u32,
    packed_len: u32,
    plain_len: u32,
    offset: u32,
};

/// Собиратель архива.
///
/// Держит всё в памяти: проект с исходниками — это то, что и так целиком
/// читается с диска, а простота здесь дороже экономии.
pub const Archive = struct {
    allocator: std.mem.Allocator,
    body: std.Io.Writer.Allocating,
    entries: std.ArrayList(Entry) = .empty,
    /// Имена храним у себя: вызывающий не обязан держать их до конца.
    names: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Archive {
        return .{ .allocator = allocator, .body = .init(allocator) };
    }

    pub fn deinit(self: *Archive) void {
        for (self.names.items) |n| self.allocator.free(n);
        self.names.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.body.deinit();
    }

    /// Положить кусок в архив.
    pub fn add(self: *Archive, name: []const u8, data: []const u8, method: Method) !void {
        if (name.len == 0 or name.len > max_name) return Error.BadName;
        if (self.entries.items.len >= max_entries) return Error.TooBig;
        if (data.len > max_total) return Error.TooBig;

        const kept = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(kept);
        try self.names.append(self.allocator, kept);

        const offset = self.body.writer.buffered().len;
        if (offset > max_total) return Error.TooBig;

        const crc = std.hash.crc.Crc32.hash(data);

        // Сжимаем до записи заголовка: в заголовке стоит длина сжатого,
        // а переписывать его потом негде — мы пишем подряд.
        var squeezed: ?[]u8 = null;
        defer if (squeezed) |s| self.allocator.free(s);
        const payload = switch (method) {
            .store => data,
            .deflate => blk: {
                const made = try squeeze(self.allocator, data);
                squeezed = made;
                // Сжатие бывает и во вред: на уже сжатом видео оно только
                // добавляет байтов. Тогда кладём как есть.
                if (made.len >= data.len) break :blk data;
                break :blk made;
            },
        };
        const real_method: Method = if (payload.ptr == data.ptr) .store else method;

        const w = &self.body.writer;
        try w.writeAll(&sig_local);
        try w.writeInt(u16, 20, .little); // какая версия нужна, чтобы прочитать
        try w.writeInt(u16, flag_utf8, .little);
        try w.writeInt(u16, @intFromEnum(real_method), .little);
        // Время и дата: ставим ноль. Настоящее время сделало бы архив
        // разным при каждой записи одного и того же, а это мешает сравнивать.
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, @intCast(payload.len), .little);
        try w.writeInt(u32, @intCast(data.len), .little);
        try w.writeInt(u16, @intCast(name.len), .little);
        try w.writeInt(u16, 0, .little); // лишних полей нет
        try w.writeAll(name);
        try w.writeAll(payload);

        try self.entries.append(self.allocator, .{
            .name = kept,
            .method = real_method,
            .crc = crc,
            .packed_len = @intCast(payload.len),
            .plain_len = @intCast(data.len),
            .offset = @intCast(offset),
        });
    }

    /// Дописать оглавление и отдать готовый архив.
    pub fn finish(self: *Archive) ![]u8 {
        const w = &self.body.writer;
        const dir_at = w.buffered().len;
        if (dir_at > max_total) return Error.TooBig;

        for (self.entries.items) |e| {
            try w.writeAll(&sig_central);
            try w.writeInt(u16, 20, .little); // чем создан
            try w.writeInt(u16, 20, .little); // что нужно, чтобы прочитать
            try w.writeInt(u16, flag_utf8, .little);
            try w.writeInt(u16, @intFromEnum(e.method), .little);
            try w.writeInt(u16, 0, .little);
            try w.writeInt(u16, 0, .little);
            try w.writeInt(u32, e.crc, .little);
            try w.writeInt(u32, e.packed_len, .little);
            try w.writeInt(u32, e.plain_len, .little);
            try w.writeInt(u16, @intCast(e.name.len), .little);
            try w.writeInt(u16, 0, .little); // лишних полей нет
            try w.writeInt(u16, 0, .little); // примечания нет
            try w.writeInt(u16, 0, .little); // том один
            try w.writeInt(u16, 0, .little); // внутренние признаки
            try w.writeInt(u32, 0, .little); // внешние признаки
            try w.writeInt(u32, e.offset, .little);
            try w.writeAll(e.name);
        }

        const dir_len = w.buffered().len - dir_at;
        try w.writeAll(&sig_end);
        try w.writeInt(u16, 0, .little); // номер тома
        try w.writeInt(u16, 0, .little); // том с оглавлением
        try w.writeInt(u16, @intCast(self.entries.items.len), .little);
        try w.writeInt(u16, @intCast(self.entries.items.len), .little);
        try w.writeInt(u32, @intCast(dir_len), .little);
        try w.writeInt(u32, @intCast(dir_at), .little);
        try w.writeInt(u16, 0, .little); // примечания к архиву нет

        return self.body.toOwnedSlice();
    }
};

/// Сжать кусок так, как это понимает ZIP: голый deflate, без обёртки.
fn squeeze(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, @max(data.len / 3, 4096));
    errdefer out.deinit();

    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);

    var press = try flate.Compress.init(&out.writer, window, .raw, .default);
    try press.writer.writeAll(data);
    try press.finish();
    return out.toOwnedSlice();
}

/// Найти кусок в архиве по имени и вернуть его содержимое.
///
/// Идём по заголовкам кусков от начала, не читая оглавление в хвосте.
/// Это нужно затем, что разметка проекта лежит в начале архива: её можно
/// достать, прочитав первые мегабайты, а не весь файл — который вместе
/// с исходниками бывает и в гигабайт.
///
/// `null` — такого куска здесь нет.
pub fn find(allocator: std.mem.Allocator, archive: []const u8, want: []const u8) !?[]u8 {
    var at: usize = 0;
    while (at + 30 <= archive.len) {
        if (!std.mem.eql(u8, archive[at..][0..4], &sig_local)) break;
        const method = std.mem.readInt(u16, archive[at + 8 ..][0..2], .little);
        const packed_len = std.mem.readInt(u32, archive[at + 18 ..][0..4], .little);
        const plain_len = std.mem.readInt(u32, archive[at + 22 ..][0..4], .little);
        const name_len = std.mem.readInt(u16, archive[at + 26 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, archive[at + 28 ..][0..2], .little);
        const name = archive[at + 30 ..][0..name_len];
        const body_at = at + 30 + name_len + extra_len;
        const body = archive[body_at..][0..packed_len];

        if (std.mem.eql(u8, name, want)) {
            if (method == 0) return try allocator.dupe(u8, body);
            var input: std.Io.Reader = .fixed(body);
            const window = try allocator.alloc(u8, flate.max_window_len);
            defer allocator.free(window);
            var un = flate.Decompress.init(&input, .raw, window);
            // Предел берём с запасом: он срабатывает при достижении, а не
            // при превышении, и ровный предел отверг бы точный размер.
            return try un.reader.allocRemaining(allocator, .limited(plain_len + 1));
        }
        at = body_at + packed_len;
    }
    return null;
}

/// Перечислить имена кусков, лежащих в начале архива.
///
/// Возвращает, сколько имён записано. Нужен, чтобы понять, что внутри,
/// не распаковывая.
pub fn names(archive: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (at + 30 <= archive.len and n < out.len) {
        if (!std.mem.eql(u8, archive[at..][0..4], &sig_local)) break;
        const packed_len = std.mem.readInt(u32, archive[at + 18 ..][0..4], .little);
        const name_len = std.mem.readInt(u16, archive[at + 26 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, archive[at + 28 ..][0..2], .little);
        if (at + 30 + name_len > archive.len) break;
        out[n] = archive[at + 30 ..][0..name_len];
        n += 1;
        at = at + 30 + name_len + extra_len + packed_len;
    }
    return n;
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;

/// Короткое имя для тестов.
fn take(allocator: std.mem.Allocator, archive: []const u8, want: []const u8) !?[]u8 {
    return find(allocator, archive, want);
}

test "положенное в архив достаётся обратно" {
    const a = testing.allocator;
    var zip = Archive.init(a);
    defer zip.deinit();

    try zip.add("метка", "ZIGREC-V-1.2.3.4", .store);
    try zip.add("проект.zrs", "zigrec-project 1\ntrack video 0 Видео\n", .deflate);

    const bytes = try zip.finish();
    defer a.free(bytes);

    const mark = (try take(a, bytes, "метка")).?;
    defer a.free(mark);
    try testing.expectEqualStrings("ZIGREC-V-1.2.3.4", mark);

    const project = (try take(a, bytes, "проект.zrs")).?;
    defer a.free(project);
    try testing.expectEqualStrings("zigrec-project 1\ntrack video 0 Видео\n", project);
}

test "архив начинается и кончается тем, чем положено" {
    const a = testing.allocator;
    var zip = Archive.init(a);
    defer zip.deinit();
    try zip.add("а", "б", .store);
    const bytes = try zip.finish();
    defer a.free(bytes);

    try testing.expectEqualSlices(u8, &sig_local, bytes[0..4]);
    // Последние двадцать два байта — запись о конце архива.
    try testing.expectEqualSlices(u8, &sig_end, bytes[bytes.len - 22 ..][0..4]);
}

test "русские имена помечены как UTF-8" {
    // Без этого признака проводник Windows покажет кракозябры.
    const a = testing.allocator;
    var zip = Archive.init(a);
    defer zip.deinit();
    try zip.add("исходники/моя запись.mp4", "данные", .store);
    const bytes = try zip.finish();
    defer a.free(bytes);

    const flags = std.mem.readInt(u16, bytes[6..8], .little);
    try testing.expect(flags & flag_utf8 != 0);
}

test "сжатие во вред не применяется" {
    // На уже сжатом видео deflate только добавляет байтов. Тогда кладём
    // как есть — и говорим об этом в заголовке куска, а не втихаря.
    const a = testing.allocator;
    var noise: [4096]u8 = undefined;
    var seed = std.Random.DefaultPrng.init(7);
    seed.random().bytes(&noise);

    var zip = Archive.init(a);
    defer zip.deinit();
    try zip.add("шум", &noise, .deflate);
    const bytes = try zip.finish();
    defer a.free(bytes);

    const method = std.mem.readInt(u16, bytes[8..10], .little);
    try testing.expectEqual(@as(u16, @intFromEnum(Method.store)), method);

    const back = (try take(a, bytes, "шум")).?;
    defer a.free(back);
    try testing.expectEqualSlices(u8, &noise, back);
}

test "сжимаемое сжимается" {
    const a = testing.allocator;
    const plain = "одно и то же " ** 500;
    var zip = Archive.init(a);
    defer zip.deinit();
    try zip.add("повтор", plain, .deflate);
    const bytes = try zip.finish();
    defer a.free(bytes);

    try testing.expect(bytes.len * 10 < plain.len);
    const back = (try take(a, bytes, "повтор")).?;
    defer a.free(back);
    try testing.expectEqualStrings(plain, back);
}

test "пустое имя не принимается" {
    const a = testing.allocator;
    var zip = Archive.init(a);
    defer zip.deinit();
    try testing.expectError(Error.BadName, zip.add("", "что-то", .store));
}

test "один и тот же архив дважды выходит одинаковым" {
    // Время в заголовках нарочно нулевое: иначе один и тот же проект
    // давал бы разные байты при каждом сохранении, и сравнить две версии
    // в системе контроля версий было бы нечем.
    const a = testing.allocator;
    var first = Archive.init(a);
    defer first.deinit();
    try first.add("проект.zrs", "zigrec-project 1\n", .deflate);
    const one = try first.finish();
    defer a.free(one);

    var second = Archive.init(a);
    defer second.deinit();
    try second.add("проект.zrs", "zigrec-project 1\n", .deflate);
    const two = try second.finish();
    defer a.free(two);

    try testing.expectEqualSlices(u8, one, two);
}

test "несколько кусков лежат по порядку и все находятся" {
    const a = testing.allocator;
    var zip = Archive.init(a);
    defer zip.deinit();
    try zip.add("первый", "раз", .store);
    try zip.add("второй", "два", .deflate);
    try zip.add("третий", "три", .store);
    const bytes = try zip.finish();
    defer a.free(bytes);

    for ([_][2][]const u8{
        .{ "первый", "раз" },
        .{ "второй", "два" },
        .{ "третий", "три" },
    }) |pair| {
        const got = (try take(a, bytes, pair[0])).?;
        defer a.free(got);
        try testing.expectEqualStrings(pair[1], got);
    }
    try testing.expect((try take(a, bytes, "четвёртый")) == null);
}

test "имена кусков перечисляются, не распаковывая" {
    const a = testing.allocator;
    var zip = Archive.init(a);
    defer zip.deinit();
    try zip.add("метка", "м", .store);
    try zip.add("проект.zrs", "разметка", .deflate);
    try zip.add("исходники/видео.mp4", "данные", .store);
    const bytes = try zip.finish();
    defer a.free(bytes);

    var list: [8][]const u8 = undefined;
    const n = names(bytes, &list);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("метка", list[0]);
    try testing.expectEqualStrings("проект.zrs", list[1]);
    try testing.expectEqualStrings("исходники/видео.mp4", list[2]);
}

test "обрезанный архив не роняет перечисление" {
    // Файл мог не докачаться или оборваться на записи. Читаем, сколько
    // прочиталось, и не падаем.
    const a = testing.allocator;
    var zip = Archive.init(a);
    defer zip.deinit();
    try zip.add("первый", "раз", .store);
    try zip.add("второй", "два", .store);
    const bytes = try zip.finish();
    defer a.free(bytes);

    var list: [8][]const u8 = undefined;
    try testing.expect(names(bytes[0 .. bytes.len / 2], &list) <= 2);
    try testing.expectEqual(@as(usize, 0), names("", &list));
    try testing.expectEqual(@as(usize, 0), names("не архив вовсе", &list));
}

test "поиск по началу архива находит разметку" {
    // На этом стоит быстрое открытие: разметка лежит в начале, и её видно,
    // не читая весь архив с исходниками.
    const a = testing.allocator;
    var zip = Archive.init(a);
    defer zip.deinit();
    try zip.add("метка", "м", .store);
    try zip.add("проект.zrs", "zigrec-project 1", .deflate);
    try zip.add("исходники/тяжёлое.mp4", "х" ** 5000, .store);
    const bytes = try zip.finish();
    defer a.free(bytes);

    // Берём только начало — исходник в него не попадает.
    const head = bytes[0..@min(bytes.len, 512)];
    const got = (try find(a, head, "проект.zrs")).?;
    defer a.free(got);
    try testing.expectEqualStrings("zigrec-project 1", got);
}
