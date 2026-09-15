//! Проигрыватель для окна редактора: кадр из файла по времени.
//!
//! Задача #23. Резать вслепую нельзя: человек должен видеть, что именно
//! он режет. Поэтому редактору нужен кадр под указателем — и на перемотке,
//! и при воспроизведении.
//!
//! Декодирует Media Foundation через `IMFSourceReader`. Просим у него сразу
//! `RGB32` и включаем встроенное преобразование: разбирать чужие раскладки
//! цветности самим — это отдельная программа, а не строчка кода.
//!
//! **Перемотка неточная нарочно.** Источник умеет встать только на ключевой
//! кадр; чтобы попасть в нужный, после перемотки читаем кадры подряд, пока
//! не дойдём до искомого времени. Иначе картинка прыгала бы к ближайшему
//! ключевому кадру, и человек резал бы не там, где смотрит.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32.zig");
const c = win32.c;

pub const Error = error{
    /// Файл не открылся или в нём нет картинки.
    NoVideo,
    /// Media Foundation не поднялась.
    StartupFailed,
    /// Кадр не декодировался.
    DecodeFailed,
    Unsupported,
    OutOfMemory,
};

/// Насколько близко к искомому времени считаем, что попали.
///
/// Полкадра при тридцати в секунду. Точнее гнаться незачем: следующий кадр
/// человек всё равно не отличит, а лишний проход по файлу стоит времени.
pub const tolerance_ns: u64 = std.time.ns_per_ms * 16;

pub const Player = struct {
    allocator: std.mem.Allocator,
    reader: ?*c.IMFSourceReader = null,
    width: u32 = 0,
    height: u32 = 0,
    duration_ns: u64 = 0,
    /// Последний декодированный кадр, BGRA сверху вниз.
    pixels: []u8 = &.{},
    /// Время этого кадра в файле.
    at_ns: u64 = 0,
    /// Есть ли что показывать.
    ready: bool = false,
    /// Строки идут снизу вверх.
    ///
    /// Направление спрашиваем у самого типа — по знаку шага строки, —
    /// а не предполагаем. Предположение стоило перевёрнутого кадра:
    /// при записи Media Foundation ждёт снизу вверх, при чтении со
    /// включённым преобразованием отдаёт сверху вниз.
    bottom_up: bool = false,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) Error!Player {
        if (builtin.os.tag != .windows) return Error.Unsupported;

        _ = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED | c.COINIT_DISABLE_OLE1DDE);
        if (win32.failed(c.MFStartup(c.MF_VERSION, c.MFSTARTUP_FULL))) return Error.StartupFailed;

        var wide: [std.fs.max_path_bytes]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wide, path) catch return Error.NoVideo;
        wide[n] = 0;

        // Просим Media Foundation самой привести картинку к RGB32.
        var attrs: ?*c.IMFAttributes = null;
        if (win32.failed(c.MFCreateAttributes(&attrs, 2))) return Error.NoVideo;
        defer _ = attrs.?.lpVtbl.*.Release.?(@ptrCast(attrs.?));
        _ = attrs.?.lpVtbl.*.SetUINT32.?(attrs.?, &c.MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, 1);

        var reader: ?*c.IMFSourceReader = null;
        if (win32.failed(c.MFCreateSourceReaderFromURL(@ptrCast(&wide), attrs, &reader))) return Error.NoVideo;
        errdefer _ = reader.?.lpVtbl.*.Release.?(@ptrCast(reader.?));
        const r = reader.?;

        // Звук здесь не нужен: проигрыватель показывает картинку.
        _ = r.lpVtbl.*.SetStreamSelection.?(r, c.MF_SOURCE_READER_ALL_STREAMS, 0);
        _ = r.lpVtbl.*.SetStreamSelection.?(r, c.MF_SOURCE_READER_FIRST_VIDEO_STREAM, 1);

        var want: ?*c.IMFMediaType = null;
        if (win32.failed(c.MFCreateMediaType(&want))) return Error.NoVideo;
        defer _ = want.?.lpVtbl.*.Release.?(@ptrCast(want.?));
        const w = want.?;
        _ = w.lpVtbl.*.SetGUID.?(w, &c.MF_MT_MAJOR_TYPE, &c.MFMediaType_Video);
        _ = w.lpVtbl.*.SetGUID.?(w, &c.MF_MT_SUBTYPE, &c.MFVideoFormat_RGB32);
        if (win32.failed(r.lpVtbl.*.SetCurrentMediaType.?(r, c.MF_SOURCE_READER_FIRST_VIDEO_STREAM, null, w))) {
            return Error.NoVideo;
        }

        var actual: ?*c.IMFMediaType = null;
        if (win32.failed(r.lpVtbl.*.GetCurrentMediaType.?(r, c.MF_SOURCE_READER_FIRST_VIDEO_STREAM, &actual))) {
            return Error.NoVideo;
        }
        defer _ = actual.?.lpVtbl.*.Release.?(@ptrCast(actual.?));

        var packed_size: u64 = 0;
        _ = actual.?.lpVtbl.*.GetUINT64.?(actual.?, &c.MF_MT_FRAME_SIZE, &packed_size);
        const width: u32 = @intCast(packed_size >> 32);
        const height: u32 = @intCast(packed_size & 0xFFFF_FFFF);
        if (width == 0 or height == 0) return Error.NoVideo;

        var stride_raw: c.UINT32 = 0;
        _ = actual.?.lpVtbl.*.GetUINT32.?(actual.?, &c.MF_MT_DEFAULT_STRIDE, &stride_raw);
        const stride: i32 = @bitCast(stride_raw);

        const pixels = allocator.alloc(u8, @as(usize, width) * height * 4) catch return Error.OutOfMemory;
        @memset(pixels, 0);

        return .{
            .allocator = allocator,
            .reader = r,
            .width = width,
            .height = height,
            .duration_ns = durationOf(r),
            .pixels = pixels,
            .bottom_up = stride < 0,
        };
    }

    pub fn close(self: *Player) void {
        if (self.pixels.len > 0) self.allocator.free(self.pixels);
        self.pixels = &.{};
        if (self.reader) |r| {
            _ = r.lpVtbl.*.Release.?(@ptrCast(r));
            self.reader = null;
            _ = c.MFShutdown();
        }
        self.ready = false;
    }

    /// Показать кадр на этом времени.
    ///
    /// Если искомое время впереди текущего и рядом — идём вперёд чтением,
    /// без перемотки: перемотка сбрасывает декодер и стоит дороже, чем
    /// прочитать несколько кадров подряд. Это и есть разница между плавным
    /// воспроизведением и рывками.
    pub fn showAt(self: *Player, when_ns: u64) Error!void {
        const r = self.reader orelse return Error.NoVideo;

        const forward_close = self.ready and when_ns >= self.at_ns and
            when_ns - self.at_ns < std.time.ns_per_s;
        if (!forward_close) try self.seek(when_ns);

        // Читаем, пока не дойдём до искомого времени.
        var guard: usize = 0;
        while (guard < 600) : (guard += 1) {
            const got = try self.readOne();
            if (!got) return; // конец файла: остаётся последний кадр
            if (self.at_ns + tolerance_ns >= when_ns) return;
        }
        _ = r;
    }

    fn seek(self: *Player, when_ns: u64) Error!void {
        const r = self.reader orelse return Error.NoVideo;
        var value = std.mem.zeroes(c.PROPVARIANT);
        // Время источника — в сотнях наносекунд.
        value.unnamed_0.unnamed_0.vt = c.VT_I8;
        value.unnamed_0.unnamed_0.unnamed_0.hVal.QuadPart = @intCast(when_ns / 100);
        _ = r.lpVtbl.*.SetCurrentPosition.?(r, &c.GUID_NULL, &value);
        self.ready = false;
        self.at_ns = 0;
    }

    /// Прочитать очередной кадр. `false` — файл кончился.
    fn readOne(self: *Player) Error!bool {
        const r = self.reader orelse return Error.NoVideo;

        var flags: c.DWORD = 0;
        var sample: ?*c.IMFSample = null;
        var stream: c.DWORD = 0;
        var timestamp: c.LONGLONG = 0;
        if (win32.failed(r.lpVtbl.*.ReadSample.?(
            r,
            c.MF_SOURCE_READER_FIRST_VIDEO_STREAM,
            0,
            &stream,
            &flags,
            &timestamp,
            &sample,
        ))) return Error.DecodeFailed;

        if (flags & c.MF_SOURCE_READERF_ENDOFSTREAM != 0) return false;
        const got = sample orelse return true; // пустой ответ — просто идём дальше
        defer _ = got.lpVtbl.*.Release.?(@ptrCast(got));

        var buffer: ?*c.IMFMediaBuffer = null;
        if (win32.failed(got.lpVtbl.*.ConvertToContiguousBuffer.?(got, &buffer))) return Error.DecodeFailed;
        defer _ = buffer.?.lpVtbl.*.Release.?(@ptrCast(buffer.?));

        var data: [*c]u8 = undefined;
        var length: c.DWORD = 0;
        if (win32.failed(buffer.?.lpVtbl.*.Lock.?(buffer.?, &data, null, &length))) return Error.DecodeFailed;
        defer _ = buffer.?.lpVtbl.*.Unlock.?(buffer.?);

        // Копируем как есть: направление строк уже известно из типа,
        // и переворачивать руками нечего — этим займётся заголовок картинки
        // при рисовании. Ручной переворот здесь однажды уже поставил кадр
        // на голову вместе с заголовком.
        const take = @min(@as(usize, length), self.pixels.len);
        @memcpy(self.pixels[0..take], data[0..take]);

        self.at_ns = @as(u64, @intCast(@max(timestamp, 0))) * 100;
        self.ready = true;
        return true;
    }
};

fn durationOf(r: *c.IMFSourceReader) u64 {
    var value = std.mem.zeroes(c.PROPVARIANT);
    if (win32.failed(r.lpVtbl.*.GetPresentationAttribute.?(
        r,
        c.MF_SOURCE_READER_MEDIASOURCE,
        &c.MF_PD_DURATION,
        &value,
    ))) return 0;
    defer _ = c.PropVariantClear(&value);
    return @as(u64, @intCast(value.unnamed_0.unnamed_0.unnamed_0.uhVal.QuadPart)) * 100;
}

/// Куда вписать кадр, чтобы он не растянулся и не обрезался.
///
/// Считается отдельно от рисования и проверяется тестами: растянутый на
/// полэкрана кадр с неверными пропорциями — это не мелочь, по нему судят
/// о том, что получится на выходе.
pub const Fit = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub fn fitInto(frame_w: u32, frame_h: u32, box_w: i32, box_h: i32) Fit {
    if (frame_w == 0 or frame_h == 0 or box_w <= 0 or box_h <= 0) {
        return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    }
    const fw: i64 = @intCast(frame_w);
    const fh: i64 = @intCast(frame_h);

    // Подгоняем по той стороне, которая упирается раньше.
    var w: i64 = box_w;
    var h = @divTrunc(w * fh, fw);
    if (h > box_h) {
        h = box_h;
        w = @divTrunc(h * fw, fh);
    }
    return .{
        .x = @intCast(@divTrunc(box_w - w, 2)),
        .y = @intCast(@divTrunc(box_h - h, 2)),
        .w = @intCast(w),
        .h = @intCast(h),
    };
}

// ---------------------------------------------------------------- тесты

test "широкий кадр в широком поле упирается в ширину" {
    const f = fitInto(1920, 1080, 800, 600);
    try std.testing.expectEqual(@as(i32, 800), f.w);
    try std.testing.expectEqual(@as(i32, 450), f.h);
    // По вертикали остаются поля сверху и снизу, поровну.
    try std.testing.expectEqual(@as(i32, 0), f.x);
    try std.testing.expectEqual(@as(i32, 75), f.y);
}

test "высокий кадр упирается в высоту" {
    const f = fitInto(1080, 1920, 800, 600);
    try std.testing.expectEqual(@as(i32, 600), f.h);
    try std.testing.expectEqual(@as(i32, 337), f.w);
    try std.testing.expect(f.x > 0);
    try std.testing.expectEqual(@as(i32, 0), f.y);
}

test "пропорции не врут ни в одну сторону" {
    // Что бы ни попросили, отношение сторон кадра сохраняется.
    for ([_][2]u32{ .{ 1920, 1080 }, .{ 640, 480 }, .{ 1080, 1920 }, .{ 100, 100 } }) |size| {
        const f = fitInto(size[0], size[1], 640, 360);
        const want = @as(f64, @floatFromInt(size[0])) / @as(f64, @floatFromInt(size[1]));
        const got = @as(f64, @floatFromInt(f.w)) / @as(f64, @floatFromInt(f.h));
        try std.testing.expectApproxEqRel(want, got, 0.02);
    }
}

test "кадр никогда не вылезает за поле" {
    const f = fitInto(4000, 100, 640, 360);
    try std.testing.expect(f.w <= 640);
    try std.testing.expect(f.h <= 360);
    try std.testing.expect(f.x >= 0 and f.y >= 0);
}

test "пустой кадр или пустое поле не делят на ноль" {
    try std.testing.expectEqual(@as(i32, 0), fitInto(0, 0, 640, 360).w);
    try std.testing.expectEqual(@as(i32, 0), fitInto(1920, 1080, 0, 0).w);
}

test "допуск попадания — меньше кадра при тридцати в секунду" {
    // Иначе проигрыватель показывал бы соседний кадр как искомый.
    try std.testing.expect(tolerance_ns < std.time.ns_per_s / 30);
}
