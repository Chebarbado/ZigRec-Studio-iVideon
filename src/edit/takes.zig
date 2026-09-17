//! Дубли озвучки: что записано с микрофона поверх видео и где лежит.
//!
//! Задача #26. Дубль — это клип на звуковой дорожке, чей исходник записан
//! микрофоном редактора (файл «озвучка …wav»). Здесь — правила без окна:
//! как отличить дубль от прочего звука, как собрать список по времени,
//! как назвать строку. Окно только рисует и щёлкает.
const std = @import("std");
const timeline = @import("timeline.zig");

/// Так называет файлы запись с микрофона в редакторе.
pub const take_prefix = "озвучка ";

/// Папка рядом с проектом, куда ложатся дубли: они переезжают с ним.
pub const take_dir = "дубли";

pub fn isTakeName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, take_prefix);
}

pub const Take = struct {
    track: usize,
    clip: usize,
    source: u16,
    at_ns: u64,
    len_ns: u64,
};

/// Больше дублей в списке не держим: клипов у дорожек столько и есть.
pub const max_takes = timeline.max_tracks * timeline.max_clips;

/// Все дубли проекта по времени начала.
pub fn list(project: *const timeline.Project, out: []Take) []Take {
    var n: usize = 0;
    const sources = project.sourceList();
    for (project.trackList(), 0..) |track, ti| {
        if (track.kind != .audio) continue;
        for (track.list(), 0..) |clip, ci| {
            if (clip.source >= sources.len) continue;
            if (!isTakeName(sources[clip.source].name())) continue;
            if (n >= out.len) break;
            out[n] = .{ .track = ti, .clip = ci, .source = clip.source, .at_ns = clip.at_ns, .len_ns = clip.len_ns };
            n += 1;
        }
    }
    // По времени: список — это «что за чем сказано», а не «в каком порядке
    // записывали».
    std.mem.sort(Take, out[0..n], {}, byTime);
    return out[0..n];
}

fn byTime(_: void, a: Take, b: Take) bool {
    if (a.at_ns != b.at_ns) return a.at_ns < b.at_ns;
    return a.track < b.track;
}

/// Заметка к дублю — у исходника: один файл — одна заметка.
pub fn noteOf(project: *const timeline.Project, take: Take) []const u8 {
    const sources = project.sourceList();
    if (take.source >= sources.len) return "";
    return sources[take.source].comment();
}

/// Куда положить новый дубль: в папку «дубли» рядом с проектом, а без
/// проекта — в общую папку. Возвращает папку, файл к ней добавит окно.
pub fn dirFor(buf: []u8, project_path: []const u8, fallback_dir: []const u8) []const u8 {
    const project_dir = std.fs.path.dirname(project_path) orelse return fallback_dir;
    if (project_dir.len == 0) return fallback_dir;
    return std.fmt.bufPrint(buf, "{s}\\{s}", .{ project_dir, take_dir }) catch fallback_dir;
}

/// Имя дорожки, которую заводим под дубли, когда своя занята.
pub const take_track_name = "дубли";

/// На какую дорожку класть дубль длиной `len_ns` с `at_ns`.
///
/// Микрофон нажали на дорожке `wanted`; если там в это время уже лежит
/// звук, дубль лёг бы поверх него, и слышно было бы обоих. Тогда — на
/// дорожку «дубли»: есть — берём, нет — заводим. Если и она занята,
/// заводим ещё одну с тем же именем: дубли одного места и должны лежать
/// друг под другом, чтобы выбирать между ними.
pub fn trackForTake(project: *timeline.Project, wanted: usize, at_ns: u64, len_ns: u64) timeline.Error!usize {
    if (wanted < project.track_count and project.tracks[wanted].kind == .audio and free(project.tracks[wanted], at_ns, len_ns)) {
        return wanted;
    }
    for (project.trackList(), 0..) |track, i| {
        if (track.kind != .audio or !std.mem.eql(u8, track.title(), take_track_name)) continue;
        if (free(track, at_ns, len_ns)) return i;
    }
    return project.addTrack(.audio, take_track_name);
}

fn free(track: timeline.Track, at_ns: u64, len_ns: u64) bool {
    const probe = timeline.Clip{ .at_ns = at_ns, .len_ns = @max(len_ns, 1) };
    for (track.list()) |clip| {
        if (clip.overlaps(probe)) return false;
    }
    return true;
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;
const sec = std.time.ns_per_s;

test "дубль узнаётся по имени файла" {
    try testing.expect(isTakeName("озвучка 2026-09-17 12-00-00.wav"));
    try testing.expect(!isTakeName("запись.mp4"));
    try testing.expect(!isTakeName("моя озвучка.wav"));
}

test "список дублей — только записи микрофона, по времени начала" {
    var p = timeline.Project{};
    const video = try p.addSource("D:\\v\\фильм.mp4", 60 * sec);
    const late = try p.addSource("D:\\v\\дубли\\озвучка 2026-09-17 12-05-00.wav", 5 * sec);
    const early = try p.addSource("D:\\v\\дубли\\озвучка 2026-09-17 12-00-00.wav", 3 * sec);
    const vt = try p.addTrack(.video, "видео");
    const at = try p.addTrack(.audio, "звук");
    try p.place(vt, video, 0, 60 * sec);
    try p.place(at, late, 20 * sec, 5 * sec);
    try p.place(at, early, 10 * sec, 3 * sec);

    var out: [max_takes]Take = undefined;
    const got = list(&p, &out);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(early, got[0].source);
    try testing.expectEqual(@as(u64, 10 * sec), got[0].at_ns);
    try testing.expectEqual(late, got[1].source);
    try testing.expectEqual(at, got[1].track);
}

test "заметка дубля живёт у исходника и не трогает отмену" {
    var p = timeline.Project{};
    const s = try p.addSource("озвучка 2026-09-17 12-00-00.wav", 3 * sec);
    const at = try p.addTrack(.audio, "звук");
    try p.place(at, s, 0, 3 * sec);
    var out: [max_takes]Take = undefined;
    const got = list(&p, &out);
    try testing.expectEqualStrings("", noteOf(&p, got[0]));
    try p.setSourceNote(s, "  первый заход, с запинкой ");
    try testing.expectEqualStrings("первый заход, с запинкой", noteOf(&p, got[0]));
    // Заметка — пометка на полях: правится прямо, без снимка отмены.
    try p.setSourceNote(s, "");
    try testing.expectEqualStrings("", noteOf(&p, got[0]));
}

test "папка дублей — рядом с проектом, без проекта — общая" {
    var buf: [600]u8 = undefined;
    try testing.expectEqualStrings("D:\\видео\\дубли", dirFor(&buf, "D:\\видео\\проект.zrs", "C:\\общая"));
    try testing.expectEqualStrings("C:\\общая", dirFor(&buf, "", "C:\\общая"));
}

test "дубль ложится на свою дорожку, если она свободна, иначе на «дубли»" {
    var p = timeline.Project{};
    const voice = try p.addSource("фильм.mp4", 60 * sec);
    const at = try p.addTrack(.audio, "звук");
    try p.place(at, voice, 0, 60 * sec);
    // Занято весь час — заводится дорожка «дубли».
    const t1 = try trackForTake(&p, at, 10 * sec, 3 * sec);
    try testing.expect(t1 != at);
    try testing.expectEqualStrings(take_track_name, p.tracks[t1].title());
    try testing.expectEqual(@as(usize, 2), p.track_count);
    // Второй дубль в другое место — на ту же «дубли», новой не надо.
    try testing.expectEqual(t1, try trackForTake(&p, at, 20 * sec, 3 * sec));
    // Дубль поверх дубля — ещё одна «дубли», под первой.
    const take = try p.addSource("озвучка 2026-09-17 12-00-00.wav", 3 * sec);
    try p.place(t1, take, 10 * sec, 3 * sec);
    const t2 = try trackForTake(&p, at, 11 * sec, 3 * sec);
    try testing.expect(t2 != t1 and t2 != at);
    try testing.expectEqual(@as(usize, 3), p.track_count);
    // Своя дорожка свободна после часа — туда.
    try testing.expectEqual(at, try trackForTake(&p, at, 61 * sec, 3 * sec));
}
