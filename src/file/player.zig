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
const win32 = @import("../win32.zig");
const gif_mod = @import("gif.zig");
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
    /// Разобранный GIF, если открыт GIF.
    ///
    /// У GIF свой путь: Media Foundation отдаёт его одной картинкой, теряя
    /// и кадры, и выдержки. Кадры уже лежат в памяти, декодировать на ходу
    /// нечего — показ сводится к тому, чтобы выбрать нужный.
    gif: ?gif_mod.Image = null,
    width: u32 = 0,
    height: u32 = 0,
    duration_ns: u64 = 0,
    /// Последний декодированный кадр, BGRA сверху вниз.
    pixels: []u8 = &.{},
    /// Время этого кадра в файле.
    at_ns: u64 = 0,
    /// Есть ли что показывать.
    ready: bool = false,
    /// Шаг строки, как его назвал тип. Может быть нулём: тогда шаг
    /// считается из длины самого буфера. Держим для справки и на случай,
    /// когда буфер приходит короче ожидаемого.
    stride: usize = 0,
    /// Длина последнего полученного буфера — для замеров.
    last_length: usize = 0,
    /// Каким путём пришёл кадр: 1 — шаг у исходного буфера, 2 — у склеенного,
    /// 3 — шаг из типа. Нужно для замеров: без этого приходится гадать,
    /// какая ветка сработала.
    route: u8 = 0,
    /// Кадр приходит уменьшенным: декодер отдаёт ровно тот размер,
    /// какой мы показываем.
    scaled: bool = false,
    /// Строки идут снизу вверх.
    ///
    /// Направление спрашиваем у самого типа — по знаку шага строки, —
    /// а не предполагаем. Предположение стоило перевёрнутого кадра:
    /// при записи Media Foundation ждёт снизу вверх, при чтении со
    /// включённым преобразованием отдаёт сверху вниз.
    bottom_up: bool = false,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) Error!Player {
        return openScaled(allocator, path, 0, 0);
    }

    /// Открыть файл, попросив кадр не больше заданного.
    ///
    /// Ускорение из «Разгона», и крупное. Кадр 4K весит 33 мегабайта,
    /// и раскодировать его целиком, чтобы показать в окошке шириной меньше
    /// тысячи точек, — работа впустую. Media Foundation умеет отдавать
    /// уменьшенный кадр сама, своим преобразователем.
    ///
    /// Ноль в пределах означает «как в файле»: так открывают для снимка,
    /// где нужен настоящий размер.
    pub fn openScaled(
        allocator: std.mem.Allocator,
        path: []const u8,
        max_width: u32,
        max_height: u32,
    ) Error!Player {
        if (builtin.os.tag != .windows) return Error.Unsupported;
        if (openGif(allocator, path)) |from_gif| return from_gif else |_| {}

        _ = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED | c.COINIT_DISABLE_OLE1DDE);
        if (win32.failed(c.MFStartup(c.MF_VERSION, c.MFSTARTUP_FULL))) return Error.StartupFailed;

        var wide: [std.fs.max_path_bytes]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wide, path) catch return Error.NoVideo;
        wide[n] = 0;

        // Просим Media Foundation самой привести картинку к RGB32.
        var attrs: ?*c.IMFAttributes = null;
        if (win32.failed(c.MFCreateAttributes(&attrs, 2))) return Error.NoVideo;
        defer _ = attrs.?.lpVtbl.*.Release.?(@ptrCast(attrs.?));
        // Две настройки видеообработки взаимно исключают друг друга: если
        // поставить обе, читатель не создастся вовсе. Проверено дорого —
        // кадр перестал приходить с ошибкой «нет картинки».
        //
        // Когда нужен уменьшенный кадр, берём продвинутую: простая умеет
        // только менять цветовое пространство, а уменьшать отказывается.
        if (max_width > 0 and max_height > 0) {
            _ = attrs.?.lpVtbl.*.SetUINT32.?(attrs.?, &c.MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, 1);
        } else {
            _ = attrs.?.lpVtbl.*.SetUINT32.?(attrs.?, &c.MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, 1);
        }

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

        // Сначала просим размер, какой нам нужен. Если Media Foundation
        // откажется — просим без размера: лучше медленно, чем никак.
        var scaled = false;
        if (max_width > 0 and max_height > 0) {
            const native = nativeSize(r);
            const want_size = fitDown(native.width, native.height, max_width, max_height);
            if (want_size.width > 0 and want_size.width < native.width) {
                _ = w.lpVtbl.*.SetUINT64.?(w, &c.MF_MT_FRAME_SIZE, win32.pack2(want_size.width, want_size.height));
                scaled = !win32.failed(r.lpVtbl.*.SetCurrentMediaType.?(
                    r,
                    c.MF_SOURCE_READER_FIRST_VIDEO_STREAM,
                    null,
                    w,
                ));
                if (!scaled) {
                    // Размер не взяли — убираем просьбу и пробуем как есть.
                    _ = w.lpVtbl.*.DeleteItem.?(w, &c.MF_MT_FRAME_SIZE);
                }
            }
        }
        if (!scaled and win32.failed(r.lpVtbl.*.SetCurrentMediaType.?(r, c.MF_SOURCE_READER_FIRST_VIDEO_STREAM, null, w))) {
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

        // Шаг может не прийти вовсе — тогда считаем его по ширине.
        const step: usize = if (stride == 0)
            @as(usize, width) * 4
        else
            @intCast(@abs(stride));

        return .{
            .allocator = allocator,
            .reader = r,
            .scaled = scaled,
            .width = width,
            .height = height,
            .duration_ns = durationOf(r),
            .pixels = pixels,
            .stride = step,
            .bottom_up = stride < 0,
        };
    }

    pub fn close(self: *Player) void {
        if (self.pixels.len > 0) self.allocator.free(self.pixels);
        self.pixels = &.{};
        if (self.gif) |*img| img.deinit(self.allocator);
        self.gif = null;
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
        if (self.gif) |img| {
            // Кадры уже в памяти: остаётся выбрать нужный и переложить.
            const index = img.frameAt(when_ns);
            const frame = img.frames[index];
            if (frame.pixels.len != self.pixels.len) return Error.NoVideo;
            @memcpy(self.pixels, frame.pixels);
            self.at_ns = when_ns;
            self.ready = true;
            return;
        }
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

    /// Переложить строки кадра к себе.
    ///
    /// `pitch` — шаг строки в источнике; отрицательный означает, что строки
    /// в памяти идут задом наперёд, и первая строка картинки лежит последней.
    fn copyRows(self: *Player, scan0: [*c]u8, pitch: c_long) void {
        const row_bytes = @as(usize, self.width) * 4;
        const step: usize = @intCast(@abs(pitch));
        if (step < row_bytes) return;

        var row: u32 = 0;
        while (row < self.height) : (row += 1) {
            const to = @as(usize, row) * row_bytes;
            if (to + row_bytes > self.pixels.len) break;
            // При отрицательном шаге идём от последней строки к первой.
            const src_row = if (pitch < 0) self.height - 1 - row else row;
            const from = @as(usize, src_row) * step;
            @memcpy(self.pixels[to .. to + row_bytes], scan0[from .. from + row_bytes]);
        }
        // Строки уже лежат сверху вниз: ниже по коду о направлении думать
        // не надо, и заголовок картинки его не переворачивает.
        self.bottom_up = false;
        self.stride = step;
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

        // Шаг строки спрашиваем у ИСХОДНОГО буфера кадра, а не у склеенного.
        // Склеивание отдаёт плоский буфер, который про двумерную раскладку
        // уже ничего не знает и отвечает отказом. У кадра 642 точки в ширину
        // настоящая раскладка — 656 точек с шагом 2624 байта; ни ширина
        // из типа, ни шаг из типа об этом не говорят, и оба привели
        // к косым полосам.
        var plane: ?*c.IMFMediaBuffer = null;
        if (!win32.failed(got.lpVtbl.*.GetBufferByIndex.?(got, 0, &plane))) {
            defer _ = plane.?.lpVtbl.*.Release.?(@ptrCast(plane.?));
            var flat: ?*c.IMF2DBuffer = null;
            if (!win32.failed(plane.?.lpVtbl.*.QueryInterface.?(
                plane.?,
                &c.IID_IMF2DBuffer,
                @ptrCast(&flat),
            ))) {
                defer _ = flat.?.lpVtbl.*.Release.?(@ptrCast(flat.?));
                var scan0: [*c]u8 = undefined;
                var pitch: c_long = 0;
                if (!win32.failed(flat.?.lpVtbl.*.Lock2D.?(flat.?, &scan0, &pitch))) {
                    defer _ = flat.?.lpVtbl.*.Unlock2D.?(flat.?);
                    self.route = 1;
                    self.copyRows(scan0, pitch);
                    self.at_ns = @as(u64, @intCast(@max(timestamp, 0))) * 100;
                    self.ready = true;
                    return true;
                }
            }
        }

        var buffer: ?*c.IMFMediaBuffer = null;
        if (win32.failed(got.lpVtbl.*.ConvertToContiguousBuffer.?(got, &buffer))) return Error.DecodeFailed;
        defer _ = buffer.?.lpVtbl.*.Release.?(@ptrCast(buffer.?));

        var two_d: ?*c.IMF2DBuffer = null;
        if (!win32.failed(buffer.?.lpVtbl.*.QueryInterface.?(
            buffer.?,
            &c.IID_IMF2DBuffer,
            @ptrCast(&two_d),
        ))) {
            defer _ = two_d.?.lpVtbl.*.Release.?(@ptrCast(two_d.?));
            var scan0: [*c]u8 = undefined;
            var pitch: c_long = 0;
            if (!win32.failed(two_d.?.lpVtbl.*.Lock2D.?(two_d.?, &scan0, &pitch))) {
                defer _ = two_d.?.lpVtbl.*.Unlock2D.?(two_d.?);
                self.route = 2;
                self.copyRows(scan0, pitch);
                self.at_ns = @as(u64, @intCast(@max(timestamp, 0))) * 100;
                self.ready = true;
                return true;
            }
        }

        var data: [*c]u8 = undefined;
        var length: c.DWORD = 0;
        if (win32.failed(buffer.?.lpVtbl.*.Lock.?(buffer.?, &data, null, &length))) return Error.DecodeFailed;
        defer _ = buffer.?.lpVtbl.*.Unlock.?(buffer.?);
        self.last_length = @intCast(length);

        // Обычный путь: двумерный доступ Media Foundation не даёт, и шаг
        // приходится выводить из длины буфера. Правило вынесено отдельно
        // и проверено на настоящих замерах.
        const guessed = strideFor(self.width, self.height, @intCast(length));
        self.route = 3;
        self.copyRows(data, @intCast(guessed));

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

pub const Size = struct { width: u32 = 0, height: u32 = 0 };

/// Какой кадр лежит в файле на самом деле.
fn nativeSize(r: *c.IMFSourceReader) Size {
    var native: ?*c.IMFMediaType = null;
    if (win32.failed(r.lpVtbl.*.GetNativeMediaType.?(r, c.MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &native))) {
        return .{};
    }
    defer _ = native.?.lpVtbl.*.Release.?(@ptrCast(native.?));
    var packed_size: u64 = 0;
    _ = native.?.lpVtbl.*.GetUINT64.?(native.?, &c.MF_MT_FRAME_SIZE, &packed_size);
    return .{
        .width = @intCast(packed_size >> 32),
        .height = @intCast(packed_size & 0xFFFF_FFFF),
    };
}

/// Ужать размер кадра под пределы, сохранив соотношение сторон.
///
/// Только вниз: растягивать кадр ради показа незачем — это работа впустую
/// и потеря резкости. Чётные числа: кодеки и преобразователи не любят
/// нечётных сторон.
pub fn fitDown(width: u32, height: u32, max_width: u32, max_height: u32) Size {
    if (width == 0 or height == 0 or max_width == 0 or max_height == 0) return .{};
    if (width <= max_width and height <= max_height) return .{ .width = width, .height = height };

    const by_width = @as(u64, max_width) * 1000 / width;
    const by_height = @as(u64, max_height) * 1000 / height;
    const scale = @min(by_width, by_height);

    var out_w: u32 = @intCast(@as(u64, width) * scale / 1000);
    var out_h: u32 = @intCast(@as(u64, height) * scale / 1000);
    out_w = @max(out_w & ~@as(u32, 1), 2);
    out_h = @max(out_h & ~@as(u32, 1), 2);
    return .{ .width = out_w, .height = out_h };
}

/// Шаг строки, выведенный из длины буфера.
///
/// Media Foundation хранит кадр выровненным: у кадра 642 точки в ширину
/// буфер держит 656 точек, у кадра 1080 строк — 1088 строк. Ни размер
/// из типа, ни шаг из типа об этом не говорят, а двумерный доступ к буферу
/// не даётся. Поэтому шаг выводим: перебираем разумные выравнивания и берём
/// первое, на которое длина делится нацело и строк выходит не меньше высоты.
///
/// Ошибка здесь не роняет программу, а тихо портит картинку: каждая
/// следующая строка уезжает вбок, и кадр расползается косыми полосами.
pub fn strideFor(width: u32, height: u32, length: usize) usize {
    const row_bytes = @as(usize, width) * 4;
    if (width == 0 or height == 0 or length == 0) return row_bytes;

    // Без выравнивания — самый частый случай, проверяем первым.
    if (length == row_bytes * height) return row_bytes;

    // Выравнивания идут от мелкого к крупному: берём наименьшее подходящее,
    // иначе на длинном буфере подойдёт заведомо слишком широкий шаг.
    const alignments = [_]u32{ 4, 8, 16, 32, 64, 128 };
    for (alignments) |step| {
        const aligned_w = (width + step - 1) / step * step;
        const stride = @as(usize, aligned_w) * 4;
        if (stride < row_bytes) continue;
        if (length % stride != 0) continue;
        if (length / stride < height) continue;
        return stride;
    }

    // Ничего не подошло: пусть будет хотя бы ширина. Косые полосы лучше,
    // чем чтение за границей буфера.
    return row_bytes;
}

/// Открыть GIF своим разбором.
///
/// Читаем файл целиком и разбираем сразу: в GIF нет оглавления, и узнать,
/// где какой кадр, можно только пройдя его до конца. Зато после этого показ
/// любого кадра — просто копирование, без перемотки и без декодера.
fn openGif(allocator: std.mem.Allocator, path: []const u8) !Player {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    const data = try std.Io.Dir.cwd().readFileAlloc(
        threaded.io(),
        path,
        allocator,
        .limited(1 << 28),
    );
    defer allocator.free(data);
    if (!gif_mod.looksLikeGif(data)) return error.NotGif;

    var img = try gif_mod.decode(allocator, data);
    errdefer img.deinit(allocator);

    const pixels = try allocator.alloc(u8, @as(usize, img.width) * img.height * 4);
    @memset(pixels, 0);

    return .{
        .allocator = allocator,
        .reader = null,
        .gif = img,
        .width = img.width,
        .height = img.height,
        .duration_ns = img.totalNs(),
        .pixels = pixels,
        .stride = @as(usize, img.width) * 4,
        // Наш разбор укладывает строки сверху вниз — как и всё остальное
        // после `copyRows`.
        .bottom_up = false,
    };
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

test "шаг строки может быть больше ширины" {
    // Ширина 1922 точки — не кратна восьми, и Media Foundation выровняет
    // строку. Копировать такой кадр одним куском значит сдвинуть каждую
    // следующую строку; так кадр и расползался полосами.
    const width: usize = 1922;
    const height: usize = 4;
    const row_bytes = width * 4;
    const src_stride = row_bytes + 8; // выравнивание

    var src: [4 * (1922 * 4 + 8)]u8 = undefined;
    for (0..height) |row| {
        for (0..src_stride) |i| {
            src[row * src_stride + i] = @intCast(row + 1);
        }
    }

    var dst: [1922 * 4 * 4]u8 = undefined;
    for (0..height) |row| {
        const from = row * src_stride;
        const to = row * row_bytes;
        @memcpy(dst[to .. to + row_bytes], src[from .. from + row_bytes]);
    }

    // Каждая строка целиком своего цвета — значит сдвига нет.
    for (0..height) |row| {
        for (0..row_bytes) |i| {
            try std.testing.expectEqual(@as(u8, @intCast(row + 1)), dst[row * row_bytes + i]);
        }
    }
}

test "шаг выводится из длины буфера: замеры с настоящих файлов" {
    // Кадр с выровненной шириной: буфер 2624 * 368 у кадра 642x362.
    try std.testing.expectEqual(@as(usize, 2624), strideFor(642, 362, 965_632));
    // Кадр, у которого ширина уже выровнена: 7680 * 1088 у 1920x1080.
    try std.testing.expectEqual(@as(usize, 7680), strideFor(1920, 1080, 8_355_840));
}

test "ровный буфер без выравнивания узнаётся сразу" {
    try std.testing.expectEqual(@as(usize, 2560), strideFor(640, 480, 640 * 4 * 480));
}

test "шаг никогда не меньше строки" {
    // Иначе копирование залезет в соседнюю строку.
    for ([_]u32{ 1, 3, 17, 642, 1921 }) |w| {
        const stride = strideFor(w, 100, 12345);
        try std.testing.expect(stride >= @as(usize, w) * 4);
    }
}

test "пустые числа не роняют и не делят на ноль" {
    try std.testing.expectEqual(@as(usize, 0), strideFor(0, 100, 1000));
    try std.testing.expectEqual(@as(usize, 400), strideFor(100, 0, 1000));
    try std.testing.expectEqual(@as(usize, 400), strideFor(100, 10, 0));
}

test "буфер короче кадра не даёт шага больше строки" {
    // Если длина явно мала, лучше честная ширина, чем чтение за границей.
    try std.testing.expectEqual(@as(usize, 2568), strideFor(642, 362, 1000));
}

test "кадр ужимается под окно, сохраняя соотношение сторон" {
    // 4K в окошко 960 по ширине.
    const got = fitDown(3840, 2160, 960, 960);
    try std.testing.expectEqual(@as(u32, 960), got.width);
    try std.testing.expectEqual(@as(u32, 540), got.height);
}

test "маленький кадр не растягивается" {
    // Растягивать ради показа незачем: работа впустую и потеря резкости.
    const got = fitDown(640, 480, 1920, 1080);
    try std.testing.expectEqual(@as(u32, 640), got.width);
    try std.testing.expectEqual(@as(u32, 480), got.height);
}

test "высокий кадр ужимается по высоте" {
    const got = fitDown(1080, 1920, 960, 540);
    try std.testing.expect(got.height <= 540);
    try std.testing.expect(got.width <= 960);
    // Соотношение сторон сохранилось с точностью до чётности.
    const want_w = 540 * 1080 / 1920;
    try std.testing.expect(@abs(@as(i64, got.width) - @as(i64, want_w)) <= 2);
}

test "стороны выходят чётными" {
    // Кодеки и преобразователи не любят нечётных сторон.
    for ([_][2]u32{ .{ 1999, 1111 }, .{ 3841, 2161 }, .{ 777, 333 } }) |pair| {
        const got = fitDown(pair[0], pair[1], 500, 500);
        try std.testing.expectEqual(@as(u32, 0), got.width % 2);
        try std.testing.expectEqual(@as(u32, 0), got.height % 2);
        try std.testing.expect(got.width >= 2 and got.height >= 2);
    }
}

test "нулевые размеры не роняют счёт" {
    try std.testing.expectEqual(@as(u32, 0), fitDown(0, 100, 50, 50).width);
    try std.testing.expectEqual(@as(u32, 0), fitDown(100, 0, 50, 50).width);
    try std.testing.expectEqual(@as(u32, 0), fitDown(100, 100, 0, 50).width);
}

test "ужатый кадр заметно меньше исходного" {
    // Ради этого всё и затевалось: 4K весит 33 МБ, а показываем мы его
    // в окошке, где помещается меньше миллиона точек.
    const big = @as(u64, 3840) * 2160;
    const got = fitDown(3840, 2160, 960, 540);
    const small = @as(u64, got.width) * got.height;
    try std.testing.expect(small * 10 < big);
}
