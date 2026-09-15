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
const win32 = @import("win32.zig");
const c = win32.c;
const timeline = @import("timeline.zig");
const view_mod = @import("editor_view.zig");
const media = @import("media.zig");
const waveform = @import("waveform.zig");
const project_file = @import("project_file.zig");
const ui = @import("ui.zig");

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

/// Высота панели кнопок. Таймлайн начинается под ней.
const toolbar_h: i32 = 44;
/// Высота строки сообщения снизу.
const status_h: i32 = 22;

/// Дескриптор курсора — не адрес, а номер в таблице ядра, и выровнен он
/// как попало. Приведение его к типизированному указателю Zig в безопасном
/// режиме падает — это пятая встреча с одной и той же ловушкой в этом
/// проекте. Объявляем `SetCursor` так, чтобы приводить было нечего.
const setCursorRaw = @extern(
    *const fn (?*anyopaque) callconv(.winapi) ?*anyopaque,
    .{ .name = "SetCursor" },
);

/// Что человек тянет мышью прямо сейчас.
const Drag = enum { none, playhead, clip, trim_left, trim_right };

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

    status: c.HWND = null,
    btn_undo: c.HWND = null,
    btn_redo: c.HWND = null,

    /// Волна каждого открытого файла. По исходнику на ячейку, номера те же,
    /// что у исходников проекта.
    waves: [timeline.max_sources]waveform.Envelope = @splat(.{}),

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

    // Ниже — таймлайн со своим началом координат. Так арифметика вида
    // остаётся той, что проверена тестами, и считает от нуля.
    const lane_height = height - toolbar_h - status_h;
    if (lane_height <= 0) return;
    _ = c.SetViewportOrgEx(dc, 0, toolbar_h, null);
    defer _ = c.SetViewportOrgEx(dc, 0, 0, null);

    drawRuler(dc, width);
    drawTracks(dc, width, lane_height);
    drawPlayhead(dc, lane_height);
    _ = hwnd;
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

fn refresh() void {
    _ = c.InvalidateRect(ed.hwnd, null, 0);
    _ = c.EnableWindow(ed.btn_undo, if (ed.project.canUndo()) 1 else 0);
    _ = c.EnableWindow(ed.btn_redo, if (ed.project.canRedo()) 1 else 0);
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

/// Положить файл на таймлайн: по дорожке на каждую дорожку файла.
fn addFile(path: []const u8) void {
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

    // Волна считается один раз, при открытии. Файл без звука — не беда:
    // просто рисовать будет нечего.
    if (source < ed.waves.len) {
        ed.waves[source] = waveform.read(path) catch .{};
    }

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
        ed.project.place(index, source, 0, len) catch |err| return complain(err);
        added += 1;
    }

    var buf: [320]u8 = undefined;
    ed.say(std.fmt.bufPrint(&buf, "{s}: {s}, дорожек {d}, {d:.2} с", .{
        std.fs.path.basename(path),
        info.format.label(),
        added,
        info.seconds(),
    }) catch "файл открыт");

    // Показываем целиком: иначе человек открыл файл и не увидел ничего.
    fitToProject();
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
    ed.project.split(ed.sel_track, ed.playhead_ns) catch |err| return complain(err);
    ed.say("разрезано");
    refresh();
}

fn deleteSelected() void {
    if (!ed.has_selection) {
        ed.say("сначала выберите клип");
        refresh();
        return;
    }
    ed.project.removeClip(ed.sel_track, ed.sel_clip) catch |err| return complain(err);
    ed.has_selection = false;
    ed.say("клип убран");
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
    return y - toolbar_h;
}

fn onDown(x: i32, y: i32) void {
    if (y < toolbar_h) return;
    const hit = view_mod.hitTest(ed.project, ed.view, x, toLane(y));
    switch (hit.target) {
        .ruler => {
            ed.playhead_ns = hit.when_ns;
            ed.drag = .playhead;
            _ = c.SetCapture(ed.hwnd);
        },
        .clip, .clip_left, .clip_right => {
            ed.has_selection = true;
            ed.sel_track = hit.track;
            ed.sel_clip = hit.clip;
            const clip = ed.project.tracks[hit.track].clips[hit.clip];
            ed.drag = switch (hit.target) {
                .clip_left => .trim_left,
                .clip_right => .trim_right,
                else => .clip,
            };
            ed.drag_grab_ns = hit.when_ns -| clip.at_ns;
            ed.drag_started = false;
            _ = c.SetCapture(ed.hwnd);
        },
        .lane => {
            ed.has_selection = false;
            ed.playhead_ns = hit.when_ns;
        },
        .header => {
            // Щелчок по имени дорожки выключает и включает её.
            ed.project.setMuted(hit.track, !ed.project.tracks[hit.track].muted) catch {};
        },
        .empty => {},
    }
    refresh();
}

fn onMove(x: i32, y: i32) void {
    if (ed.drag == .none) {
        if (y < toolbar_h) return;
        // Курсор подсказывает, что будет: у края — растяжение.
        const hit = view_mod.hitTest(ed.project, ed.view, x, toLane(y));
        var cursor: ?*anyopaque = null;
        ui.setSystemCursor(&cursor, if (hit.isEdge()) 32644 else ui.idc_arrow);
        _ = setCursorRaw(cursor);
        return;
    }

    const when = ed.view.xToTime(x);
    switch (ed.drag) {
        .playhead => {
            ed.playhead_ns = when;
            refresh();
        },
        .clip => {
            if (!ed.has_selection) return;
            const target_track = ed.view.trackAtY(toLane(y), ed.project.track_count) orelse ed.sel_track;
            const at = when -| ed.drag_grab_ns;
            ed.project.move(ed.sel_track, ed.sel_clip, target_track, at) catch {
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
            ed.project.trim(ed.sel_track, ed.sel_clip, from_left, delta) catch return;
            ed.drag_started = true;
            refresh();
        },
        .none => {},
    }
}

fn onUp() void {
    if (ed.drag != .none) {
        _ = c.ReleaseCapture();
        if (ed.drag_started) {
            ed.say(switch (ed.drag) {
                .clip => "клип переставлен",
                .trim_left, .trim_right => "клип обрезан",
                else => "",
            });
        }
        ed.drag = .none;
        ed.drag_started = false;
        refresh();
    }
}

fn onWheel(delta: i16, screen_x: i32) void {
    var point = c.POINT{ .x = screen_x, .y = 0 };
    _ = c.ScreenToClient(ed.hwnd, &point);
    ed.view = ed.view.zoomAt(point.x, delta > 0);
    refresh();
}

// ------------------------------------------------------------------- окно

fn wndProc(hwnd: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_CREATE => {
            ed.hwnd = hwnd;
            ed.status = ui.button(hwnd, "", 0, 0, 0, 0, 0, 0);
            _ = c.ShowWindow(ed.status, c.SW_HIDE);

            _ = ui.button(hwnd, "Открыть…", id_open, 10, 8, 110, 28, 0);
            _ = ui.button(hwnd, "Разрезать", id_split, 128, 8, 100, 28, 0);
            _ = ui.button(hwnd, "Удалить", id_delete, 236, 8, 92, 28, 0);
            _ = ui.button(hwnd, "Вырезать", id_ripple, 336, 8, 100, 28, 0);
            _ = ui.button(hwnd, "Встык", id_compact, 444, 8, 84, 28, 0);
            ed.btn_undo = ui.button(hwnd, "Отменить", id_undo, 544, 8, 100, 28, 0);
            ed.btn_redo = ui.button(hwnd, "Вернуть", id_redo, 652, 8, 92, 28, 0);
            _ = ui.button(hwnd, "Сохранить", id_save, 752, 8, 110, 28, 0);

            var child = c.GetWindow(hwnd, c.GW_CHILD);
            while (child != null) : (child = c.GetWindow(child, c.GW_HWNDNEXT)) ui.applyFont(child);

            ed.say("откройте файл: mp4, mov, avi, mp3, wav, ogg, flac или midi");
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
            onDown(loWord(lp), hiWord(lp));
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
                    refresh();
                },
                else => {},
            }
            return 0;
        },
        c.WM_SIZE => {
            refresh();
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

/// Открыть окно редактора. `path` — файл, который положить сразу.
pub fn run(allocator: std.mem.Allocator, path: ?[]const u8) !void {
    if (builtin.os.tag != .windows) return error.Unsupported;
    _ = c.SetProcessDPIAware();

    const project = try allocator.create(timeline.Project);
    defer allocator.destroy(project);
    project.* = .{};

    ed = .{ .allocator = allocator, .project = project };
    // Верх таймлайна опускаем под панель кнопок.
    ed.view = .{};

    const hinst: c.HINSTANCE = @ptrCast(c.GetModuleHandleW(null));
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
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
        @import("version.zig").VERSION,
    }) catch "Zig-Rec Studio — редактор";
    var title_w: [128]u16 = undefined;
    const tn = try std.unicode.utf8ToUtf16Le(&title_w, title);
    title_w[tn] = 0;

    const hwnd = c.CreateWindowExW(
        0,
        ui.wide("ZigRecEdit"),
        @ptrCast(&title_w),
        c.WS_OVERLAPPEDWINDOW,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        980,
        560,
        null,
        null,
        hinst,
        null,
    ) orelse return error.WindowFailed;

    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.UpdateWindow(hwnd);

    if (path) |p| addFile(p);

    var msg: c.MSG = undefined;
    while (c.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }
}
