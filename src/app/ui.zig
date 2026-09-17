//! Окно записи: кнопки, индикатор, трей, горячие клавиши, выбор области рамкой.
//!
//! Задачи #18 и #19.
//!
//! **Решение по оконному стеку (задача #18).** Взяли чистый Win32 с обычными
//! системными элементами, без Direct2D и без ImGui. Причины: exe остаётся
//! маленьким и без зависимостей, элементы выглядят так же, как во всей системе,
//! и рисовать здесь нечего — это панель из шести кнопок и строки состояния.
//! Direct2D понадобится редактору, когда дойдёт дело до таймлайна; тогда его и
//! добавим рядом, а не потащим сейчас ради одной панели.
//!
//! Всё — широкие версии функций (`CreateWindowExW`, `GetWindowTextW`):
//! узкие отдают текст в кодировке системы, и русские подписи превращаются в мусор.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;
const recorder = @import("recorder.zig");
const source = @import("../capture/source.zig");
const capture_types = @import("../capture/capture_types.zig");
const version = @import("../version.zig");
const errors = @import("../errors.zig");
const frame_overlay = @import("../capture/frame_overlay.zig");
const rec_dot = @import("../capture/rec_dot.zig");
const mic = @import("../sound/mic.zig");
const gain = @import("../sound/gain.zig");
const control = @import("control.zig");
const mcp = @import("mcp.zig");
const settings_mod = @import("settings.zig");
const paths = @import("paths.zig");
const recent_mod = @import("recent.zig");
const hotkey_mod = @import("hotkey.zig");
const tray_menu = @import("tray_menu.zig");
const listen = @import("listen.zig");
const corner = @import("mcp_corner.zig");
const boost_mod = @import("boost.zig");
const remote = @import("remote.zig");
const remote_win = @import("remote_win.zig");

pub const Rect = capture_types.Rect;

const id_record = 101;
const id_pause = 102;
const id_area = 103;
const id_full = 104;
const id_cursor = 105;
const id_open = 106;
const id_fps = 107;
const id_preset = 108;
const id_area_rec = 109;
const id_sound = 110;
const id_server = 111;
const id_editor = 112;
const id_server_help = 113;

// Пункты меню. Отдельный ряд номеров, чтобы не путать их с кнопками.
const id_menu_open_dir = 300;
const id_menu_exit = 301;
const id_menu_settings = 310;
const id_menu_about = 320;
const id_menu_boost = 321;
const id_set_portable = 340;
const id_set_area_key = 341;
const id_set_listen = 342;
const id_set_boost = 343;
/// Номера строк меню значка в трее. Далеко от прочих: они приходят тем же
/// путём, что и нажатия кнопок.
const id_tray_base = 800;

/// Сообщение о брошенных файлах.
const wm_dropfiles = 0x0233;

/// Поле, куда бросают файл. Координаты рабочей части окна.
const drop_zone = c.RECT{ .left = 214, .top = 432, .right = 510, .bottom = 470 };
/// Номера строк в списке недавних. Берём с запасом, чтобы не столкнуться
/// с номерами кнопок.
const id_recent_base = 700;

// Поля окна настроек.
const id_set_dir = 330;
const id_set_browse = 331;
const id_set_template = 332;
const id_set_port = 333;
const id_set_serve = 334;
const id_set_ok = 335;
const id_set_cancel = 336;

const hotkey_record = 1;
const hotkey_pause = 2;
/// Сочетание «обвёл область и пишешь».
const hotkey_area = 3;

// Числа модификаторов мы держим у себя, чтобы разбор сочетания оставался
// чистым. Здесь они встречаются с настоящими — и обязаны совпасть.
comptime {
    std.debug.assert(hotkey_mod.mod_alt == c.MOD_ALT);
    std.debug.assert(hotkey_mod.mod_ctrl == c.MOD_CONTROL);
    std.debug.assert(hotkey_mod.mod_shift == c.MOD_SHIFT);
    std.debug.assert(hotkey_mod.mod_win == c.MOD_WIN);
}

const wm_tray = c.WM_APP + 1;
const timer_tick = 1;
const timer_frame = 2;
const timer_wave = 3;

/// Состояние окна. Одно на процесс: окно тоже одно.
const App = struct {
    allocator: std.mem.Allocator,
    rec: recorder.Recorder,
    settings: recorder.Settings = .{},
    /// Что снимаем. `null` — весь экран.
    area: ?Rect = null,
    window_title: ?[]const u8 = null,
    out_dir: []const u8 = "",
    last_path: [std.fs.max_path_bytes]u8 = undefined,
    last_path_len: usize = 0,
    counter: u32 = 1,

    hwnd: c.HWND = null,
    status: c.HWND = null,
    btn_record: c.HWND = null,
    btn_pause: c.HWND = null,
    btn_open: c.HWND = null,
    chk_cursor: c.HWND = null,
    cb_fps: c.HWND = null,
    cb_preset: c.HWND = null,
    lbl_file: c.HWND = null,
    btn_area_rec: c.HWND = null,
    /// Фаза пульсации значков: та же, что у рамки, чтобы дышали в такт.
    pulse: u8 = 0,
    /// Состояние, в котором кнопки нарисованы сейчас.
    drawn_state: recorder.State = .idle,
    chk_sound: c.HWND = null,
    lbl_sound_note: c.HWND = null,
    slider_gain: c.HWND = null,
    lbl_gain: c.HWND = null,
    btn_server: c.HWND = null,
    lbl_server: c.HWND = null,
    /// Сервер для Claude Code. Сам не поднимается: только по кнопке.
    server: control.Server = .{},
    /// Положение ползунка усиления. Растягивает картинку, уровень не трогает.
    gain_pos: u8 = 0,
    /// Сколько раз в секунду обновляется экран, с которого пишем.
    /// Это потолок для числа разных кадров.
    refresh_hz: u32 = 0,
    /// Настройки, которые переживают перезапуск.
    prefs: settings_mod.Settings = .{},
    /// Где программа хранит своё: настройки, списки недавних.
    home: []const u8 = "",
    /// Недавние записи и просмотры.
    recent: recent_mod.Recent = .{},

    /// Запись начата сочетанием «обвёл и пишешь»: по окончании спросим имя.
    started_by_area_key: bool = false,
    sound_on: bool = false,
    microphone: mic.Capture = .{},
    tray_added: bool = false,
    tray_tip: [128]u8 = @splat(0),
};

var app: App = undefined;

/// Стандартные курсоры и значки задаются номером ресурса, а не адресом.
///
/// В заголовке это макрос `MAKEINTRESOURCE`, который translate-c не переносит,
/// и подсунуть номер как указатель нельзя: 32515 — нечётный «адрес», и Zig
/// в безопасном режиме честно падает на проверке выравнивания. Поэтому
/// объявляем те же функции Windows с целочисленным параметром.
const loadCursorById = @extern(
    *const fn (?*anyopaque, usize) callconv(.winapi) ?*anyopaque,
    .{ .name = "LoadCursorW" },
);
const loadIconById = @extern(
    *const fn (?*anyopaque, usize) callconv(.winapi) ?*anyopaque,
    .{ .name = "LoadIconW" },
);

/// Номера из заголовков Windows, не менялись с девяностых.
pub const idc_arrow = 32512;
const idc_cross = 32515;
const idi_information = 32516;

/// Номер нашего значка в ресурсах exe (см. assets/zigrec.rc). Один и тот же
/// значок берут проводник, окно и трей — иначе они разъедутся.
const idi_app = 1;

/// Положить дескриптор Windows в поле-указатель.
///
/// Дескрипторы окон, курсоров и значков — не адреса, а номера в таблицах ядра,
/// и выровнены они как попало. Любое приведение через `@alignCast` на них
/// падает в безопасном режиме. Копируем биты как есть: это ровно то, что делает
/// C, и единственный честный способ положить не-указатель в поле-указатель.
pub fn putHandle(field: anytype, value: ?*anyopaque) void {
    const raw: usize = @intFromPtr(value);
    @memcpy(std.mem.asBytes(field), std.mem.asBytes(&raw));
}

pub fn setSystemCursor(field: anytype, id: usize) void {
    putHandle(field, loadCursorById(null, id));
}

fn setSystemIcon(field: anytype, id: usize) void {
    putHandle(field, loadIconById(null, id));
}

/// Наш значок из ресурсов exe. Если его вдруг нет — берём системный,
/// чтобы окно всё равно открылось: значок не повод не запуститься.
pub fn setAppIcon(field: anytype) void {
    const module = c.GetModuleHandleW(null);
    const icon = loadIconById(@ptrCast(module), idi_app);
    if (icon) |got| {
        putHandle(field, got);
    } else {
        setSystemIcon(field, idi_information);
    }
}

/// Спрятать своё консольное окно.
///
/// Программа собрана как консольная, чтобы работали команды и коды возврата.
/// Но у окон консоль лишняя: при запуске с ярлыка она мигает чёрным
/// прямоугольником рядом, а при запуске редактора из окна записи просто
/// висит пустая.
///
/// Прячем только свою: если нас запустили из чужого терминала, прятать его
/// мы не имеем права.
pub fn hideOwnConsole() void {
    if (builtin.os.tag != .windows) return;
    if (c.GetConsoleWindow()) |console| {
        var console_pid: c.DWORD = 0;
        _ = c.GetWindowThreadProcessId(console, &console_pid);
        if (console_pid == c.GetCurrentProcessId()) _ = c.ShowWindow(console, c.SW_HIDE);
    }
}

pub fn wide(comptime s: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

/// Записать текст в надпись — но только если он изменился.
///
/// Проверка не ради экономии вызовов. Каждая запись текста заставляет Windows
/// стереть фон надписи и нарисовать её заново, а такт окна идёт пять раз
/// в секунду. Безусловная запись превращала неподвижную строку состояния
/// в мигающую: при удалённой работе каждая такая перерисовка ещё и уезжает
/// по сети как изменение картинки.
pub fn setText(hwnd: c.HWND, text: []const u8) void {
    var buf: [512]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, text) catch return;
    buf[n] = 0;
    if (sameText(hwnd, buf[0..n])) return;
    _ = c.SetWindowTextW(hwnd, @ptrCast(&buf));
}

/// Совпадает ли текст окна с тем, что собираются написать.
fn sameText(hwnd: c.HWND, want: []const u16) bool {
    var current: [512]u16 = undefined;
    const got = c.GetWindowTextW(hwnd, @ptrCast(&current), @intCast(current.len));
    if (got < 0) return false;
    const have: usize = @intCast(got);
    if (have != want.len) return false;
    return std.mem.eql(u16, current[0..have], want);
}

/// Кнопка. Номер ставим отдельным вызовом, а не через параметр меню:
/// туда Windows ждёт указатель, и малый номер вроде 101 — это невыровненный
/// адрес, на котором Zig честно падает.
pub fn button(parent: c.HWND, comptime text: []const u8, id: c_int, x: i32, y: i32, w: i32, h: i32, style: u32) c.HWND {
    const hwnd = c.CreateWindowExW(
        0,
        wide("BUTTON"),
        wide(text),
        @as(c.DWORD, @bitCast(@as(u32, c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP) | style)),
        x,
        y,
        w,
        h,
        parent,
        null,
        @ptrCast(c.GetModuleHandleW(null)),
        null,
    );
    // GWLP_ID = -12
    _ = c.SetWindowLongPtrW(hwnd, -12, id);
    return hwnd;
}

/// Подпись рядом с элементом.
/// Сообщения ползунка. В заголовке это `WM_USER + N`, и мы пишем их так же:
/// числами их значения ничего не сказали бы читателю.
const tbm_getpos = c.WM_USER + 0;
const tbm_setpos = c.WM_USER + 5;
const tbm_setrange = c.WM_USER + 6;
const tbm_setpagesize = c.WM_USER + 21;
/// Ползунок с делениями под ним.
const tbs_autoticks = 0x0001;

/// Ползунок усиления. Системный элемент, а не свой рисунок: он уже умеет
/// клавиатуру, колесо мыши и выглядит как везде в Windows.
fn gainSlider(parent: c.HWND, x: i32, y: i32, w: i32, h: i32) c.HWND {
    // Класс ползунка живёт в comctl32 и появляется только после этого вызова.
    var icc = std.mem.zeroes(c.INITCOMMONCONTROLSEX);
    icc.dwSize = @sizeOf(c.INITCOMMONCONTROLSEX);
    icc.dwICC = c.ICC_BAR_CLASSES;
    _ = c.InitCommonControlsEx(&icc);

    const hwnd = c.CreateWindowExW(
        0,
        wide("msctls_trackbar32"),
        wide(""),
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | tbs_autoticks,
        x,
        y,
        w,
        h,
        parent,
        null,
        @ptrCast(c.GetModuleHandleW(null)),
        null,
    );
    // Деление на каждое положение: шагов всего семь, и каждый виден.
    _ = c.SendMessageW(hwnd, tbm_setrange, 1, @as(c.LPARAM, gain.max_pos) << 16);
    _ = c.SendMessageW(hwnd, tbm_setpagesize, 0, 1);
    _ = c.SendMessageW(hwnd, tbm_setpos, 1, 0);
    return hwnd;
}

/// Ползунок живёт только вместе со звуком: усиливать выключенное нечего.
fn setGainEnabled(on: bool) void {
    const flag: c.BOOL = if (on) 1 else 0;
    _ = c.EnableWindow(app.slider_gain, flag);
    _ = c.EnableWindow(app.lbl_gain, flag);
}

fn label(parent: c.HWND, comptime text: []const u8, x: i32, y: i32, w: i32, h: i32) c.HWND {
    return c.CreateWindowExW(
        0,
        wide("STATIC"),
        wide(text),
        c.WS_CHILD | c.WS_VISIBLE,
        x,
        y,
        w,
        h,
        parent,
        null,
        @ptrCast(c.GetModuleHandleW(null)),
        null,
    );
}

/// Выпадающий список без поля ввода.
fn combo(parent: c.HWND, id: c_int, x: i32, y: i32, w: i32, h: i32) c.HWND {
    const hwnd = c.CreateWindowExW(
        0,
        wide("COMBOBOX"),
        wide(""),
        @as(c.DWORD, @bitCast(@as(u32, c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.CBS_DROPDOWNLIST))),
        x,
        y,
        w,
        h,
        parent,
        null,
        @ptrCast(c.GetModuleHandleW(null)),
        null,
    );
    _ = c.SetWindowLongPtrW(hwnd, -12, id);
    return hwnd;
}

fn addItem(combo_hwnd: c.HWND, text: []const u8) void {
    var buf: [64]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, text) catch return;
    buf[n] = 0;
    _ = c.SendMessageW(combo_hwnd, c.CB_ADDSTRING, 0, @bitCast(@intFromPtr(&buf)));
}

pub fn applyFont(hwnd: c.HWND) void {
    const font = c.GetStockObject(c.DEFAULT_GUI_FONT);
    _ = c.SendMessageW(hwnd, c.WM_SETFONT, @intFromPtr(font), 1);
}

/// Куда писать по умолчанию: `Видео\ZigRecStudio` в профиле пользователя.
pub fn defaultDir(allocator: std.mem.Allocator) ![]const u8 {
    var wide_home: [512]u16 = undefined;
    const n = c.GetEnvironmentVariableW(wide("USERPROFILE"), &wide_home, wide_home.len);
    if (n == 0 or n >= wide_home.len) return try allocator.dupe(u8, ".");
    var home: [1024]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&home, wide_home[0..n]) catch
        return try allocator.dupe(u8, ".");
    const dir = try std.fmt.allocPrint(allocator, "{s}\\Videos\\ZigRecStudio", .{home[0..len]});
    // Каталог создаём через Windows: он сам разберётся с уже существующим
    // и не потребует тащить сюда интерфейс ввода-вывода.
    var wide_dir: [1024]u16 = undefined;
    const dn = std.unicode.utf8ToUtf16Le(&wide_dir, dir) catch return dir;
    wide_dir[dn] = 0;
    _ = c.CreateDirectoryW(@ptrCast(&wide_dir), null);
    return dir;
}

fn nextPath(out: []u8) ![]const u8 {
    var name_buf: [128]u8 = undefined;
    // Шаблон — из настроек; папка — тоже, если её там задали.
    const name = try recorder.buildName(
        &name_buf,
        app.prefs.nameTemplate(),
        recorder.DateTime.now(),
        app.counter,
    );
    const dir = if (app.prefs.dir().len > 0) app.prefs.dir() else app.out_dir;
    return std.fmt.bufPrint(out, "{s}\\{s}", .{ dir, name });
}

fn startRecording() void {
    if (app.rec.isBusy()) return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = nextPath(&path_buf) catch return;
    @memcpy(app.last_path[0..path.len], path);
    app.last_path_len = path.len;

    const src: source.Source = if (app.area) |a| .{ .area = a } else .{ .monitor = app.settings.monitor };
    // Файл проверяем до захвата: занятый плеером файл — частая причина,
    // и узнать о ней надо сразу, а не в конце записи.
    errors.ensureWritable(path) catch |err| {
        setText(app.status, errors.explain(err));
        return;
    };
    // Проверка создаёт файл; если запись потом не начнётся, в папке останется
    // пустой mp4. Убираем его сразу — кодировщик создаст файл заново.
    errors.removeIfEmpty(path);
    // Галочка звука — это не только индикатор: с ней звук идёт и в файл.
    app.settings.sound = app.sound_on;
    app.rec.start(path, src, app.settings) catch |err| {
        setText(app.status, errors.explain(err));
        return;
    };
    app.counter += 1;
    showRemote();
    setText(app.btn_record, "Стоп");
    _ = c.EnableWindow(app.btn_pause, 1);
    // Рамка нужна только для куска экрана: весь экран обводить нечего.
    if (app.area) |a| frame_overlay.show(a);
    // Пунктиру нужен свой такт, чаще, чем обновление строки состояния.
    _ = c.SetTimer(app.hwnd, timer_frame, 50, null);
}

fn stopRecording() void {
    if (!app.rec.isBusy()) return;
    app.started_by_area_key = false;
    remote_win.hide();
    _ = c.KillTimer(app.hwnd, timer_frame);
    frame_overlay.hide();
    app.rec.stop();
    setText(app.btn_record, "Записать экран");
    setText(app.btn_pause, "Пауза");
    _ = c.EnableWindow(app.btn_pause, 0);
    _ = c.EnableWindow(app.btn_open, 1);
    rememberRecording();
}

/// Записанный файл попадает в «Недавно записанные».
///
/// Сохраняем сразу, а не при выходе: программу закрывают и через диспетчер
/// задач, и выключением машины, а список должен пережить и это.
fn rememberRecording() void {
    if (app.last_path_len == 0) return;
    app.recent.recorded.add(app.last_path[0..app.last_path_len]);
    _ = recent_mod.save(&app.recent, app.home);
    rebuildMenu(app.hwnd);
}

fn togglePause() void {
    if (!app.rec.isBusy()) return;
    app.rec.pause();
}

fn openLastFile() void {
    if (app.last_path_len == 0) return;
    var buf: [std.fs.max_path_bytes]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, app.last_path[0..app.last_path_len]) catch return;
    buf[n] = 0;
    _ = c.ShellExecuteW(null, wide("open"), @ptrCast(&buf), null, null, c.SW_SHOWNORMAL);
}

/// Частота обновления того экрана, с которого пишем.
///
/// Нужна не для красоты: захват отдаёт кадр тогда, когда рабочий стол его
/// показал. Просить больше кадров, чем экран показывает, можно — но взяться
/// им неоткуда, и в файле окажутся повторы. Человек должен узнать об этом
/// до записи, а не после.
fn screenRefresh() u32 {
    const list = source.listMonitors(app.allocator) catch return 0;
    defer app.allocator.free(list);
    for (list) |m| {
        if (m.index == app.settings.monitor) return m.refresh_hz;
    }
    return if (list.len > 0) list[0].refresh_hz else 0;
}

/// Предупреждение, если просят больше кадров, чем экран умеет показать.
/// Пустая строка — значит всё в порядке.
fn fpsWarning(fps: u32, refresh_hz: u32, buf: []u8) []const u8 {
    if (refresh_hz == 0 or fps <= refresh_hz) return "";
    return std.fmt.bufPrint(
        buf,
        " · экран обновляется {d} раз(а) в секунду: разных кадров будет {d}, остальные повторы",
        .{ refresh_hz, refresh_hz },
    ) catch "";
}

fn updateStatus() void {
    const p = app.rec.snapshot();
    var buf: [512]u8 = undefined;
    const secs = @as(f64, @floatFromInt(p.elapsed_ns)) / @as(f64, std.time.ns_per_s);
    var src_buf: [64]u8 = undefined;
    const source_text = if (app.area) |a|
        std.fmt.bufPrint(&src_buf, "область {d}x{d}", .{ a.width, a.height }) catch "область"
    else
        "весь экран";

    const text = if (p.state == .idle) blk: {
        if (p.message_len > 0) {
            break :blk std.fmt.bufPrint(&buf, "{s}\r\n{s} · источник: {s}", .{
                p.message_text(),
                hotkey_note,
                source_text,
            }) catch "готов";
        }
        var warn_buf: [160]u8 = undefined;
        break :blk std.fmt.bufPrint(&buf, "готов · {s}, {s}\r\nисточник: {s}, {d} кадр/с{s}", .{
            hotkey_note,
            areaKeyNote(),
            source_text,
            app.settings.fps,
            fpsWarning(app.settings.fps, app.refresh_hz, &warn_buf),
        }) catch "готов";
    } else std.fmt.bufPrint(&buf, "{s}  {d:0>2}:{d:0>2}\r\nкадров {d}, потерь {d}, путь {s}, кадр {d}x{d}", .{
        p.state.label(),
        @as(u32, @intFromFloat(secs)) / 60,
        @as(u32, @intFromFloat(secs)) % 60,
        p.frames,
        p.dropped,
        p.backend.label(),
        p.area.width,
        p.area.height,
    }) catch "идёт запись";

    setText(app.status, text);
    setText(app.btn_pause, if (p.state == .paused) "Продолжить" else "Пауза");
    updateTrayTip(p, secs);
    // Пульт показывает то же, что и окно: одно состояние, два места.
    remote_win.update(
        p.elapsed_ns,
        p.frames,
        p.dropped,
        p.state == .paused,
        if (app.sound_on) app.microphone.ring.level().peak else -1,
    );

    // Значки на кнопках зависят от состояния записи. Когда запись кончилась
    // сама, такт пульсации уже выключен, и без этой перерисовки на кнопке
    // остался бы квадрат «идёт запись».
    if (p.state != app.drawn_state) {
        app.drawn_state = p.state;
        for ([_]c.HWND{ app.btn_record, app.btn_area_rec, app.btn_pause }) |h| {
            _ = c.InvalidateRect(h, null, 0);
        }
    }

    // Имя файла на виду: человек должен знать, куда пишется, не открывая папку.
    var file_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (p.state == .idle) {
        if (nextPath(&file_buf)) |path| {
            setText(app.lbl_file, std.fs.path.basename(path));
        } else |_| {}
    } else if (app.last_path_len > 0) {
        setText(app.lbl_file, std.fs.path.basename(app.last_path[0..app.last_path_len]));
    }

    // Кнопка вернулась в исходное, если запись кончилась сама.
    if (p.state == .idle) {
        setText(app.btn_record, "Записать экран");
        _ = c.EnableWindow(app.btn_pause, 0);
    }
}

/// Размер рабочей части окна: ровно столько, сколько занимают органы
/// управления, плюс поле по краям. Считается от самой нижней и самой
/// правой кнопки — менять его надо, когда двигаются они.
const client_w: c_long = 524;
const client_h: c_long = 482;
/// WS_CLIPCHILDREN: окно не рисует там, где стоят его кнопки. Без этого
/// фон ложится поверх них, и они перерисовываются следом — а на окне,
/// которое обновляется по таймеру, это видно как мигание.
const main_style: c.DWORD = c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU |
    c.WS_MINIMIZEBOX | c.WS_CLIPCHILDREN;

/// GWL_STYLE: признаки окна.
const gwl_style: c_int = -16;

/// Что вышло с раскладкой окна: сколько органов управления не поместилось
/// и насколько далеко уехал самый дальний.
///
/// Нужен стенду: «кнопка не влезла» — ошибка, которую видно только глазами
/// и только на той машине, где рамка окна оказалась толще ожидаемой.
/// Пусть её ловит машина.
pub const Layout = struct {
    client_w: i32 = 0,
    client_h: i32 = 0,
    controls: usize = 0,
    outside: usize = 0,
    /// Насколько самый дальний орган управления вышел за нижний край.
    over_bottom: i32 = 0,
    /// То же вправо.
    over_right: i32 = 0,
    /// Стоит ли у окна признак «не рисовать под своими кнопками».
    ///
    /// Без него фон окна ложится поверх кнопок, и они перерисовываются
    /// следом. На окне, которое обновляется по таймеру, это видно как
    /// мигание — и заметить это можно только глазами и только в движении.
    clips_children: bool = false,

    pub fn ok(self: Layout) bool {
        return self.outside == 0 and self.clips_children;
    }
};

/// Пройти по всем видимым органам управления и сверить с рабочей частью окна.
pub fn measureLayout(hwnd: c.HWND) Layout {
    var out = Layout{};
    var client: c.RECT = undefined;
    if (c.GetClientRect(hwnd, &client) == 0) return out;
    out.client_w = client.right;
    out.client_h = client.bottom;

    out.clips_children = c.GetWindowLongPtrW(hwnd, gwl_style) & c.WS_CLIPCHILDREN != 0;

    var child = c.GetWindow(hwnd, c.GW_CHILD);
    while (child != null) : (child = c.GetWindow(child, c.GW_HWNDNEXT)) {
        // Спрашиваем признак у самого органа управления, а не `IsWindowVisible`:
        // тот отвечает «нет» у всех детей, пока скрыто само окно, — а мерить
        // раскладку надо именно у скрытого.
        const style = c.GetWindowLongPtrW(child, gwl_style);
        if (style & c.WS_VISIBLE == 0) continue;
        var r: c.RECT = undefined;
        if (c.GetWindowRect(child, &r) == 0) continue;

        var top_left = c.POINT{ .x = r.left, .y = r.top };
        var bottom_right = c.POINT{ .x = r.right, .y = r.bottom };
        _ = c.ScreenToClient(hwnd, &top_left);
        _ = c.ScreenToClient(hwnd, &bottom_right);

        out.controls += 1;
        const over_b = bottom_right.y - client.bottom;
        const over_r = bottom_right.x - client.right;
        if (over_b > 0 or over_r > 0 or top_left.x < 0 or top_left.y < 0) {
            out.outside += 1;
            out.over_bottom = @max(out.over_bottom, over_b);
            out.over_right = @max(out.over_right, over_r);
        }
    }
    return out;
}

/// Та же ловушка с выравниванием, что и в редакторе: `HDROP` приходит
/// числом, и превращать его в типизированный указатель Zig нельзя.
const dragQueryFileW = @extern(
    *const fn (usize, c.UINT, ?[*]u16, c.UINT) callconv(.winapi) c.UINT,
    .{ .name = "DragQueryFileW" },
);
const dragFinish = @extern(
    *const fn (usize) callconv(.winapi) void,
    .{ .name = "DragFinish" },
);

/// Как в итоге зарегистрировались горячие клавиши.
var hotkey_note: []const u8 = "";

/// Горячие клавиши. Сначала пробуем голые F9 и F10: их удобно нажимать вслепую.
/// Если заняты другой программой — а F9 занимают часто, — берём Ctrl+Alt+F9
/// и говорим об этом в окне. Молча остаться без горячих клавиш нельзя:
/// человек нажмёт и решит, что запись идёт.
fn registerHotkeys(hwnd: c.HWND) void {
    registerAreaHotkey(hwnd);
    const mod_ctrl_alt: c.UINT = c.MOD_CONTROL | c.MOD_ALT;
    const plain_rec = c.RegisterHotKey(hwnd, hotkey_record, 0, c.VK_F9) != 0;
    const plain_pause = c.RegisterHotKey(hwnd, hotkey_pause, 0, c.VK_F10) != 0;
    if (plain_rec and plain_pause) {
        hotkey_note = "F9 — запись, F10 — пауза";
        return;
    }
    if (plain_rec) _ = c.UnregisterHotKey(hwnd, hotkey_record);
    if (plain_pause) _ = c.UnregisterHotKey(hwnd, hotkey_pause);

    const alt_rec = c.RegisterHotKey(hwnd, hotkey_record, mod_ctrl_alt, c.VK_F9) != 0;
    const alt_pause = c.RegisterHotKey(hwnd, hotkey_pause, mod_ctrl_alt, c.VK_F10) != 0;
    if (alt_rec and alt_pause) {
        hotkey_note = "F9 занята, работают Ctrl+Alt+F9 и Ctrl+Alt+F10";
        return;
    }
    hotkey_note = "горячие клавиши заняты, работают только кнопки";
}

/// Как зарегистрировалось сочетание «обвёл область и пишешь».
var area_key_note: [96]u8 = @splat(0);
var area_key_note_len: usize = 0;

fn areaKeyNote() []const u8 {
    return area_key_note[0..area_key_note_len];
}

fn sayAreaKey(text: []const u8) void {
    const n = @min(text.len, area_key_note.len);
    @memcpy(area_key_note[0..n], text[0..n]);
    area_key_note_len = n;
}

/// Зарегистрировать сочетание «обвёл область и пишешь».
///
/// Сочетание берём из настроек. Не вышло — говорим об этом словами:
/// молча остаться без клавиши нельзя, человек нажмёт и решит, что
/// запись идёт.
fn registerAreaHotkey(hwnd: c.HWND) void {
    _ = c.UnregisterHotKey(hwnd, hotkey_area);

    const text = app.prefs.areaKey();
    const keys = hotkey_mod.parse(text) catch |err| {
        var buf: [160]u8 = undefined;
        sayAreaKey(std.fmt.bufPrint(&buf, "сочетание «{s}» не понято: {s}", .{
            text,
            hotkey_mod.explain(err),
        }) catch "сочетание не понято");
        return;
    };

    if (c.RegisterHotKey(hwnd, hotkey_area, keys.modifiers(), keys.key) == 0) {
        var buf: [160]u8 = undefined;
        sayAreaKey(std.fmt.bufPrint(&buf, "{s} занято другой программой", .{text}) catch "сочетание занято");
        return;
    }
    var buf: [160]u8 = undefined;
    sayAreaKey(std.fmt.bufPrint(&buf, "{s} — обвести область и писать", .{text}) catch "");
}

/// Одно нажатие — обвести область и начать запись. Второе — остановить
/// и спросить, как назвать файл.
///
/// Имя спрашиваем ПОСЛЕ записи, а не до: пока обводишь рамку, думать
/// об имени некогда, а после записи уже понятно, что получилось.
fn areaKeyPressed() void {
    if (app.rec.isBusy()) {
        const ask = app.started_by_area_key;
        stopRecording();
        if (ask) askNameForLast();
        return;
    }
    if (selectArea()) |r| {
        app.area = r;
        app.started_by_area_key = true;
        startRecording();
        // Окно могло быть свёрнуто: человек нажал сочетание, не глядя
        // на него, и должен увидеть, что запись пошла.
        updateStatus();
    }
}

/// Спросить имя для только что записанного файла и переименовать.
fn askNameForLast() void {
    app.started_by_area_key = false;
    if (app.last_path_len == 0) return;
    const current = app.last_path[0..app.last_path_len];

    var wide_path: [std.fs.max_path_bytes]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide_path, current) catch return;
    wide_path[n] = 0;

    var chosen: [std.fs.max_path_bytes]u16 = undefined;
    @memcpy(chosen[0 .. n + 1], wide_path[0 .. n + 1]);

    var ofn = std.mem.zeroes(c.OPENFILENAMEW);
    ofn.lStructSize = @sizeOf(c.OPENFILENAMEW);
    ofn.hwndOwner = app.hwnd;
    ofn.lpstrFilter = wide("Видео MP4\x00*.mp4\x00Все файлы\x00*.*\x00\x00");
    ofn.lpstrFile = &chosen;
    ofn.nMaxFile = chosen.len;
    ofn.lpstrTitle = wide("Как назвать запись");
    ofn.lpstrDefExt = wide("mp4");
    ofn.Flags = c.OFN_OVERWRITEPROMPT | c.OFN_PATHMUSTEXIST;

    if (c.GetSaveFileNameW(&ofn) == 0) {
        // Отказались — файл остаётся под своим именем. Записанное
        // не пропадает оттого, что человек передумал его называть.
        setText(app.status, "запись сохранена под прежним именем");
        return;
    }

    // Выбрали то же имя — переименовывать нечего.
    const same = std.mem.eql(u16, std.mem.sliceTo(&chosen, 0), wide_path[0..n]);
    if (same) return;

    if (c.MoveFileExW(@ptrCast(&wide_path), @ptrCast(&chosen), c.MOVEFILE_REPLACE_EXISTING) == 0) {
        setText(app.status, "переименовать не вышло: файл остался под прежним именем");
        return;
    }

    // Запоминаем новое имя: по нему открывается «Открыть» и оно попадает
    // в недавние вместо старого.
    var utf8: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&utf8, std.mem.sliceTo(&chosen, 0)) catch return;
    const keep = @min(len, app.last_path.len);
    @memcpy(app.last_path[0..keep], utf8[0..keep]);
    app.last_path_len = keep;

    // Старое имя попало в недавние при остановке — убираем его оттуда,
    // иначе в списке останется строка, ведущая в никуда.
    var i: usize = 0;
    while (i < app.recent.recorded.count) : (i += 1) {
        if (recent_mod.samePath(app.recent.recorded.at(i), current)) {
            app.recent.recorded.removeAt(i);
            break;
        }
    }
    rememberRecording();

    var note: [320]u8 = undefined;
    setText(app.status, std.fmt.bufPrint(&note, "сохранено: {s}", .{
        std.fs.path.basename(app.last_path[0..app.last_path_len]),
    }) catch "сохранено");
}

/// Подсказка значка в трее: состояние видно, даже когда окно свёрнуто
/// и человек работает на другом рабочем столе.
fn updateTrayTip(p: recorder.Progress, secs: f64) void {
    if (!app.tray_added) return;
    var text_buf: [128]u8 = undefined;
    const text = if (p.state == .idle)
        std.fmt.bufPrint(&text_buf, "Zig-Rec Studio — {s}", .{p.state.label()}) catch return
    else
        std.fmt.bufPrint(&text_buf, "Zig-Rec Studio — {s} {d:0>2}:{d:0>2}, кадров {d}", .{
            p.state.label(),
            @as(u32, @intFromFloat(secs)) / 60,
            @as(u32, @intFromFloat(secs)) % 60,
            p.frames,
        }) catch return;
    if (std.mem.eql(u8, text, app.tray_tip[0..text.len])) return;
    @memcpy(app.tray_tip[0..text.len], text);

    var nid = std.mem.zeroes(c.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(c.NOTIFYICONDATAW);
    nid.hWnd = app.hwnd;
    nid.uID = 1;
    nid.uFlags = c.NIF_TIP;
    var wide_tip: [128]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide_tip, text) catch return;
    @memcpy(nid.szTip[0..n], wide_tip[0..n]);
    nid.szTip[n] = 0;
    _ = c.Shell_NotifyIconW(c.NIM_MODIFY, &nid);
}

/// Нарисовать кнопку записи: значок слева, подпись справа.
///
/// Рисуем сами, потому что системная кнопка не умеет показывать состояние
/// значком, а подпись «Стоп» без красного квадрата читается медленнее.
fn drawRecordButton(item: *c.DRAWITEMSTRUCT) void {
    const dc = item.hDC;
    var rc = item.rcItem;

    // Рамка и фон — системные, чтобы кнопка выглядела как все кнопки Windows.
    var state: c.UINT = c.DFCS_BUTTONPUSH;
    if (item.itemState & c.ODS_SELECTED != 0) state |= c.DFCS_PUSHED;
    if (item.itemState & c.ODS_DISABLED != 0) state |= c.DFCS_INACTIVE;
    _ = c.DrawFrameControl(dc, &rc, c.DFC_BUTTON, state);

    const enabled = item.itemState & c.ODS_DISABLED == 0;
    const rec_state = app.rec.state();
    const id = item.CtlID;
    const look = if (id == id_pause)
        rec_dot.pauseLook(rec_state, enabled)
    else
        rec_dot.recordLook(rec_state, enabled, app.pulse);

    // У кнопки области значок шире: вокруг точки идёт пунктирная рамка,
    // та самая, что побежит вокруг выбранного прямоугольника при записи.
    const is_area = id == id_area_rec;
    const frame = rec_dot.areaFrame(look.radius);

    // Значок слева, по центру высоты.
    const cx = rc.left + @as(i32, if (is_area) 18 else 16);
    const cy = @divTrunc(rc.top + rc.bottom, 2);
    const r: i32 = @intCast(look.radius);
    const brush = c.CreateSolidBrush(look.color);
    defer _ = c.DeleteObject(brush);

    if (is_area) drawAreaFrame(dc, cx, cy, frame, look.color);

    switch (look.shape) {
        .circle => {
            const old = c.SelectObject(dc, brush);
            const pen = c.CreatePen(c.PS_SOLID, 1, look.color);
            const old_pen = c.SelectObject(dc, pen);
            _ = c.Ellipse(dc, cx - r, cy - r, cx + r, cy + r);
            _ = c.SelectObject(dc, old_pen);
            _ = c.DeleteObject(pen);
            _ = c.SelectObject(dc, old);
        },
        .ring => {
            const pen = c.CreatePen(c.PS_SOLID, 2, look.color);
            const old_pen = c.SelectObject(dc, pen);
            const hollow = c.GetStockObject(c.HOLLOW_BRUSH);
            const old_brush = c.SelectObject(dc, hollow);
            _ = c.Ellipse(dc, cx - r, cy - r, cx + r, cy + r);
            _ = c.SelectObject(dc, old_brush);
            _ = c.SelectObject(dc, old_pen);
            _ = c.DeleteObject(pen);
        },
        .square => {
            var box = c.RECT{ .left = cx - r, .top = cy - r, .right = cx + r, .bottom = cy + r };
            _ = c.FillRect(dc, &box, brush);
        },
    }

    // Подпись справа от значка.
    var text: [256]u16 = undefined;
    const n = c.GetWindowTextW(item.hwndItem, &text, text.len);
    if (n > 0) {
        const text_left = rc.left + if (is_area) 22 + frame.half_w else @as(i32, 30);
        var text_rc = c.RECT{ .left = text_left, .top = rc.top, .right = rc.right - 6, .bottom = rc.bottom };
        _ = c.SetBkMode(dc, c.TRANSPARENT);
        _ = c.SetTextColor(dc, if (enabled) @as(c.COLORREF, 0x00202020) else @as(c.COLORREF, 0x00909090));
        const font = c.GetStockObject(c.DEFAULT_GUI_FONT);
        const old_font = c.SelectObject(dc, font);
        _ = c.DrawTextW(dc, &text, n, &text_rc, c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);
        _ = c.SelectObject(dc, old_font);
    }

    if (item.itemState & c.ODS_FOCUS != 0) {
        var focus_rc = c.RECT{ .left = rc.left + 3, .top = rc.top + 3, .right = rc.right - 3, .bottom = rc.bottom - 3 };
        _ = c.DrawFocusRect(dc, &focus_rc);
    }
}

/// Пунктирная рамка вокруг значка записи.
///
/// Рисуем штрихами вручную, а не пунктирным пером: перо Windows кладёт
/// точки по своему шагу, и на короткой стороне их выходит две с половиной.
/// Свой шаг даёт одинаковый пунктир на всех четырёх сторонах — тот же,
/// что у рамки вокруг записываемой области.
fn drawAreaFrame(dc: c.HDC, cx: i32, cy: i32, frame: rec_dot.AreaFrame, color: c.COLORREF) void {
    const brush = c.CreateSolidBrush(color);
    defer _ = c.DeleteObject(@ptrCast(brush));

    const left = cx - frame.half_w;
    const right = cx + frame.half_w;
    const top = cy - frame.half_h;
    const bottom = cy + frame.half_h;
    const step = frame.dash * 2;

    var x = left;
    while (x < right) : (x += step) {
        const end = @min(x + frame.dash, right);
        var up = c.RECT{ .left = x, .top = top, .right = end, .bottom = top + 1 };
        _ = c.FillRect(dc, &up, brush);
        var down = c.RECT{ .left = x, .top = bottom, .right = end, .bottom = bottom + 1 };
        _ = c.FillRect(dc, &down, brush);
    }

    var y = top;
    while (y < bottom) : (y += step) {
        const end = @min(y + frame.dash, bottom);
        var l = c.RECT{ .left = left, .top = y, .right = left + 1, .bottom = end };
        _ = c.FillRect(dc, &l, brush);
        var r = c.RECT{ .left = right, .top = y, .right = right + 1, .bottom = end };
        _ = c.FillRect(dc, &r, brush);
    }
}

/// Место осциллографа в окне.
fn waveRect() c.RECT {
    return .{ .left = 112, .top = 228, .right = 510, .bottom = 316 };
}

/// Рисуем осциллограф не прямо на экране, а в памяти, и переносим готовым.
///
/// Иначе на каждом такте видно, как поле сначала заливается тёмным, а потом
/// по нему бежит линия. Двенадцать раз в секунду это читается как дрожание
/// панели, хотя на самом деле картинка не меняется.
fn paintWaveBuffered(hwnd: c.HWND, dc: c.HDC) void {
    const box = waveRect();
    const w = box.right - box.left;
    const h = box.bottom - box.top;

    const mem = c.CreateCompatibleDC(dc);
    if (mem == null) return drawWave(hwnd, dc);
    defer _ = c.DeleteDC(mem);

    const bmp = c.CreateCompatibleBitmap(dc, w, h);
    if (bmp == null) return drawWave(hwnd, dc);
    defer _ = c.DeleteObject(@ptrCast(bmp));

    const old_bmp = c.SelectObject(mem, @ptrCast(bmp));
    defer _ = c.SelectObject(mem, old_bmp);

    // Начало координат сдвигаем: `drawWave` считает в координатах окна,
    // и переучивать её ради буфера значило бы вести две системы координат.
    _ = c.SetViewportOrgEx(mem, -box.left, -box.top, null);
    drawWave(hwnd, mem);
    _ = c.SetViewportOrgEx(mem, 0, 0, null);

    _ = c.BitBlt(dc, box.left, box.top, w, h, mem, 0, 0, c.SRCCOPY);
}

/// Где горит лампочка сервера.
/// Всё, что уголку нужно знать о сервере.
fn cornerFacts() corner.Facts {
    return .{
        .state = app.server.state(),
        .address = app.prefs.listenAddress(),
        .port = app.prefs.port,
        .running = app.server.isRunning(),
        .served = app.server.served.load(.monotonic),
        .why = if (app.server.failure) |err| errors.short(err) else "",
    };
}

fn serverLampRect() c.RECT {
    return .{ .left = 214, .top = 406, .right = 228, .bottom = 420 };
}

fn drawServerLamp(dc: c.HDC) void {
    var text_buf: [96]u8 = undefined;
    const box = serverLampRect();
    const color = corner.look(&text_buf, cornerFacts()).dot;

    const brush = c.CreateSolidBrush(color);
    defer _ = c.DeleteObject(@ptrCast(brush));
    const pen = c.CreatePen(c.PS_SOLID, 1, 0x00707070);
    defer _ = c.DeleteObject(@ptrCast(pen));

    const old_brush = c.SelectObject(dc, @ptrCast(brush));
    defer _ = c.SelectObject(dc, old_brush);
    const old_pen = c.SelectObject(dc, @ptrCast(pen));
    defer _ = c.SelectObject(dc, old_pen);

    _ = c.Ellipse(dc, box.left, box.top, box.right, box.bottom);
}

/// Поле, куда бросают файл.
///
/// Пунктир, а не сплошная рамка: сплошная читается как кнопка, а сюда
/// не нажимают. Пунктирную рамку с подписью посередине понимают без слов —
/// так выглядит место для броска везде.
fn drawDropZone(dc: c.HDC) void {
    const box = drop_zone;
    const pen = c.CreatePen(c.PS_DOT, 1, 0x00A0A0A0);
    defer _ = c.DeleteObject(@ptrCast(pen));
    const old_pen = c.SelectObject(dc, @ptrCast(pen));
    defer _ = c.SelectObject(dc, old_pen);
    const hollow = c.GetStockObject(c.NULL_BRUSH);
    const old_brush = c.SelectObject(dc, hollow);
    defer _ = c.SelectObject(dc, old_brush);
    _ = c.Rectangle(dc, box.left, box.top, box.right, box.bottom);

    const font = c.GetStockObject(c.DEFAULT_GUI_FONT);
    const old_font = c.SelectObject(dc, font);
    defer _ = c.SelectObject(dc, old_font);
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    _ = c.SetTextColor(dc, 0x00808080);

    var rect = box;
    var wide_buf: [128]u16 = undefined;
    // Одна строка: `DT_VCENTER` работает только с одной, а с двумя нижняя
    // уезжает под нижний край поля.
    const text = "Бросьте файл — откроется в редакторе";
    const n = std.unicode.utf8ToUtf16Le(&wide_buf, text) catch return;
    _ = c.DrawTextW(
        dc,
        @ptrCast(&wide_buf),
        @intCast(n),
        &rect,
        c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE,
    );
}

fn refreshServerRow(hwnd: c.HWND) void {
    var corner_text: [96]u8 = undefined;
    setText(app.lbl_server, corner.look(&corner_text, cornerFacts()).text);
    var corner_button: [96]u8 = undefined;
    setText(app.btn_server, corner.look(&corner_button, cornerFacts()).button);
    var lamp = serverLampRect();
    _ = c.InvalidateRect(hwnd, &lamp, 0);
}

/// Создать папку, если её нет. Ошибку не возвращаем: папка может уже быть,
/// и это не повод беспокоить человека.
fn ensureDir(path: []const u8) void {
    if (path.len == 0) return;
    var wide_buf: [std.fs.max_path_bytes]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide_buf, path) catch return;
    wide_buf[n] = 0;
    _ = c.CreateDirectoryW(@ptrCast(&wide_buf), null);
}

/// Поля окна настроек: пока оно открыто, здесь лежат его элементы.
const SettingsWindow = struct {
    hwnd: c.HWND = null,
    dir_box: c.HWND = null,
    template_box: c.HWND = null,
    port_box: c.HWND = null,
    serve_box: c.HWND = null,
    portable_box: c.HWND = null,
    home_label: c.HWND = null,
    area_key_box: c.HWND = null,
    listen_box: c.HWND = null,
    boost_box: c.HWND = null,
    /// Нажали «Сохранить», а не «Отмена».
    accepted: bool = false,
};

var settings_win: SettingsWindow = .{};

/// Место под путь к своему хозяйству. Отдельно от `app`, потому что
/// переживает смену способа хранения прямо во время работы.
var home_store: [paths.max_path]u8 = @splat(0);

pub fn editBox(parent: c.HWND, id: c_int, x: i32, y: i32, w: i32, h: i32) c.HWND {
    const hwnd = c.CreateWindowExW(
        c.WS_EX_CLIENTEDGE,
        wide("EDIT"),
        wide(""),
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL,
        x,
        y,
        w,
        h,
        parent,
        null,
        @ptrCast(c.GetModuleHandleW(null)),
        null,
    );
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_ID, id);
    applyFont(hwnd);
    return hwnd;
}

pub fn boxText(hwnd: c.HWND, buf: []u8) []const u8 {
    var wide_buf: [512]u16 = undefined;
    const n = c.GetWindowTextW(hwnd, &wide_buf, wide_buf.len);
    if (n <= 0) return "";
    const len = std.unicode.utf16LeToUtf8(buf, wide_buf[0..@intCast(n)]) catch return "";
    return buf[0..len];
}

fn settingsProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_COMMAND => {
            switch (wp & 0xFFFF) {
                id_set_browse => browseForDir(hwnd),
                id_set_ok => {
                    settings_win.accepted = true;
                    _ = c.DestroyWindow(hwnd);
                },
                id_set_cancel => _ = c.DestroyWindow(hwnd),
                else => {},
            }
            return 0;
        },
        c.WM_CLOSE => {
            _ = c.DestroyWindow(hwnd);
            return 0;
        },
        c.WM_DESTROY => {
            // Снимаем поля до того, как окно исчезнет: после этого читать
            // из них уже нечего.
            if (settings_win.accepted) collectSettings();
            settings_win.hwnd = null;
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wp, lp);
}

/// Забрать введённое в настройки.
fn collectSettings() void {
    var buf: [512]u8 = undefined;

    const dir_text = boxText(settings_win.dir_box, &buf);
    if (dir_text.len > 0) app.prefs.setDir(dir_text);

    var buf2: [512]u8 = undefined;
    app.prefs.setTemplate(boxText(settings_win.template_box, &buf2));

    var buf3: [64]u8 = undefined;
    // Негодный порт не берём и прежний не портим: правило живёт в настройках
    // и проверено тестами.
    _ = app.prefs.setPort(boxText(settings_win.port_box, &buf3));

    var addr_buf: [128]u8 = undefined;
    const addr_text = boxText(settings_win.listen_box, &addr_buf);
    if (!app.prefs.setListenAddress(addr_text)) {
        var note: [256]u8 = undefined;
        setText(app.status, std.fmt.bufPrint(&note, "адрес «{s}» не понят — остался прежний", .{
            addr_text,
        }) catch "адрес не понят");
    } else if (listen.opensToNetwork(app.prefs.listenAddress())) {
        // Про открытый наружу порт говорим прямо и сразу: человек должен
        // узнать об этом здесь, а не потом и от кого-то другого.
        var note: [256]u8 = undefined;
        setText(app.status, std.fmt.bufPrint(&note, "внимание: {s} — порт будет виден из сети", .{
            app.prefs.listenAddress(),
        }) catch "порт будет виден из сети");
    }

    var key_buf: [128]u8 = undefined;
    const key_text = boxText(settings_win.area_key_box, &key_buf);
    if (!app.prefs.setAreaKey(key_text)) {
        // Негодное сочетание не берём и прежнее не портим: причину
        // называем словами, иначе человек не поймёт, почему не вышло.
        const why = if (hotkey_mod.parse(key_text)) |_| "" else |err| hotkey_mod.explain(err);
        var note: [256]u8 = undefined;
        setText(app.status, std.fmt.bufPrint(&note, "сочетание не принято: {s}", .{why}) catch "сочетание не принято");
    }

    app.prefs.serve_at_start = c.SendMessageW(settings_win.serve_box, c.BM_GETCHECK, 0, 0) != 0;
    app.prefs.boost_off = c.SendMessageW(settings_win.boost_box, c.BM_GETCHECK, 0, 0) == 0;

    // Сначала способ хранения: от него зависит, куда лягут настройки.
    const want: paths.Mode = if (c.SendMessageW(settings_win.portable_box, c.BM_GETCHECK, 0, 0) != 0)
        .portable
    else
        .classic;
    if (want != paths.currentMode()) {
        if (paths.setMode(want)) {
            var home_buf: [paths.max_path]u8 = undefined;
            if (paths.base(&home_buf)) |dir| {
                const n = @min(dir.len, home_store.len);
                @memcpy(home_store[0..n], dir[0..n]);
                app.home = home_store[0..n];
            } else |_| {}
        } else {
            setText(app.status, "способ хранения не сменился: папка программы недоступна");
        }
    }

    if (!settings_mod.save(&app.prefs, app.home)) {
        setText(app.status, "настройки не сохранились: папка недоступна");
        return;
    }
    // Новая папка может ещё не существовать — создаём, иначе первая же
    // запись упадёт на ровном месте.
    ensureDir(app.prefs.dir());
    // Сочетание могло смениться — перерегистрируем прямо сейчас,
    // а не при следующем запуске.
    registerAreaHotkey(app.hwnd);
    setText(app.status, "настройки сохранены");
}

/// Выбрать папку записей.
///
/// Системный выбор папки, а не ввод пути руками: путь с опечаткой
/// обнаруживается только в момент записи, когда уже поздно.
fn browseForDir(hwnd: c.HWND) void {
    var display: [std.fs.max_path_bytes]u16 = undefined;
    var info = std.mem.zeroes(c.BROWSEINFOW);
    info.hwndOwner = hwnd;
    info.pszDisplayName = &display;
    info.lpszTitle = wide("Куда класть записи");
    info.ulFlags = c.BIF_RETURNONLYFSDIRS | c.BIF_NEWDIALOGSTYLE;

    const list = c.SHBrowseForFolderW(&info);
    if (list == null) return;

    var path: [std.fs.max_path_bytes]u16 = undefined;
    if (c.SHGetPathFromIDListW(list, &path) == 0) return;

    var utf8: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&utf8, std.mem.sliceTo(&path, 0)) catch return;
    var wide_buf: [std.fs.max_path_bytes]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide_buf, utf8[0..len]) catch return;
    wide_buf[n] = 0;
    _ = c.SetWindowTextW(settings_win.dir_box, @ptrCast(&wide_buf));
}

/// Окно настроек.
fn showSettings(owner: c.HWND) void {
    if (settings_win.hwnd != null) {
        _ = c.SetForegroundWindow(settings_win.hwnd);
        return;
    }

    const hinst: c.HINSTANCE = @ptrCast(c.GetModuleHandleW(null));
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = settingsProc;
    wc.hInstance = hinst;
    wc.lpszClassName = wide("ZigRecSettings");
    wc.hbrBackground = @ptrFromInt(@as(usize, c.COLOR_BTNFACE) + 1);
    setSystemCursor(&wc.hCursor, idc_arrow);
    setAppIcon(&wc.hIcon);
    _ = c.RegisterClassExW(&wc);

    const hwnd = c.CreateWindowExW(
        c.WS_EX_DLGMODALFRAME,
        wide("ZigRecSettings"),
        wide("Настройки"),
        c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        520,
        404,
        owner,
        null,
        hinst,
        null,
    ) orelse return;

    settings_win = .{ .hwnd = hwnd };

    _ = label(hwnd, "Папка для записей", 14, 16, 200, 20);
    settings_win.dir_box = editBox(hwnd, id_set_dir, 14, 38, 380, 24);
    _ = button(hwnd, "Обзор…", id_set_browse, 402, 37, 90, 26, 0);

    _ = label(hwnd, "Имя файла: %d — дата, %t — время, %n — номер", 14, 74, 400, 20);
    settings_win.template_box = editBox(hwnd, id_set_template, 14, 96, 300, 24);

    _ = label(hwnd, "Обвести область и писать", 14, 134, 200, 20);
    settings_win.area_key_box = editBox(hwnd, id_set_area_key, 218, 132, 150, 24);

    _ = label(hwnd, "Сервер MCP: адрес и порт", 14, 168, 200, 20);
    settings_win.listen_box = editBox(hwnd, id_set_listen, 218, 166, 150, 24);
    settings_win.port_box = editBox(hwnd, id_set_port, 376, 166, 90, 24);

    settings_win.serve_box = button(hwnd, "Поднимать сервер при запуске", id_set_serve, 14, 200, 300, 24, c.BS_AUTOCHECKBOX);

    settings_win.boost_box = button(
        hwnd,
        "Разгон: включить все ускорения (ultra-speed)",
        id_set_boost,
        14,
        228,
        380,
        24,
        c.BS_AUTOCHECKBOX,
    );

    settings_win.portable_box = button(
        hwnd,
        "Portable: хранить своё рядом с программой",
        id_set_portable,
        14,
        256,
        360,
        24,
        c.BS_AUTOCHECKBOX,
    );
    // Прямо говорим, где программа оставляет следы: это её решение,
    // но знать о нём должен владелец машины.
    settings_win.home_label = label(hwnd, "", 14, 284, 490, 20);

    _ = button(hwnd, "Сохранить", id_set_ok, 300, 316, 100, 30, 0);
    _ = button(hwnd, "Отмена", id_set_cancel, 408, 316, 90, 30, 0);

    // Показываем то, что есть сейчас.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const current_dir = if (app.prefs.dir().len > 0) app.prefs.dir() else app.out_dir;
    const shown = std.fmt.bufPrint(&buf, "{s}", .{current_dir}) catch app.out_dir;
    setText(settings_win.dir_box, shown);
    setText(settings_win.template_box, app.prefs.nameTemplate());

    var port_buf: [16]u8 = undefined;
    setText(settings_win.port_box, std.fmt.bufPrint(&port_buf, "{d}", .{app.prefs.port}) catch "15599");
    setText(settings_win.area_key_box, app.prefs.areaKey());
    setText(settings_win.listen_box, app.prefs.listenAddress());
    _ = c.SendMessageW(settings_win.serve_box, c.BM_SETCHECK, if (app.prefs.serve_at_start) 1 else 0, 0);

    const mode = paths.currentMode();
    _ = c.SendMessageW(settings_win.portable_box, c.BM_SETCHECK, if (mode == .portable) 1 else 0, 0);
    _ = c.SendMessageW(settings_win.boost_box, c.BM_SETCHECK, if (app.prefs.boost()) 1 else 0, 0);
    var home_text: [640]u8 = undefined;
    setText(settings_win.home_label, std.fmt.bufPrint(&home_text, "Своё лежит в: {s}", .{app.home}) catch app.home);

    for ([_]c.HWND{
        settings_win.dir_box,
        settings_win.template_box,
        settings_win.port_box,
        settings_win.serve_box,
        settings_win.area_key_box,
        settings_win.listen_box,
        settings_win.boost_box,
    }) |h| applyFont(h);
    var child = c.GetWindow(hwnd, c.GW_CHILD);
    while (child != null) : (child = c.GetWindow(child, c.GW_HWNDNEXT)) applyFont(child);

    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.UpdateWindow(hwnd);
}

/// Полоса меню.
///
/// Меню, а не ещё один ряд кнопок: настроек и справки в окне немного,
/// а кнопок на нём уже хватает. То, чем пользуются раз в месяц, не должно
/// занимать место рядом с тем, чем пользуются каждый день.
fn buildMenu(hwnd: c.HWND) void {
    const bar = c.CreateMenu();
    if (bar == null) return;

    const file_menu = c.CreatePopupMenu();
    _ = c.AppendMenuW(file_menu, c.MF_STRING, id_menu_open_dir, wide("Папка с записями"));
    _ = c.AppendMenuW(file_menu, c.MF_SEPARATOR, 0, null);
    _ = c.AppendMenuW(
        file_menu,
        c.MF_POPUP,
        @intFromPtr(recentMenu(&app.recent.recorded, id_recent_base)),
        wide("Недавно записанные"),
    );
    _ = c.AppendMenuW(file_menu, c.MF_SEPARATOR, 0, null);
    _ = c.AppendMenuW(file_menu, c.MF_STRING, id_menu_exit, wide("Выход"));
    _ = c.AppendMenuW(bar, c.MF_POPUP, @intFromPtr(file_menu), wide("Файл"));

    const tools_menu = c.CreatePopupMenu();
    _ = c.AppendMenuW(tools_menu, c.MF_STRING, id_menu_settings, wide("Настройки…"));
    _ = c.AppendMenuW(bar, c.MF_POPUP, @intFromPtr(tools_menu), wide("Настройки"));

    const help_menu = c.CreatePopupMenu();
    _ = c.AppendMenuW(help_menu, c.MF_STRING, id_menu_boost, wide("Чем ускорено…"));
    _ = c.AppendMenuW(help_menu, c.MF_SEPARATOR, 0, null);
    _ = c.AppendMenuW(help_menu, c.MF_STRING, id_menu_about, wide("О программе"));
    _ = c.AppendMenuW(bar, c.MF_POPUP, @intFromPtr(help_menu), wide("Справка"));

    _ = c.SetMenu(hwnd, bar);
}

/// Выпадающий список недавних файлов.
///
/// Пропавший файл не прячем, а показываем и говорим, что его нет на месте:
/// молча исчезнувшая строка выглядит так, будто программа что-то потеряла.
/// Диск мог быть отключён, папка переименована — человек разберётся сам,
/// если ему сказать.
fn recentMenu(list: *const recent_mod.List, base_id: c_int) c.HMENU {
    const menu = c.CreatePopupMenu();
    if (menu == null) return menu;
    if (list.count == 0) {
        _ = c.AppendMenuW(menu, c.MF_STRING | c.MF_GRAYED, 0, wide("пока пусто"));
        return menu;
    }

    var i: usize = 0;
    while (i < list.count) : (i += 1) {
        const path = list.at(i);
        const here = recent_mod.onDisk(path);
        var text: [400]u8 = undefined;
        const shown = std.fmt.bufPrint(&text, "{s}{s}", .{
            std.fs.path.basename(path),
            if (here) "" else "  — нет на месте",
        }) catch std.fs.path.basename(path);

        var wide_buf: [512]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wide_buf, shown) catch continue;
        if (n >= wide_buf.len) continue;
        wide_buf[n] = 0;
        // Пропавший файл виден, но не нажимается: показать и не дать
        // ткнуть — честнее, чем спрятать или открыть пустоту.
        const flags: c.UINT = if (here) c.MF_STRING else c.MF_STRING | c.MF_GRAYED;
        _ = c.AppendMenuW(
            menu,
            flags,
            @intCast(base_id + @as(c_int, @intCast(i))),
            @ptrCast(&wide_buf),
        );
    }
    return menu;
}

/// Заново собрать меню: список недавних мог пополниться.
fn rebuildMenu(hwnd: c.HWND) void {
    const old = c.GetMenu(hwnd);
    buildMenu(hwnd);
    if (old != null) _ = c.DestroyMenu(old);
    _ = c.DrawMenuBar(hwnd);
}

/// Открыть недавнюю запись в редакторе дорожек.
fn openRecent(index: usize) void {
    const path = app.recent.recorded.at(index);
    if (path.len == 0) return;
    if (!recent_mod.onDisk(path)) {
        setText(app.status, "файла нет на месте");
        return;
    }
    openEditorWith(path);
}

/// Короткая справка про сервер MCP.
fn showServerHelp(owner: c.HWND) void {
    var wide_buf: [1024]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide_buf, corner.help_text) catch return;
    wide_buf[n] = 0;
    _ = c.MessageBoxW(owner, @ptrCast(&wide_buf), wide("Сервер MCP"), c.MB_OK | c.MB_ICONINFORMATION);
}

/// Меню по правой кнопке на значке в трее.
///
/// Состав меню решает `tray_menu`: это чистый счёт и проверяется тестами.
/// Здесь остаётся только показать его и вернуть выбранное.
fn showTrayMenu(hwnd: c.HWND) void {
    const menu = c.CreatePopupMenu();
    if (menu == null) return;
    defer _ = c.DestroyMenu(menu);

    const p = app.rec.snapshot();
    const paused = p.state == .paused;
    var buf: [tray_menu.max_items]tray_menu.Item = undefined;
    const items = tray_menu.build(.{
        .recording = app.rec.isBusy(),
        .paused = paused,
        .has_last = app.last_path_len > 0,
    }, &buf);

    for (items, 0..) |item, i| {
        if (item == .separator) {
            _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
            continue;
        }
        var wide_buf: [128]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wide_buf, item.label(paused)) catch continue;
        wide_buf[n] = 0;
        _ = c.AppendMenuW(menu, c.MF_STRING, @intCast(id_tray_base + @as(c_int, @intCast(i))), @ptrCast(&wide_buf));
    }

    var at: c.POINT = undefined;
    _ = c.GetCursorPos(&at);
    // Окно должно стать передним, иначе меню не закроется при щелчке мимо:
    // так устроены всплывающие меню у значков в трее.
    _ = c.SetForegroundWindow(hwnd);
    const chosen = c.TrackPopupMenu(
        menu,
        c.TPM_RIGHTBUTTON | c.TPM_RETURNCMD | c.TPM_NONOTIFY,
        at.x,
        at.y,
        0,
        hwnd,
        null,
    );
    if (chosen == 0) return;

    const index: usize = @intCast(chosen - id_tray_base);
    if (index >= items.len) return;
    switch (items[index]) {
        .show => {
            _ = c.ShowWindow(hwnd, c.SW_SHOW);
            _ = c.SetForegroundWindow(hwnd);
        },
        .record_area => areaKeyPressed(),
        .stop => {
            stopRecording();
            updateStatus();
        },
        .pause => togglePause(),
        .open_last => openLastFile(),
        .settings => {
            _ = c.ShowWindow(hwnd, c.SW_SHOW);
            showSettings(hwnd);
        },
        // Закрыть совсем, а не спрятать: за этим сюда и приходят.
        .exit => quit(hwnd),
        .separator => {},
    }
}

/// Закрыть программу совсем.
fn quit(hwnd: c.HWND) void {
    // Начатую запись доводим до конца: бросить её на середине значило бы
    // отдать испорченный файл.
    if (app.rec.isBusy()) stopRecording();
    _ = c.PostMessageW(hwnd, c.WM_CLOSE, 0, 0);
}

/// Файлы, брошенные на окно: открываем их в редакторе.
///
/// Принимаем бросок в любом месте окна, а не только в отведённом поле:
/// поле показывает, куда целиться, но промахнуться мимо программы обиднее,
/// чем попасть не в тот её угол.
fn onDrop(drop: usize) void {
    defer dragFinish(drop);

    const count = dragQueryFileW(drop, 0xFFFFFFFF, null, 0);
    if (count == 0) return;

    var wide_buf: [1024]u16 = undefined;
    var utf8: [1024]u8 = undefined;
    var opened: u32 = 0;
    var i: c.UINT = 0;
    while (i < count) : (i += 1) {
        const n = dragQueryFileW(drop, i, &wide_buf, wide_buf.len);
        if (n == 0) continue;
        const len = std.unicode.utf16LeToUtf8(&utf8, wide_buf[0..n]) catch continue;
        openEditorWith(utf8[0..len]);
        opened += 1;
    }

    var note: [160]u8 = undefined;
    setText(app.status, std.fmt.bufPrint(&note, "открываю в редакторе: файлов {d}", .{opened}) catch "открываю в редакторе");
}

/// Поднять пульт управления съёмкой.
///
/// Пульт встаёт за пределами снимаемой области — куда именно, решает
/// чистый счёт в `remote.zig`. Если снимают весь экран, спрятать его негде,
/// и пульт честно об этом пишет.
fn showRemote() void {
    const screen = screenRect();
    const area: remote.Rect = if (app.area) |a| .{
        .x = a.x,
        .y = a.y,
        .w = @intCast(a.width),
        .h = @intCast(a.height),
    } else screen;
    remote_win.show(app.hwnd, screen, area, app.area == null);
}

/// Прямоугольник того монитора, с которого пишем.
fn screenRect() remote.Rect {
    const list = source.listMonitors(app.allocator) catch return wholeScreen();
    defer app.allocator.free(list);
    for (list) |m| {
        if (m.index != app.settings.monitor) continue;
        const whole = remote.Rect{
            .x = m.area.x,
            .y = m.area.y,
            .w = @intCast(m.area.width),
            .h = @intCast(m.area.height),
        };
        return workArea(whole);
    }
    return wholeScreen();
}

fn wholeScreen() remote.Rect {
    return workArea(.{
        .x = 0,
        .y = 0,
        .w = c.GetSystemMetrics(c.SM_CXSCREEN),
        .h = c.GetSystemMetrics(c.SM_CYSCREEN),
    });
}

/// Рабочая область монитора: экран без панели задач.
///
/// Пульт ставится по ней, а не по всему экрану. Панель задач тоже «поверх
/// всех», и внизу справа она закрывает собой ровно тот угол, куда пульт
/// просится, — кнопки оказываются под ней и не нажимаются.
fn workArea(whole: remote.Rect) remote.Rect {
    const at: c.POINT = .{ .x = whole.x + @divTrunc(whole.w, 2), .y = whole.y + @divTrunc(whole.h, 2) };
    const mon = c.MonitorFromPoint(at, c.MONITOR_DEFAULTTONEAREST);
    if (mon == null) return whole;

    var info = std.mem.zeroes(c.MONITORINFO);
    info.cbSize = @sizeOf(c.MONITORINFO);
    if (c.GetMonitorInfoW(mon, &info) == 0) return whole;

    const work = remote.Rect{
        .x = info.rcWork.left,
        .y = info.rcWork.top,
        .w = info.rcWork.right - info.rcWork.left,
        .h = info.rcWork.bottom - info.rcWork.top,
    };
    // Рабочая область бывает пустой на странных сборках Windows — тогда
    // лучше весь экран, чем пульт нулевого размера.
    if (work.w < remote.width or work.h < remote.height) return whole;
    return work;
}

/// Показать папку с записями в проводнике.
fn openOutputDir() void {
    var wide_buf: [std.fs.max_path_bytes]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide_buf, app.out_dir) catch return;
    wide_buf[n] = 0;
    _ = c.ShellExecuteW(null, wide("open"), @ptrCast(&wide_buf), null, null, c.SW_SHOWNORMAL);
}

/// Окно «Чем ускорено».
///
/// Показывает не обещания, а то, что работает в этом сеансе, и отдельной
/// строкой — версию программы с датой сборки. Когда человек говорит
/// «тормозит», первый вопрос — что именно у него включилось.
fn showBoost(hwnd: c.HWND) void {
    var items: [boost_mod.max_items]boost_mod.Speedup = undefined;
    const list = boost_mod.list(.{ .boost = app.prefs.boost() }, &items);
    const counted = boost_mod.tally(list);

    var text: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&text);
    w.print("Zig-Rec Studio {s}, собрана {s}\r\n", .{
        version.VERSION,
        version.VERSION_DATE,
    }) catch {};
    w.print("Разгон {s}. Включено {d} из {d}{s}.\r\n\r\n", .{
        if (app.prefs.boost()) "включён" else "выключен",
        counted.on,
        counted.total,
        if (counted.failed > 0) ", из них не завелось: 1" else "",
    }) catch {};

    for (list) |it| {
        w.print("• {s} — {s}\r\n", .{ it.name, it.state() }) catch {};
        w.print("   {s}\r\n", .{it.what}) catch {};
        if (it.cost.len > 0) w.print("   цена: {s}\r\n", .{it.cost}) catch {};
        w.print("   чем сделано: {s}\r\n\r\n", .{it.made_by}) catch {};
    }

    var wide_buf: [8192]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide_buf, w.buffered()) catch return;
    wide_buf[n] = 0;
    _ = c.MessageBoxW(hwnd, @ptrCast(&wide_buf), wide("Чем ускорено"), c.MB_OK | c.MB_ICONINFORMATION);
}

fn showAbout(hwnd: c.HWND) void {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf,
        \\Zig-Rec Studio {s} ({s})
        \\
        \\Запись экрана в mp4, который открывается везде, и в GIF —
        \\короткой петлёй для письма. Со звуком с микрофона, с областью,
        \\обведённой мышью, и с горячей клавишей: {s}.
        \\
        \\Редактор дорожек: резка, перестановка, обрезка краёв, отмена.
        \\Видео и звук одного файла ходят вместе, пока их не развяжут.
        \\Проект сохраняется в .zigrec — при желании вместе с исходниками.
        \\
        \\Читает mp4, mov, avi, gif, wav, mp3, ogg, flac, midi.
        \\Сервер MCP даёт Claude Code управлять записью.
        \\
        \\Один файл, без установки и без зависимостей.
        \\Исходники: github.com/j0k/ZigRec-Studio
    , .{ version.VERSION, version.VERSION_DATE, app.prefs.areaKey() }) catch "Zig-Rec Studio";

    var wide_buf: [1024]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide_buf, text) catch return;
    wide_buf[n] = 0;
    _ = c.MessageBoxW(hwnd, @ptrCast(&wide_buf), wide("О программе"), c.MB_OK | c.MB_ICONINFORMATION);
}

/// Открыть редактор отдельной программой.
///
/// Отдельным процессом, а не вторым окном в этом: у записи свой цикл
/// сообщений и свои горячие клавиши, и делить их с редактором — значит
/// получить окно, которое подвисает во время записи.
fn openEditor() void {
    openEditorWith("");
}

/// Открыть редактор дорожек, при желании сразу с файлом.
fn openEditorWith(file: []const u8) void {
    var exe: [std.fs.max_path_bytes]u16 = undefined;
    const n = c.GetModuleFileNameW(null, &exe, exe.len);
    if (n == 0) return;
    exe[n] = 0;

    // Командная строка: «путь» edit «файл». Буфер изменяемый —
    // CreateProcessW имеет право в него писать.
    var line: [std.fs.max_path_bytes * 2 + 32]u16 = undefined;
    var at: usize = 0;
    line[at] = '"';
    at += 1;
    @memcpy(line[at .. at + n], exe[0..n]);
    at += n;
    const tail = wide("\" edit");
    @memcpy(line[at .. at + tail.len], tail);
    at += tail.len;

    // Путь в кавычках: в нём бывают пробелы, и без кавычек редактор
    // получил бы половину имени.
    if (file.len > 0) {
        line[at] = ' ';
        at += 1;
        line[at] = '"';
        at += 1;
        if (std.unicode.utf8ToUtf16Le(line[at..], file)) |wrote| {
            at += wrote;
            line[at] = '"';
            at += 1;
        } else |_| {
            // Путь не переводится — открываем редактор пустым, а не
            // с обрезанным именем.
            at -= 2;
        }
    }
    line[at] = 0;

    // CREATE_NO_WINDOW: консоль не создаётся вовсе. Прятать её потом поздно —
    // чёрный прямоугольник успевает мигнуть.
    var si = std.mem.zeroes(c.STARTUPINFOW);
    si.cb = @sizeOf(c.STARTUPINFOW);
    var pi = std.mem.zeroes(c.PROCESS_INFORMATION);
    const ok = c.CreateProcessW(
        @ptrCast(&exe),
        @ptrCast(&line),
        null,
        null,
        0,
        c.CREATE_NO_WINDOW,
        null,
        null,
        &si,
        &pi,
    );
    if (ok == 0) {
        setText(app.status, "редактор не открылся");
        return;
    }
    // Дескрипторы нам не нужны: редактор живёт сам по себе.
    _ = c.CloseHandle(pi.hProcess);
    _ = c.CloseHandle(pi.hThread);
}

fn toggleServer(hwnd: c.HWND) void {
    if (app.server.isRunning()) {
        app.server.stop();
    } else {
        app.server.startAt(hwnd, app.prefs.listenAddress(), app.prefs.port) catch |err| {
            app.server.failure = err;
        };
        // Даём потоку сесть на порт, чтобы лампочка сразу сказала правду,
        // а не «выключен» на первые полсекунды.
        c.Sleep(120);
    }
    refreshServerRow(hwnd);
}

/// Исполнить просьбу, пришедшую снаружи. Работает в потоке окна: запись
/// заводится и останавливается только отсюда, из одного места.
fn serveCall(call: *control.Call) void {
    var buf: [8 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    switch (call.request) {
        .start => |req| {
            if (app.rec.isBusy()) {
                call.failed = true;
                call.say("запись уже идёт; сначала остановите её");
                return;
            }
            if (req.area) |text| {
                const rect = source.parseArea(text) orelse {
                    call.failed = true;
                    call.say("область задаётся четырьмя числами: x,y,ширина,высота");
                    return;
                };
                app.area = rect;
            } else if (req.window) |title| {
                const hwnd = source.findWindow(title) catch {
                    call.failed = true;
                    w.print("окно с заголовком «{s}» не найдено", .{title}) catch {};
                    call.say(w.buffered());
                    return;
                };
                const rect = source.windowArea(hwnd) catch {
                    call.failed = true;
                    call.say("окно нашлось, но его размеры не читаются: возможно, оно свёрнуто");
                    return;
                };
                app.area = rect;
            } else {
                app.area = null;
                if (req.monitor) |n| app.settings.monitor = n;
            }
            if (req.fps) |n| app.settings.fps = n;
            app.sound_on = req.sound;
            _ = c.SendMessageW(app.chk_sound, c.BM_SETCHECK, if (req.sound) 1 else 0, 0);
            setGainEnabled(req.sound);

            startRecording();
            if (!app.rec.isBusy()) {
                call.failed = true;
                call.say("запись не началась; посмотрите строку состояния в окне");
                return;
            }
            const p = app.rec.snapshot();
            w.print("запись пошла: {s}, {d} кадров в секунду, звук {s}", .{
                if (app.area) |a| areaText(&buf, a) else "весь экран",
                app.settings.fps,
                if (req.sound) "пишется" else "выключен",
            }) catch {};
            _ = p;
            call.say(w.buffered());
        },
        .stop => {
            if (!app.rec.isBusy()) {
                call.failed = true;
                call.say("запись не идёт");
                return;
            }
            stopRecording();
            const p = app.rec.snapshot();
            const path = app.last_path[0..app.last_path_len];
            w.print("готово: {d} кадров, {d:.1} с, файл {s}", .{
                p.frames,
                @as(f64, @floatFromInt(p.elapsed_ns)) / @as(f64, std.time.ns_per_s),
                path,
            }) catch {};
            call.say(w.buffered());
        },
        .status => {
            const p = app.rec.snapshot();
            w.print("состояние: {s}, кадров {d}, {d:.1} с", .{
                p.state.label(),
                p.frames,
                @as(f64, @floatFromInt(p.elapsed_ns)) / @as(f64, std.time.ns_per_s),
            }) catch {};
            if (p.state != .idle) {
                w.print(", пишется в {s}", .{app.last_path[0..app.last_path_len]}) catch {};
            }
            call.say(w.buffered());
        },
        .monitors => {
            const list = source.listMonitors(app.allocator) catch {
                call.failed = true;
                call.say("список мониторов не читается");
                return;
            };
            defer app.allocator.free(list);
            for (list, 0..) |m, i| {
                w.print("{d}: {d}x{d} в точке ({d},{d}){s}\n", .{
                    i,
                    m.area.width,
                    m.area.height,
                    m.area.x,
                    m.area.y,
                    if (m.primary) " — основной" else "",
                }) catch break;
            }
            call.say(w.buffered());
        },
        .windows => {
            var count: u32 = 0;
            var hwnd = c.GetTopWindow(null);
            while (hwnd != null and count < 40) : (hwnd = c.GetWindow(hwnd, c.GW_HWNDNEXT)) {
                if (c.IsWindowVisible(hwnd) == 0) continue;
                var title_buf: [512]u8 = undefined;
                const title = source.windowTitle(hwnd, &title_buf);
                if (title.len == 0) continue;
                const area = source.windowArea(hwnd) catch continue;
                if (area.width < 100 or area.height < 100) continue;
                w.print("{d}x{d}  {s}\n", .{ area.width, area.height, title }) catch break;
                count += 1;
            }
            if (count == 0) call.say("видимых окон не нашлось") else call.say(w.buffered());
        },
        else => {
            call.failed = true;
            call.say("эту просьбу окно не исполняет");
        },
    }
}

/// Подпись области для ответа. Пишет в конец того же буфера, чтобы не
/// заводить второй.
fn areaText(buf: []u8, area: Rect) []const u8 {
    const tail = buf[buf.len / 2 ..];
    return std.fmt.bufPrint(tail, "область {d}x{d}", .{ area.width, area.height }) catch "область";
}

/// Осциллограф микрофона: настоящая форма сигнала, а не полоска уровня.
///
/// По полоске видно только «громко или тихо». По волне видно, говорит человек
/// или в микрофон дует ветер, и сразу заметно, что вход выбран не тот:
/// прямая линия вместо волны.
fn drawWave(hwnd: c.HWND, dc: c.HDC) void {
    const box = waveRect();
    const w = box.right - box.left;
    const h = box.bottom - box.top;

    // Тёмное поле: волна на нём видна лучше, чем на сером фоне окна.
    var rc = box;
    const back = c.CreateSolidBrush(if (app.sound_on) @as(c.COLORREF, 0x00201810) else @as(c.COLORREF, 0x00E8E8E8));
    _ = c.FillRect(dc, &rc, back);
    _ = c.DeleteObject(back);

    _ = c.SetBkMode(dc, c.TRANSPARENT);
    const font = c.GetStockObject(c.DEFAULT_GUI_FONT);
    const old_font = c.SelectObject(dc, font);
    defer _ = c.SelectObject(dc, old_font);

    if (!app.sound_on) {
        _ = c.SetTextColor(dc, 0x00808080);
        drawTextIn(dc, box, "звук выключен");
        return;
    }

    if (app.microphone.failure) |err| {
        _ = c.SetTextColor(dc, 0x004040D0);
        drawTextIn(dc, box, errors.short(err));
        return;
    }

    // Средняя линия.
    const mid = box.top + @divTrunc(h, 2);
    var axis = c.RECT{ .left = box.left, .top = mid, .right = box.right, .bottom = mid + 1 };
    const axis_brush = c.CreateSolidBrush(0x00404040);
    _ = c.FillRect(dc, &axis, axis_brush);
    _ = c.DeleteObject(axis_brush);

    var samples: [380]f32 = undefined;
    const count: usize = @intCast(@min(w, @as(i32, @intCast(samples.len))));
    app.microphone.ring.snapshot(samples[0..count]);

    const pen = c.CreatePen(c.PS_SOLID, 2, 0x0040D040);
    const old_pen = c.SelectObject(dc, pen);
    defer {
        _ = c.SelectObject(dc, old_pen);
        _ = c.DeleteObject(pen);
    }

    const half: f32 = @floatFromInt(@divTrunc(h, 2) - 6);
    const factor = gain.factorFor(app.gain_pos);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const x = box.left + @as(i32, @intCast(i));
        const y = mid - @as(i32, @intFromFloat(gain.scaled(samples[i], factor) * half));
        if (i == 0) {
            _ = c.MoveToEx(dc, x, y, null);
        } else {
            _ = c.LineTo(dc, x, y);
        }
    }

    const level = app.microphone.ring.level();
    var text: [128]u8 = undefined;
    const note = if (level.isClipping())
        "  ПЕРЕГРУЗ"
    else if (level.isSilent())
        "  тишина"
    else
        "";
    // Число — настоящее: ползунок растягивает картинку, а не вход. Если бы
    // усиление попадало сюда, прибор врал бы: волна большая, запись тихая.
    const line = std.fmt.bufPrint(&text, "{d:.0} дБ{s}", .{ level.dbfs(), note }) catch "";
    _ = c.SetTextColor(dc, if (level.isClipping()) @as(c.COLORREF, 0x004040F0) else @as(c.COLORREF, 0x0060D060));
    const label_rc = c.RECT{ .left = box.left + 6, .top = box.top + 4, .right = box.right - 6, .bottom = box.top + 22 };
    drawTextInRect(dc, label_rc, line);

    // Раз картинка растянута — это должно быть видно на самой картинке,
    // иначе через минуту непонятно, отчего волна такая большая.
    if (app.gain_pos > 0) {
        var gain_buf: [16]u8 = undefined;
        const gain_text = gain.label(app.gain_pos, &gain_buf);
        _ = c.SetTextColor(dc, if (gain.pictureClipped(level.peak, factor)) @as(c.COLORREF, 0x0030A0D0) else @as(c.COLORREF, 0x00909090));
        const gain_rc = c.RECT{ .left = box.right - 60, .top = box.top + 4, .right = box.right - 6, .bottom = box.top + 22 };
        drawTextRight(dc, gain_rc, gain_text);
    }
    _ = hwnd;
}

fn drawTextIn(dc: c.HDC, box: c.RECT, text: []const u8) void {
    const inner = c.RECT{ .left = box.left + 8, .top = box.top + 8, .right = box.right - 8, .bottom = box.bottom - 4 };
    drawTextInRect(dc, inner, text);
}

fn drawTextInRect(dc: c.HDC, rect: c.RECT, text: []const u8) void {
    var wide_buf: [512]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide_buf, text) catch return;
    var rc = rect;
    _ = c.DrawTextW(dc, &wide_buf, @intCast(n), &rc, c.DT_LEFT | c.DT_TOP | c.DT_WORDBREAK);
}

/// То же, но прижав текст к правому краю: подпись усиления стоит в углу поля,
/// и слева от неё — уровень, который может быть любой длины.
fn drawTextRight(dc: c.HDC, rect: c.RECT, text: []const u8) void {
    var wide_buf: [64]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide_buf, text) catch return;
    var rc = rect;
    _ = c.DrawTextW(dc, &wide_buf, @intCast(n), &rc, c.DT_RIGHT | c.DT_TOP | c.DT_SINGLELINE);
}

fn addTray(hwnd: c.HWND) void {
    var nid = std.mem.zeroes(c.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(c.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = 1;
    nid.uFlags = c.NIF_ICON | c.NIF_MESSAGE | c.NIF_TIP;
    nid.uCallbackMessage = wm_tray;
    setAppIcon(&nid.hIcon);
    const tip = wide("Zig-Rec Studio");
    @memcpy(nid.szTip[0..tip.len], tip);
    app.tray_added = c.Shell_NotifyIconW(c.NIM_ADD, &nid) != 0;
}

fn removeTray(hwnd: c.HWND) void {
    if (!app.tray_added) return;
    var nid = std.mem.zeroes(c.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(c.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = 1;
    _ = c.Shell_NotifyIconW(c.NIM_DELETE, &nid);
    app.tray_added = false;
}

fn wndProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_CREATE => {
            app.hwnd = hwnd;
            app.status = c.CreateWindowExW(
                0,
                wide("STATIC"),
                wide("готов"),
                c.WS_CHILD | c.WS_VISIBLE,
                14,
                14,
                480,
                40,
                hwnd,
                null,
                @ptrCast(c.GetModuleHandleW(null)),
                null,
            );
            app.btn_record = button(hwnd, "Записать экран", id_record, 14, 66, 170, 32, c.BS_OWNERDRAW);
            app.btn_area_rec = button(hwnd, "Записать область", id_area_rec, 192, 66, 186, 32, c.BS_OWNERDRAW);
            app.btn_pause = button(hwnd, "Пауза", id_pause, 404, 66, 106, 32, c.BS_OWNERDRAW);

            _ = button(hwnd, "Выбрать область…", id_area, 14, 106, 176, 30, 0);
            _ = button(hwnd, "Весь экран", id_full, 198, 106, 160, 30, 0);
            app.chk_cursor = button(hwnd, "Курсор и клики", id_cursor, 370, 106, 140, 30, c.BS_AUTOCHECKBOX);
            app.chk_sound = button(hwnd, "Звук", id_sound, 14, 232, 90, 24, c.BS_AUTOCHECKBOX);
            // Галочка не должна врать: пока звук слышно, но в файл он не идёт.
            app.lbl_gain = label(hwnd, "Усиление", 14, 328, 90, 20);
            app.slider_gain = gainSlider(hwnd, 106, 322, 320, 30);
            app.lbl_sound_note = label(hwnd, "с галочкой звук идёт и в индикатор, и в файл", 14, 362, 496, 20);

            // Уголок: точка, надпись, кнопка «пуск/стоп» и «?». Про сервер
            // смотрят раз в день — целый ряд посреди окна он не заслужил.
            app.btn_server = button(hwnd, "▶", id_server, 446, 400, 28, 24, 0);
            _ = button(hwnd, "?", id_server_help, 478, 400, 28, 24, 0);
            _ = button(hwnd, "Редактор дорожек…", id_editor, 14, 438, 190, 30, 0);

            // Принимаем файлы, брошенные мышью из проводника.
            c.DragAcceptFiles(hwnd, 1);
            app.lbl_server = label(hwnd, "", 234, 404, 206, 20);

            _ = label(hwnd, "Кадров/с", 14, 152, 90, 20);
            app.cb_fps = combo(hwnd, id_fps, 104, 148, 84, 200);
            for ([_][]const u8{ "15", "24", "30", "60", "120" }) |item| addItem(app.cb_fps, item);
            _ = c.SendMessageW(app.cb_fps, c.CB_SETCURSEL, 2, 0);

            _ = label(hwnd, "Качество", 206, 152, 90, 20);
            app.cb_preset = combo(hwnd, id_preset, 296, 148, 130, 200);
            for ([_][]const u8{ "текст", "видео", "максимум" }) |item| addItem(app.cb_preset, item);
            _ = c.SendMessageW(app.cb_preset, c.CB_SETCURSEL, 0, 0);

            app.btn_open = button(hwnd, "Открыть запись", id_open, 376, 190, 134, 30, 0);
            app.lbl_file = label(hwnd, "", 14, 196, 360, 22);
            _ = c.SendMessageW(app.chk_cursor, c.BM_SETCHECK, 1, 0);
            _ = c.EnableWindow(app.btn_pause, 0);
            _ = c.EnableWindow(app.btn_open, 0);

            for ([_]c.HWND{ app.status, app.btn_record, app.btn_pause, app.btn_open, app.chk_cursor, app.cb_fps, app.cb_preset, app.lbl_file, app.chk_sound, app.lbl_sound_note, app.lbl_gain, app.btn_server, app.lbl_server }) |h| applyFont(h);
            setGainEnabled(false);
            for ([_]c_int{ id_area, id_full, id_area_rec }) |id| applyFont(c.GetDlgItem(hwnd, id));

            buildMenu(hwnd);
            app.refresh_hz = screenRefresh();
            registerHotkeys(hwnd);
            addTray(hwnd);
            _ = c.SetTimer(hwnd, timer_tick, 200, null);
            return 0;
        },
        c.WM_COMMAND => {
            const id = wp & 0xFFFF;
            switch (id) {
                id_record => if (app.rec.isBusy()) stopRecording() else startRecording(),
                id_pause => togglePause(),
                id_open => openLastFile(),
                id_full => {
                    app.area = null;
                    updateStatus();
                },
                id_area => {
                    if (selectArea()) |r| {
                        app.area = r;
                        updateStatus();
                    }
                },
                id_area_rec => {
                    // Два действия: нажали кнопку — обвели рамку — пошла запись.
                    if (app.rec.isBusy()) {
                        stopRecording();
                    } else if (selectArea()) |r| {
                        app.area = r;
                        startRecording();
                    }
                },
                id_fps => {
                    const sel = c.SendMessageW(app.cb_fps, c.CB_GETCURSEL, 0, 0);
                    app.settings.fps = switch (sel) {
                        0 => 15,
                        1 => 24,
                        3 => 60,
                        4 => 120,
                        else => 30,
                    };
                    updateStatus();
                },
                id_preset => {
                    const sel = c.SendMessageW(app.cb_preset, c.CB_GETCURSEL, 0, 0);
                    app.settings.preset = switch (sel) {
                        1 => .video,
                        2 => .max,
                        else => .text_ui,
                    };
                },
                id_sound => {
                    app.sound_on = c.SendMessageW(app.chk_sound, c.BM_GETCHECK, 0, 0) != 0;
                    if (app.sound_on) {
                        app.microphone.start() catch {};
                        _ = c.SetTimer(hwnd, timer_wave, 80, null);
                    } else {
                        _ = c.KillTimer(hwnd, timer_wave);
                        app.microphone.stop();
                    }
                    setGainEnabled(app.sound_on);
                    _ = c.InvalidateRect(hwnd, null, 1);
                },
                id_server => toggleServer(hwnd),
                id_server_help => showServerHelp(hwnd),
                id_editor => openEditor(),
                id_menu_open_dir => openOutputDir(),
                id_recent_base...id_recent_base + recent_mod.max_items - 1 => {
                    openRecent(@intCast((wp & 0xFFFF) - id_recent_base));
                },
                id_menu_exit => _ = c.PostMessageW(hwnd, c.WM_CLOSE, 0, 0),
                id_menu_settings => showSettings(hwnd),
                id_menu_about => showAbout(hwnd),
                id_menu_boost => showBoost(hwnd),
                id_cursor => {
                    const checked = c.SendMessageW(app.chk_cursor, c.BM_GETCHECK, 0, 0) != 0;
                    app.settings.cursor = checked;
                    app.settings.clicks = checked;
                },
                else => {},
            }
            return 0;
        },
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const dc = c.BeginPaint(hwnd, &ps);
            paintWaveBuffered(hwnd, dc);
            drawServerLamp(dc);
            drawDropZone(dc);
            _ = c.EndPaint(hwnd, &ps);
            return 0;
        },
        control.wm_control => {
            const call: *control.Call = @ptrFromInt(@as(usize, @bitCast(lp)));
            serveCall(call);
            return 0;
        },
        c.WM_HSCROLL => {
            // Ползунок один, поэтому разбирать отправителя незачем.
            if (app.slider_gain != null) {
                const pos = c.SendMessageW(app.slider_gain, tbm_getpos, 0, 0);
                app.gain_pos = @intCast(std.math.clamp(pos, 0, gain.max_pos));
                var box = waveRect();
                _ = c.InvalidateRect(hwnd, &box, 0);
            }
            return 0;
        },
        c.WM_DRAWITEM => {
            const item: *c.DRAWITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lp)));
            drawRecordButton(item);
            return 1;
        },
        c.WM_HOTKEY => {
            switch (wp) {
                hotkey_record => if (app.rec.isBusy()) stopRecording() else startRecording(),
                hotkey_pause => togglePause(),
                hotkey_area => areaKeyPressed(),
                else => {},
            }
            return 0;
        },
        c.WM_TIMER => {
            if (wp == timer_wave) {
                var box = waveRect();
                _ = c.InvalidateRect(hwnd, &box, 0);
                return 0;
            }
            if (wp == timer_frame) {
                frame_overlay.animate();
                app.pulse = rec_dot.pulseFromAlpha(frame_overlay.currentAlpha());
                _ = c.InvalidateRect(app.btn_record, null, 0);
                _ = c.InvalidateRect(app.btn_area_rec, null, 0);
                _ = c.InvalidateRect(app.btn_pause, null, 0);
                return 0;
            }
            updateStatus();
            refreshServerRow(hwnd);
            // Запись могла кончиться сама (ошибка, конец времени) — рамку убираем.
            if (frame_overlay.isShown() and !app.rec.isBusy()) {
                _ = c.KillTimer(hwnd, timer_frame);
                frame_overlay.hide();
            }
            return 0;
        },
        remote_win.wm_remote => {
            switch (@as(remote_win.Press, @enumFromInt(wp))) {
                .stop => {
                    stopRecording();
                    updateStatus();
                },
                .pause => togglePause(),
            }
            return 0;
        },
        wm_tray => {
            if (lp == c.WM_LBUTTONUP or lp == c.WM_LBUTTONDBLCLK) {
                if (c.IsWindowVisible(hwnd) != 0) {
                    _ = c.ShowWindow(hwnd, c.SW_HIDE);
                } else {
                    _ = c.ShowWindow(hwnd, c.SW_SHOW);
                    _ = c.SetForegroundWindow(hwnd);
                }
            }
            if (lp == c.WM_RBUTTONUP or lp == c.WM_CONTEXTMENU) showTrayMenu(hwnd);
            return 0;
        },
        wm_dropfiles => {
            onDrop(@bitCast(wp));
            return 0;
        },
        c.WM_KEYDOWN => {
            // Esc убирает окно в трей: запись продолжается, состояние видно
            // по подсказке значка. Закрыть насовсем — крестик или Alt+F4.
            if (wp == c.VK_ESCAPE) {
                // Пульт в кадре мешает записи — его Esc убирает первым:
                // окно спрятать можно и потом, а испорченный кадр не вернёшь.
                if (remote_win.inFrame()) {
                    remote_win.hide();
                    return 0;
                }
                _ = c.ShowWindow(hwnd, c.SW_HIDE);
                return 0;
            }
            return 0;
        },
        c.WM_SIZE => {
            if (wp == c.SIZE_MINIMIZED) _ = c.ShowWindow(hwnd, c.SW_HIDE);
            return 0;
        },
        c.WM_CLOSE => {
            stopRecording();
            app.microphone.stop();
            removeTray(hwnd);
            _ = c.UnregisterHotKey(hwnd, hotkey_record);
            _ = c.UnregisterHotKey(hwnd, hotkey_pause);
            _ = c.UnregisterHotKey(hwnd, hotkey_area);
            _ = c.DestroyWindow(hwnd);
            return 0;
        },
        c.WM_DESTROY => {
            c.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wp, lp);
}

// ------------------------------------------------------- выбор области рамкой

const Selector = struct {
    var start_x: i32 = 0;
    var start_y: i32 = 0;
    var cur_x: i32 = 0;
    var cur_y: i32 = 0;
    var dragging: bool = false;
    var done: bool = false;
    var cancelled: bool = false;
};

fn selectorProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_LBUTTONDOWN => {
            Selector.dragging = true;
            Selector.start_x = @as(i16, @truncate(@as(i32, @intCast(lp & 0xFFFF))));
            Selector.start_y = @as(i16, @truncate(@as(i32, @intCast((lp >> 16) & 0xFFFF))));
            Selector.cur_x = Selector.start_x;
            Selector.cur_y = Selector.start_y;
            return 0;
        },
        c.WM_MOUSEMOVE => {
            if (!Selector.dragging) return 0;
            Selector.cur_x = @as(i16, @truncate(@as(i32, @intCast(lp & 0xFFFF))));
            Selector.cur_y = @as(i16, @truncate(@as(i32, @intCast((lp >> 16) & 0xFFFF))));
            _ = c.InvalidateRect(hwnd, null, 1);
            return 0;
        },
        c.WM_LBUTTONUP => {
            Selector.dragging = false;
            Selector.done = true;
            _ = c.DestroyWindow(hwnd);
            return 0;
        },
        c.WM_KEYDOWN => {
            if (wp == c.VK_ESCAPE) {
                Selector.cancelled = true;
                _ = c.DestroyWindow(hwnd);
            }
            return 0;
        },
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const dc = c.BeginPaint(hwnd, &ps);
            // Затемнение: сплошная заливка, поверх которой лежит прозрачность окна.
            var full: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &full);
            const back = c.CreateSolidBrush(0x00000000);
            _ = c.FillRect(dc, &full, back);
            _ = c.DeleteObject(back);
            if (Selector.dragging) {
                var r = c.RECT{
                    .left = @min(Selector.start_x, Selector.cur_x),
                    .top = @min(Selector.start_y, Selector.cur_y),
                    .right = @max(Selector.start_x, Selector.cur_x),
                    .bottom = @max(Selector.start_y, Selector.cur_y),
                };
                const brush = c.CreateSolidBrush(0x00E0A040);
                _ = c.FrameRect(dc, &r, brush);
                _ = c.DeleteObject(brush);
            }
            _ = c.EndPaint(hwnd, &ps);
            return 0;
        },
        c.WM_DESTROY => {
            // Никакого PostQuitMessage: цикл рамки вложен в цикл главного окна,
            // и WM_QUIT завершил бы оба. Программа закрывалась сразу после
            // выбора области, не начав запись. Выход из вложенного цикла — по
            // флагам done и cancelled.
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wp, lp);
}

/// Затемнить экран и дать обвести прямоугольник. `null` — если передумали.
fn selectArea() ?Rect {
    if (builtin.os.tag != .windows) return null;
    const hinst: c.HINSTANCE = @ptrCast(c.GetModuleHandleW(null));
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = selectorProc;
    wc.hInstance = hinst;
    wc.lpszClassName = wide("ZigRecSelect");
    // Фон не задаём: дескриптор системной кисти не обязан быть выровнен так,
    // как ждёт указатель в Zig, и @alignCast на нём падает. Затемнение рисуем
    // сами в WM_PAINT — заодно видно, что именно закрашивается.
    wc.hbrBackground = null;
    setSystemCursor(&wc.hCursor, idc_cross);
    _ = c.RegisterClassExW(&wc);
    defer _ = c.UnregisterClassW(wide("ZigRecSelect"), hinst);

    const d = source.desktopArea();
    Selector.done = false;
    Selector.cancelled = false;
    Selector.dragging = false;

    const overlay = c.CreateWindowExW(
        c.WS_EX_TOPMOST | c.WS_EX_LAYERED | c.WS_EX_TOOLWINDOW,
        wide("ZigRecSelect"),
        wide("Обведите область, Esc — отмена"),
        c.WS_POPUP,
        d.x,
        d.y,
        @intCast(d.width),
        @intCast(d.height),
        null,
        null,
        hinst,
        null,
    ) orelse return null;
    // Полупрозрачное затемнение: видно, что под рамкой, но понятно, что идёт выбор.
    _ = c.SetLayeredWindowAttributes(overlay, 0, 90, c.LWA_ALPHA);
    _ = c.ShowWindow(overlay, c.SW_SHOW);
    _ = c.SetForegroundWindow(overlay);

    defer app.server.stop();

    var msg: c.MSG = undefined;
    while (c.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
        if (Selector.done or Selector.cancelled) break;
    }
    if (Selector.cancelled or !Selector.done) return null;

    const r = Rect{
        .x = d.x + @min(Selector.start_x, Selector.cur_x),
        .y = d.y + @min(Selector.start_y, Selector.cur_y),
        .width = @intCast(@abs(Selector.cur_x - Selector.start_x)),
        .height = @intCast(@abs(Selector.cur_y - Selector.start_y)),
    };
    const even = r.evenSized();
    // Случайный щелчок без протягивания — это не выбор области.
    if (even.width < 16 or even.height < 16) return null;
    return even;
}

// ------------------------------------------------------------------- запуск

pub fn run(allocator: std.mem.Allocator) !void {
    return runWith(allocator, false);
}

/// `start_hidden` — начать сразу в трее: окно можно не открывать вовсе,
/// хватает значка и горячих клавиш.
pub fn runWith(allocator: std.mem.Allocator, start_hidden: bool) !void {
    return runFull(allocator, start_hidden, false);
}

/// `serve_at_once` — поднять сервер сразу, не дожидаясь нажатия кнопки.
///
/// Для человека сервер поднимается только кнопкой: программа, молча
/// открывающая порт, — не то, что стоит ставить на рабочую машину.
/// Ключ нужен самопроверке, которой некому нажимать кнопки.
pub fn runFull(allocator: std.mem.Allocator, start_hidden: bool, serve_at_once: bool) !void {
    return runInner(allocator, start_hidden, serve_at_once, null);
}

/// Построить окно, замерить раскладку и закрыть, не показывая.
///
/// Тот же путь, что и у настоящего запуска: те же кнопки, тот же порядок.
/// Мерить раскладку по отдельному, «почти такому же» окну значит мерить
/// не то, что видит человек.
pub fn checkLayout(allocator: std.mem.Allocator) !Layout {
    var out = Layout{};
    try runInner(allocator, true, false, &out);
    return out;
}

fn runInner(
    allocator: std.mem.Allocator,
    start_hidden: bool,
    serve_at_once: bool,
    report: ?*Layout,
) !void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    _ = c.SetProcessDPIAware();

    hideOwnConsole();

    app = .{ .allocator = allocator, .rec = recorder.Recorder.init(allocator) };
    app.out_dir = try defaultDir(allocator);
    defer allocator.free(app.out_dir);

    // Где программа хранит своё — до всего остального: оттуда читаются
    // и настройки, и списки недавних.
    var home_buf: [paths.max_path]u8 = undefined;
    app.home = paths.base(&home_buf) catch app.out_dir;

    // Настройки читаем до создания окна: от них зависит и папка, и порт,
    // и то, поднимать ли сервер сразу.
    {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        // Прежние выпуски клали настройки в папку записей. Если там они
        // есть, а на новом месте нет — читаем оттуда: человек не должен
        // обнаружить, что обновление стёрло его выбор.
        app.prefs = if (settings_mod.present(app.home))
            settings_mod.load(threaded.io(), allocator, app.home)
        else
            settings_mod.load(threaded.io(), allocator, app.out_dir);
        app.recent = recent_mod.load(threaded.io(), allocator, app.home);
    }

    const hinst: c.HINSTANCE = @ptrCast(c.GetModuleHandleW(null));
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinst;
    wc.lpszClassName = wide("ZigRecMain");
    wc.hbrBackground = @ptrFromInt(@as(usize, c.COLOR_BTNFACE) + 1);
    setSystemCursor(&wc.hCursor, idc_arrow);
    // Значок класса: он же стоит в заголовке окна и в списке задач.
    setAppIcon(&wc.hIcon);
    setAppIcon(&wc.hIconSm);
    if (c.RegisterClassExW(&wc) == 0) return error.WindowFailed;

    var title_buf: [128]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Zig-Rec Studio v{s}", .{version.VERSION}) catch "Zig-Rec Studio";

    // Размер окна считаем от содержимого, а не подбираем на глаз. Рамка,
    // заголовок и полоса меню у разных версий Windows разной толщины,
    // и зашитое число однажды оказалось на девять точек меньше нужного:
    // нижняя кнопка уехала за край окна.
    var outer = c.RECT{ .left = 0, .top = 0, .right = client_w, .bottom = client_h };
    // Единица — «у окна есть полоса меню»: без неё окно выйдет ниже
    // ровно на её высоту.
    _ = c.AdjustWindowRectEx(&outer, main_style, 1, 0);
    var title_w: [128]u16 = undefined;
    const tn = try std.unicode.utf8ToUtf16Le(&title_w, title);
    title_w[tn] = 0;

    const hwnd = c.CreateWindowExW(
        0,
        wide("ZigRecMain"),
        @ptrCast(&title_w),
        main_style,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        outer.right - outer.left,
        outer.bottom - outer.top,
        null,
        null,
        hinst,
        null,
    ) orelse return error.WindowFailed;
    if (report) |r| {
        // Окно уже собрано: все кнопки созданы в WM_CREATE. Мерим и уходим,
        // не показывая его и не заводя цикл сообщений.
        r.* = measureLayout(hwnd);
        _ = c.DestroyWindow(hwnd);
        return;
    }

    _ = c.ShowWindow(hwnd, if (start_hidden) c.SW_HIDE else c.SW_SHOW);
    _ = c.UpdateWindow(hwnd);
    // Сервер поднимается сам, только если человек это разрешил в настройках
    // или попросил ключом. Молча открывать порт программа не должна.
    if (serve_at_once or app.prefs.serve_at_start) toggleServer(hwnd);
    refreshServerRow(hwnd);

    var msg: c.MSG = undefined;
    while (c.GetMessageW(&msg, null, 0, 0) > 0) {
        // IsDialogMessage даёт Tab, стрелки и пробел по элементам: без него
        // окно управляется только мышью, а по стилю клавиатура наравне.
        if (c.IsDialogMessageW(hwnd, &msg) != 0) continue;
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }
}

// ---------------------------------------------------------------- тесты

test "имя файла для окна берётся по шаблону с датой и временем" {
    var buf: [128]u8 = undefined;
    const stamp = recorder.DateTime{ .year = 2026, .month = 9, .day = 10, .hour = 1, .minute = 2, .second = 3 };
    const name = try recorder.buildName(&buf, "zigrec-%d-%t.mp4", stamp, 1);
    try std.testing.expectEqualStrings("zigrec-2026-09-10-01-02-03.mp4", name);
}

test "надпись не переписывается, когда текст не изменился" {
    // Проверяем на настоящем окне Windows, а не на пересказе правила: ошибиться
    // тут можно как раз на стыке с системой — в длине, в нуле на конце,
    // в усечении буфера. Именно из-за такой безусловной записи окно моргало
    // пять раз в секунду.
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const hwnd = c.CreateWindowExW(
        0,
        wide("STATIC"),
        wide(""),
        c.WS_POPUP,
        0,
        0,
        200,
        40,
        null,
        null,
        @ptrCast(c.GetModuleHandleW(null)),
        null,
    ) orelse return error.SkipZigTest;
    defer _ = c.DestroyWindow(hwnd);

    setText(hwnd, "готов · источник: весь экран");

    var same: [128]u16 = undefined;
    const n = try std.unicode.utf8ToUtf16Le(&same, "готов · источник: весь экран");
    try std.testing.expect(sameText(hwnd, same[0..n]));

    // Тот же текст — писать нечего.
    var other: [128]u16 = undefined;
    const m = try std.unicode.utf8ToUtf16Le(&other, "идёт запись  00:07");
    try std.testing.expect(!sameText(hwnd, other[0..m]));

    // Более короткий текст не должен «совпасть» с началом длинного.
    var prefix: [128]u16 = undefined;
    const k = try std.unicode.utf8ToUtf16Le(&prefix, "готов");
    try std.testing.expect(!sameText(hwnd, prefix[0..k]));

    // А после настоящей смены текста совпадение переезжает на новый.
    setText(hwnd, "идёт запись  00:07");
    try std.testing.expect(sameText(hwnd, other[0..m]));
    try std.testing.expect(!sameText(hwnd, same[0..n]));
}
