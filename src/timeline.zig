//! Модель проекта: дорожки, клипы, резка, перестановка, отмена.
//!
//! Задача #24. Это спина редактора: всё, что человек делает мышью, здесь
//! становится числами. Ни одного вызова Windows — чистая арифметика, поэтому
//! проверяется тестами целиком, а окно остаётся тонким.
//!
//! **Правка не трогает исходный файл.** Клип помнит, из какого файла он взят
//! и какой кусок этого файла показывает. Обрезать — значит подвинуть границы
//! куска, а не переписать байты. Открытый файл читается и никогда не пишется.
//!
//! Видео и звук живут на разных дорожках и правятся порознь: звук можно
//! подвинуть относительно картинки, укоротить или выбросить, не трогая видео.
const std = @import("std");

pub const TrackKind = enum {
    video,
    audio,

    pub fn label(self: TrackKind) []const u8 {
        return switch (self) {
            .video => "видео",
            .audio => "звук",
        };
    }
};

/// Кусок исходного файла, поставленный на дорожку.
pub const Clip = struct {
    /// Номер исходника в списке проекта.
    source: u16 = 0,
    /// Откуда в исходнике начинается показываемый кусок.
    in_ns: u64 = 0,
    /// Сколько его показывать.
    len_ns: u64 = 0,
    /// Где он стоит на дорожке.
    at_ns: u64 = 0,

    pub fn endsAt(self: Clip) u64 {
        return self.at_ns + self.len_ns;
    }

    pub fn covers(self: Clip, when_ns: u64) bool {
        return when_ns >= self.at_ns and when_ns < self.endsAt();
    }

    /// Пересекаются ли два клипа по времени.
    pub fn overlaps(self: Clip, other: Clip) bool {
        return self.at_ns < other.endsAt() and other.at_ns < self.endsAt();
    }
};

// Пределы посчитаны, а не взяты с потолка. Клип — 32 байта, значит
// дорожка на 128 клипов это 4 КБ, восемь дорожек — 33 КБ, и столько же
// весит один снимок для отмены. Двадцать четыре снимка дают 800 КБ —
// столько проект и занимает. Первый заход был на 256 клипов, 16 дорожек
// и 64 снимка: восемь с половиной мегабайт, и тесты легли переполнением
// стека. Отсюда и правило: `Project` живёт в куче, не на стеке.
pub const max_clips = 128;
pub const max_tracks = 8;
pub const max_sources = 32;
pub const max_history = 24;

/// Самый короткий кусок, который имеет смысл оставлять: одна сотая секунды.
/// Короче человек не увидит и не услышит, а клипы нулевой длины засоряют
/// дорожку невидимым мусором.
pub const min_len_ns: u64 = std.time.ns_per_s / 100;

/// Сколько байт имени влезает в отведённое место, не разрубив букву.
///
/// Русская буква занимает два байта. Обрезка ровно по границе места
/// оставила бы половину буквы, и вместо имени вышел бы вопросительный знак
/// в ромбе — а заметно это стало бы только на длинном имени.
pub fn fitName(text: []const u8, room: usize) usize {
    if (text.len <= room) return text.len;
    var n = room;
    // Продолжение буквы в UTF-8 начинается с битов 10.
    while (n > 0 and (text[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

pub const Track = struct {
    kind: TrackKind = .video,
    /// Имя для полосы в окне.
    name: [48]u8 = @splat(0),
    name_len: usize = 0,
    /// Дорожку не видно и не слышно, но она никуда не делась.
    muted: bool = false,
    clips: [max_clips]Clip = @splat(.{}),
    count: usize = 0,

    pub fn title(self: *const Track) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setTitle(self: *Track, text: []const u8) void {
        const n = fitName(text, self.name.len);
        @memcpy(self.name[0..n], text[0..n]);
        self.name_len = n;
    }

    pub fn list(self: *const Track) []const Clip {
        return self.clips[0..self.count];
    }

    /// Докуда занята дорожка.
    pub fn endsAt(self: *const Track) u64 {
        var last: u64 = 0;
        for (self.list()) |c| last = @max(last, c.endsAt());
        return last;
    }

    /// Какой клип стоит в этой точке.
    pub fn clipAt(self: *const Track, when_ns: u64) ?usize {
        for (self.list(), 0..) |c, i| {
            if (c.covers(when_ns)) return i;
        }
        return null;
    }

    fn insert(self: *Track, clip: Clip) bool {
        if (self.count >= max_clips) return false;
        // Держим клипы отсортированными по времени: так и рисовать проще,
        // и соседей искать, и склеивать.
        var at: usize = self.count;
        while (at > 0 and self.clips[at - 1].at_ns > clip.at_ns) : (at -= 1) {
            self.clips[at] = self.clips[at - 1];
        }
        self.clips[at] = clip;
        self.count += 1;
        return true;
    }

    fn remove(self: *Track, index: usize) void {
        if (index >= self.count) return;
        var i = index;
        while (i + 1 < self.count) : (i += 1) self.clips[i] = self.clips[i + 1];
        self.count -= 1;
    }
};

/// Открытый файл. Проект хранит путь, а не содержимое.
pub const Source = struct {
    path: [260]u8 = @splat(0),
    path_len: usize = 0,
    duration_ns: u64 = 0,

    /// Полный путь, как его открыли.
    pub fn fullPath(self: *const Source) []const u8 {
        return self.path[0..self.path_len];
    }

    /// Только имя файла — это и показывается на клипе.
    pub fn name(self: *const Source) []const u8 {
        return std.fs.path.basename(self.fullPath());
    }
};

pub const Error = error{
    /// Дорожек больше не помещается.
    TooManyTracks,
    /// Клипов на дорожке больше не помещается.
    TooManyClips,
    /// Исходников больше не помещается.
    TooManySources,
    /// Такой дорожки или клипа нет.
    NoSuchThing,
    /// Резать нечего: точка не попала ни в один клип.
    NothingThere,
    /// После правки остался бы кусок короче различимого.
    TooShort,
};

/// Снимок для отмены. Целиком, а не по шагам.
///
/// Хранить список действий и уметь их обращать — это вдвое больше кода
/// и вдвое больше мест, где отмена разойдётся с действием. Снимок дорожек
/// весит 33 КБ, журнал на двадцать четыре шага — 800 КБ. За такую цену
/// отмена просто не может ошибиться.
const Snapshot = struct {
    tracks: [max_tracks]Track = @splat(.{}),
    track_count: usize = 0,
};

/// Проект. **Заводится в куче, а не на стеке**: вместе с журналом отмен
/// он занимает около восьмисот килобайт, и на стеке ему не место.
///
///     const p = try allocator.create(Project);
///     p.* = .{};
///     defer allocator.destroy(p);
pub const Project = struct {
    sources: [max_sources]Source = @splat(.{}),
    source_count: usize = 0,
    tracks: [max_tracks]Track = @splat(.{}),
    track_count: usize = 0,

    history: [max_history]Snapshot = @splat(.{}),
    /// Сколько снимков лежит позади.
    past: usize = 0,
    /// Сколько отменённых снимков лежит впереди.
    future: usize = 0,

    pub fn trackList(self: *const Project) []const Track {
        return self.tracks[0..self.track_count];
    }

    pub fn sourceList(self: *const Project) []const Source {
        return self.sources[0..self.source_count];
    }

    /// Длительность проекта — по самой длинной дорожке.
    pub fn durationNs(self: *const Project) u64 {
        var last: u64 = 0;
        for (self.trackList()) |t| last = @max(last, t.endsAt());
        return last;
    }

    pub fn addSource(self: *Project, path: []const u8, duration_ns: u64) Error!u16 {
        if (self.source_count >= max_sources) return Error.TooManySources;
        var src = Source{ .duration_ns = duration_ns };
        const n = @min(path.len, src.path.len);
        @memcpy(src.path[0..n], path[0..n]);
        src.path_len = n;
        self.sources[self.source_count] = src;
        self.source_count += 1;
        return @intCast(self.source_count - 1);
    }

    pub fn addTrack(self: *Project, kind: TrackKind, title: []const u8) Error!usize {
        if (self.track_count >= max_tracks) return Error.TooManyTracks;
        var t = Track{ .kind = kind };
        t.setTitle(title);
        self.tracks[self.track_count] = t;
        self.track_count += 1;
        return self.track_count - 1;
    }

    fn track(self: *Project, index: usize) Error!*Track {
        if (index >= self.track_count) return Error.NoSuchThing;
        return &self.tracks[index];
    }

    // -------------------------------------------------------------- отмена

    /// Запомнить состояние перед правкой.
    ///
    /// Зовётся до изменения, а не после: отменить — значит вернуться к тому,
    /// что было, а не к тому, что стало.
    fn remember(self: *Project) void {
        // Новое действие обрывает ветку отменённого: вперёд идти уже некуда.
        self.future = 0;
        if (self.past == max_history) {
            // Самый старый снимок уходит: глубина отмены ограничена, и это
            // честнее, чем незаметно съедать память.
            var i: usize = 0;
            while (i + 1 < max_history) : (i += 1) self.history[i] = self.history[i + 1];
            self.past -= 1;
        }
        var shot = Snapshot{ .track_count = self.track_count };
        @memcpy(shot.tracks[0..self.track_count], self.tracks[0..self.track_count]);
        self.history[self.past] = shot;
        self.past += 1;
    }

    pub fn canUndo(self: *const Project) bool {
        return self.past > 0;
    }

    pub fn canRedo(self: *const Project) bool {
        return self.future > 0;
    }

    pub fn undo(self: *Project) bool {
        if (self.past == 0) return false;
        // Текущее состояние кладём вперёд, чтобы можно было вернуть.
        var now = Snapshot{ .track_count = self.track_count };
        @memcpy(now.tracks[0..self.track_count], self.tracks[0..self.track_count]);

        // Журнал — одна лента: слева от `past` лежит прошлое, справа —
        // отменённое. Шаг назад освобождает ровно ту ячейку, откуда взят
        // снимок, и текущее состояние кладётся именно в неё. Класть его
        // в `past + future`, как было сначала, значит затирать соседний
        // отменённый шаг: первый возврат работал, второй — уже нет.
        self.past -= 1;
        const shot = self.history[self.past];
        self.history[self.past] = now;
        self.future += 1;

        self.track_count = shot.track_count;
        @memcpy(self.tracks[0..shot.track_count], shot.tracks[0..shot.track_count]);
        return true;
    }

    pub fn redo(self: *Project) bool {
        if (self.future == 0) return false;
        var now = Snapshot{ .track_count = self.track_count };
        @memcpy(now.tracks[0..self.track_count], self.tracks[0..self.track_count]);

        const shot = self.history[self.past];
        self.history[self.past] = now;
        self.past += 1;
        self.future -= 1;

        self.track_count = shot.track_count;
        @memcpy(self.tracks[0..shot.track_count], shot.tracks[0..shot.track_count]);
        return true;
    }

    // ------------------------------------------------------------ действия

    /// Положить весь исходник на дорожку в указанное место.
    pub fn place(self: *Project, track_index: usize, source: u16, at_ns: u64, len_ns: u64) Error!void {
        const t = try self.track(track_index);
        if (len_ns < min_len_ns) return Error.TooShort;
        self.remember();
        const tr = try self.track(track_index);
        if (!tr.insert(.{ .source = source, .in_ns = 0, .len_ns = len_ns, .at_ns = at_ns })) {
            _ = self.undo();
            return Error.TooManyClips;
        }
        _ = t;
    }

    /// Разрезать клип в точке. На месте одного получаются два подряд.
    pub fn split(self: *Project, track_index: usize, when_ns: u64) Error!void {
        const t = try self.track(track_index);
        const index = t.clipAt(when_ns) orelse return Error.NothingThere;
        const clip = t.clips[index];

        const left_len = when_ns - clip.at_ns;
        const right_len = clip.len_ns - left_len;
        if (left_len < min_len_ns or right_len < min_len_ns) return Error.TooShort;
        if (t.count >= max_clips) return Error.TooManyClips;

        self.remember();
        const tr = try self.track(track_index);
        tr.clips[index].len_ns = left_len;
        // Правая половина показывает следующий кусок исходника: точка реза
        // сдвигает и начало внутри файла, иначе вторая половина повторила бы
        // первую.
        _ = tr.insert(.{
            .source = clip.source,
            .in_ns = clip.in_ns + left_len,
            .len_ns = right_len,
            .at_ns = when_ns,
        });
    }

    /// Подтянуть край клипа. `from_left` — какой именно край.
    ///
    /// Обрезка двигает границы куска внутри исходника, а не переписывает
    /// файл. Слева при этом едет и начало внутри файла: иначе кадр под краем
    /// сменился бы на другой.
    pub fn trim(self: *Project, track_index: usize, index: usize, from_left: bool, delta_ns: i64) Error!void {
        const t = try self.track(track_index);
        if (index >= t.count) return Error.NoSuchThing;
        const clip = t.clips[index];

        var updated = clip;
        if (from_left) {
            const shift = delta_ns;
            const new_len = @as(i64, @intCast(clip.len_ns)) - shift;
            const new_in = @as(i64, @intCast(clip.in_ns)) + shift;
            const new_at = @as(i64, @intCast(clip.at_ns)) + shift;
            if (new_len < @as(i64, @intCast(min_len_ns)) or new_in < 0 or new_at < 0) return Error.TooShort;
            updated.len_ns = @intCast(new_len);
            updated.in_ns = @intCast(new_in);
            updated.at_ns = @intCast(new_at);
        } else {
            const new_len = @as(i64, @intCast(clip.len_ns)) + delta_ns;
            if (new_len < @as(i64, @intCast(min_len_ns))) return Error.TooShort;
            updated.len_ns = @intCast(new_len);
        }

        self.remember();
        const tr = try self.track(track_index);
        tr.clips[index] = updated;
    }

    /// Передвинуть клип по времени и, если надо, на другую дорожку.
    pub fn move(self: *Project, from_track: usize, index: usize, to_track: usize, at_ns: u64) Error!void {
        const src = try self.track(from_track);
        if (index >= src.count) return Error.NoSuchThing;
        if (to_track >= self.track_count) return Error.NoSuchThing;
        var clip = src.clips[index];

        // Видео на звуковую дорожку и наоборот не кладём: полоса дорожки
        // говорит, что на ней лежит, и смешивать — значит врать глазу.
        if (self.tracks[from_track].kind != self.tracks[to_track].kind) return Error.NoSuchThing;

        self.remember();
        const from = try self.track(from_track);
        from.remove(index);
        clip.at_ns = at_ns;
        const to = try self.track(to_track);
        if (!to.insert(clip)) {
            _ = self.undo();
            return Error.TooManyClips;
        }
    }

    /// Убрать клип.
    pub fn removeClip(self: *Project, track_index: usize, index: usize) Error!void {
        const t = try self.track(track_index);
        if (index >= t.count) return Error.NoSuchThing;
        self.remember();
        const tr = try self.track(track_index);
        tr.remove(index);
    }

    /// Вырезать участок на дорожке и сдвинуть остальное влево.
    ///
    /// Это то, ради чего редактор и открывают: выкинуть паузу и не оставить
    /// на её месте дыру.
    pub fn ripple(self: *Project, track_index: usize, from_ns: u64, to_ns: u64) Error!void {
        if (to_ns <= from_ns) return Error.TooShort;
        const t = try self.track(track_index);
        _ = t;
        self.remember();

        const tr = try self.track(track_index);
        const gap = to_ns - from_ns;
        var out: Track = .{ .kind = tr.kind, .name = tr.name, .name_len = tr.name_len, .muted = tr.muted };

        for (tr.list()) |clip| {
            const starts = clip.at_ns;
            const ends = clip.endsAt();

            // Целиком до вырезаемого — остаётся как есть.
            if (ends <= from_ns) {
                _ = out.insert(clip);
                continue;
            }
            // Целиком после — едет влево.
            if (starts >= to_ns) {
                var moved = clip;
                moved.at_ns = starts - gap;
                _ = out.insert(moved);
                continue;
            }
            // Целиком внутри — исчезает.
            if (starts >= from_ns and ends <= to_ns) continue;

            // Торчит слева.
            if (starts < from_ns) {
                var left = clip;
                left.len_ns = from_ns - starts;
                if (left.len_ns >= min_len_ns) _ = out.insert(left);
            }
            // Торчит справа.
            if (ends > to_ns) {
                var right = clip;
                const cut = to_ns - starts;
                right.in_ns = clip.in_ns + cut;
                right.len_ns = ends - to_ns;
                right.at_ns = from_ns;
                if (right.len_ns >= min_len_ns) _ = out.insert(right);
            }
        }

        const dst = try self.track(track_index);
        dst.* = out;
    }

    /// Собрать клипы дорожки встык, без дыр, сохранив порядок.
    pub fn compact(self: *Project, track_index: usize) Error!void {
        const t = try self.track(track_index);
        if (t.count == 0) return;
        self.remember();
        const tr = try self.track(track_index);
        var at: u64 = 0;
        var i: usize = 0;
        while (i < tr.count) : (i += 1) {
            tr.clips[i].at_ns = at;
            at += tr.clips[i].len_ns;
        }
    }

    /// Поменять местами две дорожки — порядок полос в окне.
    pub fn swapTracks(self: *Project, a: usize, b: usize) Error!void {
        if (a >= self.track_count or b >= self.track_count) return Error.NoSuchThing;
        if (a == b) return;
        self.remember();
        const tmp = self.tracks[a];
        self.tracks[a] = self.tracks[b];
        self.tracks[b] = tmp;
    }

    /// Переименовать дорожку.
    ///
    /// Через отмену наравне с резкой: переименовал не ту — отменил.
    /// Пустое имя не берём: полоса без подписи хуже полосы с «Звук 2».
    pub fn renameTrack(self: *Project, track_index: usize, name: []const u8) Error!void {
        const t = try self.track(track_index);
        const clean = std.mem.trim(u8, name, " ");
        if (clean.len == 0) return;
        if (std.mem.eql(u8, t.title(), clean)) return;
        self.remember();
        const tr = try self.track(track_index);
        tr.setTitle(clean);
    }

    pub fn setMuted(self: *Project, track_index: usize, muted: bool) Error!void {
        const t = try self.track(track_index);
        if (t.muted == muted) return;
        self.remember();
        const tr = try self.track(track_index);
        tr.muted = muted;
    }
};

// ---------------------------------------------------------------- тесты

const sec = std.time.ns_per_s;

/// Заготовка для тестов: проект в куче, видеодорожка и звуковая.
fn sample() !*Project {
    const p = try std.testing.allocator.create(Project);
    p.* = .{};
    _ = try p.addSource("D:\\видео\\запись.mp4", 60 * sec);
    _ = try p.addTrack(.video, "Видео");
    _ = try p.addTrack(.audio, "Микрофон");
    return p;
}

fn drop(p: *Project) void {
    std.testing.allocator.destroy(p);
}

test "клип помнит, откуда взят, и правка не трогает исходник" {
    const p = try sample();
    defer drop(p);
    try p.place(0, 0, 0, 10 * sec);
    const c = p.trackList()[0].list()[0];
    try std.testing.expectEqual(@as(u64, 0), c.in_ns);
    try std.testing.expectEqual(@as(u64, 10 * sec), c.len_ns);
    // Исходник как лежал, так и лежит: длительность файла не изменилась.
    try std.testing.expectEqual(@as(u64, 60 * sec), p.sourceList()[0].duration_ns);
}

test "разрез даёт два куска подряд, и второй показывает продолжение" {
    const p = try sample();
    defer drop(p);
    try p.place(0, 0, 0, 10 * sec);
    try p.split(0, 4 * sec);

    const clips = p.trackList()[0].list();
    try std.testing.expectEqual(@as(usize, 2), clips.len);

    try std.testing.expectEqual(@as(u64, 0), clips[0].at_ns);
    try std.testing.expectEqual(@as(u64, 4 * sec), clips[0].len_ns);
    try std.testing.expectEqual(@as(u64, 0), clips[0].in_ns);

    try std.testing.expectEqual(@as(u64, 4 * sec), clips[1].at_ns);
    try std.testing.expectEqual(@as(u64, 6 * sec), clips[1].len_ns);
    // Главное: вторая половина показывает следующий кусок файла, а не тот же.
    try std.testing.expectEqual(@as(u64, 4 * sec), clips[1].in_ns);
}

test "разрез мимо клипа и у самого края отклоняется" {
    const p = try sample();
    defer drop(p);
    try p.place(0, 0, 2 * sec, 10 * sec);
    try std.testing.expectError(Error.NothingThere, p.split(0, 1 * sec));
    try std.testing.expectError(Error.TooShort, p.split(0, 2 * sec));
}

test "обрезка слева двигает и начало внутри файла" {
    const p = try sample();
    defer drop(p);
    try p.place(0, 0, 5 * sec, 10 * sec);
    try p.trim(0, 0, true, 2 * sec);

    const c = p.trackList()[0].list()[0];
    try std.testing.expectEqual(@as(u64, 7 * sec), c.at_ns);
    try std.testing.expectEqual(@as(u64, 8 * sec), c.len_ns);
    // Без этого под краем сменился бы кадр: кусок поехал бы по файлу.
    try std.testing.expectEqual(@as(u64, 2 * sec), c.in_ns);
}

test "обрезка справа меняет только длину" {
    const p = try sample();
    defer drop(p);
    try p.place(0, 0, 0, 10 * sec);
    try p.trim(0, 0, false, -3 * sec);

    const c = p.trackList()[0].list()[0];
    try std.testing.expectEqual(@as(u64, 0), c.at_ns);
    try std.testing.expectEqual(@as(u64, 0), c.in_ns);
    try std.testing.expectEqual(@as(u64, 7 * sec), c.len_ns);
}

test "обрезать до невидимого нельзя" {
    const p = try sample();
    defer drop(p);
    try p.place(0, 0, 0, sec);
    try std.testing.expectError(Error.TooShort, p.trim(0, 0, false, -sec));
    try std.testing.expectError(Error.TooShort, p.trim(0, 0, true, @intCast(sec)));
    // Клип остался цел.
    try std.testing.expectEqual(@as(u64, sec), p.trackList()[0].list()[0].len_ns);
}

test "перестановка по времени и между дорожками своего вида" {
    const p = try sample();
    defer drop(p);
    _ = try p.addTrack(.video, "Видео 2");
    try p.place(0, 0, 0, 5 * sec);
    try p.move(0, 0, 2, 12 * sec);

    try std.testing.expectEqual(@as(usize, 0), p.trackList()[0].list().len);
    const moved = p.trackList()[2].list()[0];
    try std.testing.expectEqual(@as(u64, 12 * sec), moved.at_ns);
    // Кусок файла не поехал: двигали по дорожке, а не по исходнику.
    try std.testing.expectEqual(@as(u64, 0), moved.in_ns);
}

test "видео на звуковую дорожку не кладётся" {
    const p = try sample();
    defer drop(p);
    try p.place(0, 0, 0, 5 * sec);
    // Полоса дорожки говорит, что на ней лежит; смешивать — значит врать глазу.
    try std.testing.expectError(Error.NoSuchThing, p.move(0, 0, 1, 0));
}

test "клипы на дорожке всегда по порядку" {
    const p = try sample();
    defer drop(p);
    try p.place(0, 0, 30 * sec, 5 * sec);
    try p.place(0, 0, 10 * sec, 5 * sec);
    try p.place(0, 0, 20 * sec, 5 * sec);

    const clips = p.trackList()[0].list();
    try std.testing.expectEqual(@as(u64, 10 * sec), clips[0].at_ns);
    try std.testing.expectEqual(@as(u64, 20 * sec), clips[1].at_ns);
    try std.testing.expectEqual(@as(u64, 30 * sec), clips[2].at_ns);
}

test "вырезать участок: дыры не остаётся" {
    const p = try sample();
    defer drop(p);
    try p.place(0, 0, 0, 10 * sec);
    try p.place(0, 0, 10 * sec, 10 * sec);
    // Выкидываем с 4-й по 14-ю секунду — по куску от каждого клипа.
    try p.ripple(0, 4 * sec, 14 * sec);

    const clips = p.trackList()[0].list();
    try std.testing.expectEqual(@as(usize, 2), clips.len);

    // Левый обрезан справа.
    try std.testing.expectEqual(@as(u64, 0), clips[0].at_ns);
    try std.testing.expectEqual(@as(u64, 4 * sec), clips[0].len_ns);
    // Правый подъехал вплотную и показывает свой хвост.
    try std.testing.expectEqual(@as(u64, 4 * sec), clips[1].at_ns);
    try std.testing.expectEqual(@as(u64, 6 * sec), clips[1].len_ns);
    try std.testing.expectEqual(@as(u64, 4 * sec), clips[1].in_ns);
    // И общая длина укоротилась ровно на вырезанное.
    try std.testing.expectEqual(@as(u64, 10 * sec), p.trackList()[0].endsAt());
}

test "вырезать целиком лежащий внутри клип" {
    const p = try sample();
    defer drop(p);
    try p.place(0, 0, 0, 3 * sec);
    try p.place(0, 0, 5 * sec, 3 * sec);
    try p.place(0, 0, 20 * sec, 3 * sec);
    try p.ripple(0, 4 * sec, 10 * sec);

    const clips = p.trackList()[0].list();
    // Средний исчез, последний подъехал на шесть секунд.
    try std.testing.expectEqual(@as(usize, 2), clips.len);
    try std.testing.expectEqual(@as(u64, 0), clips[0].at_ns);
    try std.testing.expectEqual(@as(u64, 14 * sec), clips[1].at_ns);
}

test "собрать встык: дыры убраны, порядок цел" {
    const p = try sample();
    defer drop(p);
    try p.place(0, 0, 10 * sec, 3 * sec);
    try p.place(0, 0, 30 * sec, 2 * sec);
    try p.compact(0);

    const clips = p.trackList()[0].list();
    try std.testing.expectEqual(@as(u64, 0), clips[0].at_ns);
    try std.testing.expectEqual(@as(u64, 3 * sec), clips[1].at_ns);
    try std.testing.expectEqual(@as(u64, 5 * sec), p.trackList()[0].endsAt());
}

test "отмена возвращает к тому, что было, а не к тому, что стало" {
    const p = try sample();
    defer drop(p);
    try p.place(0, 0, 0, 10 * sec);
    try p.split(0, 5 * sec);
    try std.testing.expectEqual(@as(usize, 2), p.trackList()[0].list().len);

    try std.testing.expect(p.undo());
    try std.testing.expectEqual(@as(usize, 1), p.trackList()[0].list().len);
    try std.testing.expectEqual(@as(u64, 10 * sec), p.trackList()[0].list()[0].len_ns);

    try std.testing.expect(p.undo());
    try std.testing.expectEqual(@as(usize, 0), p.trackList()[0].list().len);

    try std.testing.expect(!p.canUndo());
    try std.testing.expect(!p.undo());
}

test "возврат после отмены восстанавливает шаг за шагом" {
    const p = try sample();
    defer drop(p);
    try p.place(0, 0, 0, 10 * sec);
    try p.split(0, 5 * sec);
    _ = p.undo();
    _ = p.undo();

    try std.testing.expect(p.redo());
    try std.testing.expectEqual(@as(usize, 1), p.trackList()[0].list().len);
    try std.testing.expect(p.redo());
    try std.testing.expectEqual(@as(usize, 2), p.trackList()[0].list().len);
    try std.testing.expect(!p.canRedo());
}

test "новое действие обрывает ветку отменённого" {
    const p = try sample();
    defer drop(p);
    try p.place(0, 0, 0, 10 * sec);
    try p.split(0, 5 * sec);
    _ = p.undo();
    try std.testing.expect(p.canRedo());

    // Сделали что-то другое — возвращать уже некуда.
    try p.trim(0, 0, false, -2 * sec);
    try std.testing.expect(!p.canRedo());
}

test "отмена ходит и по перестановке, и по звуку дорожки" {
    const p = try sample();
    defer drop(p);
    try p.place(1, 0, 0, 5 * sec);
    try p.setMuted(1, true);
    try std.testing.expect(p.trackList()[1].muted);
    try std.testing.expect(p.undo());
    try std.testing.expect(!p.trackList()[1].muted);

    try p.swapTracks(0, 1);
    try std.testing.expectEqual(TrackKind.audio, p.trackList()[0].kind);
    try std.testing.expect(p.undo());
    try std.testing.expectEqual(TrackKind.video, p.trackList()[0].kind);
}

test "глубина отмены ограничена честно, а не бесконечной памятью" {
    const p = try sample();
    defer drop(p);
    var i: usize = 0;
    while (i < max_history + 10) : (i += 1) {
        try p.place(0, 0, @as(u64, i) * sec, sec / 2);
    }
    // Отменяем до упора: должно хватить ровно на глубину журнала.
    var undone: usize = 0;
    while (p.undo()) undone += 1;
    try std.testing.expectEqual(max_history, undone);
}

test "длительность проекта — по самой длинной дорожке" {
    const p = try sample();
    defer drop(p);
    try p.place(0, 0, 0, 5 * sec);
    try p.place(1, 0, 0, 12 * sec);
    try std.testing.expectEqual(@as(u64, 12 * sec), p.durationNs());
}

test "какой клип под указателем" {
    const p = try sample();
    defer drop(p);
    try p.place(0, 0, 2 * sec, 3 * sec);
    const t = &p.tracks[0];
    try std.testing.expect(t.clipAt(sec) == null);
    try std.testing.expectEqual(@as(usize, 0), t.clipAt(3 * sec).?);
    // Правый край не принадлежит клипу: иначе два соседних спорили бы за точку.
    try std.testing.expect(t.clipAt(5 * sec) == null);
}

test "имя исходника показывается без пути" {
    const p = try std.testing.allocator.create(Project);
    defer drop(p);
    p.* = .{};
    _ = try p.addSource("D:\\видео\\моя запись.mp4", 10 * sec);
    try std.testing.expectEqualStrings("моя запись.mp4", p.sourceList()[0].name());
}

test "пересечение клипов видно" {
    const a = Clip{ .at_ns = 0, .len_ns = 5 * sec };
    const b = Clip{ .at_ns = 4 * sec, .len_ns = 5 * sec };
    const c = Clip{ .at_ns = 5 * sec, .len_ns = 5 * sec };
    try std.testing.expect(a.overlaps(b));
    // Встык — это не пересечение.
    try std.testing.expect(!a.overlaps(c));
}

test "отмена и возврат на три шага: лента не путается" {
    // Ошибка, которую поймал предыдущий тест, была видна только со второго
    // шага назад. Проверяем глубже: три действия, три отмены, три возврата.
    const p = try sample();
    defer drop(p);

    try p.place(0, 0, 0, 12 * sec);
    try p.split(0, 4 * sec);
    try p.split(0, 8 * sec);
    try std.testing.expectEqual(@as(usize, 3), p.trackList()[0].list().len);

    try std.testing.expect(p.undo());
    try std.testing.expectEqual(@as(usize, 2), p.trackList()[0].list().len);
    try std.testing.expect(p.undo());
    try std.testing.expectEqual(@as(usize, 1), p.trackList()[0].list().len);
    try std.testing.expect(p.undo());
    try std.testing.expectEqual(@as(usize, 0), p.trackList()[0].list().len);

    try std.testing.expect(p.redo());
    try std.testing.expectEqual(@as(usize, 1), p.trackList()[0].list().len);
    try std.testing.expect(p.redo());
    try std.testing.expectEqual(@as(usize, 2), p.trackList()[0].list().len);
    try std.testing.expect(p.redo());
    try std.testing.expectEqual(@as(usize, 3), p.trackList()[0].list().len);
    try std.testing.expect(!p.canRedo());
}

test "переименование дорожки отменяется наравне с резкой" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);

    try p.renameTrack(1, "Микрофон ведущего");
    try std.testing.expectEqualStrings("Микрофон ведущего", p.tracks[1].title());

    try std.testing.expect(p.undo());
    try std.testing.expectEqualStrings("Микрофон", p.tracks[1].title());
    try std.testing.expect(p.redo());
    try std.testing.expectEqualStrings("Микрофон ведущего", p.tracks[1].title());
}

test "пустое имя не принимается и не тратит шаг отмены" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);

    try p.renameTrack(0, "   ");
    try std.testing.expectEqualStrings("Видео", p.tracks[0].title());
    // Отменять нечего: шага в истории не появилось.
    try std.testing.expect(!p.undo());

    // Пробелы по краям срезаются, а имя внутри остаётся как есть.
    try p.renameTrack(0, "  Экран целиком  ");
    try std.testing.expectEqualStrings("Экран целиком", p.tracks[0].title());
}

test "то же имя не считается изменением" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    try p.renameTrack(0, "Видео");
    try std.testing.expect(!p.undo());
}

test "чужой номер дорожки — отказ, а не порча соседней" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    try std.testing.expectError(Error.NoSuchThing, p.renameTrack(9, "Никакая"));
}

test "длинное имя обрезается по букве, а не по байту" {
    // Сорок восемь байт — это двадцать четыре русские буквы.
    var t = Track{};
    t.setTitle("ааааааааааааааааааааааааааааааа");
    try std.testing.expectEqual(@as(usize, 48), t.name_len);
    // Обрезанное имя должно остаться годным текстом.
    try std.testing.expect(std.unicode.utf8ValidateSlice(t.title()));

    // Латиница влезает целиком до самого предела.
    t.setTitle("abcdefghijklmnopqrstuvwxyz");
    try std.testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyz", t.title());
}
