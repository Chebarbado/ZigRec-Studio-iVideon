//! Окно редактора: дорожки видно, клипы можно резать, двигать и обрезать.
//!
//! Задача #24. Окно нарочно тонкое: вся правка — в `timeline.zig`, вся
//! арифметика вида и попаданий мышью — в `editor_view.zig`, и обе проверены
//! тестами. Здесь остаётся рисование и перевод движений мыши в вызовы модели.
//!
//! Вид тот же, что у окна записи: системные кнопки, ничего лишнего, всё
//! читается с одного взгляда. Полоса дорожки говорит, что на ней лежит:
//! у видео одна заливка, у звука другая.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;
const timeline = @import("timeline.zig");
const view_mod = @import("editor_view.zig");
const media = @import("../file/media.zig");
const waveform = @import("../file/waveform.zig");
const project_file = @import("../file/project_file.zig");
const player_mod = @import("../file/player.zig");
const settings_mod = @import("../app/settings.zig");
const paths = @import("../app/paths.zig");
const recent_mod = @import("../app/recent.zig");
const png = @import("../file/png.zig");
const ui = @import("../app/ui.zig");

const View = view_mod.View;
const Target = view_mod.Target;

const id_open = 201;
const id_split = 202;
const id_delete = 203;
const id_ripple = 204;
const id_compact = 205;
const id_undo = 206;
const id_redo = 207;
const id_save = 208;
const id_add_video = 209;
const id_add_audio = 210;
const id_play = 211;
const id_shot = 212;
const id_rename_box = 213;
const id_link = 214;
const id_menu_open = 301;
const id_menu_save = 302;
const id_menu_close = 303;
/// Номера строк в списках недавних. Два ряда подряд, по одному на список.
const id_recent_rec = 700;
const id_recent_view = 740;

/// Высота панели кнопок. Таймлайн начинается под ней.
/// Два ряда: сверху файл и дорожки, снизу правка.
const toolbar_h: i32 = 82;
/// Высота строки сообщения снизу.
const status_h: i32 = 22;
/// Высота окна предпросмотра над таймлайном.
///
/// Не постоянная величина: границу тянут мышью, и подогнанная высота
/// переживает перезапуск — лежит в настройках.
var preview_h: i32 = 260;
/// Такт воспроизведения. Тридцать раз в секунду: чаще человек не заметит,
/// реже — заметит рывки.
const timer_play = 1;

/// Дескриптор курсора — не адрес, а номер в таблице ядра, и выровнен он
/// как попало. Приведение его к типизированному указателю Zig в безопасном
/// режиме падает — это пятая встреча с одной и той же ловушкой в этом
/// проекте. Объявляем `SetCursor` так, чтобы приводить было нечего.
const setCursorRaw = @extern(
    *const fn (?*anyopaque) callconv(.winapi) ?*anyopaque,
    .{ .name = "SetCursor" },
);

/// Та же ловушка, шестая встреча: `HDROP` приходит числом в `wParam`,
/// и превратить его в типизированный указатель Zig нельзя — упадёт
/// на проверке выравнивания. Объявляем приёмники с целым параметром.
const dragQueryFileW = @extern(
    *const fn (usize, c.UINT, ?[*]u16, c.UINT) callconv(.winapi) c.UINT,
    .{ .name = "DragQueryFileW" },
);
const dragQueryPoint = @extern(
    *const fn (usize, *c.POINT) callconv(.winapi) c.BOOL,
    .{ .name = "DragQueryPoint" },
);
const dragFinish = @extern(
    *const fn (usize) callconv(.winapi) void,
    .{ .name = "DragFinish" },
);

/// Та же ловушка, седьмая встреча: прежний обработчик поля ввода
/// приходит числом, и превращать его в типизированный указатель Zig
/// незачем — держим числом и числом же отдаём обратно.
const callWindowProcW = @extern(
    *const fn (usize, c.HWND, c.UINT, c.WPARAM, c.LPARAM) callconv(.winapi) c.LRESULT,
    .{ .name = "CallWindowProcW" },
);

/// Сообщение о брошенных файлах.
const wm_dropfiles = 0x0233;

/// Волна посчиталась: пора перерисовать дорожку.
const wm_wave_ready = c.WM_APP + 3;

/// Держат ли Alt — «сделать врозь, не трогая связку».
///
/// Alt, а не кнопка на панели: решение принимается в тот момент, когда
/// клип уже взят мышью, и тянуться в этот момент к панели неудобно.
/// Так же это делают и в других монтажных программах.
fn apart() bool {
    return c.GetKeyState(c.VK_MENU) < 0;
}

/// Окно должно получать двойные щелчки: без этого признака Windows
/// присылает два одиночных, и переименование не начинается никогда.
const cs_dblclks: c.UINT = 0x0008;

/// Что человек тянет мышью прямо сейчас.
const Drag = enum { none, playhead, clip, trim_left, trim_right, splitter };

const Editor = struct {
    allocator: std.mem.Allocator,
    hwnd: c.HWND = null,
    project: *timeline.Project = undefined,
    view: View = .{},

    /// Указатель воспроизведения.
    playhead_ns: u64 = 0,
    /// Выбранный клип: дорожка и номер.
    has_selection: bool = false,
    sel_track: usize = 0,
    sel_clip: usize = 0,

    drag: Drag = .none,
    /// Смещение от начала клипа до точки захвата — чтобы клип не прыгал
    /// под курсор своим левым краем.
    drag_grab_ns: u64 = 0,
    drag_started: bool = false,
    /// Тянут ли врозь. Решается один раз, когда клип взят мышью: если
    /// спрашивать клавиатуру на каждом движении, половина перетаскивания
    /// пройдёт со связкой, а половина без, и результат не объяснить.
    drag_apart: bool = false,

    status: c.HWND = null,
    btn_undo: c.HWND = null,
    btn_redo: c.HWND = null,
    btn_link: c.HWND = null,

    /// Волна каждого открытого файла. По исходнику на ячейку, номера те же,
    /// что у исходников проекта.
    waves: [timeline.max_sources]waveform.Envelope = @splat(.{}),

    /// Открытый проигрыватель и чей исходник он показывает.
    player: ?player_mod.Player = null,
    player_source: u16 = 0,
    /// Идёт ли воспроизведение.
    playing: bool = false,
    /// Когда был предыдущий такт — чтобы время шло по часам, а не по тактам.
    last_tick_ns: u64 = 0,
    btn_play: c.HWND = null,

    /// Дорожка, с которой работают: её переименовывает F2.
    cur_track: usize = 0,
    /// Где лежит своё: настройки и списки недавних.
    home: [paths.max_path]u8 = @splat(0),
    home_len: usize = 0,
    /// Недавно записанное и недавно просмотренное.
    recent: recent_mod.Recent = .{},

    /// Поле ввода имени, открытое поверх полосы дорожки.
    name_box: c.HWND = null,
    /// Чьё имя правим и какой обработчик у поля был до нас.
    name_track: usize = 0,
    name_prev_proc: usize = 0,

    /// Последнее сообщение человеку.
    note: [256]u8 = @splat(0),
    note_len: usize = 0,

    fn say(self: *Editor, text: []const u8) void {
        const n = @min(text.len, self.note.len);
        @memcpy(self.note[0..n], text[0..n]);
        self.note_len = n;
    }

    fn message(self: *const Editor) []const u8 {
        return self.note[0..self.note_len];
    }
};

var ed: Editor = undefined;

// ------------------------------------------------------------------ цвета

// Записаны как BGR: так их ждёт Windows.
const col_lane: c.COLORREF = 0x00F2F2F2;
const col_lane_line: c.COLORREF = 0x00D8D8D8;
const col_video: c.COLORREF = 0x00C89A5A;
const col_video_edge: c.COLORREF = 0x00A87A3A;
const col_audio: c.COLORREF = 0x006FB36F;
const col_audio_edge: c.COLORREF = 0x004F934F;
const col_selected: c.COLORREF = 0x002E2EE8;
const col_wave: c.COLORREF = 0x00306B30;
const col_playhead: c.COLORREF = 0x002020C0;
const col_ruler: c.COLORREF = 0x00FAFAFA;
const col_text: c.COLORREF = 0x00303030;
const col_muted: c.COLORREF = 0x00BFBFBF;

fn solid(dc: c.HDC, rect: c.RECT, color: c.COLORREF) void {
    var r = rect;
    const brush = c.CreateSolidBrush(color);
    defer _ = c.DeleteObject(@ptrCast(brush));
    _ = c.FillRect(dc, &r, brush);
}

fn line(dc: c.HDC, x1: i32, y1: i32, x2: i32, y2: i32, color: c.COLORREF, width: i32) void {
    const pen = c.CreatePen(c.PS_SOLID, width, color);
    defer _ = c.DeleteObject(@ptrCast(pen));
    const old = c.SelectObject(dc, @ptrCast(pen));
    defer _ = c.SelectObject(dc, old);
    _ = c.MoveToEx(dc, x1, y1, null);
    _ = c.LineTo(dc, x2, y2);
}

fn drawText(dc: c.HDC, x: i32, y: i32, s: []const u8, color: c.COLORREF) void {
    var buf: [256]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, s) catch return;
    _ = c.SetTextColor(dc, color);
    _ = c.SetBkMode(dc, c.TRANSPARENT);
    _ = c.TextOutW(dc, x, y, &buf, @intCast(n));
}

// ---------------------------------------------------------------- рисование

fn paint(hwnd: c.HWND, dc: c.HDC, width: i32, height: i32) void {
    solid(dc, .{ .left = 0, .top = 0, .right = width, .bottom = height }, 0x00FFFFFF);
    // Полоса под кнопками: фон окна мы рисуем сами, иначе под ними останется
    // мусор от предыдущего кадра.
    solid(dc, .{ .left = 0, .top = 0, .right = width, .bottom = toolbar_h }, 0x00F0F0F0);
    line(dc, 0, toolbar_h - 1, width, toolbar_h - 1, col_lane_line, 1);

    const font = c.GetStockObject(c.DEFAULT_GUI_FONT);
    const old_font = c.SelectObject(dc, font);
    defer _ = c.SelectObject(dc, old_font);

    // Сообщение снизу — там же, где у окна записи строка состояния.
    solid(dc, .{ .left = 0, .top = height - status_h, .right = width, .bottom = height }, 0x00F5F5F5);
    drawText(dc, 10, height - status_h + 3, ed.message(), col_text);

    drawPreview(dc, width);
    drawSplitter(dc, width);

    // Ниже — таймлайн со своим началом координат. Так арифметика вида
    // остаётся той, что проверена тестами, и считает от нуля.
    const lane_height = height - toolbar_h - preview_h - view_mod.splitter_h - status_h;
    if (lane_height <= 0) return;
    _ = c.SetViewportOrgEx(dc, 0, toolbar_h + preview_h + view_mod.splitter_h, null);
    defer _ = c.SetViewportOrgEx(dc, 0, 0, null);

    drawRuler(dc, width);
    drawTracks(dc, width, lane_height);
    drawEmptyHint(dc, width, lane_height);
    drawPlayhead(dc, lane_height);
    _ = hwnd;
}

/// Окно предпросмотра: кадр, который сейчас под указателем.
///
/// Чёрное поле, а не серое: на чёрном видно настоящие края кадра, и глаз
/// не принимает поля за часть картинки.
fn drawPreview(dc: c.HDC, width: i32) void {
    const top = toolbar_h;
    const bottom = top + preview_h;
    solid(dc, .{ .left = 0, .top = top, .right = width, .bottom = bottom }, 0x00202020);
    line(dc, 0, bottom - 1, width, bottom - 1, 0x00808080, 1);

    // Время под указателем — всегда, даже когда кадра нет.
    var time_buf: [64]u8 = undefined;
    const stamp = view_mod.timeLabel(&time_buf, ed.playhead_ns, std.time.ns_per_ms * 100);
    drawText(dc, 10, bottom - 22, stamp, 0x00C0C0C0);

    const p = &(ed.player orelse {
        drawCentered(dc, width, top, bottom, "здесь будет кадр: поставьте указатель на клип", 0x00808080);
        return;
    });
    if (!p.ready) {
        drawCentered(dc, width, top, bottom, "кадр не читается", 0x008080C0);
        return;
    }

    const box_h = preview_h - 28;
    const fit = player_mod.fitInto(p.width, p.height, width, box_h);
    if (fit.w <= 0 or fit.h <= 0) return;

    // Направление строк берём у самого кадра: положительная высота —
    // строки снизу вверх, отрицательная — сверху вниз.
    var info = std.mem.zeroes(c.BITMAPINFO);
    info.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    info.bmiHeader.biWidth = @intCast(p.width);
    info.bmiHeader.biHeight = if (p.bottom_up)
        @as(i32, @intCast(p.height))
    else
        -@as(i32, @intCast(p.height));
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = c.BI_RGB;

    _ = c.SetStretchBltMode(dc, c.HALFTONE);
    _ = c.StretchDIBits(
        dc,
        fit.x,
        top + fit.y,
        fit.w,
        fit.h,
        0,
        0,
        @intCast(p.width),
        @intCast(p.height),
        p.pixels.ptr,
        &info,
        c.DIB_RGB_COLORS,
        c.SRCCOPY,
    );
}

/// Полоса-граница между кадром и таймлайном.
///
/// Три чёрточки посередине — общепринятый знак «это тянется». Без него
/// полосу принимают за рамку и не пробуют трогать.
fn drawSplitter(dc: c.HDC, width: i32) void {
    const top = toolbar_h + preview_h;
    solid(dc, .{
        .left = 0,
        .top = top,
        .right = width,
        .bottom = top + view_mod.splitter_h,
    }, 0x00E4E4E4);

    const middle = @divTrunc(width, 2);
    var shift: i32 = -14;
    while (shift <= 14) : (shift += 14) {
        solid(dc, .{
            .left = middle + shift - 5,
            .top = top + 2,
            .right = middle + shift + 5,
            .bottom = top + 4,
        }, 0x00A6A6A6);
    }
}

/// Строка посередине поля.
fn drawCentered(dc: c.HDC, width: i32, top: i32, bottom: i32, text_line: []const u8, color: c.COLORREF) void {
    var wide_buf: [160]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide_buf, text_line) catch return;
    var size: c.SIZE = undefined;
    if (c.GetTextExtentPoint32W(dc, &wide_buf, @intCast(n), &size) == 0) return;
    drawText(dc, @divTrunc(width - size.cx, 2), @divTrunc(top + bottom - size.cy, 2), text_line, color);
}

/// Подсказка на пустом таймлайне.
///
/// Пустое окно ничего не говорит о себе. Одна строка посередине говорит
/// ровно то, что человеку нужно знать первым.
fn drawEmptyHint(dc: c.HDC, width: i32, height: i32) void {
    if (ed.project.track_count > 0) return;
    const hint = "Откройте файл или добавьте дорожку кнопкой сверху";
    // Считаем ширину строки, чтобы поставить её посередине, а не «примерно».
    var wide_buf: [128]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide_buf, hint) catch return;
    var size: c.SIZE = undefined;
    if (c.GetTextExtentPoint32W(dc, &wide_buf, @intCast(n), &size) == 0) return;
    drawText(
        dc,
        @divTrunc(width + view_mod.header_w - size.cx, 2),
        @divTrunc(height, 2) - 8,
        hint,
        0x00909090,
    );
}

fn drawRuler(dc: c.HDC, width: i32) void {
    const r = c.RECT{ .left = 0, .top = 0, .right = width, .bottom = view_mod.ruler_h };
    solid(dc, r, col_ruler);
    line(dc, 0, view_mod.ruler_h - 1, width, view_mod.ruler_h - 1, col_lane_line, 1);

    const step = ed.view.rulerStepNs();
    if (step == 0) return;
    // Начинаем с ближайшего деления левее видимого края.
    var when = ed.view.at_ns / step * step;
    var guard: usize = 0;
    while (guard < 4096) : (guard += 1) {
        const x = ed.view.timeToX(when);
        if (x > width) break;
        if (x >= view_mod.header_w) {
            line(dc, x, view_mod.ruler_h - 8, x, view_mod.ruler_h - 1, col_lane_line, 1);
            var buf: [32]u8 = undefined;
            drawText(dc, x + 3, 4, view_mod.timeLabel(&buf, when, step), col_text);
        }
        when += step;
    }
}

fn drawTracks(dc: c.HDC, width: i32, height: i32) void {
    for (ed.project.trackList(), 0..) |track, index| {
        const top = ed.view.laneTop(index);
        if (top > height) break;
        const bottom = top + view_mod.lane_h;

        // Полоса.
        solid(dc, .{ .left = view_mod.header_w, .top = top, .right = width, .bottom = bottom }, col_lane);
        line(dc, view_mod.header_w, bottom, width, bottom, col_lane_line, 1);

        // Левая колонка: имя и что за дорожка.
        solid(dc, .{ .left = 0, .top = top, .right = view_mod.header_w, .bottom = bottom }, 0x00FFFFFF);
        line(dc, view_mod.header_w - 1, top, view_mod.header_w - 1, bottom, col_lane_line, 1);
        drawText(dc, 10, top + 8, track.title(), col_text);

        var kind_buf: [64]u8 = undefined;
        const kind_text = std.fmt.bufPrint(&kind_buf, "{s}{s}", .{
            track.kind.label(),
            if (track.muted) " · выключена" else "",
        }) catch track.kind.label();
        drawText(dc, 10, top + 28, kind_text, if (track.muted) col_muted else 0x00808080);

        drawClips(dc, track, index, top, width);
    }
}

fn drawClips(dc: c.HDC, track: timeline.Track, track_index: usize, top: i32, width: i32) void {
    const body = if (track.kind == .video) col_video else col_audio;
    const edge = if (track.kind == .video) col_video_edge else col_audio_edge;

    for (track.list(), 0..) |clip, i| {
        var left = ed.view.timeToX(clip.at_ns);
        var right = ed.view.timeToX(clip.endsAt());
        if (right < view_mod.header_w or left > width) continue;
        left = @max(left, view_mod.header_w);
        right = @min(right, width);
        if (right - left < 2) right = left + 2;

        const rect = c.RECT{ .left = left, .top = top + 4, .right = right, .bottom = top + view_mod.lane_h - 4 };
        solid(dc, rect, if (track.muted) col_muted else body);

        const selected = ed.has_selection and ed.sel_track == track_index and ed.sel_clip == i;
        const frame_color = if (selected) col_selected else edge;
        const frame_width: i32 = if (selected) 2 else 1;
        line(dc, rect.left, rect.top, rect.right, rect.top, frame_color, frame_width);
        line(dc, rect.left, rect.bottom, rect.right, rect.bottom, frame_color, frame_width);
        line(dc, rect.left, rect.top, rect.left, rect.bottom, frame_color, frame_width);
        line(dc, rect.right - 1, rect.top, rect.right - 1, rect.bottom, frame_color, frame_width);

        if (track.kind == .audio and !track.muted) drawWave(dc, clip, rect);
        if (clip.link != 0) drawLinkMark(dc, rect);

        // Подпись помещается — пишем. Не помещается — не пишем: обрезанное
        // слово читается хуже, чем его отсутствие.
        if (right - left > 60) {
            const src = ed.project.sourceList();
            const name = if (clip.source < src.len) src[clip.source].name() else "клип";
            var len_buf: [32]u8 = undefined;
            const len_text = view_mod.lengthLabel(&len_buf, clip.len_ns);

            // Под подписью — своя подложка: поверх волны буквы не читаются,
            // а волна под буквами перестаёт быть волной.
            const label_w = @min(@as(i32, @intCast(6 + @max(name.len, len_text.len) * 7)), right - left - 4);
            solid(dc, .{
                .left = left + 2,
                .top = rect.top + 2,
                .right = left + 2 + label_w,
                .bottom = rect.top + 38,
            }, if (track.muted) col_muted else body);

            drawText(dc, left + 6, rect.top + 4, name, 0x00202020);
            drawText(dc, left + 6, rect.top + 22, len_text, 0x00404040);
        }
    }
}

/// Значок связки: два звена цепи в правом верхнем углу клипа.
///
/// Без значка связку нечем увидеть: человек тянет видео, звук едет следом,
/// и почему — непонятно. Рисуем справа, потому что слева стоит подпись.
fn drawLinkMark(dc: c.HDC, rect: c.RECT) void {
    const x = rect.right - 26;
    const y = rect.top + 5;
    // Не влезает — не рисуем: обрезанный значок хуже, чем его отсутствие.
    if (x < rect.left + 4) return;
    ring(dc, x, y);
    ring(dc, x + 8, y);
}

fn ring(dc: c.HDC, x: i32, y: i32) void {
    const col: c.COLORREF = 0x00404040;
    line(dc, x, y, x + 11, y, col, 1);
    line(dc, x, y + 8, x + 11, y + 8, col, 1);
    line(dc, x, y, x, y + 8, col, 1);
    line(dc, x + 10, y, x + 10, y + 8, col, 1);
}

/// Волна внутри клипа.
///
/// Рисуем столбиками от средней линии вверх и вниз: так видно и громкость,
/// и то, что это звук, а не заливка. Берём пик на отрезке, который
/// приходится на столбик, а не значение в точке — иначе при мелком масштабе
/// волна превращается в случайный узор из попавших под пиксель отсчётов.
fn drawWave(dc: c.HDC, clip: timeline.Clip, rect: c.RECT) void {
    if (clip.source >= ed.waves.len) return;
    const env = &ed.waves[clip.source];
    if (!env.ready or clip.len_ns == 0) return;

    const width = rect.right - rect.left;
    if (width < 4) return;
    const middle = @divTrunc(rect.top + rect.bottom, 2);
    const half = @divTrunc(rect.bottom - rect.top, 2) - 3;
    if (half <= 0) return;

    const pen = c.CreatePen(c.PS_SOLID, 1, col_wave);
    defer _ = c.DeleteObject(@ptrCast(pen));
    const old = c.SelectObject(dc, @ptrCast(pen));
    defer _ = c.SelectObject(dc, old);

    var x: i32 = 0;
    while (x < width) : (x += 1) {
        // Какой кусок исходника показывает этот столбик.
        const from = clip.in_ns + @as(u64, @intCast(x)) * clip.len_ns / @as(u64, @intCast(width));
        const to = clip.in_ns + @as(u64, @intCast(x + 1)) * clip.len_ns / @as(u64, @intCast(width));
        const peak = env.relativeBetween(from, to);
        const h: i32 = @intFromFloat(peak * @as(f32, @floatFromInt(half)));
        if (h <= 0) continue;
        _ = c.MoveToEx(dc, rect.left + x, middle - h, null);
        _ = c.LineTo(dc, rect.left + x, middle + h);
    }

    // Средняя линия — чтобы тишина читалась как тишина, а не как пустое место.
    line(dc, rect.left, middle, rect.right, middle, col_wave, 1);
}

fn drawPlayhead(dc: c.HDC, height: i32) void {
    const x = ed.view.timeToX(ed.playhead_ns);
    if (x < view_mod.header_w) return;
    line(dc, x, 0, x, height, col_playhead, 1);
    // Треугольник сверху, чтобы указатель было за что взять глазом.
    var i: i32 = 0;
    while (i < 6) : (i += 1) {
        line(dc, x - 6 + i, i, x + 6 - i, i, col_playhead, 1);
    }
}

// ------------------------------------------------------------------ работа

/// Показать кадр, который приходится на указатель.
///
/// Клип помнит, из какого места файла он взят, поэтому время в файле —
/// это не время на дорожке: надо перевести одно в другое, иначе после
/// обрезки картинка поедет.
fn showFrame() void {
    const found = clipUnderPlayhead() orelse {
        if (ed.player) |*p| {
            p.close();
            ed.player = null;
        }
        return;
    };
    const clip = found.clip;

    if (ed.player == null or ed.player_source != clip.source) {
        if (ed.player) |*p| p.close();
        ed.player = null;

        const sources = ed.project.sourceList();
        if (clip.source >= sources.len) return;
        ed.player = player_mod.Player.open(ed.allocator, sources[clip.source].fullPath()) catch {
            ed.say("кадр из этого файла не читается: в нём нет картинки");
            return;
        };
        ed.player_source = clip.source;
    }

    // Время на дорожке → время внутри файла.
    const inside = clip.in_ns + (ed.playhead_ns -| clip.at_ns);
    if (ed.player) |*p| p.showAt(inside) catch {};
}

const FoundClip = struct { track: usize, clip: timeline.Clip };

/// Клип с картинкой под указателем. Ищем по видеодорожкам сверху вниз:
/// верхняя дорожка — то, что видит зритель.
fn clipUnderPlayhead() ?FoundClip {
    for (ed.project.trackList(), 0..) |track, i| {
        if (track.kind != .video or track.muted) continue;
        if (track.clipAt(ed.playhead_ns)) |index| {
            return .{ .track = i, .clip = track.clips[index] };
        }
    }
    return null;
}

/// Пустить или остановить воспроизведение.
fn togglePlay() void {
    if (ed.project.durationNs() == 0) {
        ed.say("играть нечего: на дорожках пусто");
        refresh();
        return;
    }
    ed.playing = !ed.playing;
    if (ed.playing) {
        // Дошли до конца — начинаем сначала, а не стоим на месте.
        if (ed.playhead_ns >= ed.project.durationNs()) ed.playhead_ns = 0;
        ed.last_tick_ns = win32.nowNs();
        _ = c.SetTimer(ed.hwnd, timer_play, 33, null);
        ui.setText(ed.btn_play, "⏸ Пауза");
        ed.say("играю");
    } else {
        _ = c.KillTimer(ed.hwnd, timer_play);
        ui.setText(ed.btn_play, "▶ Играть");
        ed.say("пауза");
    }
    showFrame();
    refresh();
}

/// Такт воспроизведения.
///
/// Время идёт по часам, а не по числу тактов: такт может задержаться,
/// и считать по тактам значит проигрывать медленнее, чем на самом деле.
fn onPlayTick() void {
    if (!ed.playing) return;
    const now = win32.nowNs();
    const step = now -| ed.last_tick_ns;
    ed.last_tick_ns = now;

    ed.playhead_ns += step;
    const total = ed.project.durationNs();
    if (ed.playhead_ns >= total) {
        ed.playhead_ns = total;
        ed.playing = false;
        _ = c.KillTimer(ed.hwnd, timer_play);
        ui.setText(ed.btn_play, "▶ Играть");
        ed.say("конец");
    }
    showFrame();
    // Во время игры меняются только кадр и указатель. Перерисовывать ради
    // них всё окно значит тридцать раз в секунду закрашивать и место под
    // кнопками — они мигали именно поэтому.
    refreshStage();
}

/// Перерисовать только кадр и таймлайн, не трогая панель кнопок.
fn refreshStage() void {
    var rect: c.RECT = undefined;
    if (c.GetClientRect(ed.hwnd, &rect) == 0) return refresh();
    rect.top = toolbar_h;
    _ = c.InvalidateRect(ed.hwnd, &rect, 0);
}

fn refresh() void {
    _ = c.InvalidateRect(ed.hwnd, null, 0);
    _ = c.EnableWindow(ed.btn_undo, if (ed.project.canUndo()) 1 else 0);
    _ = c.EnableWindow(ed.btn_redo, if (ed.project.canRedo()) 1 else 0);
    // Одна кнопка вместо двух: развязать можно только связанное, связать —
    // только развязанное, и держать рядом две кнопки, из которых одна
    // всегда бесполезна, значит занимать место ничем.
    ui.setText(ed.btn_link, if (selectedLink() != 0) "⛓ Развязать" else "🔗 Связать");
}

/// Номер связки у выбранного клипа. Ноль — клип сам по себе или не выбран.
fn selectedLink() u16 {
    if (!ed.has_selection) return 0;
    if (ed.sel_track >= ed.project.track_count) return 0;
    const t = &ed.project.tracks[ed.sel_track];
    if (ed.sel_clip >= t.count) return 0;
    return t.clips[ed.sel_clip].link;
}

/// Связать то, что стоит под указателем, или развязать выбранное.
fn toggleLink() void {
    if (selectedLink() != 0) {
        ed.project.unlink(ed.sel_track, ed.sel_clip) catch |err| return complain(err);
        ed.say("связка снята: теперь звук и картинка двигаются порознь");
        refresh();
        return;
    }
    const n = ed.project.linkUnder(ed.playhead_ns) catch |err| {
        if (err == timeline.Error.NothingThere) {
            ed.say("связывать нечего: под указателем должно быть хотя бы два клипа");
            refresh();
            return;
        }
        return complain(err);
    };
    var buf: [128]u8 = undefined;
    ed.say(std.fmt.bufPrint(&buf, "связано клипов: {d} — теперь они ходят вместе", .{n}) catch "связано");
    refresh();
}

/// Сказать, что не вышло, словами — а не проглотить ошибку.
fn complain(err: anyerror) void {
    ed.say(switch (err) {
        timeline.Error.TooShort => "слишком короткий кусок: резать или обрезать тут нечего",
        timeline.Error.NothingThere => "в этой точке ничего нет",
        timeline.Error.NoSuchThing => "так нельзя: видео и звук живут на своих дорожках",
        timeline.Error.TooManyClips => "на дорожке больше не помещается клипов",
        timeline.Error.TooManyTracks => "больше дорожек не помещается",
        timeline.Error.TooManySources => "больше открытых файлов не помещается",
        else => "не получилось",
    });
    refresh();
}

fn openFile() void {
    // Список форматов длинный, и перевод его в UTF-16 на этапе сборки
    // упирается в счётчик шагов вычисления. Поднимаем предел здесь, а не
    // укорачиваем список: список нужен человеку, а предел — только сборке.
    @setEvalBranchQuota(20000);
    var path: [1024]u16 = @splat(0);
    var ofn = std.mem.zeroes(c.OPENFILENAMEW);
    ofn.lStructSize = @sizeOf(c.OPENFILENAMEW);
    ofn.hwndOwner = ed.hwnd;
    ofn.lpstrFile = &path;
    ofn.nMaxFile = path.len;
    // Список форматов: сначала «всё, что мы открываем», потом по отдельности.
    ofn.lpstrFilter = ui.wide(
        "Проекты, видео и звук\x00*.zrs;*.mp4;*.mov;*.avi;*.mp3;*.wav;*.ogg;*.flac;*.mid;*.midi\x00" ++
            "Проект Zig-Rec\x00*.zrs\x00" ++
            "Видео\x00*.mp4;*.mov;*.avi\x00" ++
            "Звук\x00*.mp3;*.wav;*.ogg;*.flac;*.mid;*.midi\x00" ++
            "Все файлы\x00*.*\x00\x00",
    );
    ofn.Flags = c.OFN_FILEMUSTEXIST | c.OFN_PATHMUSTEXIST | c.OFN_NOCHANGEDIR;
    if (c.GetOpenFileNameW(&ofn) == 0) return;

    var utf8: [1024]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&utf8, std.mem.sliceTo(&path, 0)) catch return;
    const chosen = utf8[0..len];

    // Что открыли — проект или запись — решаем по содержимому, а не по
    // расширению: расширение врёт так же, как у видеофайлов.
    if (looksLikeProject(chosen)) loadProject(chosen) else addFile(chosen);
}

/// Начинается ли файл подписью проекта.
fn looksLikeProject(path: []const u8) bool {
    var wide: [std.fs.max_path_bytes]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, path) catch return false;
    wide[n] = 0;
    const handle = c.CreateFileW(
        @ptrCast(&wide),
        c.GENERIC_READ,
        c.FILE_SHARE_READ,
        null,
        c.OPEN_EXISTING,
        c.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == c.INVALID_HANDLE_VALUE) return false;
    defer _ = c.CloseHandle(handle);

    var head: [64]u8 = undefined;
    var got: c.DWORD = 0;
    if (c.ReadFile(handle, &head, head.len, &got, null) == 0) return false;
    return got >= project_file.magic.len and
        std.mem.eql(u8, head[0..project_file.magic.len], project_file.magic);
}

/// Прочитать проект с диска.
fn loadProject(path: []const u8) void {
    var threaded: std.Io.Threaded = .init(ed.allocator, .{});
    defer threaded.deinit();

    const data = std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, ed.allocator, .limited(1 << 22)) catch {
        ed.say("файл проекта не читается");
        refresh();
        return;
    };
    defer ed.allocator.free(data);

    project_file.read(ed.project, data) catch |err| {
        ed.say(project_file.explain(err));
        refresh();
        return;
    };

    // Волны считаем заново: в проекте их нет, там только пути.
    // Файл мог и переехать — тогда волны просто не будет, а дорожка
    // останется на месте.
    var missing: usize = 0;
    for (ed.project.sourceList(), 0..) |src, i| {
        if (i >= ed.waves.len) break;
        ed.waves[i] = waveform.read(src.fullPath()) catch blk: {
            missing += 1;
            break :blk .{};
        };
    }

    ed.has_selection = false;
    ed.playhead_ns = 0;
    fitToProject();

    var buf: [320]u8 = undefined;
    ed.say(if (missing > 0)
        std.fmt.bufPrint(&buf, "{s}: дорожек {d}, но {d} исходник(ов) не нашлось на месте", .{
            std.fs.path.basename(path),
            ed.project.track_count,
            missing,
        }) catch "проект открыт"
    else
        std.fmt.bufPrint(&buf, "{s}: проект открыт, дорожек {d}", .{
            std.fs.path.basename(path),
            ed.project.track_count,
        }) catch "проект открыт");
    refresh();
}

/// Сохранить проект: спросить имя и записать текстом.
/// Завести пустую дорожку.
///
/// Дорожка нужна раньше того, что на неё ляжет: на неё перетаскивают клипы
/// с других дорожек, на неё пишут озвучку. Пустая дорожка — это не мусор,
/// а место, которое человек приготовил себе заранее.
fn addEmptyTrack(kind: timeline.TrackKind) void {
    var name_buf: [48]u8 = undefined;
    // Считаем дорожки своего вида: «Звук 2» понятнее, чем «Дорожка 5».
    var same: usize = 0;
    for (ed.project.trackList()) |t| {
        if (t.kind == kind) same += 1;
    }
    const name = std.fmt.bufPrint(&name_buf, "{s} {d}", .{
        if (kind == .video) "Видео" else "Звук",
        same + 1,
    }) catch "Дорожка";

    _ = ed.project.addTrack(kind, name) catch |err| return complain(err);

    var buf: [128]u8 = undefined;
    ed.say(std.fmt.bufPrint(&buf, "добавлена дорожка «{s}»", .{name}) catch "дорожка добавлена");
    refresh();
}

fn saveProject() void {
    if (ed.project.track_count == 0) {
        ed.say("сохранять нечего: в проекте нет дорожек");
        refresh();
        return;
    }

    var path: [1024]u16 = @splat(0);
    const default = ui.wide("проект.zrs");
    @memcpy(path[0..default.len], default);

    var ofn = std.mem.zeroes(c.OPENFILENAMEW);
    ofn.lStructSize = @sizeOf(c.OPENFILENAMEW);
    ofn.hwndOwner = ed.hwnd;
    ofn.lpstrFile = &path;
    ofn.nMaxFile = path.len;
    ofn.lpstrFilter = ui.wide("Проект Zig-Rec\x00*.zrs\x00Все файлы\x00*.*\x00\x00");
    ofn.lpstrDefExt = ui.wide("zrs");
    ofn.Flags = c.OFN_OVERWRITEPROMPT | c.OFN_NOCHANGEDIR;
    if (c.GetSaveFileNameW(&ofn) == 0) return;

    var text: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&text);
    project_file.write(ed.project, &w) catch {
        ed.say("проект не помещается в файл: слишком много клипов");
        refresh();
        return;
    };

    const handle = c.CreateFileW(
        @ptrCast(&path),
        c.GENERIC_WRITE,
        0,
        null,
        c.CREATE_ALWAYS,
        c.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == c.INVALID_HANDLE_VALUE) {
        ed.say("файл не создаётся: путь недоступен или файл занят");
        refresh();
        return;
    }
    defer _ = c.CloseHandle(handle);

    const bytes = w.buffered();
    var written: c.DWORD = 0;
    const ok = c.WriteFile(handle, bytes.ptr, @intCast(bytes.len), &written, null) != 0;

    var name: [512]u8 = undefined;
    const name_len = std.unicode.utf16LeToUtf8(&name, std.mem.sliceTo(&path, 0)) catch 0;
    var buf: [320]u8 = undefined;
    ed.say(if (ok and written == bytes.len)
        std.fmt.bufPrint(&buf, "сохранено: {s}", .{
            std.fs.path.basename(name[0..name_len]),
        }) catch "сохранено"
    else
        "файл записался не целиком: проверьте место на диске");
    refresh();
}

/// Положить файл на таймлайн в начало.
fn addFile(path: []const u8) void {
    addFileAt(path, 0);
}

/// Положить файл на таймлайн: по дорожке на каждую дорожку файла.
fn addFileAt(path: []const u8, at_ns: u64) void {
    var threaded: std.Io.Threaded = .init(ed.allocator, .{});
    defer threaded.deinit();

    const info = media.read(threaded.io(), ed.allocator, path) catch |err| {
        var buf: [320]u8 = undefined;
        ed.say(std.fmt.bufPrint(&buf, "{s}: {s}", .{
            std.fs.path.basename(path),
            media.explain(err),
        }) catch "файл не открылся");
        refresh();
        return;
    };

    const source = ed.project.addSource(path, info.duration_ns) catch |err| return complain(err);

    // Волну считаем в стороне, а не здесь. Декодирование звука часового
    // файла занимает секунды, и всё это время окно стояло бы столбом
    // с брошенным на него файлом. Клип появится сразу, волна — когда
    // досчитается.
    if (source < ed.waves.len) startWave(path, source);

    // Дорожки одного файла связываем сразу: звук должен ходить за
    // картинкой с первой секунды, а не после того, как человек об этом
    // попросит. Одна дорожка — связывать не с чем.
    const link: u16 = if (info.list().len > 1) ed.project.newLink() else 0;

    var added: usize = 0;
    for (info.list()) |track| {
        const kind: timeline.TrackKind = if (track.kind == .video) .video else .audio;
        var name_buf: [48]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s} {d}", .{
            kind.label(),
            ed.project.track_count + 1,
        }) catch "дорожка";

        const index = ed.project.addTrack(kind, name) catch |err| return complain(err);
        const len = if (track.duration_ns > 0) track.duration_ns else info.duration_ns;
        if (len < timeline.min_len_ns) continue;
        ed.project.placeLinked(index, source, at_ns, len, link) catch |err| return complain(err);
        added += 1;
    }

    var buf: [320]u8 = undefined;
    ed.say(std.fmt.bufPrint(&buf, "{s}: {s}, дорожек {d}, {d:.2} с{s}", .{
        std.fs.path.basename(path),
        info.format.label(),
        added,
        info.seconds(),
        if (link != 0) " — связаны, Alt тянет врозь" else "",
    }) catch "файл открыт");

    rememberViewed(path);

    // Показываем целиком: иначе человек открыл файл и не увидел ничего.
    fitToProject();
    showFrame();
    refresh();
}

/// Подобрать масштаб так, чтобы проект был виден весь.
fn fitToProject() void {
    var rect: c.RECT = undefined;
    _ = c.GetClientRect(ed.hwnd, &rect);
    const lane_w = @max(rect.right - view_mod.header_w, 100);
    const total = @max(ed.project.durationNs(), std.time.ns_per_s);
    ed.view.at_ns = 0;
    ed.view.ns_per_px = std.math.clamp(
        total / @as(u64, @intCast(lane_w)),
        View.finest_ns_per_px,
        View.coarsest_ns_per_px,
    );
}

fn splitAtPlayhead() void {
    if (!ed.has_selection) {
        ed.say("сначала выберите клип: резать надо что-то определённое");
        refresh();
        return;
    }
    const alone = apart();
    const cut = if (alone)
        ed.project.splitOne(ed.sel_track, ed.playhead_ns)
    else
        ed.project.split(ed.sel_track, ed.playhead_ns);
    cut catch |err| return complain(err);
    ed.say(if (alone) "разрезан один клип" else "разрезано вместе со связкой");
    refresh();
}

fn deleteSelected() void {
    if (!ed.has_selection) {
        ed.say("сначала выберите клип");
        refresh();
        return;
    }
    const alone = apart();
    const linked = selectedLink() != 0 and !alone;
    const gone = if (alone)
        ed.project.removeClipOne(ed.sel_track, ed.sel_clip)
    else
        ed.project.removeClip(ed.sel_track, ed.sel_clip);
    gone catch |err| return complain(err);
    ed.has_selection = false;
    ed.say(if (linked) "связка убрана целиком" else "клип убран");
    refresh();
}

/// Вырезать от указателя до конца выбранного клипа и сдвинуть остальное.
fn rippleFromPlayhead() void {
    if (!ed.has_selection) {
        ed.say("сначала выберите клип: вырезать надо из чего-то");
        refresh();
        return;
    }
    const track = &ed.project.tracks[ed.sel_track];
    if (ed.sel_clip >= track.count) return;
    const clip = track.clips[ed.sel_clip];
    if (!clip.covers(ed.playhead_ns)) {
        ed.say("указатель не внутри выбранного клипа");
        refresh();
        return;
    }
    ed.project.ripple(ed.sel_track, ed.playhead_ns, clip.endsAt()) catch |err| return complain(err);
    ed.has_selection = false;
    ed.say("участок вырезан, остальное подтянуто");
    refresh();
}

fn compactSelected() void {
    if (!ed.has_selection) {
        ed.say("сначала выберите дорожку, ткнув в её клип");
        refresh();
        return;
    }
    ed.project.compact(ed.sel_track) catch |err| return complain(err);
    ed.say("клипы собраны встык");
    refresh();
}

fn undoStep() void {
    if (!ed.project.undo()) {
        ed.say("отменять нечего");
    } else {
        ed.has_selection = false;
        ed.say("отменено");
    }
    refresh();
}

fn redoStep() void {
    if (!ed.project.redo()) {
        ed.say("возвращать нечего");
    } else {
        ed.has_selection = false;
        ed.say("возвращено");
    }
    refresh();
}

// -------------------------------------------------------------------- мышь

/// Мышь приходит в координатах окна, а таймлайн живёт под панелью кнопок.
/// Приводим в одном месте, чтобы сдвиг не расползся по обработчикам.
fn toLane(y: i32) i32 {
    return y - toolbar_h - preview_h - view_mod.splitter_h;
}

/// Верх таймлайна: под окном кадра и полосой-границей.
fn laneAreaTop() i32 {
    return toolbar_h + preview_h + view_mod.splitter_h;
}

fn onDown(x: i32, y: i32) void {
    if (view_mod.onSplitter(y, toolbar_h, preview_h)) {
        ed.drag = .splitter;
        _ = c.SetCapture(ed.hwnd);
        return;
    }
    if (y < laneAreaTop()) return;
    const hit = view_mod.hitTest(ed.project, ed.view, x, toLane(y));
    switch (hit.target) {
        .ruler => {
            ed.playhead_ns = hit.when_ns;
            ed.drag = .playhead;
            showFrame();
            _ = c.SetCapture(ed.hwnd);
        },
        .clip, .clip_left, .clip_right => {
            ed.has_selection = true;
            ed.sel_track = hit.track;
            ed.cur_track = hit.track;
            ed.sel_clip = hit.clip;
            const clip = ed.project.tracks[hit.track].clips[hit.clip];
            ed.drag = switch (hit.target) {
                .clip_left => .trim_left,
                .clip_right => .trim_right,
                else => .clip,
            };
            ed.drag_grab_ns = hit.when_ns -| clip.at_ns;
            ed.drag_started = false;
            ed.drag_apart = apart();
            _ = c.SetCapture(ed.hwnd);
        },
        .lane => {
            ed.has_selection = false;
            ed.cur_track = hit.track;
            ed.playhead_ns = hit.when_ns;
            showFrame();
        },
        .header_name => {
            // Строка имени только выбирает дорожку. Выключать звук отсюда
            // нельзя: двойной щелчок по имени успевал бы заодно выключить
            // дорожку, а человек просил всего лишь переименовать.
            ed.cur_track = hit.track;
        },
        .header => {
            // Ниже имени — выключатель звука.
            ed.cur_track = hit.track;
            ed.project.setMuted(hit.track, !ed.project.tracks[hit.track].muted) catch {};
        },
        .empty => {},
    }
    refresh();
}

fn onMove(x: i32, y: i32) void {
    if (ed.drag == .none) {
        if (view_mod.onSplitter(y, toolbar_h, preview_h)) {
            // 32645 — курсор «тянуть вверх-вниз».
            var cursor: ?*anyopaque = null;
            ui.setSystemCursor(&cursor, 32645);
            _ = setCursorRaw(cursor);
            return;
        }
        if (y < laneAreaTop()) return;
        // Курсор подсказывает, что будет: у края — растяжение.
        const hit = view_mod.hitTest(ed.project, ed.view, x, toLane(y));
        var cursor: ?*anyopaque = null;
        ui.setSystemCursor(&cursor, if (hit.isEdge()) 32644 else ui.idc_arrow);
        _ = setCursorRaw(cursor);
        return;
    }

    if (ed.drag == .splitter) {
        moveSplitter(y);
        return;
    }

    const when = ed.view.xToTime(x);
    switch (ed.drag) {
        .playhead => {
            ed.playhead_ns = when;
            showFrame();
            refresh();
        },
        .clip => {
            if (!ed.has_selection) return;
            const target_track = ed.view.trackAtY(toLane(y), ed.project.track_count) orelse ed.sel_track;
            const at = when -| ed.drag_grab_ns;
            const moved = if (ed.drag_apart)
                ed.project.moveOne(ed.sel_track, ed.sel_clip, target_track, at)
            else
                ed.project.move(ed.sel_track, ed.sel_clip, target_track, at);
            moved catch {
                // На чужой вид дорожки не пускаем — молча, потому что это
                // происходит на каждом движении мыши, и ругаться тут значит
                // мигать сообщением.
                return;
            };
            ed.sel_track = target_track;
            // После перестановки клип мог сменить номер: ищем его заново.
            if (ed.project.tracks[target_track].clipAt(at + 1)) |i| ed.sel_clip = i;
            ed.drag_started = true;
            refresh();
        },
        .trim_left, .trim_right => {
            if (!ed.has_selection) return;
            const track = &ed.project.tracks[ed.sel_track];
            if (ed.sel_clip >= track.count) return;
            const clip = track.clips[ed.sel_clip];
            const from_left = ed.drag == .trim_left;
            const edge_now = if (from_left) clip.at_ns else clip.endsAt();
            const delta = @as(i64, @intCast(when)) - @as(i64, @intCast(edge_now));
            if (delta == 0) return;
            const cut = if (ed.drag_apart)
                ed.project.trimOne(ed.sel_track, ed.sel_clip, from_left, delta)
            else
                ed.project.trim(ed.sel_track, ed.sel_clip, from_left, delta);
            cut catch return;
            ed.drag_started = true;
            refresh();
        },
        .splitter, .none => {},
    }
}

/// Поставить границу туда, куда её тянут. Всё решение — в правиле вида,
/// здесь только окно спрашивается о своей высоте.
fn moveSplitter(y: i32) void {
    var rect: c.RECT = undefined;
    if (c.GetClientRect(ed.hwnd, &rect) == 0) return;
    const room = rect.bottom - toolbar_h - status_h;
    const want = view_mod.previewHeightAt(y, toolbar_h, room);
    if (want == preview_h) return;
    preview_h = want;
    refresh();
}

fn onUp() void {
    if (ed.drag != .none) {
        _ = c.ReleaseCapture();
        if (ed.drag_started) {
            const alone = ed.drag_apart;
            ed.say(switch (ed.drag) {
                .clip => if (alone) "клип переставлен отдельно от связки" else "клип переставлен",
                .trim_left, .trim_right => if (alone) "клип обрезан отдельно от связки" else "клип обрезан",
                else => "",
            });
        }
        if (ed.drag == .splitter) {
            // Сохраняем не на каждом движении мыши, а когда её отпустили:
            // иначе файл переписывался бы сотню раз за одно перетаскивание.
            savePreviewHeight();
        }
        ed.drag = .none;
        ed.drag_started = false;
        refresh();
    }
}

/// Файлы, брошенные на окно.
///
/// Раскладываем так же, как при открытии: каждая дорожка файла — своя полоса.
/// Если бросили на пустое место таймлайна, клипы встают под курсор, а не
/// в начало: человек показал мышью, куда именно.
fn onDrop(drop: usize) void {
    defer dragFinish(drop);

    var point = c.POINT{ .x = 0, .y = 0 };
    _ = dragQueryPoint(drop, &point);
    const at_ns: u64 = if (point.x > view_mod.header_w and point.y > laneAreaTop())
        ed.view.xToTime(point.x)
    else
        0;

    // Сколько файлов бросили: 0xFFFFFFFF — это просьба назвать их число.
    const count = dragQueryFileW(drop, 0xFFFFFFFF, null, 0);
    if (count == 0) return;

    var wide: [1024]u16 = undefined;
    var utf8: [1024]u8 = undefined;
    var added: u32 = 0;
    var i: c.UINT = 0;
    while (i < count) : (i += 1) {
        const n = dragQueryFileW(drop, i, &wide, wide.len);
        if (n == 0) continue;
        const len = std.unicode.utf16LeToUtf8(&utf8, wide[0..n]) catch continue;
        const path = utf8[0..len];

        if (looksLikeProject(path)) {
            // Проект заменяет всё, что открыто: складывать два проекта
            // в один — это не «добавить», это каша.
            loadProject(path);
            return;
        }
        addFileAt(path, at_ns);
        added += 1;
    }

    if (added > 1) {
        var buf: [128]u8 = undefined;
        ed.say(std.fmt.bufPrint(&buf, "добавлено файлов: {d}", .{added}) catch "файлы добавлены");
        refresh();
    }
}

fn onWheel(delta: i16, screen_x: i32) void {
    var point = c.POINT{ .x = screen_x, .y = 0 };
    _ = c.ScreenToClient(ed.hwnd, &point);
    ed.view = ed.view.zoomAt(point.x, delta > 0);
    refresh();
}

// ----------------------------------------------------------- снимок кадра

/// Сохранить то, что сейчас в окне кадра, отдельной картинкой.
///
/// Кладём рядом с записями: снимок делают из той же работы, что и запись,
/// и искать его человек пойдёт туда же. Имя — по времени кадра: два снимка
/// подряд не затрут друг друга, а по имени видно, откуда кадр.
fn saveFrame() void {
    const p = &(ed.player orelse {
        ed.say("снимать нечего: поставьте указатель на клип");
        refresh();
        return;
    });
    if (!p.ready) {
        ed.say("снимать нечего: кадр не прочитался");
        refresh();
        return;
    }

    const dir = ui.defaultDir(ed.allocator) catch {
        ed.say("не нашлась папка записей — снимок не сохранён");
        refresh();
        return;
    };
    defer ed.allocator.free(dir);

    const ms = p.at_ns / std.time.ns_per_ms;
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "снимок-{d:0>2}-{d:0>2}-{d:0>3}.png", .{
        ms / 60_000,
        (ms / 1000) % 60,
        ms % 1000,
    }) catch "снимок.png";

    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ dir, name }) catch {
        ed.say("слишком длинный путь — снимок не сохранён");
        refresh();
        return;
    };

    // Строки в проигрывателе уже уложены сверху вниз и плотно: шаг равен
    // ширине кадра. Это делает `copyRows`, и на этом же стоит рисование.
    const bytes = png.fromBgra(ed.allocator, p.pixels, p.width, p.height, @as(usize, p.width) * 4) catch |err| {
        var buf: [128]u8 = undefined;
        ed.say(std.fmt.bufPrint(&buf, "снимок не собрался: {s}", .{@errorName(err)}) catch "снимок не собрался");
        refresh();
        return;
    };
    defer ed.allocator.free(bytes);

    if (!writeWholeFile(path, bytes)) {
        ed.say("снимок не записался: нет доступа к папке записей");
        refresh();
        return;
    }

    var buf: [320]u8 = undefined;
    ed.say(std.fmt.bufPrint(&buf, "снимок сохранён: {s} ({d} КБ)", .{
        name,
        (bytes.len + 1023) / 1024,
    }) catch "снимок сохранён");
    refresh();
}

/// Записать файл целиком. Через Windows напрямую: путь бывает с русскими
/// буквами, и он должен дойти до диска тем же, каким мы его собрали.
fn writeWholeFile(path: []const u8, bytes: []const u8) bool {
    var wide_path: [std.fs.max_path_bytes]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide_path, path) catch return false;
    wide_path[n] = 0;

    const handle = c.CreateFileW(
        @ptrCast(&wide_path),
        c.GENERIC_WRITE,
        0,
        null,
        c.CREATE_ALWAYS,
        c.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == c.INVALID_HANDLE_VALUE) return false;
    defer _ = c.CloseHandle(handle);

    var at: usize = 0;
    while (at < bytes.len) {
        var written: c.DWORD = 0;
        const piece: c.DWORD = @intCast(@min(bytes.len - at, 1 << 20));
        if (c.WriteFile(handle, bytes.ptr + at, piece, &written, null) == 0) return false;
        if (written == 0) return false;
        at += written;
    }
    return true;
}

// ------------------------------------------------- переименование дорожки

/// Двойной щелчок по имени дорожки открывает поле ввода прямо на месте имени.
fn onDoubleClick(x: i32, y: i32) void {
    if (y < laneAreaTop()) return;
    const hit = view_mod.hitTest(ed.project, ed.view, x, toLane(y));
    if (hit.target != .header_name) return;
    startRename(hit.track);
}

/// Открыть поле ввода поверх имени дорожки.
fn startRename(track_index: usize) void {
    if (ed.name_box != null) return;
    if (track_index >= ed.project.track_count) {
        ed.say("нечего переименовывать: сначала добавьте дорожку");
        refresh();
        return;
    }

    const top = laneAreaTop() + ed.view.laneTop(track_index) + 3;
    const box = ui.editBox(ed.hwnd, id_rename_box, 6, top, view_mod.header_w - 14, view_mod.name_line_h - 2);
    if (box == null) return;

    ed.name_box = box;
    ed.name_track = track_index;

    // Поле ввода само не отдаёт Enter и Esc: перехватываем их, подменив
    // его обработчик. Прежний держим числом — типизированный указатель
    // на чужой обработчик Zig проверяет на выравнивание и падает.
    ed.name_prev_proc = @bitCast(c.SetWindowLongPtrW(box, gwlp_wndproc, @bitCast(@intFromPtr(&renameProc))));

    ui.setText(box, ed.project.tracks[track_index].title());
    // Всё имя выделено: чаще имя меняют целиком, чем правят в середине.
    _ = c.SendMessageW(box, c.EM_SETSEL, 0, -1);
    _ = c.SetFocus(box);

    ed.say("новое имя, затем Enter; Esc — оставить как было");
    refresh();
}

/// GWLP_WNDPROC: обработчик окна.
const gwlp_wndproc: c_int = -4;

fn renameProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_KEYDOWN => switch (wp) {
            c.VK_RETURN => {
                finishRename(true);
                return 0;
            },
            c.VK_ESCAPE => {
                finishRename(false);
                return 0;
            },
            else => {},
        },
        // Однострочное поле встречает Enter и Esc звонком. Глотаем их здесь,
        // иначе каждое переименование заканчивалось бы писком.
        c.WM_CHAR => switch (wp) {
            '\r', 27 => return 0,
            else => {},
        },
        // Ушли мышью в другое место — считаем это согласием: так ведут себя
        // все списки с переименованием, и терять набранное обидно.
        c.WM_KILLFOCUS => {
            finishRename(true);
            return 0;
        },
        else => {},
    }
    return callWindowProcW(ed.name_prev_proc, hwnd, msg, wp, lp);
}

/// Закрыть поле ввода. `accept` — принять набранное.
fn finishRename(accept: bool) void {
    const box = ed.name_box orelse return;
    // Обнуляем заранее: закрытие поля само пришлёт WM_KILLFOCUS, и без
    // этого мы зашли бы сюда второй раз уже с закрытым полем.
    ed.name_box = null;

    var buf: [256]u8 = undefined;
    const typed = if (accept) ui.boxText(box, &buf) else "";

    _ = c.SetWindowLongPtrW(box, gwlp_wndproc, @bitCast(ed.name_prev_proc));
    _ = c.DestroyWindow(box);
    ed.name_prev_proc = 0;
    _ = c.SetFocus(ed.hwnd);

    if (accept and typed.len > 0) {
        ed.project.renameTrack(ed.name_track, typed) catch {
            ed.say("имя не принято");
            refresh();
            return;
        };
        ed.say("дорожка переименована");
    } else {
        ed.say("имя оставлено прежним");
    }
    refresh();
}

// ------------------------------------------------------------ волна

/// Задание фоновому счёту волны.
///
/// Путь копируем к себе: тот, что пришёл, живёт на стеке вызывающего
/// и к началу счёта его уже не будет.
const WaveJob = struct {
    path: [512]u8 = @splat(0),
    len: usize = 0,
    source: u16 = 0,
};

/// Посчитать волну в стороне от окна.
fn startWave(path: []const u8, source: u16) void {
    if (path.len >= 512) return;
    const job = ed.allocator.create(WaveJob) catch return;
    job.* = .{ .source = source, .len = path.len };
    @memcpy(job.path[0..path.len], path);

    const thread = std.Thread.spawn(.{}, waveWorker, .{job}) catch {
        // Поток не завёлся — считаем прямо здесь. Лучше подождать,
        // чем остаться без волны.
        ed.allocator.destroy(job);
        ed.waves[source] = waveform.read(path) catch .{};
        return;
    };
    // Не ждём его: он сам сообщит окну, когда досчитает.
    thread.detach();
}

fn waveWorker(job: *WaveJob) void {
    const made = waveform.read(job.path[0..job.len]) catch waveform.Envelope{};
    if (job.source < ed.waves.len) ed.waves[job.source] = made;
    // Просим окно перерисоваться из его же потока: трогать окно из чужого
    // потока нельзя, а сообщение — можно.
    _ = c.PostMessageW(ed.hwnd, wm_wave_ready, 0, 0);
    ed.allocator.destroy(job);
}

// ------------------------------------------------------------- недавние

fn homeDir() []const u8 {
    return ed.home[0..ed.home_len];
}

/// Прочитать, где своё, и что открывали в прошлые разы.
fn loadRecent() void {
    var buf: [paths.max_path]u8 = undefined;
    const dir = paths.base(&buf) catch return;
    const n = @min(dir.len, ed.home.len);
    @memcpy(ed.home[0..n], dir[0..n]);
    ed.home_len = n;

    var threaded: std.Io.Threaded = .init(ed.allocator, .{});
    defer threaded.deinit();
    ed.recent = recent_mod.load(threaded.io(), ed.allocator, homeDir());
}

/// Отметить, что этот файл смотрели.
fn rememberViewed(path: []const u8) void {
    if (ed.home_len == 0) return;
    ed.recent.viewed.add(path);
    _ = recent_mod.save(&ed.recent, homeDir());
    buildMenu(ed.hwnd);
}

/// Выпадающий список недавних.
///
/// Пропавший файл виден, но не нажимается: молча исчезнувшая строка
/// выглядит так, будто программа что-то потеряла, а открыть то, чего нет,
/// всё равно нельзя.
fn recentMenu(list: *const recent_mod.List, base_id: c_int) c.HMENU {
    const menu = c.CreatePopupMenu();
    if (menu == null) return menu;
    if (list.count == 0) {
        _ = c.AppendMenuW(menu, c.MF_STRING | c.MF_GRAYED, 0, ui.wide("пока пусто"));
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
        const flags: c.UINT = if (here) c.MF_STRING else c.MF_STRING | c.MF_GRAYED;
        _ = c.AppendMenuW(menu, flags, @intCast(base_id + @as(c_int, @intCast(i))), @ptrCast(&wide_buf));
    }
    return menu;
}

/// Полоса меню. Пересобирается целиком: списки недавних меняются на ходу.
fn buildMenu(hwnd: c.HWND) void {
    const bar = c.CreateMenu();
    if (bar == null) return;

    const file_menu = c.CreatePopupMenu();
    _ = c.AppendMenuW(file_menu, c.MF_STRING, id_menu_open, ui.wide("Открыть…\tCtrl+O"));
    _ = c.AppendMenuW(file_menu, c.MF_STRING, id_menu_save, ui.wide("Сохранить проект\tCtrl+S"));
    _ = c.AppendMenuW(file_menu, c.MF_SEPARATOR, 0, null);
    _ = c.AppendMenuW(
        file_menu,
        c.MF_POPUP,
        @intFromPtr(recentMenu(&ed.recent.recorded, id_recent_rec)),
        ui.wide("Недавно записанные"),
    );
    _ = c.AppendMenuW(
        file_menu,
        c.MF_POPUP,
        @intFromPtr(recentMenu(&ed.recent.viewed, id_recent_view)),
        ui.wide("Недавно просмотренные"),
    );
    _ = c.AppendMenuW(file_menu, c.MF_SEPARATOR, 0, null);
    _ = c.AppendMenuW(file_menu, c.MF_STRING, id_menu_close, ui.wide("Закрыть"));
    _ = c.AppendMenuW(bar, c.MF_POPUP, @intFromPtr(file_menu), ui.wide("Файл"));

    const old = c.GetMenu(hwnd);
    _ = c.SetMenu(hwnd, bar);
    if (old != null) _ = c.DestroyMenu(old);
    _ = c.DrawMenuBar(hwnd);
}

/// Открыть файл из списка недавних.
fn openFromRecent(list: *const recent_mod.List, index: usize) void {
    const path = list.at(index);
    if (path.len == 0) return;
    if (!recent_mod.onDisk(path)) {
        ed.say("файла нет на месте");
        refresh();
        return;
    }
    // Путь надо скопировать: добавление в список недавних переставляет
    // строки, и та, на которую мы смотрим, уедет под ногами.
    var copy: [recent_mod.max_path]u8 = undefined;
    const n = @min(path.len, copy.len);
    @memcpy(copy[0..n], path[0..n]);
    addFile(copy[0..n]);
}

// ------------------------------------------------------------------- окно

fn wndProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_CREATE => {
            ed.hwnd = hwnd;
            ed.status = ui.button(hwnd, "", 0, 0, 0, 0, 0, 0);
            _ = c.ShowWindow(ed.status, c.SW_HIDE);

            // Верхний ряд: что делаем с файлом и с дорожками.
            _ = ui.button(hwnd, "📂 Открыть…", id_open, 10, 8, 128, 28, 0);
            _ = ui.button(hwnd, "💾 Сохранить", id_save, 146, 8, 132, 28, 0);
            _ = ui.button(hwnd, "➕ Видеодорожка", id_add_video, 294, 8, 168, 28, 0);
            _ = ui.button(hwnd, "➕ Звуковая дорожка", id_add_audio, 470, 8, 196, 28, 0);
            ed.btn_play = ui.button(hwnd, "▶ Играть", id_play, 674, 8, 110, 28, 0);
            _ = ui.button(hwnd, "📷 Снимок", id_shot, 792, 8, 112, 28, 0);

            // Нижний ряд: правка того, что уже лежит на дорожках.
            _ = ui.button(hwnd, "✂ Разрезать", id_split, 10, 46, 120, 28, 0);
            _ = ui.button(hwnd, "🗑 Удалить", id_delete, 138, 46, 114, 28, 0);
            _ = ui.button(hwnd, "⌦ Вырезать", id_ripple, 260, 46, 120, 28, 0);
            _ = ui.button(hwnd, "⇥ Встык", id_compact, 388, 46, 102, 28, 0);
            ed.btn_undo = ui.button(hwnd, "↶ Отменить", id_undo, 498, 46, 120, 28, 0);
            ed.btn_redo = ui.button(hwnd, "↷ Вернуть", id_redo, 626, 46, 114, 28, 0);
            ed.btn_link = ui.button(hwnd, "⛓ Развязать", id_link, 748, 46, 140, 28, 0);

            var child = c.GetWindow(hwnd, c.GW_CHILD);
            while (child != null) : (child = c.GetWindow(child, c.GW_HWNDNEXT)) ui.applyFont(child);

            // Принимаем файлы, брошенные мышью из проводника.
            c.DragAcceptFiles(hwnd, 1);
            // Колесо приходит окну с клавиатурным вниманием. Без этой строки
            // внимание остаётся на первой кнопке, кнопка колесо не пересылает,
            // и масштаб не меняется.
            _ = c.SetFocus(hwnd);

            loadRecent();
            buildMenu(hwnd);

            ed.say("откройте файл, перетащите его сюда мышью или добавьте дорожку");
            refresh();
            return 0;
        },
        c.WM_COMMAND => {
            switch (wp & 0xFFFF) {
                id_open => openFile(),
                id_split => splitAtPlayhead(),
                id_delete => deleteSelected(),
                id_ripple => rippleFromPlayhead(),
                id_compact => compactSelected(),
                id_undo => undoStep(),
                id_redo => redoStep(),
                id_save => saveProject(),
                id_add_video => addEmptyTrack(.video),
                id_add_audio => addEmptyTrack(.audio),
                id_play => togglePlay(),
                id_shot => saveFrame(),
                id_link => toggleLink(),
                id_menu_open => openFile(),
                id_menu_save => saveProject(),
                id_menu_close => _ = c.PostMessageW(hwnd, c.WM_CLOSE, 0, 0),
                id_recent_rec...id_recent_rec + recent_mod.max_items - 1 => {
                    openFromRecent(&ed.recent.recorded, @intCast((wp & 0xFFFF) - id_recent_rec));
                },
                id_recent_view...id_recent_view + recent_mod.max_items - 1 => {
                    openFromRecent(&ed.recent.viewed, @intCast((wp & 0xFFFF) - id_recent_view));
                },
                else => {},
            }
            return 0;
        },
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const dc = c.BeginPaint(hwnd, &ps);
            var rect: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &rect);
            paintBuffered(hwnd, dc, rect.right, rect.bottom);
            _ = c.EndPaint(hwnd, &ps);
            return 0;
        },
        c.WM_ERASEBKGND => return 1, // всё рисуем сами, в буфере
        c.WM_LBUTTONDOWN => {
            // Возвращаем внимание окну: после нажатия кнопки оно осталось
            // на ней, и колесо с клавиатурой перестали доходить.
            _ = c.SetFocus(hwnd);
            onDown(loWord(lp), hiWord(lp));
            return 0;
        },
        wm_dropfiles => {
            onDrop(@bitCast(wp));
            return 0;
        },
        wm_wave_ready => {
            refresh();
            return 0;
        },
        c.WM_LBUTTONDBLCLK => {
            onDoubleClick(loWord(lp), hiWord(lp));
            return 0;
        },
        c.WM_MOUSEMOVE => {
            onMove(loWord(lp), hiWord(lp));
            return 0;
        },
        c.WM_LBUTTONUP => {
            onUp();
            return 0;
        },
        c.WM_MOUSEWHEEL => {
            onWheel(@bitCast(@as(u16, @truncate(wp >> 16))), loWord(lp));
            return 0;
        },
        c.WM_KEYDOWN => {
            const ctrl = c.GetKeyState(c.VK_CONTROL) < 0;
            switch (wp) {
                'Z' => if (ctrl) undoStep(),
                'Y' => if (ctrl) redoStep(),
                'O' => if (ctrl) openFile(),
                // Одна буква, два смысла: с Ctrl сохраняем, без — режем.
                'S' => if (ctrl) saveProject() else splitAtPlayhead(),
                c.VK_DELETE => deleteSelected(),
                c.VK_HOME => {
                    ed.playhead_ns = 0;
                    showFrame();
                    refresh();
                },
                c.VK_SPACE => togglePlay(),
                c.VK_F2 => startRename(ed.cur_track),
                c.VK_F12 => saveFrame(),
                else => {},
            }
            return 0;
        },
        c.WM_TIMER => {
            if (wp == timer_play) onPlayTick();
            return 0;
        },
        c.WM_SIZE => {
            refresh();
            return 0;
        },
        c.WM_DESTROY => {
            if (ed.name_box != null) finishRename(false);
            if (ed.player) |*p| p.close();
            ed.player = null;
            c.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wp, lp);
}

fn loWord(lp: c.LPARAM) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lp))))));
}

fn hiWord(lp: c.LPARAM) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lp)) >> 16))));
}

/// Рисуем в памяти и переносим готовым — как и панель осциллографа в окне
/// записи. На таймлайне это заметнее вдвое: полос много, и перерисовка
/// прямо на экране мигала бы при каждом движении мыши.
fn paintBuffered(hwnd: c.HWND, dc: c.HDC, width: i32, height: i32) void {
    if (width <= 0 or height <= 0) return;
    const mem = c.CreateCompatibleDC(dc);
    if (mem == null) return paint(hwnd, dc, width, height);
    defer _ = c.DeleteDC(mem);

    const bmp = c.CreateCompatibleBitmap(dc, width, height);
    if (bmp == null) return paint(hwnd, dc, width, height);
    defer _ = c.DeleteObject(@ptrCast(bmp));

    const old = c.SelectObject(mem, @ptrCast(bmp));
    defer _ = c.SelectObject(mem, old);

    paint(hwnd, mem, width, height);
    _ = c.BitBlt(dc, 0, 0, width, height, mem, 0, 0, c.SRCCOPY);
}

/// Папка, где лежат настройки. Редактор — отдельная программа, и путь
/// к ним он вычисляет сам, тем же способом, что и окно записи.
fn settingsDir(allocator: std.mem.Allocator) ?[]const u8 {
    var buf: [paths.max_path]u8 = undefined;
    const dir = paths.base(&buf) catch return ui.defaultDir(allocator) catch null;
    return allocator.dupe(u8, dir) catch null;
}

/// Прочитать высоту кадра, подогнанную в прошлый раз.
fn loadPreviewHeight(allocator: std.mem.Allocator) void {
    const dir = settingsDir(allocator) orelse return;
    defer allocator.free(dir);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const prefs = settings_mod.load(threaded.io(), allocator, dir);
    preview_h = prefs.preview_h;
}

/// Запомнить высоту кадра. Читаем весь файл заново и меняем одну строку:
/// рядом может работать окно записи со своими настройками, и затирать
/// их нашими умолчаниями нельзя.
fn savePreviewHeight() void {
    const allocator = ed.allocator;
    const dir = settingsDir(allocator) orelse return;
    defer allocator.free(dir);

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var prefs = settings_mod.load(threaded.io(), allocator, dir);
    if (prefs.preview_h == preview_h) return;
    prefs.preview_h = preview_h;
    _ = settings_mod.save(&prefs, dir);
}

/// Открыть окно редактора. `path` — файл, который положить сразу.
pub fn run(allocator: std.mem.Allocator, path: ?[]const u8) !void {
    return runInner(allocator, path, null);
}

/// Собрать окно редактора, замерить раскладку и закрыть, не показывая.
///
/// Тот же путь, что и у настоящего запуска: те же кнопки, тот же порядок.
pub fn checkLayout(allocator: std.mem.Allocator) !ui.Layout {
    var out = ui.Layout{};
    try runInner(allocator, null, &out);
    return out;
}

fn runInner(allocator: std.mem.Allocator, path: ?[]const u8, report: ?*ui.Layout) !void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    _ = c.SetProcessDPIAware();
    // Консоль редактору не нужна: она висела пустым чёрным окном рядом.
    ui.hideOwnConsole();

    const project = try allocator.create(timeline.Project);
    defer allocator.destroy(project);
    project.* = .{};

    ed = .{ .allocator = allocator, .project = project };
    // Верх таймлайна опускаем под панель кнопок.
    ed.view = .{};
    // Высота окна кадра — та, на которой её оставили в прошлый раз.
    loadPreviewHeight(allocator);

    const hinst: c.HINSTANCE = @ptrCast(c.GetModuleHandleW(null));
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.style = cs_dblclks;
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinst;
    wc.lpszClassName = ui.wide("ZigRecEdit");
    wc.hbrBackground = null; // фон рисуем сами
    ui.setSystemCursor(&wc.hCursor, ui.idc_arrow);
    ui.setAppIcon(&wc.hIcon);
    ui.setAppIcon(&wc.hIconSm);
    if (c.RegisterClassExW(&wc) == 0) return error.WindowFailed;

    var title_buf: [128]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Zig-Rec Studio — редактор v{s}", .{
        @import("../version.zig").VERSION,
    }) catch "Zig-Rec Studio — редактор";
    var title_w: [128]u16 = undefined;
    const tn = try std.unicode.utf8ToUtf16Le(&title_w, title);
    title_w[tn] = 0;

    const hwnd = c.CreateWindowExW(
        0,
        ui.wide("ZigRecEdit"),
        @ptrCast(&title_w),
        // WS_CLIPCHILDREN: окно не рисует там, где стоят его кнопки.
        // Без этого фон панели ложится поверх них, и они перерисовываются
        // следом — то самое мигание.
        c.WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        1000,
        860,
        null,
        null,
        hinst,
        null,
    ) orelse return error.WindowFailed;

    if (report) |r| {
        // Окно собрано: кнопки созданы в WM_CREATE. Мерим и уходим,
        // не показывая его и не заводя цикл сообщений.
        r.* = ui.measureLayout(hwnd);
        _ = c.DestroyWindow(hwnd);
        return;
    }

    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.UpdateWindow(hwnd);

    if (path) |p| addFile(p);

    var msg: c.MSG = undefined;
    while (c.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }
}
