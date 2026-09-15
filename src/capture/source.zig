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

/// Заголовок окна в UTF-8. Только широкая версия: `GetWindowTextA` отдаёт
/// текст в кодировке системы, и русские заголовки превращаются в мусор.
pub fn windowTitle(hwnd: c.HWND, out: []u8) []const u8 {
    if (builtin.os.tag != .windows) return out[0..0];
    var wide: [512]u16 = undefined;
    const n = c.GetWindowTextW(hwnd, &wide, wide.len);
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
    const n = c.GetWindowTextW(h, &title, title.len);
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
