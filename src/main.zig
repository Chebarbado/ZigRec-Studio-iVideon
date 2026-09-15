//! Точка входа zigrec. Пока командная строка: окно записи появится в задаче #18.
const std = @import("std");
const Io = std.Io;
const zigrec = @import("zigrec");

const usage =
    \\zigrec — рекордер экрана и редактор
    \\
    \\  zigrec --version                  версия и дата выпуска
    \\  zigrec --help                     эта справка
    \\
    \\  zigrec record ФАЙЛ [ключи]        записать экран в mp4 или GIF
    \\        имя, кончающееся на .gif, даёт петлю вместо видео
    \\        --sec N          сколько секунд писать (по умолчанию 5)
    \\        --fps N          частота кадров (по умолчанию 30)
    \\        --monitor N      номер монитора (по умолчанию 0)
    \\        --area x,y,ш,в   прямоугольник рабочего стола
    \\        --window ТЕКСТ   окно, найденное по части заголовка; область едет за окном
    \\        --sound          писать звук с микрофона в ту же дорожку
    \\  zigrec monitors                   какие есть мониторы
    \\  zigrec windows                    какие есть видимые окна
    \\  zigrec edit [ФАЙЛ]                окно редактора: дорожки, резка, перестановка
    \\  zigrec info ФАЙЛ                  что внутри файла: формат, дорожки, кодеки
    \\        понимает mp4, mov, avi, wav, mp3, ogg, flac, midi
    \\  zigrec verify-mp4 ФАЙЛ            разобрать mp4: боксы, быстрый старт, данные
    \\
    \\  zigrec capture-smoke [N] [dxgi|gdi]
    \\        самопроверка захвата: показать N кадров и прочитать их обратно с экрана
    \\  zigrec encode-smoke ФАЙЛ [N] [--audio]
    \\        самопроверка кодирования: N кадров стенда в mp4 и разбор файла;
    \\        с --audio в файл идёт ещё и звуковая дорожка с известным рисунком
    \\  zigrec mcp [ПОРТ]
    \\        сервер MCP для Claude Code; передаёт просьбы в открытое окно
    \\  zigrec ui-smoke
    \\        самопроверка окна: всё ли поместилось в его рабочую часть
    \\  zigrec hotkey-smoke [СОЧЕТАНИЕ]
    \\        самопроверка сочетания: Windows его принимает
    \\  zigrec gif-write-smoke ФАЙЛ.gif [N]
    \\        самопроверка записи GIF: N эталонных кадров в петлю
    \\  zigrec gif-smoke ФАЙЛ.gif [КАДР.png]
    \\        самопроверка чтения GIF: кадры, выдержки, первый кадр в png
    \\  zigrec recent-smoke ПАПКА
    \\        самопроверка списков недавних: запись, чтение, порядок
    \\  zigrec home-smoke
    \\        самопроверка хранения: Portable и Classic
    \\  zigrec shot-smoke ФАЙЛ.png [НОМЕР]
    \\        самопроверка снимка: эталонный кадр записывается картинкой
    \\  zigrec frame-smoke ФАЙЛ [СЕКУНДЫ]
    \\        самопроверка кадра: размер, шаг строки, длина буфера
    \\  zigrec project-smoke ФАЙЛ.zrs
    \\        самопроверка файла проекта: записать, прочитать, сверить
    \\  zigrec mcp-smoke [ПОРТ]
    \\        самопроверка сервера: настоящий разговор с окном и сверка ответов
    \\  zigrec audio-sync ФАЙЛ.wav
    \\        сверить вынутую дорожку со стендом: уровень и рассинхрон
    \\  zigrec verify-raw ФАЙЛ Ш В
    \\        прочитать таймкоды из распакованного BGRA-потока и сверить порядок
    \\
    \\Коды возврата: 0 — записан, 3 — записан с пропусками кадров,
    \\1 — не записан, 2 — неверные ключи.
    \\
    \\Ход работ: http://127.0.0.1:8000/zigrecstudio-trac
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var buf: [8192]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), init.io, &buf);
    const w = &file_writer.interface;

    const cmd: []const u8 = if (args.len > 1) args[1] else "";
    var code: u8 = 0;

    if (args.len <= 1 or eq(cmd, "--help") or eq(cmd, "-h")) {
        try w.writeAll(usage);
    } else if (eq(cmd, "--version") or eq(cmd, "-v")) {
        try w.print("zigrec {s} ({s})\n", .{ zigrec.version.VERSION, zigrec.version.VERSION_DATE });
    } else if (eq(cmd, "capture-smoke")) {
        const frames = argInt(args, 2, 240);
        const backend: zigrec.capture.Backend = if (args.len > 3) blk: {
            if (eq(args[3], "dxgi")) break :blk .dxgi;
            if (eq(args[3], "gdi")) break :blk .gdi;
            break :blk .auto;
        } else .auto;
        code = try captureSmoke(arena, w, frames, backend);
    } else if (eq(cmd, "encode-smoke")) {
        if (args.len < 3) {
            try w.writeAll("нужен путь к файлу\n");
            code = 2;
        } else {
            var with_audio = false;
            for (args[2..]) |a| {
                if (eq(a, "--audio")) with_audio = true;
            }
            code = try encodeSmoke(init.io, arena, w, args[2], argInt(args, 3, 120), with_audio);
        }
    } else if (eq(cmd, "edit") or eq(cmd, "редактор")) {
        const path: ?[]const u8 = if (args.len > 2) args[2] else null;
        zigrec.editor.run(arena, path) catch |err| {
            try w.print("редактор не открылся: {s}\n", .{@errorName(err)});
            code = 1;
        };
    } else if (eq(cmd, "info")) {
        if (args.len < 3) {
            try w.writeAll("нужен путь к файлу\n");
            code = 2;
        } else {
            code = try fileInfo(init.io, arena, w, args[2]);
        }
    } else if (eq(cmd, "verify-mp4")) {
        if (args.len < 3) {
            try w.writeAll("нужен путь к файлу\n");
            code = 2;
        } else {
            code = try verifyMp4(init.io, arena, w, args[2]);
        }
    } else if (eq(cmd, "verify-raw")) {
        if (args.len < 5) {
            try w.writeAll("нужны файл, ширина и высота\n");
            code = 2;
        } else {
            code = try verifyRaw(init.io, arena, w, args[2], argInt(args, 3, 0), argInt(args, 4, 0));
        }
    } else if (eq(cmd, "record")) {
        if (args.len < 3) {
            try w.writeAll("нужен путь к файлу\n");
            code = 2;
        } else if (parseRecordArgs(args[3..])) |opt| {
            code = try record(init.io, arena, w, args[2], opt);
        } else |err| {
            try w.print("не разобрать ключи: {s}\n\n", .{explainArgs(err)});
            try w.writeAll(usage);
            code = zigrec.errors.Outcome.bad_usage.exitCode();
        }
    } else if (eq(cmd, "ui") or eq(cmd, "окно")) {
        var hidden = false;
        var serve = false;
        for (args[2..]) |a| {
            if (eq(a, "--tray")) hidden = true;
            if (eq(a, "--server")) serve = true;
        }
        zigrec.ui.runFull(arena, hidden, serve) catch |err| {
            try w.print("окно не открылось: {s}\n", .{@errorName(err)});
            code = 1;
        };
    } else if (eq(cmd, "animate")) {
        const secs = argInt(args, 2, 10);
        const width = argInt(args, 3, 640);
        const height = argInt(args, 4, 360);
        try w.print("[anim] рисую {d} с в окне {d}x{d} — источник изменений для замера захвата\n", .{ secs, width, height });
        try w.flush();
        const painted = zigrec.smoke.animateOnly(arena, secs, width, height) catch |err| {
            try w.print("[anim] ПРОВАЛ: {s}\n", .{explain(err)});
            return;
        };
        try w.print("[anim] нарисовано кадров {d} ({d:.1} в секунду)\n", .{
            painted,
            @as(f64, @floatFromInt(painted)) / @as(f64, @floatFromInt(@max(secs, 1))),
        });
    } else if (eq(cmd, "audio-check")) {
        if (args.len < 3) {
            try w.writeAll("нужен путь к WAV\n");
            code = 2;
        } else {
            const expect: ?f32 = if (args.len > 3) std.fmt.parseFloat(f32, args[3]) catch null else null;
            code = try audioCheck(init.io, arena, w, args[2], expect);
        }
    } else if (eq(cmd, "mcp")) {
        code = try mcpBridge(init.io, arena, argInt(args, 2, zigrec.control.default_port));
    } else if (eq(cmd, "ui-smoke")) {
        code = try uiSmoke(arena, w);
    } else if (eq(cmd, "hotkey-smoke")) {
        code = try hotkeySmoke(w, if (args.len > 2) args[2] else zigrec.hotkey.default_text);
    } else if (eq(cmd, "gif-write-smoke")) {
        if (args.len < 3) {
            try w.writeAll("нужен путь к GIF\n");
            code = 2;
        } else {
            code = try gifWriteSmoke(init.io, arena, w, args[2], argInt(args, 3, 12));
        }
    } else if (eq(cmd, "gif-smoke")) {
        if (args.len < 3) {
            try w.writeAll("нужен путь к GIF\n");
            code = 2;
        } else {
            code = try gifSmoke(init.io, arena, w, args[2], if (args.len > 3) args[3] else null);
        }
    } else if (eq(cmd, "recent-smoke")) {
        if (args.len < 3) {
            try w.writeAll("нужна папка\n");
            code = 2;
        } else {
            code = try recentSmoke(init.io, arena, w, args[2]);
        }
    } else if (eq(cmd, "home-smoke")) {
        code = try homeSmoke(w);
    } else if (eq(cmd, "shot-smoke")) {
        if (args.len < 3) {
            try w.writeAll("нужен путь к картинке\n");
            code = 2;
        } else {
            code = try shotSmoke(init.io, arena, w, args[2], argInt(args, 3, 7));
        }
    } else if (eq(cmd, "frame-smoke")) {
        if (args.len < 3) {
            try w.writeAll("нужен путь к файлу\n");
            code = 2;
        } else {
            code = try frameSmoke(arena, w, args[2], argInt(args, 3, 1));
        }
    } else if (eq(cmd, "project-smoke")) {
        if (args.len < 3) {
            try w.writeAll("нужен путь к файлу проекта\n");
            code = 2;
        } else {
            code = try projectSmoke(init.io, arena, w, args[2]);
        }
    } else if (eq(cmd, "mcp-smoke")) {
        code = try mcpSmoke(arena, w, argInt(args, 2, zigrec.control.default_port));
    } else if (eq(cmd, "audio-sync")) {
        if (args.len < 3) {
            try w.writeAll("нужен путь к WAV\n");
            code = 2;
        } else {
            code = try audioSync(init.io, arena, w, args[2]);
        }
    } else if (eq(cmd, "mic")) {
        code = try micCheck(w, argInt(args, 2, 5));
    } else if (eq(cmd, "monitors")) {
        code = try listMonitors(arena, w);
    } else if (eq(cmd, "windows")) {
        code = try listWindows(w);
    } else {
        try w.print("неизвестная команда: {s}\n\n", .{cmd});
        try w.writeAll(usage);
        code = 2;
    }

    try w.flush();
    if (code != 0) std.process.exit(code);
}

/// Ошибки разбора ключей — тоже словами.
fn explainArgs(err: ArgError) []const u8 {
    return switch (err) {
        ArgError.MissingValue => "у ключа нет значения",
        ArgError.BadValue => "значение ключа не подходит",
        ArgError.UnknownKey => "неизвестный ключ",
        ArgError.OneSourceOnly => "источник записи должен быть один: монитор, область или окно",
    };
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn argInt(args: []const []const u8, index: usize, default: u32) u32 {
    if (args.len <= index) return default;
    return std.fmt.parseInt(u32, args[index], 10) catch default;
}

// ------------------------------------------------------------ самопроверки

fn captureSmoke(allocator: std.mem.Allocator, w: anytype, frames: u32, backend: zigrec.capture.Backend) !u8 {
    try w.print("[smoke] захват: показываем {d} кадров и читаем их обратно с экрана\n", .{frames});
    try w.flush();

    const report = zigrec.smoke.run(allocator, .{ .frames = frames, .backend = backend }) catch |err| {
        try w.print("[smoke] ПРОВАЛ: {s}\n", .{explain(err)});
        return 1;
    };

    try w.print("[smoke] экран {d}x{d}, путь {s}\n", .{ report.width, report.height, report.backend.label() });
    try w.print("[smoke] показано {d}, снято {d}, номер прочитан в {d}\n", .{
        report.shown,
        report.captured,
        report.read,
    });
    // Совпадение с той же итерацией — свойство машины, а не захвата:
    // печатаем, но не судим по нему.
    try w.print("[smoke] экран отставал в среднем на {d:.1} кадра, совпало сразу {d}\n", .{
        report.lag,
        report.matched,
    });
    try w.print("[smoke] потери {d}, повторы {d}, порядок сбит {d} раз\n", .{
        report.tally.dropped,
        report.tally.duplicated,
        report.tally.out_of_order,
    });
    try w.print("[smoke] кадров в секунду {d:.1}, накоплено системой {d}, простоев {d}, пересозданий дубликации {d}\n", .{
        report.stats.fps(),
        report.stats.dropped,
        report.stats.idle,
        report.stats.recoveries,
    });

    if (!report.ok()) {
        try w.writeAll("[smoke] ПРОВАЛ: снято слишком мало кадров или номера не сходятся\n");
        return 1;
    }
    try w.writeAll("[smoke] ЗАХВАТ ЖИВОЙ\n");
    return 0;
}

/// Кодирование без захвата: кадры берём у стенда, поэтому результат
/// повторяем и не зависит ни от экрана, ни от того, что на нём происходит.
fn encodeSmoke(io: std.Io, allocator: std.mem.Allocator, w: anytype, path: []const u8, frames: u32, with_audio: bool) !u8 {
    const bench = zigrec.testbench;
    const width: u32 = bench.min_width;
    const height: u32 = 64;
    const fps: u32 = 30;

    try w.print("[encode] {d} кадров стенда {d}x{d} в {s}\n", .{ frames, width, height, path });
    if (with_audio) try w.writeAll("[encode] со звуком: тишина и два всплеска — на первой и на второй секунде\n");
    try w.flush();

    const screen = try bench.Screen.init(width, height, fps);
    const buf = try allocator.alloc(u8, screen.frameBytes());
    defer allocator.free(buf);

    const audio: ?zigrec.encode.AudioSettings = if (with_audio) .{} else null;
    var enc = zigrec.encode.Writer.create(path, width, height, .{ .fps = fps, .audio = audio }) catch |err| {
        try w.print("[encode] ПРОВАЛ на создании писателя: {s}\n", .{@errorName(err)});
        return 1;
    };

    // Звук стенда синтезируется, а не берётся с микрофона: живой микрофон
    // у каждого свой, и проверка на нём ничего не доказывает.
    const plan = zigrec.tone.benchPlan();
    const audio_cfg = zigrec.encode.AudioSettings{};
    var audio_written: u64 = 0;
    var chunk: [4096]i16 = undefined;

    const frame_ns: u64 = std.time.ns_per_s / fps;
    var i: u32 = 1;
    while (i <= frames) : (i += 1) {
        try screen.render(buf, i);
        enc.writeFrame(buf, width * 4, frame_ns * i) catch |err| {
            try w.print("[encode] ПРОВАЛ на кадре {d}: {s}\n", .{ i, @errorName(err) });
            enc.abort();
            return 1;
        };
        if (!with_audio) continue;

        // Звук догоняет видео: отдаём ровно те отсчёты, что укладываются
        // в уже записанное время. Так дорожки не разъезжаются на длинной записи.
        const want = @as(u64, frame_ns) * i * audio_cfg.sample_rate / std.time.ns_per_s;
        while (audio_written < want) {
            const take: usize = @intCast(@min(want - audio_written, chunk.len));
            for (0..take) |k| {
                chunk[k] = zigrec.resample.toI16(plan.sampleAt(@intCast(audio_written + k), audio_cfg.sample_rate));
            }
            const at_ns = audio_written * std.time.ns_per_s / audio_cfg.sample_rate;
            enc.writeAudio(chunk[0..take], at_ns) catch |err| {
                try w.print("[encode] ПРОВАЛ на звуке: {s}\n", .{@errorName(err)});
                enc.abort();
                return 1;
            };
            audio_written += take;
        }
    }

    const summary = enc.finish() catch |err| {
        try w.print("[encode] ПРОВАЛ на закрытии файла: {s}\n", .{@errorName(err)});
        return 1;
    };
    try w.print("[encode] записано кадров {d}, длительность {d:.2} с\n", .{
        summary.frames,
        @as(f64, @floatFromInt(summary.duration_ns)) / @as(f64, std.time.ns_per_s),
    });
    if (with_audio) {
        try w.print("[encode] звуковых отсчётов {d} ({d:.2} с)\n", .{
            summary.audio_samples,
            @as(f64, @floatFromInt(summary.audio_samples)) / @as(f64, @floatFromInt(audio_cfg.sample_rate)),
        });
        if (summary.audio_samples == 0) {
            try w.writeAll("[encode] ПРОВАЛ: звуковая дорожка пуста\n");
            return 1;
        }
    }

    try fastStart(io, allocator, w, path);

    const ok = try verifyMp4(io, allocator, w, path);
    if (ok != 0) return ok;
    if (summary.frames + 1 < frames) {
        try w.writeAll("[encode] ПРОВАЛ: до файла дошли не все кадры\n");
        return 1;
    }
    try w.writeAll("[encode] ФАЙЛ ГОДНЫЙ\n");
    return 0;
}

/// Перенести moov в начало: своими руками, потому что штатный ключ
/// Media Foundation портит файл (см. src/encode.zig).
fn fastStart(io: std.Io, allocator: std.mem.Allocator, w: anytype, path: []const u8) !void {
    const moved = zigrec.mp4.makeFastStart(io, allocator, path) catch |err| {
        try w.print("[mp4] не удалось перенести moov в начало: {s}\n", .{@errorName(err)});
        return;
    };
    if (moved) try w.writeAll("[mp4] moov перенесён в начало файла\n");
}

fn verifyMp4(io: std.Io, allocator: std.mem.Allocator, w: anytype, path: []const u8) !u8 {
    var boxes: [64]zigrec.mp4.Box = undefined;
    const layout = zigrec.mp4.inspect(io, allocator, path, &boxes) catch |err| {
        try w.print("[mp4] ПРОВАЛ: {s} ({s})\n", .{ @errorName(err), path });
        return 1;
    };

    try w.print("[mp4] {s}: {d} байт, боксов {d}\n", .{ path, layout.total, layout.boxes.len });
    for (layout.boxes) |b| {
        try w.print("[mp4]   {d:>10}  {s}  {d}\n", .{ b.offset, b.kind, b.size });
    }
    if (!layout.playable()) {
        try w.writeAll("[mp4] ПРОВАЛ: нет moov или пустой mdat — файл не играется\n");
        return 1;
    }
    if (!layout.fastStart()) {
        try w.writeAll("[mp4] ПРОВАЛ: moov после mdat — браузер не начнёт играть, пока не скачает целиком\n");
        return 1;
    }
    try w.print("[mp4] moov перед mdat, данных {d} байт\n", .{layout.mdat_size});
    return 0;
}

/// Проверка распакованного потока: сюда попадает то, что вернул чужой
/// декодер. Так видно, пережил ли таймкод кодирование.
fn verifyRaw(io: std.Io, allocator: std.mem.Allocator, w: anytype, path: []const u8, width: u32, height: u32) !u8 {
    if (width == 0 or height == 0) {
        try w.writeAll("[raw] нужны ширина и высота\n");
        return 2;
    }
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 30)) catch |err| {
        try w.print("[raw] ПРОВАЛ: не читается {s}: {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    defer allocator.free(data);

    const stride = width * 4;
    const frame_bytes = @as(usize, stride) * height;
    if (frame_bytes == 0 or data.len < frame_bytes) {
        try w.writeAll("[raw] ПРОВАЛ: в потоке нет ни одного кадра\n");
        return 1;
    }

    const count = data.len / frame_bytes;
    var seen = try allocator.alloc(u32, count);
    defer allocator.free(seen);
    var n: usize = 0;
    for (0..count) |k| {
        const frame = data[k * frame_bytes ..][0..frame_bytes];
        seen[n] = zigrec.testbench.readIndex(frame, width, stride) catch continue;
        n += 1;
    }

    const t = zigrec.testbench.tally(seen[0..n]);
    try w.print("[raw] кадров {d}, прочитано номеров {d}\n", .{ count, n });
    try w.print("[raw] потери {d}, повторы {d}, порядок сбит {d} раз\n", .{ t.dropped, t.duplicated, t.out_of_order });
    if (n > 0) try w.print("[raw] первый номер {d}, последний {d}\n", .{ seen[0], seen[n - 1] });

    if (n < count or !t.ok()) {
        try w.writeAll("[raw] ПРОВАЛ: таймкоды не пережили кодирование\n");
        return 1;
    }
    try w.writeAll("[raw] ТАЙМКОДЫ ЦЕЛЫ\n");
    return 0;
}

// ------------------------------------------------------------------ запись

/// Что и как писать. Разбор ключей отделён от самой записи, чтобы его
/// можно было проверить тестом.
const RecordArgs = struct {
    seconds: u32 = 5,
    fps: u32 = 30,
    monitor: u32 = 0,
    area: ?zigrec.source.Rect = null,
    window: ?[]const u8 = null,
    cursor: bool = true,
    clicks: bool = true,
    preset: zigrec.encode.Preset = .text_ui,
    bitrate_kbps: ?u32 = null,
    gop: u32 = 60,
    /// Писать ли звук с микрофона. По умолчанию нет: запись экрана
    /// не должна начинать слушать микрофон сама по себе.
    sound: bool = false,
};

const ArgError = error{
    /// Ключ есть, значения нет.
    MissingValue,
    /// Значение не разобралось.
    BadValue,
    /// Ключ неизвестен.
    UnknownKey,
    /// Указано несколько источников сразу.
    OneSourceOnly,
};

fn parseRecordArgs(args: []const []const u8) ArgError!RecordArgs {
    var out = RecordArgs{};
    var sources: u32 = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const key = args[i];
        const has_value = i + 1 < args.len;
        if (eq(key, "--sec")) {
            if (!has_value) return ArgError.MissingValue;
            i += 1;
            out.seconds = std.fmt.parseInt(u32, args[i], 10) catch return ArgError.BadValue;
        } else if (eq(key, "--fps")) {
            if (!has_value) return ArgError.MissingValue;
            i += 1;
            out.fps = std.fmt.parseInt(u32, args[i], 10) catch return ArgError.BadValue;
            if (out.fps == 0 or out.fps > 240) return ArgError.BadValue;
        } else if (eq(key, "--monitor")) {
            if (!has_value) return ArgError.MissingValue;
            i += 1;
            out.monitor = std.fmt.parseInt(u32, args[i], 10) catch return ArgError.BadValue;
            sources += 1;
        } else if (eq(key, "--area")) {
            if (!has_value) return ArgError.MissingValue;
            i += 1;
            out.area = zigrec.source.parseArea(args[i]) orelse return ArgError.BadValue;
            sources += 1;
        } else if (eq(key, "--window")) {
            if (!has_value) return ArgError.MissingValue;
            i += 1;
            out.window = args[i];
            sources += 1;
        } else if (eq(key, "--sound")) {
            out.sound = true;
        } else if (eq(key, "--no-cursor")) {
            out.cursor = false;
        } else if (eq(key, "--no-clicks")) {
            out.clicks = false;
        } else if (eq(key, "--preset")) {
            if (!has_value) return ArgError.MissingValue;
            i += 1;
            if (eq(args[i], "text")) {
                out.preset = .text_ui;
            } else if (eq(args[i], "video")) {
                out.preset = .video;
            } else if (eq(args[i], "max")) {
                out.preset = .max;
            } else return ArgError.BadValue;
        } else if (eq(key, "--bitrate")) {
            if (!has_value) return ArgError.MissingValue;
            i += 1;
            const v = std.fmt.parseInt(u32, args[i], 10) catch return ArgError.BadValue;
            if (v < 100 or v > 200_000) return ArgError.BadValue;
            out.bitrate_kbps = v;
        } else if (eq(key, "--gop")) {
            if (!has_value) return ArgError.MissingValue;
            i += 1;
            const v = std.fmt.parseInt(u32, args[i], 10) catch return ArgError.BadValue;
            if (v < 1 or v > 600) return ArgError.BadValue;
            out.gop = v;
        } else {
            return ArgError.UnknownKey;
        }
    }
    if (sources > 1) return ArgError.OneSourceOnly;
    return out;
}

fn listMonitors(allocator: std.mem.Allocator, w: anytype) !u8 {
    const list = zigrec.source.listMonitors(allocator) catch |err| {
        try w.print("не получилось перечислить мониторы: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer allocator.free(list);
    for (list) |m| {
        try w.print("монитор {d}: {d}x{d} в точке ({d},{d}), {d} Гц{s}\n", .{
            m.index,
            m.area.width,
            m.area.height,
            m.area.x,
            m.area.y,
            m.refresh_hz,
            if (m.primary) " — основной" else "",
        });
    }
    const d = zigrec.source.desktopArea();
    try w.print("рабочий стол целиком: {d}x{d} в точке ({d},{d})\n", .{ d.width, d.height, d.x, d.y });
    return 0;
}

fn listWindows(w: anytype) !u8 {
    const c = zigrec.win32.c;
    var count: u32 = 0;
    var hwnd = c.GetTopWindow(null);
    while (hwnd != null and count < 40) : (hwnd = c.GetWindow(hwnd, c.GW_HWNDNEXT)) {
        if (c.IsWindowVisible(hwnd) == 0) continue;
        var title_buf: [1024]u8 = undefined;
        const title = zigrec.source.windowTitle(hwnd, &title_buf);
        if (title.len == 0) continue;
        const area = zigrec.source.windowArea(hwnd) catch continue;
        if (area.width < 100 or area.height < 100) continue;
        try w.print("{d}x{d} в точке ({d},{d})  {s}\n", .{
            area.width,
            area.height,
            area.x,
            area.y,
            title,
        });
        count += 1;
    }
    if (count == 0) try w.writeAll("видимых окон не нашлось\n");
    return 0;
}

/// Куда идут кадры: в видео или в петлю.
///
/// Два вида записи различаются только приёмником. Разводить ради этого
/// два цикла захвата значило бы держать две копии одного и того же —
/// и чинить их по очереди.
const Sink = union(enum) {
    mp4: zigrec.encode.Writer,
    gif: zigrec.gif_write.Sink,

    fn writeFrame(self: *Sink, pixels: []const u8, stride: u32, at_ns: u64) !void {
        return switch (self.*) {
            .mp4 => |*enc| enc.writeFrame(pixels, stride, at_ns),
            .gif => |*sink| sink.writeFrame(pixels, stride, at_ns),
        };
    }

    fn abort(self: *Sink) void {
        switch (self.*) {
            .mp4 => |*enc| enc.abort(),
            .gif => |*sink| sink.deinit(),
        }
    }
};

/// Просят ли петлю вместо видео.
fn wantsGif(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".gif");
}

fn record(io: std.Io, allocator: std.mem.Allocator, w: anytype, path: []const u8, opt: RecordArgs) !u8 {
    try w.print("[rec] пишем в {s}: {d} с, до {d} кадров в секунду\n", .{ path, opt.seconds, opt.fps });
    try w.flush();

    // Файл проверяем первым: незачем поднимать захват и кодировщик, чтобы
    // в конце узнать, что файл открыт в плеере.
    zigrec.errors.ensureWritable(path) catch |err| {
        try w.print("[rec] ПРОВАЛ: {s}\n{s}\n", .{ path, explain(err) });
        return zigrec.errors.Outcome.failed.exitCode();
    };

    // Окно ищем до открытия захвата: если его нет, незачем и начинать.
    var src: zigrec.source.Source = .{ .monitor = opt.monitor };
    if (opt.window) |title| {
        const hwnd = zigrec.source.findWindow(title) catch |err| {
            try w.print("[rec] ПРОВАЛ: окно «{s}».\n{s}\n", .{ title, explain(err) });
            return 1;
        };
        src = .{ .window = hwnd };
    } else if (opt.area) |a| {
        src = .{ .area = a };
    }

    var cap = zigrec.capture.Capturer.open(allocator, .{ .output = opt.monitor }) catch |err| {
        try w.print("[rec] ПРОВАЛ: захват не открылся.\n{s}\n", .{explain(err)});
        return 1;
    };
    defer cap.deinit();

    const screen = cap.frameSize();
    // Размер кадра выбирается один раз: кодировщик не умеет менять его на ходу.
    // Окно во время записи можно двигать — область поедет следом, — но если его
    // растянуть, в кадре останется прежний прямоугольник.
    const area = zigrec.source.resolve(src, screen) catch |err| {
        try w.print("[rec] ПРОВАЛ: источник не определился.\n{s}\n", .{explain(err)});
        return 1;
    };
    try w.print("[rec] экран {d}x{d}, путь {s}\n", .{ screen.width, screen.height, cap.backend().label() });
    try warnAboutFps(allocator, w, opt.monitor, opt.fps);
    try w.print("[rec] снимаем {d}x{d} в точке ({d},{d})\n", .{ area.width, area.height, area.x, area.y });

    // Звук поднимаем до создания файла: писатель принимает новые потоки
    // только до начала записи. Тот же слой, что и у окна, — иначе формы
    // разъедутся, и «в окне звук есть, а из консоли нет» станет вопросом времени.
    var sound = zigrec.audio.Feeder{};
    defer sound.deinit(allocator);
    const origin_ns = zigrec.win32.nowNs();
    if (opt.sound) {
        sound.start(allocator, origin_ns);
        if (sound.failure) |err| {
            try w.print("[rec] звука не будет: {s}\n", .{explain(err)});
        } else {
            try w.print("[rec] звук: микрофон, {d} Гц, один канал, {d} кбит/с\n", .{
                sound.settings.sample_rate,
                sound.settings.bitrate_kbps,
            });
        }
    }

    const settings = zigrec.encode.Settings{
        .fps = opt.fps,
        .preset = opt.preset,
        .bitrate_kbps = opt.bitrate_kbps,
        .gop = opt.gop,
        .audio = sound.encoderSettings(),
    };
    try w.print("[rec] пресет «{s}», битрейт {d} кбит/с, ключевой кадр каждые {d}\n", .{
        opt.preset.label(),
        settings.bitrate(area.width, area.height),
        opt.gop,
    });
    const to_gif = wantsGif(path);
    var enc: Sink = if (to_gif) .{
        .gif = zigrec.gif_write.Sink.create(allocator, area.width, area.height, opt.fps),
    } else .{
        .mp4 = zigrec.encode.Writer.create(path, area.width, area.height, settings) catch |err| {
            try w.print("[rec] ПРОВАЛ: кодировщик не создался.\n{s}\n", .{explain(err)});
            return 1;
        },
    };
    if (to_gif) {
        try w.print("[rec] пишем петлю GIF, до {d} кадров в секунду\n", .{enc.gif.fps});
        if (opt.sound) try w.writeAll("[rec] в GIF звука не бывает: он записан не будет\n");
    }

    // Курсор дорисовываем сами: захват отдаёт рабочий стол без него. Для этого
    // нужен свой буфер — кадр захвата открыт только на чтение.
    var painter = zigrec.cursor.Painter.init(allocator, .{ .draw = opt.cursor, .clicks = opt.clicks });
    defer painter.deinit();
    const out_stride = area.width * 4;
    const canvas: ?[]u8 = if (opt.cursor)
        try allocator.alloc(u8, @as(usize, out_stride) * area.height)
    else
        null;
    defer if (canvas) |b| allocator.free(b);

    const started = origin_ns;
    const until = started + @as(u64, opt.seconds) * std.time.ns_per_s;
    var written: u64 = 0;
    var moved: u64 = 0;
    var current = area;
    while (zigrec.win32.nowNs() < until) {
        const frame = cap.next(200) catch |err| {
            try w.print("[rec] ПРОВАЛ на захвате: {s}\n", .{@errorName(err)});
            enc.abort();
            return 1;
        } orelse continue;

        // Окно могли подвинуть: берём его положение заново, а размер держим
        // прежний — иначе кадр перестанет соответствовать заголовку файла.
        if (src.isWindow()) {
            if (zigrec.source.resolve(src, screen)) |now| {
                if (now.x != current.x or now.y != current.y) {
                    moved += 1;
                    current.x = now.x;
                    current.y = now.y;
                    current = current.clampTo(screen.width, screen.height);
                    current.width = area.width;
                    current.height = area.height;
                }
            } else |_| {}
        }

        const view = zigrec.capture_types.cropView(frame.pixels, frame.stride, current);

        var pixels = view;
        var pixels_stride = frame.stride;
        if (canvas) |buf| {
            // Копируем построчно в свой буфер и рисуем поверх курсор.
            var row: u32 = 0;
            while (row < area.height) : (row += 1) {
                const from = @as(usize, row) * frame.stride;
                if (from + out_stride > view.len) break;
                @memcpy(buf[@as(usize, row) * out_stride ..][0..out_stride], view[from..][0..out_stride]);
            }
            painter.poll(frame.timestamp_ns);
            painter.paint(
                buf,
                out_stride,
                .{ .width = area.width, .height = area.height },
                screen.x + current.x,
                screen.y + current.y,
                frame.timestamp_ns,
            );
            pixels = buf;
            pixels_stride = out_stride;
        }

        // Время от начала записи, а не показания часов: с двумя дорожками
        // начало отсчёта должно быть одно на обе.
        enc.writeFrame(pixels, pixels_stride, frame.timestamp_ns -| started) catch |err| {
            try w.print("[rec] ПРОВАЛ на кодировании: {s}\n", .{@errorName(err)});
            cap.release();
            enc.abort();
            return 1;
        };
        written += 1;
        cap.release();

        if (to_gif) continue;
        sound.drain(&enc.mp4) catch |err| {
            try w.print("[rec] ПРОВАЛ на звуке: {s}\n", .{@errorName(err)});
            enc.abort();
            return 1;
        };
    }

    if (!to_gif) sound.finish(&enc.mp4) catch |err| {
        try w.print("[rec] ПРОВАЛ на хвосте звука: {s}\n", .{@errorName(err)});
        enc.abort();
        return 1;
    };

    // Петля собирается в конце: палитра считается по всем кадрам сразу,
    // и пока не виден последний, неизвестно, какие цвета в неё войдут.
    if (to_gif) {
        defer enc.gif.deinit();
        const loop = enc.gif.finish(io, path) catch |err| {
            try w.print("[rec] ПРОВАЛ: петля не записалась: {s}\n", .{@errorName(err)});
            return zigrec.errors.Outcome.failed.exitCode();
        };
        try w.print("[rec] петля: кадров {d}, пропущено {d}, {d:.2} с, {d} КБ\n", .{
            loop.frames,
            loop.skipped,
            @as(f64, @floatFromInt(loop.total_ns)) / @as(f64, std.time.ns_per_s),
            (loop.bytes + 1023) / 1024,
        });
        if (enc.gif.full) {
            try w.writeAll("[rec] петля упёрлась в предел памяти: хвост записи в неё не вошёл\n");
        }
        try w.print("[rec] итог: {s}\n", .{zigrec.errors.Outcome.recorded.label()});
        return zigrec.errors.Outcome.recorded.exitCode();
    }

    const summary = enc.mp4.finish() catch |err| {
        try w.print("[rec] ПРОВАЛ на закрытии файла: {s}\n", .{@errorName(err)});
        return 1;
    };
    if (sound.active()) {
        try w.print("[rec] звука записано {d:.1} с, потеряно отсчётов {d}\n", .{
            sound.seconds(),
            sound.dropped(),
        });
    }
    const stats = cap.stats();
    const secs = @as(f64, @floatFromInt(zigrec.win32.nowNs() - started)) / @as(f64, std.time.ns_per_s);
    try w.print("[rec] кадров записано {d} за {d:.1} с ({d:.1} в секунду), простоев {d}, потерь {d}\n", .{
        summary.frames,
        secs,
        @as(f64, @floatFromInt(summary.frames)) / @max(secs, 0.001),
        stats.idle,
        stats.dropped,
    });
    if (summary.frames == 0) {
        try w.writeAll("[rec] ПРОВАЛ: за всё время экран не отдал ни одного кадра.\n" ++
            "Скорее всего, на экране ничего не менялось или он не показывается совсем.\n");
        return zigrec.errors.Outcome.failed.exitCode();
    }
    try fastStart(io, allocator, w, path);
    if (try verifyMp4(io, allocator, w, path) != 0) return zigrec.errors.Outcome.failed.exitCode();

    const outcome: zigrec.errors.Outcome = if (stats.dropped > 0) .recorded_with_drops else .recorded;
    try w.print("[rec] итог: {s}\n", .{outcome.label()});
    return outcome.exitCode();
}

/// Уровень звука в файле. Проверка на известном сигнале, а не на живом
/// микрофоне: микрофон у каждого свой и шумит по-разному, а синус минус
/// двадцать децибел из файла — это проверяемое число.
fn audioCheck(io: std.Io, allocator: std.mem.Allocator, w: anytype, path: []const u8, expect_db: ?f32) !u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 28)) catch |err| {
        try w.print("[audio] ПРОВАЛ: не читается {s}: {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    defer allocator.free(data);

    const info = zigrec.wav.parse(data) catch |err| {
        try w.print("[audio] ПРОВАЛ: {s} — {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    const m = zigrec.wav.measure(data, info);
    try w.print("[audio] {s}: {d} Гц, каналов {d}, {d} бит, {d:.2} с\n", .{
        std.fs.path.basename(path),
        info.sample_rate,
        info.channels,
        info.bits,
        info.durationSeconds(),
    });
    try w.print("[audio] пик {d:.2} дБ, среднеквадратичное {d:.2} дБ\n", .{ m.dbfs(), m.rmsDbfs() });

    if (expect_db) |want| {
        const diff = @abs(m.dbfs() - want);
        try w.print("[audio] ожидали {d:.2} дБ, разница {d:.2} дБ\n", .{ want, diff });
        if (diff > 1.0) {
            try w.writeAll("[audio] ПРОВАЛ: уровень не сходится с ожидаемым\n");
            return 1;
        }
    }
    try w.writeAll("[audio] УРОВЕНЬ СОШЁЛСЯ\n");
    return 0;
}

/// Сверить вынутую звуковую дорожку со стендом: тот ли уровень и на месте ли
/// всплески.
///
/// Уровень отвечает на вопрос «звук вообще дошёл и не исказился». Моменты
/// всплесков — на вопрос «звук не разъехался с видео», и это то, что человек
/// замечает первым: губы отдельно, голос отдельно.
///
/// Два всплеска, а не один: по одному не отличить постоянный сдвиг (звук
/// начался позже) от накапливающегося дрейфа (звук идёт с другой скоростью).
fn audioSync(io: std.Io, allocator: std.mem.Allocator, w: anytype, path: []const u8) !u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 28)) catch |err| {
        try w.print("[sync] ПРОВАЛ: не читается {s}: {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    defer allocator.free(data);

    const info = zigrec.wav.parse(data) catch |err| {
        try w.print("[sync] ПРОВАЛ: {s} — {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    const frames = info.frameCount();
    try w.print("[sync] {s}: {d} Гц, каналов {d}, {d:.2} с\n", .{
        std.fs.path.basename(path),
        info.sample_rate,
        info.channels,
        info.durationSeconds(),
    });

    const samples = try allocator.alloc(f32, frames);
    defer allocator.free(samples);
    for (samples, 0..) |*v, i| v.* = zigrec.wav.sampleAt(data, info, i);

    const plan = zigrec.tone.benchPlan();
    const want_peak = plan.peak();
    var peak: f32 = 0;
    for (samples) |v| peak = @max(peak, @abs(v));
    const want_db = 20 * std.math.log10(want_peak);
    const got_db = if (peak > 0.00003) 20 * std.math.log10(peak) else -90;
    try w.print("[sync] уровень {d:.2} дБ, ожидали {d:.2} дБ\n", .{ got_db, want_db });
    if (@abs(got_db - want_db) > 3.0) {
        try w.writeAll("[sync] ПРОВАЛ: уровень дорожки не тот\n");
        return 1;
    }

    // Порог берём заметно ниже всплеска, но выше того, что кодировщик
    // оставляет в тишине.
    const threshold = want_peak * 0.25;
    var onsets: [8]u64 = undefined;
    const found = zigrec.tone.findOnsets(samples, info.sample_rate, threshold, 64, &onsets);
    if (found != plan.bursts.len) {
        try w.print("[sync] ПРОВАЛ: всплесков {d}, а должно быть {d}\n", .{ found, plan.bursts.len });
        return 1;
    }

    // Порог из цели эпика: рассинхрон меньше 20 миллисекунд.
    const tolerance_ms: f64 = 20;
    var worst: f64 = 0;
    for (plan.bursts, 0..) |b, i| {
        const got_ms = @as(f64, @floatFromInt(onsets[i])) / @as(f64, std.time.ns_per_ms);
        const want_ms = @as(f64, @floatFromInt(b.at_ns)) / @as(f64, std.time.ns_per_ms);
        const off = got_ms - want_ms;
        worst = @max(worst, @abs(off));
        try w.print("[sync] всплеск {d}: ждали {d:.0} мс, пришёл {d:.0} мс, сдвиг {d:.1} мс\n", .{
            i + 1, want_ms, got_ms, off,
        });
    }
    try w.print("[sync] наибольший рассинхрон {d:.1} мс, порог {d:.0} мс\n", .{ worst, tolerance_ms });
    if (worst > tolerance_ms) {
        try w.writeAll("[sync] ПРОВАЛ: звук разъехался с видео\n");
        return 1;
    }
    try w.writeAll("[sync] ЗВУК НА МЕСТЕ\n");
    return 0;
}

/// Самопроверка раскладки окна.
///
/// «Кнопка не влезла» — ошибка, которую видно только глазами и только
/// на той машине, где рамка окна оказалась толще ожидаемой. Стенд собирает
/// настоящее окно, не показывая его, и проходит по всем его кнопкам:
/// вылезло ли что-нибудь за рабочую часть.
fn uiSmoke(allocator: std.mem.Allocator, w: anytype) !u8 {
    var bad: u8 = 0;
    if (try checkWindow(w, "запись", zigrec.ui.checkLayout(allocator))) bad = 1;
    if (try checkWindow(w, "редактор", zigrec.editor.checkLayout(allocator))) bad = 1;
    if (bad != 0) return 1;
    try w.writeAll("[ui] ОБА ОКНА В ПОРЯДКЕ\n");
    return 0;
}

/// Разобрать замер одного окна. Возвращает, было ли плохо.
fn checkWindow(w: anytype, name: []const u8, got: anyerror!zigrec.ui.Layout) !bool {
    const layout = got catch |err| {
        try w.print("[ui] ПРОВАЛ: окно «{s}» не собралось: {s}\n", .{ name, @errorName(err) });
        return true;
    };

    try w.print("[ui] {s}: рабочая часть {d}x{d}, органов управления {d}\n", .{
        name,
        layout.client_w,
        layout.client_h,
        layout.controls,
    });
    if (layout.controls == 0) {
        try w.print("[ui] ПРОВАЛ: в окне «{s}» не оказалось ни одной кнопки\n", .{name});
        return true;
    }
    if (layout.outside > 0) {
        try w.print("[ui] ПРОВАЛ: в окне «{s}» не поместилось {d}; вниз на {d}, вправо на {d} точек\n", .{
            name,
            layout.outside,
            layout.over_bottom,
            layout.over_right,
        });
        return true;
    }
    if (!layout.clips_children) {
        // Без этого признака фон окна ложится поверх кнопок, и они
        // перерисовываются следом: на обновлении по таймеру это мигание.
        try w.print("[ui] ПРОВАЛ: окно «{s}» рисует под своими кнопками — они будут мигать\n", .{name});
        return true;
    }
    try w.print("[ui] {s}: всё поместилось, под кнопками не рисуем\n", .{name});
    return false;
}

/// Самопроверка сочетания клавиш.
///
/// Разбор строки проверен тестами, но числа в нём наши собственные:
/// и модификаторы, и коды клавиш выписаны из заголовков Windows руками.
/// Сойдутся ли они с настоящими, в памяти не проверишь — а не сойдутся,
/// и клавиша просто не сработает или сработает не та. Здесь мы просим
/// Windows зарегистрировать сочетание по-настоящему и тут же отпускаем.
fn hotkeySmoke(w: anytype, text: []const u8) !u8 {
    const hotkey = zigrec.hotkey;
    const c = zigrec.win32.c;

    const keys = hotkey.parse(text) catch |err| {
        try w.print("[hotkey] ПРОВАЛ: «{s}» — {s}\n", .{ text, hotkey.explain(err) });
        return 1;
    };

    var back: [hotkey.max_text]u8 = undefined;
    try w.print("[hotkey] разобрано: {s} (модификаторы 0x{X:0>4}, клавиша 0x{X:0>2})\n", .{
        keys.write(&back),
        keys.modifiers(),
        keys.key,
    });

    // Записанное словами должно читаться обратно тем же: иначе в настройках
    // окажется не то, что человек ввёл.
    if (!std.mem.eql(u8, keys.write(&back), text)) {
        try w.print("[hotkey] ПРОВАЛ: обратно вышло «{s}» вместо «{s}»\n", .{ keys.write(&back), text });
        return 1;
    }

    // Регистрируем на поток, без окна: окно тут ни при чём, проверяются числа.
    const id: c_int = 0x5A16;
    if (c.RegisterHotKey(null, id, keys.modifiers(), keys.key) == 0) {
        try w.print("[hotkey] {s} занято другой программой — Windows его не отдала\n", .{text});
        // Это не провал проекта: сочетание может быть законно занято.
        // Но и «работает» сказать нельзя, поэтому говорим как есть.
        try w.writeAll("[hotkey] ЗАНЯТО\n");
        return 0;
    }
    _ = c.UnregisterHotKey(null, id);
    try w.print("[hotkey] Windows приняла {s} и отпустила\n", .{text});
    try w.writeAll("[hotkey] СОЧЕТАНИЕ РАБОТАЕТ\n");
    return 0;
}

/// Самопроверка записи GIF.
///
/// Кадры берём у стенда, а не с экрана: в них записан номер, и его можно
/// прочитать обратно. Записываем петлю, читаем её своим разбором и сверяем
/// числа — а в `check.cmd` ту же петлю распаковывает ffmpeg, и номера
/// кадров достаёт `verify-raw`. Своим кодом проверять свою же запись
/// значит не заметить ошибки, сделанной в обе стороны одинаково.
fn gifWriteSmoke(io: std.Io, allocator: std.mem.Allocator, w: anytype, path: []const u8, frames: u32) !u8 {
    const bench = zigrec.testbench;
    const width: u32 = bench.min_width;
    const height: u32 = 64;

    const screen = bench.Screen.init(width, height, 20) catch {
        try w.writeAll("[gifw] ПРОВАЛ: кадр меньше таймкода\n");
        return 1;
    };

    const list = try allocator.alloc(zigrec.gif.Frame, frames);
    defer {
        for (list) |f| allocator.free(f.pixels);
        allocator.free(list);
    }
    for (list, 0..) |*f, i| {
        const px = try allocator.alloc(u8, screen.frameBytes());
        try screen.render(px, @intCast(i + 1));
        f.* = .{ .delay_ns = 50 * std.time.ns_per_ms, .pixels = px };
    }

    const bytes = zigrec.gif_write.encode(allocator, list, width, height, 0) catch |err| {
        try w.print("[gifw] ПРОВАЛ: петля не собралась: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer allocator.free(bytes);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch |err| {
        try w.print("[gifw] ПРОВАЛ: не записывается {s}: {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    try w.print("[gifw] {d} кадров {d}x{d} → {d} байт ({d} байт на кадр)\n", .{
        frames,
        width,
        height,
        bytes.len,
        bytes.len / frames,
    });

    var back = zigrec.gif.decode(allocator, bytes) catch |err| {
        try w.print("[gifw] ПРОВАЛ: своя же петля не читается: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer back.deinit(allocator);

    if (back.frames.len != frames or back.width != width or back.height != height) {
        try w.print("[gifw] ПРОВАЛ: вернулось {d} кадров {d}x{d}\n", .{
            back.frames.len,
            back.width,
            back.height,
        });
        return 1;
    }

    // Главное: номер кадра должен пережить палитру и сжатие. Таймкод
    // нарисован чёрным по белому, и если он не читается — палитра съела
    // то, ради чего кадр и записывали.
    var wrong: usize = 0;
    for (back.frames, 0..) |f, i| {
        const got = bench.readIndex(f.pixels, width, width * 4) catch {
            wrong += 1;
            continue;
        };
        if (got != i + 1) wrong += 1;
    }
    if (wrong > 0) {
        try w.print("[gifw] ПРОВАЛ: номер не прочитался в {d} кадрах из {d}\n", .{ wrong, frames });
        return 1;
    }
    try w.print("[gifw] номера всех {d} кадров целы\n", .{frames});
    try w.print("[gifw] петля {d:.2} с, крутится бесконечно: {s}\n", .{
        @as(f64, @floatFromInt(back.totalNs())) / @as(f64, std.time.ns_per_s),
        if (back.loops == 0) "да" else "нет",
    });
    try w.writeAll("[gifw] ПЕТЛЯ ЗАПИСАНА\n");
    return 0;
}

/// Самопроверка чтения GIF.
///
/// Файл делает чужая программа, читаем своим разбором, а первый кадр
/// кладём в png — его снова читает чужая программа. Так замыкается круг:
/// ошибка в нашем понимании формата не может пройти незамеченной, потому
/// что на обоих концах стоит не наш код.
fn gifSmoke(io: std.Io, allocator: std.mem.Allocator, w: anytype, path: []const u8, png_path: ?[]const u8) !u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 28)) catch |err| {
        try w.print("[gif] ПРОВАЛ: не читается {s}: {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    defer allocator.free(data);

    const counted = zigrec.gif.measure(data) catch |err| {
        try w.print("[gif] ПРОВАЛ: не пересчитались кадры: {s}\n", .{@errorName(err)});
        return 1;
    };
    try w.print("[gif] {s}: {d}x{d}, кадров {d}, петля {d:.2} с\n", .{
        std.fs.path.basename(path),
        counted.width,
        counted.height,
        counted.frames,
        @as(f64, @floatFromInt(counted.total_ns)) / @as(f64, std.time.ns_per_s),
    });

    var img = zigrec.gif.decode(allocator, data) catch |err| {
        try w.print("[gif] ПРОВАЛ: не разобрался: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer img.deinit(allocator);

    // Быстрый пересчёт и полный разбор обязаны сойтись: иначе числа
    // в окне будут не те, что на экране.
    if (img.frames.len != counted.frames or img.totalNs() != counted.total_ns or
        img.width != counted.width or img.height != counted.height)
    {
        try w.writeAll("[gif] ПРОВАЛ: быстрый пересчёт разошёлся с полным разбором\n");
        return 1;
    }
    try w.writeAll("[gif] пересчёт сошёлся с разбором\n");

    // Ни один кадр не должен быть пустым: чёрный холст означает, что
    // распаковка отдала нули, а мы этого не заметили.
    var empty: usize = 0;
    for (img.frames) |f| {
        var lit: usize = 0;
        for (f.pixels) |b| {
            if (b != 0) lit += 1;
        }
        if (lit * 20 < f.pixels.len) empty += 1;
    }
    if (empty > 0) {
        try w.print("[gif] ПРОВАЛ: почти пустых кадров {d} из {d}\n", .{ empty, img.frames.len });
        return 1;
    }
    try w.print("[gif] все {d} кадров с картинкой\n", .{img.frames.len});

    if (png_path) |out_path| {
        const bytes = zigrec.png.fromBgra(
            allocator,
            img.frames[0].pixels,
            img.width,
            img.height,
            @as(usize, img.width) * 4,
        ) catch |err| {
            try w.print("[gif] ПРОВАЛ: кадр не лёг в png: {s}\n", .{@errorName(err)});
            return 1;
        };
        defer allocator.free(bytes);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = bytes }) catch |err| {
            try w.print("[gif] ПРОВАЛ: не записывается {s}: {s}\n", .{ out_path, @errorName(err) });
            return 1;
        };
        try w.print("[gif] первый кадр записан в {s} ({d} байт)\n", .{
            std.fs.path.basename(out_path),
            bytes.len,
        });
    }

    try w.writeAll("[gif] GIF ПРОЧИТАН\n");
    return 0;
}

/// Самопроверка списков недавних на диске.
///
/// Правила списка проверены тестами в памяти. Здесь добавляется диск:
/// русские буквы в путях, пробелы в именах, кодировка файла — всё то,
/// что в памяти не проверишь.
fn recentSmoke(io: std.Io, allocator: std.mem.Allocator, w: anytype, dir: []const u8) !u8 {
    const recent = zigrec.recent;
    zigrec.paths.ensureDir(dir);

    var made = recent.Recent{};
    made.recorded.add("D:\\Мои видео\\запись экрана 1.mp4");
    made.recorded.add("D:\\Мои видео\\запись экрана 2.mp4");
    // Тот же файл ещё раз — должен всплыть наверх, а не появиться дважды.
    made.recorded.add("D:\\Мои видео\\запись экрана 1.mp4");
    made.viewed.add("E:\\чужое\\клип с пробелами.mov");

    if (!recent.save(&made, dir)) {
        try w.print("[recent] ПРОВАЛ: не записалось в {s}\n", .{dir});
        return 1;
    }
    try w.print("[recent] записано: записей {d}, просмотров {d}\n", .{
        made.recorded.count,
        made.viewed.count,
    });

    const back = recent.load(io, allocator, dir);
    if (back.recorded.count != 2 or back.viewed.count != 1) {
        try w.print("[recent] ПРОВАЛ: вернулось записей {d}, просмотров {d}\n", .{
            back.recorded.count,
            back.viewed.count,
        });
        return 1;
    }
    if (!std.mem.eql(u8, back.recorded.at(0), "D:\\Мои видео\\запись экрана 1.mp4")) {
        try w.print("[recent] ПРОВАЛ: наверху оказалось «{s}»\n", .{back.recorded.at(0)});
        return 1;
    }
    if (!std.mem.eql(u8, back.viewed.at(0), "E:\\чужое\\клип с пробелами.mov")) {
        try w.writeAll("[recent] ПРОВАЛ: путь с пробелами развалился\n");
        return 1;
    }
    try w.print("[recent] прочитано обратно, наверху: {s}\n", .{back.recorded.at(0)});

    // Пропавший файл должен опознаваться как пропавший, а не прятаться.
    if (recent.onDisk(back.recorded.at(0))) {
        try w.writeAll("[recent] ПРОВАЛ: несуществующий файл выдан за существующий\n");
        return 1;
    }
    try w.writeAll("[recent] пропавший файл опознан как пропавший\n");
    try w.writeAll("[recent] СПИСКИ ЦЕЛЫ\n");
    return 0;
}

/// Самопроверка хранения: оба способа, и возврат к тому, что было.
///
/// Трогаем настоящий признак рядом с программой — и обязательно возвращаем
/// его в прежнее состояние: самопроверка не должна менять то, как человек
/// настроил программу.
fn homeSmoke(w: anytype) !u8 {
    const paths = zigrec.paths;
    const was = paths.currentMode();
    try w.print("[home] сейчас: {s}\n", .{was.label()});

    var exe_buf: [paths.max_path]u8 = undefined;
    const exe_dir = paths.exeDir(&exe_buf) catch {
        try w.writeAll("[home] ПРОВАЛ: не нашлась папка программы\n");
        return 1;
    };

    var buf: [paths.max_path]u8 = undefined;
    var code: u8 = 0;

    if (paths.setMode(.portable)) {
        const base = paths.base(&buf) catch "";
        try w.print("[home] Portable: {s}\n", .{base});
        if (paths.currentMode() != .portable or !std.mem.eql(u8, base, exe_dir)) {
            try w.writeAll("[home] ПРОВАЛ: Portable не привёл к папке программы\n");
            code = 1;
        }
    } else {
        try w.writeAll("[home] ПРОВАЛ: признак Portable не создался\n");
        code = 1;
    }

    if (code == 0) {
        if (paths.setMode(.classic)) {
            const base = paths.base(&buf) catch "";
            try w.print("[home] Classic: {s}\n", .{base});
            if (paths.currentMode() != .classic or std.mem.eql(u8, base, exe_dir)) {
                try w.writeAll("[home] ПРОВАЛ: Classic не увёл из папки программы\n");
                code = 1;
            }
        } else {
            try w.writeAll("[home] ПРОВАЛ: признак Portable не убрался\n");
            code = 1;
        }
    }

    // Возвращаем как было — что бы ни случилось выше.
    _ = paths.setMode(was);
    if (paths.currentMode() != was) {
        try w.writeAll("[home] ПРОВАЛ: способ хранения не вернулся к прежнему\n");
        return 1;
    }
    try w.print("[home] вернулись к прежнему: {s}\n", .{was.label()});
    if (code != 0) return code;
    try w.writeAll("[home] ХРАНЕНИЕ ПЕРЕКЛЮЧАЕТСЯ\n");
    return 0;
}

/// Самопроверка снимка кадра.
///
/// Рисуем эталонный кадр с таймкодом, записываем его картинкой и печатаем
/// числа. Дальше в дело вступает чужая программа: `tools\\check.cmd` просит
/// ffmpeg распаковать нашу картинку обратно в пиксели, а `verify-raw` читает
/// из них номер кадра. Своим же кодом проверять свою запись — значит
/// не заметить ошибки, сделанной в обе стороны одинаково.
fn shotSmoke(io: std.Io, allocator: std.mem.Allocator, w: anytype, path: []const u8, index: u32) !u8 {
    const screen = zigrec.testbench.Screen.init(384, 64, 60) catch {
        try w.writeAll("[shot] ПРОВАЛ: кадр меньше таймкода\n");
        return 1;
    };

    const frame = try allocator.alloc(u8, screen.frameBytes());
    defer allocator.free(frame);
    try screen.render(frame, index);

    const stride = @as(usize, screen.width) * 4;
    const bytes = zigrec.png.fromBgra(allocator, frame, screen.width, screen.height, stride) catch |err| {
        try w.print("[shot] ПРОВАЛ: картинка не собралась: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer allocator.free(bytes);

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch |err| {
        try w.print("[shot] ПРОВАЛ: не записывается {s}: {s}\n", .{ path, @errorName(err) });
        return 1;
    };

    try w.print("[shot] кадр {d}x{d}, номер {d}\n", .{ screen.width, screen.height, index });
    try w.print("[shot] пикселей {d} байт, картинка {d} байт\n", .{ frame.len, bytes.len });

    // Сжатие без пользы означало бы, что мы записали не то, что думали.
    if (bytes.len >= frame.len) {
        try w.writeAll("[shot] ПРОВАЛ: картинка не меньше кадра\n");
        return 1;
    }
    // Восемь байт подписи узнают все: если их нет, это не PNG.
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &zigrec.png.signature)) {
        try w.writeAll("[shot] ПРОВАЛ: у файла не та подпись\n");
        return 1;
    }
    try w.print("[shot] СНИМОК ЗАПИСАН: {s}\n", .{std.fs.path.basename(path)});
    return 0;
}

/// Самопроверка кадра: числа, по которым видно, как лежит картинка в памяти.
///
/// Появился после того, как кадр с камеры расползся косыми полосами,
/// а два предположения о шаге строки подряд оказались неверными. Мерить
/// надо, а не догадываться.
fn frameSmoke(allocator: std.mem.Allocator, w: anytype, path: []const u8, seconds: u32) !u8 {
    var p = zigrec.player.Player.open(allocator, path) catch |err| {
        try w.print("[frame] ПРОВАЛ: {s} — {s}\n", .{ std.fs.path.basename(path), @errorName(err) });
        return 1;
    };
    defer p.close();

    try w.print("[frame] {s}: кадр {d}x{d}, длительность {d:.2} с\n", .{
        std.fs.path.basename(path),
        p.width,
        p.height,
        @as(f64, @floatFromInt(p.duration_ns)) / @as(f64, std.time.ns_per_s),
    });

    p.showAt(@as(u64, seconds) * std.time.ns_per_s) catch |err| {
        try w.print("[frame] ПРОВАЛ на кадре: {s}\n", .{@errorName(err)});
        return 1;
    };
    if (!p.ready) {
        try w.writeAll("[frame] ПРОВАЛ: кадр не получен\n");
        return 1;
    }

    const row_bytes = @as(usize, p.width) * 4;
    const measured = if (p.height > 0) p.last_length / p.height else 0;
    try w.print("[frame] строка по ширине {d} байт, шаг из типа {d}, длина буфера {d}\n", .{
        row_bytes,
        p.stride,
        p.last_length,
    });
    try w.print("[frame] длина делить на высоту: {d}, остаток {d}\n", .{
        measured,
        if (p.height > 0) p.last_length % p.height else 0,
    });
    try w.print("[frame] шаг взят: {s}\n", .{switch (p.route) {
        1 => "у исходного буфера кадра",
        2 => "у склеенного буфера",
        3 => "из типа (двумерный доступ не дали)",
        else => "никак: кадра нет",
    }});
    try w.print("[frame] строки {s} вверх, время кадра {d:.3} с\n", .{
        if (p.bottom_up) "снизу" else "сверху",
        @as(f64, @floatFromInt(p.at_ns)) / @as(f64, std.time.ns_per_s),
    });

    // Кадр не должен быть пустым: чёрное поле означает, что декодер ничего
    // не отдал, а мы этого не заметили.
    var non_zero: usize = 0;
    for (p.pixels) |b| {
        if (b != 0) non_zero += 1;
    }
    try w.print("[frame] ненулевых байт {d} из {d}\n", .{ non_zero, p.pixels.len });
    if (non_zero * 20 < p.pixels.len) {
        try w.writeAll("[frame] ПРОВАЛ: кадр почти пустой\n");
        return 1;
    }
    try w.writeAll("[frame] КАДР ПОЛУЧЕН\n");
    return 0;
}

/// Самопроверка файла проекта: собрать, записать на диск, прочитать, сверить.
///
/// Тесты проверяют запись и чтение в памяти. Этот стенд добавляет диск:
/// путь с русскими буквами, перевод строк, кодировку файла — всё то, что
/// в памяти не проверишь.
fn projectSmoke(io: std.Io, allocator: std.mem.Allocator, w: anytype, path: []const u8) !u8 {
    const timeline = zigrec.timeline;
    const pf = zigrec.project_file;

    const made = try allocator.create(timeline.Project);
    defer allocator.destroy(made);
    made.* = .{};

    const src = try made.addSource("D:\\видео\\моя запись 2026.mp4", 60 * std.time.ns_per_s);
    _ = try made.addTrack(.video, "Видео");
    _ = try made.addTrack(.audio, "Микрофон ведущего");
    // Видео и звук кладём одной связкой — так их кладёт и редактор,
    // когда открывают обычный mp4.
    const link = made.newLink();
    try made.placeLinked(0, src, 0, 10 * std.time.ns_per_s, link);
    try made.placeLinked(1, src, 0, 10 * std.time.ns_per_s, link);
    try made.split(0, 4 * std.time.ns_per_s);
    try made.setMuted(1, true);

    try w.print("[project] собран проект: дорожек {d}, клипов {d}\n", .{
        made.track_count,
        made.trackList()[0].list().len + made.trackList()[1].list().len,
    });

    var text: [64 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&text);
    try pf.write(made, &writer);
    const bytes = writer.buffered();

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch |err| {
        try w.print("[project] ПРОВАЛ: не записывается {s}: {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    try w.print("[project] записано {d} байт в {s}\n", .{ bytes.len, std.fs.path.basename(path) });

    const back_data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 22)) catch |err| {
        try w.print("[project] ПРОВАЛ: не читается обратно: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer allocator.free(back_data);

    const back = try allocator.create(timeline.Project);
    defer allocator.destroy(back);
    back.* = .{};
    pf.read(back, back_data) catch |err| {
        try w.print("[project] ПРОВАЛ: {s}\n", .{pf.explain(err)});
        return 1;
    };

    if (back.track_count != made.track_count or back.source_count != made.source_count) {
        try w.writeAll("[project] ПРОВАЛ: дорожек или исходников стало не столько\n");
        return 1;
    }
    if (!std.mem.eql(u8, back.sourceList()[0].fullPath(), made.sourceList()[0].fullPath())) {
        try w.writeAll("[project] ПРОВАЛ: путь к исходнику не совпал\n");
        return 1;
    }
    for (made.trackList(), back.trackList()) |a, b| {
        if (a.kind != b.kind or a.muted != b.muted or a.count != b.count) {
            try w.writeAll("[project] ПРОВАЛ: дорожка изменилась\n");
            return 1;
        }
        if (!std.mem.eql(u8, a.title(), b.title())) {
            try w.writeAll("[project] ПРОВАЛ: имя дорожки не совпало\n");
            return 1;
        }
        for (a.list(), b.list()) |x, y| {
            if (x.source != y.source or x.in_ns != y.in_ns or x.len_ns != y.len_ns or x.at_ns != y.at_ns) {
                try w.writeAll("[project] ПРОВАЛ: клип изменился\n");
                return 1;
            }
            if (x.link != y.link) {
                try w.writeAll("[project] ПРОВАЛ: связка не пережила запись\n");
                return 1;
            }
        }
    }

    try w.print("[project] прочитано обратно: дорожек {d}, пути и имена целы\n", .{back.track_count});

    // Связка должна не просто сохраниться числом, а работать после чтения:
    // двигаем видео и смотрим, пошёл ли за ним звук. Совпадение номеров
    // ничего не стоит, если по ним никто не ходит.
    const left_link = back.tracks[0].clips[0].link;
    if (left_link == 0) {
        try w.writeAll("[project] ПРОВАЛ: после чтения клипы оказались сами по себе\n");
        return 1;
    }
    const sound_was = back.tracks[1].clips[0].at_ns;
    try back.move(0, 0, 0, 3 * std.time.ns_per_s);
    const sound_now = back.tracks[1].clips[0].at_ns;
    if (sound_now != sound_was + 3 * std.time.ns_per_s) {
        try w.print("[project] ПРОВАЛ: звук не пошёл за картинкой: было {d}, стало {d}\n", .{
            sound_was,
            sound_now,
        });
        return 1;
    }
    try w.print("[project] связка цела: сдвинули видео на 3 с — звук ушёл на 3 с\n", .{});

    // И развязанное должно оставаться развязанным.
    try back.unlink(0, 0);
    try back.move(0, 0, 0, 0);
    if (back.tracks[1].clips[0].at_ns != sound_now) {
        try w.writeAll("[project] ПРОВАЛ: развязанный звук всё равно поехал\n");
        return 1;
    }
    try w.writeAll("[project] развязанный звук остался на месте\n");
    try w.writeAll("[project] ПРОЕКТ СОШЁЛСЯ\n");
    return 0;
}

/// Сказать, если просят больше кадров, чем экран показывает.
///
/// Захват отдаёт кадр тогда, когда рабочий стол его показал. Больше разных
/// кадров, чем обновлений экрана, взяться неоткуда; кодировщик добьёт файл
/// до постоянной частоты повторами. Файл будет правильным и заиграет везде,
/// но человек должен знать, за что платит битрейтом.
fn warnAboutFps(allocator: std.mem.Allocator, w: anytype, monitor: u32, fps: u32) !void {
    const list = zigrec.source.listMonitors(allocator) catch return;
    defer allocator.free(list);

    var hz: u32 = 0;
    for (list) |m| {
        if (m.index == monitor) hz = m.refresh_hz;
    }
    if (hz == 0 or fps <= hz) return;

    try w.print(
        "[rec] экран обновляется {d} раз(а) в секунду: разных кадров больше {d} в секунду\n",
        .{ hz, hz },
    );
    try w.writeAll("[rec] взяться неоткуда, и кодировщик добьёт файл повторами\n");
}

/// Что внутри файла: дорожки, длительность, кодеки.
///
/// Первое, что нужно редактору: показать открытый файл ещё до того, как он
/// научится его проигрывать. Декодер для этого не нужен — всё написано
/// в заголовке.
fn fileInfo(io: std.Io, allocator: std.mem.Allocator, w: anytype, path: []const u8) !u8 {
    const info = zigrec.media.read(io, allocator, path) catch |err| {
        try w.print("[info] ПРОВАЛ: {s} — {s}\n", .{
            std.fs.path.basename(path),
            zigrec.media.explain(err),
        });
        return 1;
    };

    try w.print("[info] {s}: {s}, {d:.2} с, дорожек {d}\n", .{
        std.fs.path.basename(path),
        info.format.label(),
        info.seconds(),
        info.list().len,
    });

    for (info.list(), 0..) |t, i| {
        if (t.kind == .video) {
            try w.print("[info]  {d}. {s}: {s}, {d}x{d}, {d:.1} кадр/с, {d:.2} с\n", .{
                i + 1, t.kind.label(), t.codec, t.width, t.height, t.fps, t.seconds(),
            });
        } else if (t.sample_rate > 0) {
            try w.print("[info]  {d}. {s}: {s}, {d} Гц, каналов {d}, {d:.2} с\n", .{
                i + 1, t.kind.label(), t.codec, t.sample_rate, t.channels, t.seconds(),
            });
        } else {
            try w.print("[info]  {d}. {s}: {s}, {d:.2} с\n", .{
                i + 1, t.kind.label(), t.codec, t.seconds(),
            });
        }
    }
    if (info.list().len == 0) try w.writeAll("[info] дорожек не нашлось\n");
    return 0;
}

/// Проверка микрофона без окна: видно, слышно ли, и не занят ли вход.
fn micCheck(w: anytype, seconds: u32) !u8 {
    var cap = zigrec.mic.Capture{};
    cap.start() catch |err| {
        try w.print("[mic] ПРОВАЛ: {s}\n", .{explain(err)});
        return 1;
    };
    defer cap.stop();

    // Первым делом ждём, пока поток поднимется и скажет формат.
    zigrec.win32.c.Sleep(300);
    if (cap.failure) |err| {
        try w.print("[mic] ПРОВАЛ: {s}\n", .{explain(err)});
        return 1;
    }
    try w.print("[mic] устройство: {d} Гц, каналов {d}\n", .{ cap.sample_rate, cap.channels });
    try w.flush();

    var loud: u32 = 0;
    var i: u32 = 0;
    while (i < seconds * 4) : (i += 1) {
        zigrec.win32.c.Sleep(250);
        const level = cap.ring.level();
        if (!level.isSilent()) loud += 1;

        // Столбик из символов: видно и в консоли, и в журнале.
        var bar: [40]u8 = @splat(' ');
        const filled = @min(@as(usize, @intFromFloat(level.peak * 40)), 40);
        for (bar[0..filled]) |*ch| ch.* = '#';
        try w.print("[mic] {s} пик {d:6.1} дБ{s}\n", .{
            bar,
            level.dbfs(),
            if (level.isClipping()) "  ПЕРЕГРУЗ" else if (level.isSilent()) "  тишина" else "",
        });
        try w.flush();
    }

    if (loud == 0) {
        try w.writeAll("[mic] за всё время ни звука: проверьте, тот ли вход выбран и не выключен ли микрофон\n");
        return 1;
    }
    try w.print("[mic] СЛЫШНО: звук был в {d} замерах из {d}\n", .{ loud, i });
    return 0;
}

fn explain(err: anyerror) []const u8 {
    return zigrec.errors.explain(err);
}

/// Сервер MCP для Claude Code.
///
/// Сам ничего не записывает: он труба между Claude Code и открытым окном
/// Zig-Rec Studio. Записывает по-прежнему окно — то самое, которое видит
/// человек. Иначе получились бы две программы, снимающие экран одновременно.
///
/// Рукопожатие и список инструментов отвечаем сами, не заглядывая в окно:
/// клиент должен уметь подключиться и увидеть, что мы умеем, даже когда окно
/// закрыто. Иначе Claude Code при запуске решит, что сервера нет вовсе.
fn mcpBridge(io: std.Io, allocator: std.mem.Allocator, port: u32) !u8 {
    const net = std.Io.net;

    var in_buf: [64 * 1024]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;
    var stdin: Io.File.Reader = .init(.stdin(), io, &in_buf);
    var stdout: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const r = &stdin.interface;
    const w = &stdout.interface;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    while (true) {
        // `takeDelimiter` сдвигается за перевод строки; `...Exclusive`
        // оставляет его, и следующая строка приходит пустой.
        const line = (r.takeDelimiter('\n') catch break) orelse break;
        if (line.len == 0) continue;
        _ = arena_state.reset(.retain_capacity);

        var session = zigrec.mcp.parse(arena_state.allocator(), line);
        defer session.deinit();
        const got = session.result;

        if (got.fault) |fault| {
            try zigrec.mcp.writeFault(w, got.id, fault);
            try w.writeByte('\n');
            try w.flush();
            continue;
        }
        const request = got.request orelse continue;
        switch (request) {
            // Уведомление ответа не требует: лишний ответ строгий клиент
            // считает ошибкой протокола.
            .initialized => continue,
            .initialize => {
                try zigrec.mcp.writeInitialize(w, got.id, zigrec.version.VERSION);
                try w.writeByte('\n');
                try w.flush();
                continue;
            },
            .list_tools => {
                try zigrec.mcp.writeToolList(w, got.id);
                try w.writeByte('\n');
                try w.flush();
                continue;
            },
            else => {},
        }

        // Остальное умеет только окно.
        var addr = net.IpAddress.parseLiteral("127.0.0.1:1") catch unreachable;
        addr.setPort(@intCast(port));
        const stream = addr.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch {
            // Не молчим и не падаем: человек должен прочитать, что делать.
            try zigrec.mcp.writeToolText(
                w,
                got.id,
                "окно Zig-Rec Studio не отвечает. Откройте его и нажмите кнопку «Сервер MCP» — рядом загорится зелёная лампочка.",
                true,
            );
            try w.writeByte('\n');
            try w.flush();
            continue;
        };
        defer stream.close(io);

        var sock_out: [64 * 1024]u8 = undefined;
        var sock_in: [64 * 1024]u8 = undefined;
        var sock_w = stream.writer(io, &sock_out);
        var sock_r = stream.reader(io, &sock_in);
        try sock_w.interface.writeAll(line);
        try sock_w.interface.writeByte('\n');
        try sock_w.interface.flush();

        const reply = (sock_r.interface.takeDelimiter('\n') catch null) orelse {
            try zigrec.mcp.writeToolText(w, got.id, "окно приняло просьбу, но не ответило", true);
            try w.writeByte('\n');
            try w.flush();
            continue;
        };
        try w.writeAll(reply);
        try w.writeByte('\n');
        try w.flush();
    }
    return 0;
}

/// Самопроверка сервера: настоящий разговор с окном и сверка ответов.
///
/// Проверяем не «поднялся ли порт», а то, ради чего сервер сделан: что на той
/// стороне отвечает работающее окно и что ответы — годный JSON с ожидаемым
/// содержимым. Окно к этому времени должно быть запущено с ключом `--server`.
fn mcpSmoke(allocator: std.mem.Allocator, w: anytype, port: u32) !u8 {
    const net = std.Io.net;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try w.print("[mcp] стучимся в 127.0.0.1:{d}\n", .{port});
    try w.flush();

    var addr = net.IpAddress.parseLiteral("127.0.0.1:1") catch unreachable;
    addr.setPort(@intCast(port));
    const stream = addr.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch |err| {
        try w.print("[mcp] ПРОВАЛ: окно не отвечает ({s})\n", .{@errorName(err)});
        return 1;
    };
    defer stream.close(io);

    var out_buf: [16 * 1024]u8 = undefined;
    var in_buf: [64 * 1024]u8 = undefined;
    var sock_w = stream.writer(io, &out_buf);
    var sock_r = stream.reader(io, &in_buf);

    const Step = struct {
        what: []const u8,
        line: []const u8,
        /// Что должно встретиться в ответе.
        expect: []const u8,
    };
    const steps = [_]Step{
        .{
            .what = "рукопожатие",
            .line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
            .expect = "protocolVersion",
        },
        .{
            .what = "список инструментов",
            .line = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}",
            .expect = "start_recording",
        },
        .{
            .what = "состояние записи",
            .line = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"recording_status\"}}",
            .expect = "состояние",
        },
        .{
            .what = "список мониторов",
            .line = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"list_monitors\"}}",
            .expect = "точке",
        },
        .{
            .what = "неизвестный инструмент",
            .line = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"полетели\"}}",
            .expect = "-32601",
        },
    };

    for (steps) |step| {
        try sock_w.interface.writeAll(step.line);
        try sock_w.interface.writeByte('\n');
        try sock_w.interface.flush();

        const reply = (sock_r.interface.takeDelimiter('\n') catch |err| {
            try w.print("[mcp] ПРОВАЛ на «{s}»: ответа нет ({s})\n", .{ step.what, @errorName(err) });
            return 1;
        }) orelse {
            try w.print("[mcp] ПРОВАЛ на «{s}»: связь оборвалась\n", .{step.what});
            return 1;
        };

        // Ответ обязан быть годным JSON: клиент разбирает его строго.
        const doc = std.json.parseFromSlice(std.json.Value, allocator, reply, .{}) catch {
            // Показываем сам ответ: без него остаётся только гадать,
            // а гадать про чужой протокол — долго.
            try w.print("[mcp] ПРОВАЛ на «{s}»: ответ не разбирается как JSON\n", .{step.what});
            try w.print("[mcp] длина ответа {d}, начало: {s}\n", .{
                reply.len,
                reply[0..@min(reply.len, 200)],
            });
            return 1;
        };
        defer doc.deinit();

        if (std.mem.indexOf(u8, reply, step.expect) == null) {
            try w.print("[mcp] ПРОВАЛ на «{s}»: в ответе нет «{s}»\n", .{ step.what, step.expect });
            return 1;
        }
        try w.print("[mcp] {s} — ответ получен\n", .{step.what});
        try w.flush();
    }

    try w.writeAll("[mcp] СЕРВЕР ОТВЕЧАЕТ\n");
    return 0;
}

test "версия ядра доступна из exe" {
    try std.testing.expect(zigrec.version.VERSION.len > 0);
    _ = zigrec.version.current();
}

test "разбор числового аргумента" {
    const args = [_][]const u8{ "zigrec", "record", "out.mp4", "12", "плохо" };
    try std.testing.expectEqual(@as(u32, 12), argInt(&args, 3, 5));
    try std.testing.expectEqual(@as(u32, 30), argInt(&args, 4, 30));
    try std.testing.expectEqual(@as(u32, 7), argInt(&args, 9, 7));
}

test "ключи записи: умолчания" {
    const a = try parseRecordArgs(&.{});
    try std.testing.expectEqual(@as(u32, 5), a.seconds);
    try std.testing.expectEqual(@as(u32, 30), a.fps);
    try std.testing.expectEqual(@as(u32, 0), a.monitor);
    try std.testing.expect(a.area == null);
    try std.testing.expect(a.window == null);
}

test "ключи записи: область и время" {
    const a = try parseRecordArgs(&.{ "--sec", "12", "--area", "10,20,640,480" });
    try std.testing.expectEqual(@as(u32, 12), a.seconds);
    try std.testing.expectEqual(@as(u32, 640), a.area.?.width);
}

test "ключи записи: окно по части заголовка" {
    const a = try parseRecordArgs(&.{ "--window", "Блокнот", "--fps", "60" });
    try std.testing.expectEqualStrings("Блокнот", a.window.?);
    try std.testing.expectEqual(@as(u32, 60), a.fps);
}

test "ключи записи: два источника сразу — ошибка" {
    try std.testing.expectError(
        ArgError.OneSourceOnly,
        parseRecordArgs(&.{ "--area", "0,0,10,10", "--window", "что-то" }),
    );
}

test "ключи записи: пропущенное значение и мусор" {
    try std.testing.expectError(ArgError.MissingValue, parseRecordArgs(&.{"--sec"}));
    try std.testing.expectError(ArgError.BadValue, parseRecordArgs(&.{ "--fps", "0" }));
    try std.testing.expectError(ArgError.BadValue, parseRecordArgs(&.{ "--fps", "999" }));
    try std.testing.expectError(ArgError.BadValue, parseRecordArgs(&.{ "--area", "плохо" }));
    try std.testing.expectError(ArgError.UnknownKey, parseRecordArgs(&.{"--луна"}));
}

test "ключи качества" {
    const a = try parseRecordArgs(&.{ "--preset", "max", "--gop", "30", "--bitrate", "8000" });
    try std.testing.expectEqual(zigrec.encode.Preset.max, a.preset);
    try std.testing.expectEqual(@as(u32, 30), a.gop);
    try std.testing.expectEqual(@as(u32, 8000), a.bitrate_kbps.?);
}

test "ключи качества: мусор отвергается" {
    try std.testing.expectError(ArgError.BadValue, parseRecordArgs(&.{ "--preset", "лучший" }));
    try std.testing.expectError(ArgError.BadValue, parseRecordArgs(&.{ "--bitrate", "10" }));
    try std.testing.expectError(ArgError.BadValue, parseRecordArgs(&.{ "--gop", "0" }));
}

test "ключи курсора" {
    const a = try parseRecordArgs(&.{ "--no-cursor", "--no-clicks" });
    try std.testing.expect(!a.cursor);
    try std.testing.expect(!a.clicks);
    const b = try parseRecordArgs(&.{});
    try std.testing.expect(b.cursor and b.clicks);
}

test "звук пишется только когда его попросили" {
    // Умолчание — без звука: запись экрана не должна начать слушать микрофон
    // сама по себе, об этом человек просит явно.
    const quiet = try parseRecordArgs(&.{});
    try std.testing.expect(!quiet.sound);
    const loud = try parseRecordArgs(&.{"--sound"});
    try std.testing.expect(loud.sound);
}
