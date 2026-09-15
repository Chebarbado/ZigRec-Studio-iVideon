//! Сквозная самопроверка захвата: нарисовали — сняли — сверили.
//!
//! Задачи #12 и #13. Смысл: проверить захват без человека и без «на глаз плавно».
//! Программа сама создаёт маленькое окно в левом верхнем углу, рисует в нём кадр
//! тестового стенда с двоичным таймкодом, снимает экран через DXGI и читает
//! номер кадра обратно из снятых пикселей.
//!
//! Так проверяется именно то, что важно: кадры доходят, доходят по порядку,
//! и то, что показали, совпадает с тем, что сняли. Статичный рабочий стол для
//! такой проверки бесполезен — там просто нечему меняться, и захват честно
//! молчит. Поэтому источник изменений создаём сами.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;
const capture = @import("../capture/capture.zig");
const testbench = @import("testbench.zig");

pub const Options = struct {
    /// Сколько кадров показать.
    frames: u32 = 240,
    /// Ожидание нового кадра, миллисекунды.
    timeout_ms: u32 = 200,
    /// Индекс монитора.
    output: u32 = 0,
    /// Каким путём снимать.
    backend: capture.Backend = .auto,
};

pub const Report = struct {
    shown: u32 = 0,
    captured: u32 = 0,
    /// Кадров, в которых номер вообще удалось прочитать.
    ///
    /// Это и есть главный вопрос к захвату: пришло ли с экрана то, что мы
    /// туда нарисовали. Нечитаемый номер означает, что снято не наше окно
    /// или снято испорченным.
    read: u32 = 0,
    /// Кадров, где снятый номер совпал с показанным В ТОЙ ЖЕ итерации.
    ///
    /// Число любопытное, но судить по нему нельзя: между тем, как мы
    /// нарисовали кадр, и тем, как рабочий стол его показал, проходит
    /// время. На занятой машине экран отстаёт на кадр-другой, и совпадений
    /// почти не остаётся — при совершенно исправном захвате.
    matched: u32 = 0,
    /// На сколько кадров экран отставал от рисования, в среднем.
    lag: f64 = 0,
    tally: testbench.Tally = .{},
    stats: capture.Stats = .{},
    width: u32 = 0,
    height: u32 = 0,
    /// Каким путём кадры в итоге снимались.
    backend: capture.Backend = .auto,

    /// Прогон засчитан, если кадры доходят, читаются и идут по порядку.
    ///
    /// **Судим не по совпадению с той же итерацией.** Раньше требовалось,
    /// чтобы снятый кадр нёс ровно тот номер, который только что нарисован,
    /// — а это гонка с рабочим столом, которую на занятой машине не выиграть.
    /// Стенд ругался на исправный захват, и это хуже, чем не проверять вовсе:
    /// на крик, который слышишь каждый день, перестают оборачиваться.
    ///
    /// Спрашиваем то, что и правда важно:
    ///
    ///  * кадры доходят — снято не меньше четверти показанного;
    ///  * номера читаются — значит, снято НАШЕ окно и снято целым;
    ///  * порядок в целом сохранён — редкая перестановка не в счёт;
    ///  * один и тот же кадр не приходит снова и снова.
    ///
    /// **Пропуски в номерах поломкой не считаются.** Мы рисуем быстрее,
    /// чем рабочий стол успевает показывать, и часть нарисованного он
    /// пропускает — это его право и наша же заслуга. Захват при этом
    /// отдаёт ровно то, что было на экране.
    ///
    /// Отставание экрана от рисования измеряется и печатается: это тоже
    /// свойство машины, а не поломка, и знать его полезно.
    pub fn ok(self: Report) bool {
        if (self.captured == 0 or self.read == 0) return false;
        if (self.captured < self.shown / 4) return false;
        // Нечитаемый номер — настоящая беда: значит, с экрана пришло не то.
        if (self.read * 10 < self.captured * 8) return false;
        // Одна перестановка на десяток — работа композитора, а не поломка;
        // а вот сплошная каша означает, что кадры идут не оттуда.
        if (self.tally.out_of_order * 10 > self.read) return false;
        // Один и тот же кадр снова и снова — признак того, что экран замер,
        // а мы этого не заметили.
        if (self.tally.duplicated * 2 > self.read) return false;
        return true;
    }
};

const class_name = "ZigRecSmoke";

/// `IDC_ARROW` объявлен через макрос `MAKEINTRESOURCE`, а его translate-c
/// не переводит. Значение стандартное и не меняется с девяностых.
const idc_arrow: c.LPCSTR = @ptrFromInt(32512);

fn wndProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    return c.DefWindowProcA(hwnd, msg, wp, lp);
}

/// Прогнать проверку. Возвращает отчёт; печать — на вызывающей стороне.
pub fn run(allocator: std.mem.Allocator, opt: Options) !Report {
    if (builtin.os.tag != .windows) return error.Unsupported;

    // Без этого Windows отдаёт растянутые координаты при масштабе экрана
    // больше 100 %, окно уезжает, и снятые пиксели оказываются не наши.
    _ = c.SetProcessDPIAware();

    const hinst: c.HINSTANCE = @ptrCast(c.GetModuleHandleA(null));
    var wc = std.mem.zeroes(c.WNDCLASSEXA);
    wc.cbSize = @sizeOf(c.WNDCLASSEXA);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinst;
    wc.lpszClassName = class_name;
    wc.hCursor = c.LoadCursorA(null, idc_arrow);
    if (c.RegisterClassExA(&wc) == 0) return error.WindowFailed;
    defer _ = c.UnregisterClassA(class_name, hinst);

    const w: i32 = testbench.min_width;
    const h: i32 = testbench.min_height;
    const hwnd = c.CreateWindowExA(
        c.WS_EX_TOPMOST | c.WS_EX_TOOLWINDOW | c.WS_EX_NOACTIVATE,
        class_name,
        class_name,
        c.WS_POPUP,
        0,
        0,
        w,
        h,
        null,
        null,
        hinst,
        null,
    ) orelse return error.WindowFailed;
    defer _ = c.DestroyWindow(hwnd);
    _ = c.ShowWindow(hwnd, c.SW_SHOWNOACTIVATE);
    _ = c.UpdateWindow(hwnd);

    const screen = try testbench.Screen.init(@intCast(w), @intCast(h), 60);
    const buf = try allocator.alloc(u8, screen.frameBytes());
    defer allocator.free(buf);

    var bmi = std.mem.zeroes(c.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    // Отрицательная высота — строки сверху вниз, как у нас и у DXGI.
    bmi.bmiHeader.biHeight = -h;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = c.BI_RGB;

    var dup = try capture.Capturer.open(allocator, .{
        .backend = opt.backend,
        .output = opt.output,
        // DXGI на неподвижном экране молчит законно, поэтому на понижение
        // даём столько же, сколько на весь показ кадров, но не меньше секунды.
        .downgrade_after_ms = @max(1000, opt.frames * 4),
    });
    defer dup.deinit();

    const size = dup.frameSize();
    var report = Report{ .width = size.width, .height = size.height };
    var seen = try std.ArrayList(u32).initCapacity(allocator, opt.frames);
    defer seen.deinit(allocator);

    const started = win32.nowNs();
    var lag_sum: u64 = 0;
    var index: u32 = 1; // с единицы: нулевой кадр не отличить от чёрного экрана
    while (index <= opt.frames) : (index += 1) {
        pumpMessages();

        try screen.render(buf, index);
        const dc = c.GetDC(hwnd) orelse return error.WindowFailed;
        _ = c.StretchDIBits(dc, 0, 0, w, h, 0, 0, w, h, buf.ptr, &bmi, c.DIB_RGB_COLORS, c.SRCCOPY);
        _ = c.ReleaseDC(hwnd, dc);
        _ = c.GdiFlush();
        report.shown += 1;

        const frame = try dup.next(opt.timeout_ms) orelse continue;
        report.captured += 1;
        const got = testbench.readIndex(frame.pixels, testbench.min_width, frame.stride) catch {
            dup.release();
            continue;
        };
        report.read += 1;
        if (got == index) report.matched += 1;
        // Отставание считаем только назад: вперёд экран уйти не может,
        // а прочитанный «будущий» номер означал бы мусор, а не опережение.
        if (index > got) lag_sum += index - got;
        try seen.append(allocator, got);
        dup.release();
    }

    report.stats = dup.stats();
    report.backend = dup.backend();
    report.stats.elapsed_ns = win32.nowNs() - started;
    report.tally = testbench.tally(seen.items);
    report.lag = if (report.read > 0)
        @as(f64, @floatFromInt(lag_sum)) / @as(f64, @floatFromInt(report.read))
    else
        0;
    return report;
}

/// Только рисовать, не снимать: источник быстрых изменений на экране.
///
/// Нужен, чтобы измерить, сколько кадров в секунду вытягивает наш захват.
/// На неподвижном экране DXGI не отдаёт ничего — и это не медленность
/// программы, а отсутствие кадров. Чтобы отличить одно от другого, экран
/// должен меняться заведомо быстрее, чем мы снимаем.
pub fn animateOnly(allocator: std.mem.Allocator, seconds: u32, width: u32, height: u32) !u64 {
    if (builtin.os.tag != .windows) return error.Unsupported;
    _ = c.SetProcessDPIAware();

    const hinst: c.HINSTANCE = @ptrCast(c.GetModuleHandleA(null));
    var wc = std.mem.zeroes(c.WNDCLASSEXA);
    wc.cbSize = @sizeOf(c.WNDCLASSEXA);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinst;
    wc.lpszClassName = "ZigRecAnimator";
    wc.hCursor = c.LoadCursorA(null, idc_arrow);
    if (c.RegisterClassExA(&wc) == 0) return error.WindowFailed;
    defer _ = c.UnregisterClassA("ZigRecAnimator", hinst);

    const w: i32 = @intCast(width);
    const h: i32 = @intCast(height);
    const hwnd = c.CreateWindowExA(
        c.WS_EX_TOPMOST | c.WS_EX_TOOLWINDOW | c.WS_EX_NOACTIVATE,
        "ZigRecAnimator",
        "ZigRecAnimator",
        c.WS_POPUP,
        0,
        0,
        w,
        h,
        null,
        null,
        hinst,
        null,
    ) orelse return error.WindowFailed;
    defer _ = c.DestroyWindow(hwnd);
    _ = c.ShowWindow(hwnd, c.SW_SHOWNOACTIVATE);

    const screen = try testbench.Screen.init(@max(width, testbench.min_width), height, 60);
    const buf = try allocator.alloc(u8, screen.frameBytes());
    defer allocator.free(buf);

    var bmi = std.mem.zeroes(c.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = @intCast(screen.width);
    bmi.bmiHeader.biHeight = -@as(i32, @intCast(screen.height));
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = c.BI_RGB;

    const dc = c.GetDC(hwnd) orelse return error.WindowFailed;
    defer _ = c.ReleaseDC(hwnd, dc);

    const until = win32.nowNs() + @as(u64, seconds) * std.time.ns_per_s;
    var painted: u64 = 0;
    var index: u32 = 1;
    while (win32.nowNs() < until) : (index +%= 1) {
        pumpMessages();
        try screen.render(buf, index);
        _ = c.StretchDIBits(dc, 0, 0, w, h, 0, 0, @intCast(screen.width), @intCast(screen.height), buf.ptr, &bmi, c.DIB_RGB_COLORS, c.SRCCOPY);
        _ = c.GdiFlush();
        painted += 1;
    }
    return painted;
}

fn pumpMessages() void {
    var msg: c.MSG = undefined;
    while (c.PeekMessageA(&msg, null, 0, 0, c.PM_REMOVE) != 0) {
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageA(&msg);
    }
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;

test "исправный захват засчитывается даже при отставании экрана" {
    // Ровно тот случай, на котором стенд раньше кричал: кадры дошли,
    // номера читаются и идут по порядку, а совпадений с той же итерацией
    // почти нет — экран отстаёт.
    const r = Report{
        .shown = 60,
        .captured = 59,
        .read = 57,
        .matched = 7,
        .tally = .{ .captured = 57, .dropped = 4, .duplicated = 4, .out_of_order = 0 },
    };
    try testing.expect(r.ok());
}

test "нечитаемые номера — это провал" {
    // Кадры идут, но в них не наше окно: снято не то.
    const r = Report{
        .shown = 60,
        .captured = 60,
        .read = 3,
        .matched = 3,
        .tally = .{ .captured = 3 },
    };
    try testing.expect(!r.ok());
}

test "редкая перестановка кадров не считается поломкой" {
    // Композитор изредка показывает кадр не по порядку. Это не повод
    // объявлять захват сломанным.
    const rare = Report{
        .shown = 60,
        .captured = 59,
        .read = 57,
        .matched = 50,
        .tally = .{ .captured = 57, .out_of_order = 1 },
    };
    try testing.expect(rare.ok());

    // А сплошная каша означает, что кадры идут не оттуда.
    const mess = Report{
        .shown = 60,
        .captured = 59,
        .read = 57,
        .matched = 5,
        .tally = .{ .captured = 57, .out_of_order = 20 },
    };
    try testing.expect(!mess.ok());
}

test "пропуски в номерах — это про экран, а не про захват" {
    // Рисуем быстрее, чем рабочий стол показывает: он пропускает часть
    // нарисованного, и это его право.
    const r = Report{
        .shown = 60,
        .captured = 33,
        .read = 33,
        .matched = 26,
        .tally = .{ .captured = 33, .dropped = 25 },
    };
    try testing.expect(r.ok());
}

test "один и тот же кадр снова и снова — это провал" {
    // Значит, экран замер, а мы этого не заметили.
    const r = Report{
        .shown = 60,
        .captured = 59,
        .read = 57,
        .matched = 2,
        .tally = .{ .captured = 57, .duplicated = 50 },
    };
    try testing.expect(!r.ok());
}

test "слишком мало кадров — это провал" {
    const r = Report{ .shown = 60, .captured = 10, .read = 10, .tally = .{ .captured = 10 } };
    try testing.expect(!r.ok());
}

test "пустой прогон не засчитывается" {
    try testing.expect(!(Report{}).ok());
    try testing.expect(!(Report{ .shown = 60, .captured = 0 }).ok());
}

test "тот самый прогон, на котором стенд кричал зря" {
    // Числа взяты с настоящего прогона на занятой машине: 60 нарисовано,
    // 33 снято, все номера прочитаны, пропусков 25, перестановка одна.
    // Захват исправен — и стенд обязан это сказать.
    const real = Report{
        .shown = 60,
        .captured = 33,
        .read = 33,
        .matched = 26,
        .lag = 0.2,
        .tally = .{ .captured = 33, .dropped = 25, .duplicated = 1, .out_of_order = 1 },
    };
    try testing.expect(real.ok());
}
