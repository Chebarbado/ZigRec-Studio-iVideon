//! Выбор источника: монитор, область, окно.
//!
//! Задача #14. Захват умеет снимать экран целиком, а человеку почти всегда
//! нужен кусок: одно окно, одна панель, один угол. Здесь превращаем «что
//! снимаем» в прямоугольник в пикселях экрана.
//!
//! Окно отслеживается на каждом кадре: его двигают и разворачивают прямо во
//! время записи, и область должна ехать следом.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;
const types = @import("capture_types.zig");

pub const Rect = types.Rect;

pub const Error = error{
    /// Окна с таким заголовком нет.
    WindowNotFound,
    /// Окно свёрнуто: снимать нечего.
    WindowMinimized,
    /// Монитора с таким номером нет.
    NoSuchMonitor,
    Unsupported,
    OutOfMemory,
};

/// Что снимаем.
pub const Source = union(enum) {
    /// Монитор целиком.
    monitor: u32,
    /// Прямоугольник в координатах рабочего стола.
    area: Rect,
    /// Окно, найденное по части заголовка. Область едет за окном.
    window: c.HWND,

    pub fn isWindow(self: Source) bool {
        return self == .window;
    }
};

pub const Monitor = struct {
    index: u32,
    area: Rect,
    primary: bool,
    /// Сколько раз в секунду экран обновляется.
    ///
    /// Это потолок для числа **разных** кадров: захват отдаёт кадр тогда,
    /// когда рабочий стол его показал. Просить больше можно, но взяться
    /// им неоткуда — в файле окажутся повторы.
    refresh_hz: u32 = 0,
};

/// Разобрать `x,y,ш,в`. Отдельная функция, потому что ошибиться тут легко,
/// а ошибка приводит к записи не того куска экрана.
pub fn parseArea(text: []const u8) ?Rect {
    var it = std.mem.splitScalar(u8, text, ',');
    var v: [4]i64 = undefined;
    var n: usize = 0;
    while (it.next()) |part| {
        if (n == 4) return null;
        const t = std.mem.trim(u8, part, " ");
        v[n] = std.fmt.parseInt(i64, t, 10) catch return null;
        n += 1;
    }
    if (n != 4) return null;
    if (v[2] <= 0 or v[3] <= 0) return null;
    if (v[2] > 65535 or v[3] > 65535) return null;
    return Rect{
        .x = @intCast(v[0]),
        .y = @intCast(v[1]),
        .width = @intCast(v[2]),
        .height = @intCast(v[3]),
    };
}

/// Размер всего рабочего стола (все мониторы вместе).
pub fn desktopArea() Rect {
    if (builtin.os.tag != .windows) return .{ .width = 0, .height = 0 };
    _ = c.SetProcessDPIAware();
    return .{
        .x = c.GetSystemMetrics(c.SM_XVIRTUALSCREEN),
        .y = c.GetSystemMetrics(c.SM_YVIRTUALSCREEN),
        .width = @intCast(c.GetSystemMetrics(c.SM_CXVIRTUALSCREEN)),
        .height = @intCast(c.GetSystemMetrics(c.SM_CYVIRTUALSCREEN)),
    };
}

var monitor_list: ?*std.ArrayList(Monitor) = null;
var monitor_alloc: std.mem.Allocator = undefined;

fn monitorProc(h: c.HMONITOR, dc: c.HDC, r: [*c]c.RECT, l: c.LPARAM) callconv(.winapi) c.BOOL {
    _ = dc;
    _ = l;
    var info = std.mem.zeroes(c.MONITORINFO);
    info.cbSize = @sizeOf(c.MONITORINFO);
    _ = c.GetMonitorInfoA(h, &info);
    const list = monitor_list orelse return 1;
    const hz = refreshOf(h);
    const index: u32 = @intCast(list.items.len);
    list.append(monitor_alloc, .{
        .index = index,
        .area = .{
            .x = r.*.left,
            .y = r.*.top,
            .width = @intCast(r.*.right - r.*.left),
            .height = @intCast(r.*.bottom - r.*.top),
        },
        .primary = (info.dwFlags & c.MONITORINFOF_PRIMARY) != 0,
        .refresh_hz = hz,
    }) catch {};
    return 1;
}

/// Частота обновления монитора.
///
/// Спрашиваем у самого устройства, а не у первого попавшегося: у двух
/// мониторов частоты бывают разные, и брать чужую — значит обещать
/// не то число.
fn refreshOf(h: c.HMONITOR) u32 {
    var info = std.mem.zeroes(c.MONITORINFOEXW);
    info.unnamed_0.cbSize = @sizeOf(c.MONITORINFOEXW);
    if (c.GetMonitorInfoW(h, @ptrCast(&info)) == 0) return 0;

    var mode = std.mem.zeroes(c.DEVMODEW);
    mode.dmSize = @sizeOf(c.DEVMODEW);
    // ENUM_CURRENT_SETTINGS = -1: то, что стоит сейчас, а не из списка.
    if (c.EnumDisplaySettingsW(@ptrCast(&info.szDevice), @bitCast(@as(i32, -1)), &mode) == 0) return 0;
    return mode.dmDisplayFrequency;
}

/// Перечислить мониторы. Порядок тот же, что у `EnumDisplayMonitors`, и он
/// совпадает с нумерацией, которую человек видит в настройках экрана.
pub fn listMonitors(allocator: std.mem.Allocator) Error![]Monitor {
    if (builtin.os.tag != .windows) return Error.Unsupported;
    _ = c.SetProcessDPIAware();
    var list: std.ArrayList(Monitor) = .empty;
    monitor_list = &list;
    monitor_alloc = allocator;
    defer monitor_list = null;
    _ = c.EnumDisplayMonitors(null, null, monitorProc, 0);
    return list.toOwnedSlice(allocator) catch Error.OutOfMemory;
}

// ------------------------------------------------------- список окон

/// Сколько окон показываем. Больше сорока — это уже не список, а свалка,
/// и нужное в нём ищут дольше, чем набирают часть заголовка руками.
pub const max_windows = 40;

/// Самое маленькое окно, которое имеет смысл предлагать для записи.
///
/// Мельче — это всплывающие подсказки, пустые окна служб и невидимые
/// окна-помощники, которых на рабочем столе десятки. Показать их значит
/// утопить в них те три окна, которые человек ищет.
pub const min_window_side: u32 = 100;

/// Одно окно в списке.
pub const WindowInfo = struct {
    /// Само окно. Держим указателем, а не числом.
    ///
    /// Обратное превращение числа в указатель здесь невозможно: указатели
    /// окон Windows не выровнены, и Zig на проверке выравнивания честно
    /// падает. Число нужно только наружу — в ответ сервера, — и обратно
    /// оно не возвращается: снаружи окно называют заголовком, а не адресом.
    handle: c.HWND = null,
    title: [256]u8 = @splat(0),
    title_len: usize = 0,
    area: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    /// Окно свёрнуто. Размер тогда взят из того, каким оно развернётся.
    ///
    /// Свёрнутое окно в списке нужно: человек ищет в нём «моё окно»,
    /// а не «окно, которое сейчас на экране». Пропускать свёрнутые молча —
    /// значит показать пять окон из тридцати и не объяснить, куда делись
    /// остальные.
    minimized: bool = false,

    pub fn name(self: *const WindowInfo) []const u8 {
        return self.title[0..self.title_len];
    }

    /// Окно числом — для ответа наружу.
    pub fn number(self: *const WindowInfo) usize {
        return @intFromPtr(self.handle);
    }
};

/// Стоит ли показывать такое окно в списке.
///
/// Отдельным чистым правилом: это единственное место, где решается,
/// что человек увидит, а чего не увидит вовсе, — и ошибка здесь выглядит
/// как «моего окна нет в списке», без всякого объяснения.
pub fn worthShowing(title_len: usize, visible: bool, area: Rect) bool {
    if (!visible) return false;
    if (title_len == 0) return false;
    return area.width >= min_window_side and area.height >= min_window_side;
}

/// Каким окно станет, если его развернуть.
///
/// У свёрнутого окна `DwmGetWindowAttribute` отдаёт координаты где-то
/// за краем экрана, и по ним нельзя ни показать размер, ни решить, стоит
/// ли окно показывать. Windows помнит, каким оно было до сворачивания, —
/// это и спрашиваем.
fn restoredArea(hwnd: c.HWND) Error!Rect {
    var wp = std.mem.zeroes(c.WINDOWPLACEMENT);
    wp.length = @sizeOf(c.WINDOWPLACEMENT);
    if (c.GetWindowPlacement(hwnd, &wp) == 0) return Error.WindowNotFound;
    const r = wp.rcNormalPosition;
    if (r.right <= r.left or r.bottom <= r.top) return Error.WindowNotFound;
    return .{
        .x = r.left,
        .y = r.top,
        .width = @intCast(r.right - r.left),
        .height = @intCast(r.bottom - r.top),
    };
}

/// Развернуть свёрнутое окно.
///
/// Снимать свёрнутое окно нечего, поэтому выбор такого окна значит
/// «разверни и снимай»: спрашивать об этом отдельно — лишний шаг там,
/// где другого ответа всё равно нет.
pub fn restoreWindow(hwnd: c.HWND) void {
    if (builtin.os.tag != .windows) return;
    if (c.IsIconic(hwnd) == 0) return;
    _ = c.ShowWindow(hwnd, c.SW_RESTORE);
}

/// Видимые окна с заголовками, сверху вниз по порядку перекрытия.
///
/// Порядок не случаен: сверху лежит то, на что человек смотрит сейчас,
/// и его окно чаще всего оказывается первым или вторым в списке.
pub fn listWindows(out: []WindowInfo) []const WindowInfo {
    if (builtin.os.tag != .windows) return out[0..0];
    var count: usize = 0;
    var hwnd = c.GetTopWindow(null);
    while (hwnd != null and count < out.len) : (hwnd = c.GetWindow(hwnd, c.GW_HWNDNEXT)) {
        var title_buf: [1024]u8 = undefined;
        const title = windowTitle(hwnd, &title_buf);

        // У свёрнутого окна размеры не спросишь — берём те, какими оно
        // развернётся. Иначе список показывает пять окон из тридцати
        // и не объясняет, куда делись остальные.
        const folded = c.IsIconic(hwnd) != 0;
        const area = (if (folded) restoredArea(hwnd) else windowArea(hwnd)) catch continue;
        if (!worthShowing(title.len, c.IsWindowVisible(hwnd) != 0, area)) continue;

        var item = WindowInfo{ .handle = hwnd, .area = area, .minimized = folded };
        const n = fitTitle(title, item.title.len);
        @memcpy(item.title[0..n], title[0..n]);
        item.title_len = n;
        out[count] = item;
        count += 1;
    }
    openFirst(out[0..count]);
    return out[0..count];
}

/// Сначала открытые окна, потом свёрнутые.
///
/// Свёрнутых обычно больше, чем открытых, и без этого нужное окно тонет
/// среди тех, которых сейчас на экране нет. Внутри каждой половины порядок
/// прежний — по перекрытию, сверху вниз: наверху то, на что человек
/// смотрит сейчас, и его окно оказывается первым или вторым.
pub fn openFirst(items: []WindowInfo) void {
    var put: usize = 0;
    var i: usize = 0;
    // Устойчивая перестановка: вынимаем открытые по очереди и сдвигаем
    // всё, что между. Сортировка сравнением сбила бы порядок по перекрытию,
    // а он здесь и есть главное.
    while (i < items.len) : (i += 1) {
        if (items[i].minimized) continue;
        const moved = items[i];
        var j = i;
        while (j > put) : (j -= 1) items[j] = items[j - 1];
        items[put] = moved;
        put += 1;
    }
}

/// Обрезать заголовок по букве, а не по байту: русская буква занимает
/// два байта, и обрезка ровно по границе места оставила бы половину буквы.
fn fitTitle(text: []const u8, room: usize) usize {
    if (text.len <= room) return text.len;
    var n = room;
    while (n > 0 and (text[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

/// Живо ли ещё это окно.
///
/// Окно могло закрыться между тем, как список показали, и тем, как в нём
/// выбрали строку, — и писать в пустоту вместо закрытого окна нельзя.
pub fn stillThere(hwnd: c.HWND) bool {
    if (builtin.os.tag != .windows) return false;
    if (hwnd == null) return false;
    return c.IsWindow(hwnd) != 0;
}

/// Заголовок окна в UTF-8. Только широкая версия: `GetWindowTextA` отдаёт
/// текст в кодировке системы, и русские заголовки превращаются в мусор.
///
/// `InternalGetWindowText`, а не `GetWindowTextW` (#101): тот для окна своего
/// процесса шлёт `WM_GETTEXT` потоку окна и ждёт. Отсюда спрашивает и поток
/// записи — а поток окна на «Стоп» ждёт его в `join`. Выходило зависание
/// намертво; подробности — у `event_tap.titleOf`.
pub fn windowTitle(hwnd: c.HWND, out: []u8) []const u8 {
    if (builtin.os.tag != .windows) return out[0..0];
    var wide: [512]u16 = undefined;
    const n = c.InternalGetWindowText(hwnd, &wide, wide.len);
    if (n <= 0) return out[0..0];
    const len = std.unicode.utf16LeToUtf8(out, wide[0..@intCast(n)]) catch return out[0..0];
    return out[0..len];
}

var find_needle: [256]u16 = undefined;
var find_needle_len: usize = 0;
var find_result: c.HWND = null;

fn findProc(h: c.HWND, l: c.LPARAM) callconv(.winapi) c.BOOL {
    _ = l;
    if (find_result != null) return 0;
    if (c.IsWindowVisible(h) == 0) return 1;
    var title: [512]u16 = undefined;
    // Перебор идёт и по нашему собственному окну, а зовут его из потока
    // записи на каждом кадре: `GetWindowTextW` тут — тупик на «Стоп» (#101).
    const n = c.InternalGetWindowText(h, &title, title.len);
    if (n <= 0) return 1;
    // Регистр приводит сама Windows: она знает про русские буквы, а
    // std.ascii — только про латиницу.
    _ = c.CharLowerBuffW(&title, @intCast(n));
    if (containsW(title[0..@intCast(n)], find_needle[0..find_needle_len])) {
        find_result = h;
        return 0;
    }
    return 1;
}

fn containsW(haystack: []const u16, needle: []const u16) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u16, haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// Найти видимое окно по части заголовка. Регистр не важен: человек пишет
/// «блокнот», а в заголовке «Блокнот».
pub fn findWindow(title_part: []const u8) Error!c.HWND {
    if (builtin.os.tag != .windows) return Error.Unsupported;
    if (title_part.len == 0) return Error.WindowNotFound;
    find_needle_len = std.unicode.utf8ToUtf16Le(&find_needle, title_part) catch return Error.WindowNotFound;
    _ = c.CharLowerBuffW(&find_needle, @intCast(find_needle_len));
    find_result = null;
    _ = c.EnumWindows(findProc, 0);
    return find_result orelse Error.WindowNotFound;
}

/// Прямоугольник окна в координатах рабочего стола.
///
/// Берём `DwmGetWindowAttribute`, а не `GetWindowRect`: у обычного окна
/// `GetWindowRect` возвращает прямоугольник вместе с невидимой рамкой тени,
/// и в кадр попадает лишняя полоса пустого места по краям.
pub fn windowArea(hwnd: c.HWND) Error!Rect {
    if (builtin.os.tag != .windows) return Error.Unsupported;
    if (c.IsIconic(hwnd) != 0) return Error.WindowMinimized;
    var r: c.RECT = undefined;
    // DWMWA_EXTENDED_FRAME_BOUNDS = 9
    const hres = c.DwmGetWindowAttribute(hwnd, 9, &r, @sizeOf(c.RECT));
    if (win32.failed(hres)) {
        if (c.GetWindowRect(hwnd, &r) == 0) return Error.WindowNotFound;
    }
    return Rect{
        .x = r.left,
        .y = r.top,
        .width = @intCast(@max(r.right - r.left, 0)),
        .height = @intCast(@max(r.bottom - r.top, 0)),
    };
}

/// Область источника на текущий момент, уже обрезанная по экрану и с чётными
/// сторонами. Для окна вызывается на каждом кадре: окно двигают во время записи.
pub fn resolve(src: Source, screen: Rect) Error!Rect {
    const area = switch (src) {
        .monitor => screen,
        .area => |a| a,
        .window => |h| try windowArea(h),
    };
    // Координаты рабочего стола могут начинаться не с нуля (второй монитор
    // слева), а кадр захвата всегда начинается с нуля своего экрана.
    const local = Rect{
        .x = area.x - screen.x,
        .y = area.y - screen.y,
        .width = area.width,
        .height = area.height,
    };
    const clamped = local.clampTo(screen.width, screen.height).evenSized();
    if (clamped.isEmpty()) return Error.WindowNotFound;
    return clamped;
}

// ---------------------------------------------------------------- тесты

test "разбор области" {
    const r = parseArea("100,200,640,480").?;
    try std.testing.expectEqual(@as(i32, 100), r.x);
    try std.testing.expectEqual(@as(i32, 200), r.y);
    try std.testing.expectEqual(@as(u32, 640), r.width);
    try std.testing.expectEqual(@as(u32, 480), r.height);
}

test "разбор области: отрицательный угол законен, нулевой размер нет" {
    try std.testing.expect(parseArea("-1920,0,800,600") != null);
    try std.testing.expect(parseArea("0,0,0,600") == null);
    try std.testing.expect(parseArea("0,0,800,-1") == null);
}

test "разбор области: мусор отвергается" {
    try std.testing.expect(parseArea("") == null);
    try std.testing.expect(parseArea("1,2,3") == null);
    try std.testing.expect(parseArea("1,2,3,4,5") == null);
    try std.testing.expect(parseArea("a,b,c,d") == null);
    try std.testing.expect(parseArea("100 200 300 400") == null);
}

test "разбор области: пробелы вокруг чисел не мешают" {
    const r = parseArea(" 10 , 20 , 30 , 40 ").?;
    try std.testing.expectEqual(@as(i32, 10), r.x);
    try std.testing.expectEqual(@as(u32, 40), r.height);
}

test "область приводится к координатам экрана и к чётным сторонам" {
    const screen = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const got = try resolve(.{ .area = .{ .x = 101, .y = 50, .width = 641, .height = 481 } }, screen);
    try std.testing.expectEqual(@as(i32, 101), got.x);
    try std.testing.expectEqual(@as(u32, 640), got.width);
    try std.testing.expectEqual(@as(u32, 480), got.height);
}

test "экран со смещением: область пересчитывается в местные координаты" {
    const screen = Rect{ .x = -1920, .y = 0, .width = 1920, .height = 1080 };
    const got = try resolve(.{ .area = .{ .x = -1900, .y = 10, .width = 200, .height = 100 } }, screen);
    try std.testing.expectEqual(@as(i32, 20), got.x);
    try std.testing.expectEqual(@as(u32, 200), got.width);
}

test "область целиком вне экрана — ошибка, а не пустая запись" {
    const screen = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    try std.testing.expectError(
        Error.WindowNotFound,
        resolve(.{ .area = .{ .x = 5000, .y = 5000, .width = 100, .height = 100 } }, screen),
    );
}

test "поиск подстроки в широких строках" {
    const hay = std.unicode.utf8ToUtf16LeStringLiteral("блокнот — заметки");
    try std.testing.expect(containsW(hay, std.unicode.utf8ToUtf16LeStringLiteral("заметки")));
    try std.testing.expect(containsW(hay, std.unicode.utf8ToUtf16LeStringLiteral("блокнот")));
    try std.testing.expect(!containsW(hay, std.unicode.utf8ToUtf16LeStringLiteral("word")));
    try std.testing.expect(!containsW(
        std.unicode.utf8ToUtf16LeStringLiteral("abc"),
        std.unicode.utf8ToUtf16LeStringLiteral("abcd"),
    ));
    try std.testing.expect(!containsW(hay, &[_]u16{}));
}

test "в список не попадает то, что нельзя записать" {
    const big = Rect{ .x = 0, .y = 0, .width = 800, .height = 600 };
    const tiny = Rect{ .x = 0, .y = 0, .width = 40, .height = 40 };

    try std.testing.expect(worthShowing(10, true, big));
    // Невидимое окно записывать нечего.
    try std.testing.expect(!worthShowing(10, false, big));
    // Без заголовка его не отличить от соседнего такого же.
    try std.testing.expect(!worthShowing(0, true, big));
    // Крошечные окна — это подсказки и служебные окна, их десятки.
    try std.testing.expect(!worthShowing(10, true, tiny));
}

test "граница размера проходит там, где написано" {
    const exact = Rect{ .x = 0, .y = 0, .width = min_window_side, .height = min_window_side };
    try std.testing.expect(worthShowing(1, true, exact));

    const narrow = Rect{ .x = 0, .y = 0, .width = min_window_side - 1, .height = min_window_side };
    try std.testing.expect(!worthShowing(1, true, narrow));

    const low = Rect{ .x = 0, .y = 0, .width = min_window_side, .height = min_window_side - 1 };
    try std.testing.expect(!worthShowing(1, true, low));
}

test "длинный заголовок обрезается по букве, а не по байту" {
    // Русская буква занимает два байта. Обрезка по границе места оставила бы
    // половину буквы, то есть ромб с вопросительным знаком вместо имени.
    const text = "ааааа";
    try std.testing.expectEqual(@as(usize, 10), fitTitle(text, 10));
    try std.testing.expectEqual(@as(usize, 8), fitTitle(text, 9));
    try std.testing.expectEqual(@as(usize, 8), fitTitle(text, 8));
    try std.testing.expectEqual(@as(usize, 0), fitTitle(text, 1));
}

test "пустое окно живым не считается" {
    try std.testing.expect(!stillThere(null));
}

test "свёрнутое окно остаётся в списке, если оно годное по размеру" {
    // Правило показа не должно зависеть от того, свёрнуто окно или нет:
    // человек ищет «моё окно», а не «окно, которое сейчас на экране».
    const big = Rect{ .x = -32000, .y = -32000, .width = 1200, .height = 800 };
    try std.testing.expect(worthShowing(10, true, big));
}

test "открытые окна идут первыми, порядок внутри не сбивается" {
    var items: [6]WindowInfo = undefined;
    const folded = [_]bool{ true, false, true, false, true, false };
    for (&items, 0..) |*it, i| {
        it.* = .{ .minimized = folded[i] };
        it.title_len = 1;
        it.title[0] = @intCast('a' + @as(u8, @intCast(i)));
    }

    openFirst(&items);

    // Сначала открытые.
    try std.testing.expect(!items[0].minimized);
    try std.testing.expect(!items[1].minimized);
    try std.testing.expect(!items[2].minimized);
    try std.testing.expect(items[3].minimized);
    try std.testing.expect(items[4].minimized);
    try std.testing.expect(items[5].minimized);

    // И порядок по перекрытию внутри каждой половины прежний: наверху то,
    // на что человек смотрит сейчас.
    try std.testing.expectEqualStrings("b", items[0].name());
    try std.testing.expectEqualStrings("d", items[1].name());
    try std.testing.expectEqualStrings("f", items[2].name());
    try std.testing.expectEqualStrings("a", items[3].name());
    try std.testing.expectEqualStrings("c", items[4].name());
    try std.testing.expectEqualStrings("e", items[5].name());
}

test "список из одних свёрнутых или одних открытых не портится" {
    var all_folded: [3]WindowInfo = @splat(.{ .minimized = true });
    openFirst(&all_folded);
    for (all_folded) |it| try std.testing.expect(it.minimized);

    var all_open: [3]WindowInfo = @splat(.{});
    openFirst(&all_open);
    for (all_open) |it| try std.testing.expect(!it.minimized);

    var none: [0]WindowInfo = .{};
    openFirst(&none);
}
