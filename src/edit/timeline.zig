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
//! Видео и звук живут на разных дорожках, но по умолчанию ходят вместе:
//! куски одного файла связаны, и то, что сделано с картинкой, происходит
//! и со звуком. Иначе звук разъезжается с изображением на первом же
//! перетаскивании, и человек замечает это через полчаса работы.
//!
//! Связку можно снять — и тогда звук двигается, режется и выбрасывается
//! сам по себе. Так делают, когда звук нарочно кладут под другую картинку.
const std = @import("std");
const volume = @import("../sound/volume.zig");
const marks_mod = @import("marks.zig");
const annot_mod = @import("annotations.zig");

/// Громкость наружу, чтобы окно не тянуло звуковой модуль отдельно.
pub const Volume = volume;
/// Метки наружу — по той же причине.
pub const Marks = marks_mod;
pub const Annotations = annot_mod;

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
    /// Насколько этот кусок тише или громче остального, в десятых долях
    /// децибела. Ноль — как записано.
    ///
    /// Громкость клипа отдельно от громкости дорожки: «сделать всю дорожку
    /// тише» и «сделать тише вот этот кусок» — разные желания, и второе
    /// не должно пропадать, когда поправили первое.
    gain_db10: volume.Db10 = 0,

    /// Значок клипа. Ноль — без значка.
    icon: marks_mod.Icons.Icon = .none,

    /// Номер связки: клипы с одним номером ходят вместе. Ноль — сам по себе.
    ///
    /// Номер, а не ссылка на соседа: соседей бывает больше двух (видео
    /// и две звуковые дорожки), а список внутри клипа пришлось бы чинить
    /// после каждого удаления.
    link: u16 = 0,

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
    /// Значок дорожки: что это за дорожка, быстрее подписи.
    icon: marks_mod.Icons.Icon = .none,
    /// Громкость всей дорожки, в десятых долях децибела.
    gain_db10: volume.Db10 = 0,
    /// Считать ли кривую громкости. Выключенная кривая не стирается:
    /// её выключают, чтобы сравнить с ней и без неё, и нарисованное
    /// должно пережить такое сравнение.
    curve_on: bool = false,
    /// Ломаная громкости поверх дорожки, как в Logic.
    curve: volume.Curve = .{},
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

    /// Переставить клипы по времени.
    ///
    /// Нужна после сдвига связки: клип мог перепрыгнуть соседа, а весь
    /// остальной код ждёт их по порядку — и рисование, и поиск попадания.
    fn sort(self: *Track) void {
        var i: usize = 1;
        while (i < self.count) : (i += 1) {
            const cur = self.clips[i];
            var j = i;
            while (j > 0 and self.clips[j - 1].at_ns > cur.at_ns) : (j -= 1) {
                self.clips[j] = self.clips[j - 1];
            }
            self.clips[j] = cur;
        }
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
    /// Заметка к исходнику — у дублей озвучки (#26): «первый заход,
    /// с запинкой». Восемьдесят байт: строка списка, не дневник.
    note: [80]u8 = @splat(0),
    note_len: usize = 0,

    pub fn comment(self: *const Source) []const u8 {
        return self.note[0..self.note_len];
    }

    pub fn setNote(self: *Source, text: []const u8) void {
        const n = @min(text.len, self.note.len);
        @memcpy(self.note[0..n], text[0..n]);
        self.note_len = n;
    }

    /// Перенаправить исходник на другой файл.
    ///
    /// Нужно при открытии архива: внутри лежит копия, и брать надо её,
    /// а не путь, записанный на чужой машине.
    pub fn setPath(self: *Source, text: []const u8) void {
        const n = @min(text.len, self.path.len);
        @memcpy(self.path[0..n], text[0..n]);
        self.path_len = n;
    }

    /// Полный путь, как его открыли.
    pub fn fullPath(self: *const Source) []const u8 {
        return self.path[0..self.path_len];
    }

    /// Только имя файла — это и показывается на клипе.
    pub fn name(self: *const Source) []const u8 {
        return std.fs.path.basename(self.fullPath());
    }
};

/// Насколько на самом деле сдвинется связка, если её тянут на `delta_ns`.
///
/// Влево — только до начала дорожки: за нулём времени нет. Упирается связка
/// тем клипом, который стоит раньше всех, и тогда останавливается вся
/// целиком. Если бы каждый упирался сам за себя, связка расползлась бы
/// у начала дорожки, а звук уехал бы относительно картинки — ровно то,
/// ради чего связка и заведена.
pub fn allowedShift(earliest_at_ns: u64, delta_ns: i64) i64 {
    if (delta_ns >= 0) return delta_ns;
    const room = -@as(i64, @intCast(earliest_at_ns));
    return @max(delta_ns, room);
}

/// Каким станет клип, если подтянуть его край.
///
/// Обрезка двигает границы куска внутри исходника, а не переписывает файл.
/// Слева при этом едет и начало внутри файла: иначе кадр под краем сменился
/// бы на другой.
///
/// Вынесено отдельной чистой функцией, потому что связку надо посчитать
/// целиком ДО того, как что-то менять: подрезанная наполовину связка хуже,
/// чем несостоявшееся движение мыши.
pub fn trimmed(clip: Clip, from_left: bool, delta_ns: i64) Error!Clip {
    var out = clip;
    if (from_left) {
        const new_len = @as(i64, @intCast(clip.len_ns)) - delta_ns;
        const new_in = @as(i64, @intCast(clip.in_ns)) + delta_ns;
        const new_at = @as(i64, @intCast(clip.at_ns)) + delta_ns;
        if (new_len < @as(i64, @intCast(min_len_ns)) or new_in < 0 or new_at < 0) return Error.TooShort;
        out.len_ns = @intCast(new_len);
        out.in_ns = @intCast(new_in);
        out.at_ns = @intCast(new_at);
    } else {
        const new_len = @as(i64, @intCast(clip.len_ns)) + delta_ns;
        if (new_len < @as(i64, @intCast(min_len_ns))) return Error.TooShort;
        out.len_ns = @intCast(new_len);
    }
    return out;
}

/// Влезет ли рез в точке: обе половины должны остаться различимыми.
fn splitFits(clip: Clip, when_ns: u64, count: usize) Error!void {
    if (!clip.covers(when_ns)) return Error.NothingThere;
    const left_len = when_ns - clip.at_ns;
    if (left_len < min_len_ns or clip.len_ns - left_len < min_len_ns) return Error.TooShort;
    if (count >= max_clips) return Error.TooManyClips;
}

/// Сдвинуть точку на дорожке, не уходя за ноль.
fn shifted(at_ns: u64, delta_ns: i64) u64 {
    const out = @as(i64, @intCast(at_ns)) + delta_ns;
    return if (out < 0) 0 else @intCast(out);
}

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
    /// Метки отменяются наравне с резкой: поставленная не туда метка —
    /// такая же правка, как сдвинутый не туда клип.
    marks: marks_mod.Marks = .{},
    /// Аннотации (#28) — тоже.
    annotations: annot_mod.Annotations = .{},
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

    /// Метки на времени проекта: где переснять, вырезать, вставить.
    ///
    /// На времени проекта, а не на клипе: подвинул клип — метка осталась
    /// там, где поставлена. Так это работает в монтажных программах.
    marks: marks_mod.Marks = .{},

    /// Аннотации поверх кадра (#28): текст, стрелки, выноски со временем.
    annotations: annot_mod.Annotations = .{},

    /// Откуда берутся номера связок. Ноль означает «ещё ни одной»:
    /// первый же вызов `newLink` выдаст единицу.
    ///
    /// Номера не переиспользуются: выданный заново номер склеил бы два
    /// разных файла в одну связку, и они поехали бы вместе без всякой
    /// на то причины.
    ///
    /// **Умолчание здесь обязано быть нулевым.** Проект весит восемьсот
    /// килобайт, и пока все его поля нулевые, он лежит в обнуляемой
    /// области и в файле программы места не занимает. Стоило поставить
    /// здесь единицу — и весь этот восьмисоткилобайтный ноль лёг в .exe
    /// готовыми байтами: 1318 КБ превратились в 2145 КБ из-за одного
    /// двухбайтного поля.
    next_link: u16 = 0,

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
        var shot = Snapshot{ .track_count = self.track_count, .marks = self.marks, .annotations = self.annotations };
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
        var now = Snapshot{ .track_count = self.track_count, .marks = self.marks, .annotations = self.annotations };
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
        self.marks = shot.marks;
        self.annotations = shot.annotations;
        @memcpy(self.tracks[0..shot.track_count], shot.tracks[0..shot.track_count]);
        return true;
    }

    pub fn redo(self: *Project) bool {
        if (self.future == 0) return false;
        var now = Snapshot{ .track_count = self.track_count, .marks = self.marks, .annotations = self.annotations };
        @memcpy(now.tracks[0..self.track_count], self.tracks[0..self.track_count]);

        const shot = self.history[self.past];
        self.history[self.past] = now;
        self.past += 1;
        self.future -= 1;

        self.track_count = shot.track_count;
        self.marks = shot.marks;
        self.annotations = shot.annotations;
        @memcpy(self.tracks[0..shot.track_count], shot.tracks[0..shot.track_count]);
        return true;
    }

    // ------------------------------------------------------------ действия

    /// Положить весь исходник на дорожку в указанное место.
    pub fn place(self: *Project, track_index: usize, source: u16, at_ns: u64, len_ns: u64) Error!void {
        return self.placeLinked(track_index, source, at_ns, len_ns, 0);
    }

    /// То же, но клип сразу входит в связку с номером `link`.
    ///
    /// Так кладут дорожки одного файла: видео и звук должны ходить вместе
    /// с первой же секунды, а не после того, как человек об этом попросит.
    pub fn placeLinked(
        self: *Project,
        track_index: usize,
        source: u16,
        at_ns: u64,
        len_ns: u64,
        link: u16,
    ) Error!void {
        _ = try self.track(track_index);
        if (len_ns < min_len_ns) return Error.TooShort;
        self.remember();
        const tr = try self.track(track_index);
        if (!tr.insert(.{
            .source = source,
            .in_ns = 0,
            .len_ns = len_ns,
            .at_ns = at_ns,
            .link = link,
        })) {
            _ = self.undo();
            return Error.TooManyClips;
        }
    }

    // ------------------------------------------------------------- связки

    /// Выдать новый номер связки.
    pub fn newLink(self: *Project) u16 {
        if (self.next_link == 0) self.next_link = 1;
        const out = self.next_link;
        // У самого края перестаём считать: шестьдесят пять тысяч файлов
        // в одном проекте — это уже не монтаж, но и падать тут незачем.
        if (self.next_link < std.math.maxInt(u16)) self.next_link += 1;
        return out;
    }

    /// Сколько клипов в связке.
    pub fn linkSize(self: *const Project, link: u16) usize {
        if (link == 0) return 0;
        var n: usize = 0;
        for (self.trackList()) |t| {
            for (t.list()) |cl| {
                if (cl.link == link) n += 1;
            }
        }
        return n;
    }

    /// Где стоит самый ранний клип связки.
    ///
    /// `anchor` считается всегда: он и сам часть связки, а когда связки
    /// нет — он единственный, кто упирается в начало дорожки.
    fn earliestOf(self: *const Project, link: u16, anchor: Clip) u64 {
        var first = anchor.at_ns;
        if (link == 0) return first;
        for (self.trackList()) |t| {
            for (t.list()) |cl| {
                if (cl.link == link) first = @min(first, cl.at_ns);
            }
        }
        return first;
    }

    /// Сдвинуть по времени все клипы связки.
    fn shiftLinked(self: *Project, link: u16, delta_ns: i64) void {
        if (link == 0 or delta_ns == 0) return;
        for (self.tracks[0..self.track_count]) |*t| {
            var changed = false;
            for (t.clips[0..t.count]) |*cl| {
                if (cl.link != link) continue;
                cl.at_ns = shifted(cl.at_ns, delta_ns);
                changed = true;
            }
            // Сдвинутый клип мог перепрыгнуть соседа по своей дорожке.
            if (changed) t.sort();
        }
    }

    /// Развязать связку: клипы останутся на местах, но ходить вместе
    /// перестанут.
    ///
    /// Развязываем всю связку, а не один клип: «половина связки» — это
    /// состояние, которое человеку нечем увидеть и незачем иметь.
    pub fn unlink(self: *Project, track_index: usize, index: usize) Error!void {
        const t = try self.track(track_index);
        if (index >= t.count) return Error.NoSuchThing;
        const link = t.clips[index].link;
        if (link == 0) return;
        self.remember();
        for (self.tracks[0..self.track_count]) |*tr| {
            for (tr.clips[0..tr.count]) |*cl| {
                if (cl.link == link) cl.link = 0;
            }
        }
    }

    /// Связать всё, что стоит под указателем. Возвращает, сколько связалось.
    ///
    /// Связывать выбранное мышью было бы точнее, но выбирать несколько
    /// клипов в окне пока нечем, а «всё, что под указателем» — это ровно
    /// то, что человек и видит в одной вертикали.
    pub fn linkUnder(self: *Project, when_ns: u64) Error!usize {
        var found: usize = 0;
        for (self.trackList()) |t| {
            if (t.clipAt(when_ns) != null) found += 1;
        }
        // Связывать один клип не с чем.
        if (found < 2) return Error.NothingThere;

        self.remember();
        const link = self.newLink();
        for (self.tracks[0..self.track_count]) |*t| {
            if (t.clipAt(when_ns)) |i| t.clips[i].link = link;
        }
        return found;
    }

    /// Разрезать связку в точке. На месте одного клипа получаются два подряд.
    pub fn split(self: *Project, track_index: usize, when_ns: u64) Error!void {
        return self.splitImpl(track_index, when_ns, false);
    }

    /// Разрезать только этот клип, не трогая связку.
    pub fn splitOne(self: *Project, track_index: usize, when_ns: u64) Error!void {
        return self.splitImpl(track_index, when_ns, true);
    }

    fn splitImpl(self: *Project, track_index: usize, when_ns: u64, alone: bool) Error!void {
        const t = try self.track(track_index);
        const index = t.clipAt(when_ns) orelse return Error.NothingThere;
        const clip = t.clips[index];
        const link = if (alone) 0 else clip.link;

        // Считаем всю связку до правки: разрезанная наполовину связка хуже,
        // чем отказ резать.
        if (link == 0) {
            try splitFits(clip, when_ns, t.count);
        } else {
            for (self.trackList()) |tr| {
                for (tr.list()) |cl| {
                    if (cl.link != link or !cl.covers(when_ns)) continue;
                    try splitFits(cl, when_ns, tr.count);
                }
            }
        }

        self.remember();
        // Правые половины получают свой номер: иначе после реза вся четвёрка
        // ходила бы вместе, и резать было бы незачем.
        const right_link: u16 = if (link == 0) 0 else self.newLink();

        // Сначала укорачиваем левые половины, потом вставляем правые:
        // вставка меняет номера клипов, и делать её внутри обхода — значит
        // обойти один клип дважды или не обойти вовсе.
        var pending: [max_tracks]?Clip = @splat(null);
        for (self.tracks[0..self.track_count], 0..) |*tr, ti| {
            var ci: usize = 0;
            while (ci < tr.count) : (ci += 1) {
                const cl = tr.clips[ci];
                const mine = if (link == 0)
                    (ti == track_index and ci == index)
                else
                    (cl.link == link and cl.covers(when_ns));
                if (!mine) continue;

                const left_len = when_ns - cl.at_ns;
                tr.clips[ci].len_ns = left_len;
                // Правая половина показывает следующий кусок исходника:
                // точка реза сдвигает и начало внутри файла, иначе вторая
                // половина повторила бы первую.
                pending[ti] = .{
                    .source = cl.source,
                    .in_ns = cl.in_ns + left_len,
                    .len_ns = cl.len_ns - left_len,
                    .at_ns = when_ns,
                    .link = right_link,
                };
                break;
            }
        }
        for (self.tracks[0..self.track_count], 0..) |*tr, ti| {
            if (pending[ti]) |right| _ = tr.insert(right);
        }
    }

    /// Подтянуть край связки. `from_left` — какой именно край.
    pub fn trim(self: *Project, track_index: usize, index: usize, from_left: bool, delta_ns: i64) Error!void {
        return self.trimImpl(track_index, index, from_left, delta_ns, false);
    }

    /// Подтянуть край только этого клипа, не трогая связку.
    pub fn trimOne(self: *Project, track_index: usize, index: usize, from_left: bool, delta_ns: i64) Error!void {
        return self.trimImpl(track_index, index, from_left, delta_ns, true);
    }

    fn trimImpl(
        self: *Project,
        track_index: usize,
        index: usize,
        from_left: bool,
        delta_ns: i64,
        alone: bool,
    ) Error!void {
        const t = try self.track(track_index);
        if (index >= t.count) return Error.NoSuchThing;
        const clip = t.clips[index];
        const link = if (alone) 0 else clip.link;

        if (link == 0) {
            const updated = try trimmed(clip, from_left, delta_ns);
            self.remember();
            const tr = try self.track(track_index);
            tr.clips[index] = updated;
            if (from_left) tr.sort();
            return;
        }

        // Связку обрезают целиком или не обрезают вовсе: если хоть один
        // кусок стал бы короче различимого, отказываемся до правки.
        for (self.trackList()) |tr| {
            for (tr.list()) |cl| {
                if (cl.link != link) continue;
                _ = try trimmed(cl, from_left, delta_ns);
            }
        }

        self.remember();
        for (self.tracks[0..self.track_count]) |*tr| {
            var changed = false;
            for (tr.clips[0..tr.count]) |*cl| {
                if (cl.link != link) continue;
                cl.* = trimmed(cl.*, from_left, delta_ns) catch unreachable;
                changed = true;
            }
            // Левый край двигает и начало клипа: порядок мог измениться.
            if (changed and from_left) tr.sort();
        }
    }

    /// Передвинуть связку по времени и, если надо, на другую дорожку.
    ///
    /// На другую дорожку переезжает только тот клип, за который тянут:
    /// остальные остаются у себя и лишь сдвигаются во времени. Иначе
    /// перетаскивание видео на соседнюю дорожку утащило бы туда и звук,
    /// которому на видеодорожке не место.
    pub fn move(self: *Project, from_track: usize, index: usize, to_track: usize, at_ns: u64) Error!void {
        return self.moveImpl(from_track, index, to_track, at_ns, false);
    }

    /// Передвинуть только этот клип, оставив связку на месте.
    pub fn moveOne(self: *Project, from_track: usize, index: usize, to_track: usize, at_ns: u64) Error!void {
        return self.moveImpl(from_track, index, to_track, at_ns, true);
    }

    fn moveImpl(
        self: *Project,
        from_track: usize,
        index: usize,
        to_track: usize,
        at_ns: u64,
        alone: bool,
    ) Error!void {
        const src = try self.track(from_track);
        if (index >= src.count) return Error.NoSuchThing;
        if (to_track >= self.track_count) return Error.NoSuchThing;
        var clip = src.clips[index];

        // Видео на звуковую дорожку и наоборот не кладём: полоса дорожки
        // говорит, что на ней лежит, и смешивать — значит врать глазу.
        if (self.tracks[from_track].kind != self.tracks[to_track].kind) return Error.NoSuchThing;

        const link = if (alone) 0 else clip.link;
        const wanted = @as(i64, @intCast(at_ns)) - @as(i64, @intCast(clip.at_ns));
        const delta = allowedShift(self.earliestOf(link, clip), wanted);

        self.remember();
        // Сначала вынимаем клип, потом двигаем связку: сортировка после
        // сдвига меняет номера клипов, и вынимать стало бы нечего.
        const from = try self.track(from_track);
        from.remove(index);
        self.shiftLinked(link, delta);

        clip.at_ns = shifted(clip.at_ns, delta);
        const to = try self.track(to_track);
        if (!to.insert(clip)) {
            _ = self.undo();
            return Error.TooManyClips;
        }
    }

    /// Убрать связку целиком.
    pub fn removeClip(self: *Project, track_index: usize, index: usize) Error!void {
        return self.removeImpl(track_index, index, false);
    }

    /// Убрать только этот клип, оставив связку.
    pub fn removeClipOne(self: *Project, track_index: usize, index: usize) Error!void {
        return self.removeImpl(track_index, index, true);
    }

    fn removeImpl(self: *Project, track_index: usize, index: usize, alone: bool) Error!void {
        const t = try self.track(track_index);
        if (index >= t.count) return Error.NoSuchThing;
        const link = if (alone) 0 else t.clips[index].link;

        self.remember();
        if (link == 0) {
            const tr = try self.track(track_index);
            tr.remove(index);
            return;
        }
        for (self.tracks[0..self.track_count]) |*tr| {
            var i: usize = 0;
            while (i < tr.count) {
                if (tr.clips[i].link == link) tr.remove(i) else i += 1;
            }
        }
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

    // ----------------------------------------------------------- громкость

    /// Громкость всей дорожки.
    pub fn setTrackGain(self: *Project, track_index: usize, db10: volume.Db10) Error!void {
        const want = volume.clamp(db10);
        const t = try self.track(track_index);
        // Ползунок шлёт сообщение на каждую точку своего хода. Запоминать
        // снимок на каждую — значит забить журнал отмен одним движением
        // мыши и потерять всё, что было до него.
        if (t.gain_db10 == want) return;
        self.remember();
        const tr = try self.track(track_index);
        tr.gain_db10 = want;
    }

    /// Громкость одного клипа.
    pub fn setClipGain(self: *Project, track_index: usize, clip_index: usize, db10: volume.Db10) Error!void {
        const want = volume.clamp(db10);
        const t = try self.track(track_index);
        if (clip_index >= t.count) return Error.NoSuchThing;
        if (t.clips[clip_index].gain_db10 == want) return;
        self.remember();
        const tr = try self.track(track_index);
        tr.clips[clip_index].gain_db10 = want;
    }

    /// Включить или выключить кривую. Нарисованное при этом не стирается.
    pub fn setCurveOn(self: *Project, track_index: usize, on: bool) Error!void {
        const t = try self.track(track_index);
        if (t.curve_on == on) return;
        self.remember();
        const tr = try self.track(track_index);
        tr.curve_on = on;
    }

    /// Поставить точку кривой. Возвращает её номер.
    ///
    /// Первая же поставленная точка включает кривую: человек ткнул в линию,
    /// чтобы она заработала, а не чтобы нарисовать её и потом искать,
    /// где её включают.
    pub fn addCurvePoint(self: *Project, track_index: usize, at_ns: u64, db10: volume.Db10) Error!usize {
        const t = try self.track(track_index);
        // Считаем ДО снимка: кривая могла оказаться полной, и тогда снимок
        // был бы потрачен на несостоявшееся действие.
        var probe_curve = t.curve;
        const where = probe_curve.add(at_ns, db10) catch return Error.TooManyClips;

        self.remember();
        const tr = try self.track(track_index);
        tr.curve = probe_curve;
        tr.curve_on = true;
        return where;
    }

    /// Передвинуть точку. Возвращает её новый номер: она могла перепрыгнуть
    /// соседа, а рисование и попадание мышью ждут точки по порядку.
    pub fn moveCurvePoint(
        self: *Project,
        track_index: usize,
        point: usize,
        at_ns: u64,
        db10: volume.Db10,
    ) Error!usize {
        const t = try self.track(track_index);
        if (point >= t.curve.count) return Error.NoSuchThing;
        const before = t.curve.points[point];
        if (before.at_ns == at_ns and before.db10 == volume.clamp(db10)) return point;

        var probe_curve = t.curve;
        const where = probe_curve.moveTo(point, at_ns, db10) catch return Error.NoSuchThing;

        self.remember();
        const tr = try self.track(track_index);
        tr.curve = probe_curve;
        return where;
    }

    pub fn removeCurvePoint(self: *Project, track_index: usize, point: usize) Error!void {
        const t = try self.track(track_index);
        if (point >= t.curve.count) return Error.NoSuchThing;
        self.remember();
        const tr = try self.track(track_index);
        tr.curve.removeAt(point) catch unreachable;
    }

    // --------------------------------------------------------------- метки

    /// Поставить метку. Возвращает её номер.
    ///
    /// Без имени — даём своё: пустая подпись выглядит недоделкой, а
    /// придумывать имя на каждую метку человек не обязан. Их ставят
    /// быстро, подряд, и называют потом только те, к которым возвращаются.
    pub fn addMark(self: *Project, at_ns: u64, colour: marks_mod.Colour, name: []const u8) Error!usize {
        // Считаем ДО снимка: меток могло не остаться, и снимок был бы
        // потрачен на несостоявшееся действие.
        var probe = self.marks;

        // Метка на этом времени уже есть — имени ей не придумываем: своё
        // у неё уже есть, а придуманное затёрло бы его. Заодно два нажатия
        // в одном месте перестают плодить «метку 2» рядом с «меткой 2»:
        // счётчик имён идёт от числа меток, и оно после замены не растёт.
        var here = false;
        for (probe.list()) |m| {
            if (m.at_ns == at_ns) here = true;
        }

        var buf: [32]u8 = undefined;
        const title = if (name.len > 0)
            name
        else if (here)
            ""
        else
            marks_mod.defaultName(&buf, probe.count + 1);
        const where = probe.add(at_ns, colour, title) catch return Error.TooManyClips;

        self.remember();
        self.marks = probe;
        return where;
    }

    // ------------------------------------------------------ аннотации (#28)

    pub fn addAnnotation(self: *Project, made: annot_mod.Annotation) Error!usize {
        var probe = self.annotations;
        const where = probe.add(made) catch return Error.TooManyClips;
        self.remember();
        self.annotations = probe;
        return where;
    }

    pub fn removeAnnotation(self: *Project, index: usize) Error!void {
        if (index >= self.annotations.count) return Error.NoSuchThing;
        self.remember();
        self.annotations.removeAt(index) catch unreachable;
    }

    /// Передвинуть по времени; возвращает новый номер.
    pub fn moveAnnotation(self: *Project, index: usize, at_ns: u64) Error!usize {
        if (index >= self.annotations.count) return Error.NoSuchThing;
        if (self.annotations.items[index].at_ns == at_ns) return index;
        var probe = self.annotations;
        const where = probe.moveTo(index, at_ns) catch return Error.NoSuchThing;
        self.remember();
        self.annotations = probe;
        return where;
    }

    pub fn setAnnotationLength(self: *Project, index: usize, len_ns: u64) Error!void {
        if (index >= self.annotations.count) return Error.NoSuchThing;
        self.remember();
        self.annotations.setLength(index, len_ns) catch unreachable;
    }

    pub fn setAnnotationText(self: *Project, index: usize, text: []const u8) Error!void {
        if (index >= self.annotations.count) return Error.NoSuchThing;
        const clean = std.mem.trim(u8, text, " ");
        if (std.mem.eql(u8, self.annotations.items[index].title(), clean)) return;
        self.remember();
        self.annotations.setText(index, clean) catch unreachable;
    }

    /// Поставить в кадре. Каждое движение мыши — не снимок: снимок берётся
    /// один раз, когда тянуть начали (`remember_now`).
    pub fn placeAnnotation(self: *Project, index: usize, end: bool, x: i32, y: i32, remember_now: bool) Error!void {
        if (index >= self.annotations.count) return Error.NoSuchThing;
        if (remember_now) self.remember();
        if (end) {
            self.annotations.placeEnd(index, x, y) catch unreachable;
        } else {
            self.annotations.place(index, x, y) catch unreachable;
        }
    }

    pub fn removeMark(self: *Project, index: usize) Error!void {
        if (index >= self.marks.count) return Error.NoSuchThing;
        self.remember();
        self.marks.removeAt(index) catch unreachable;
    }

    /// Передвинуть метку. Возвращает её новый номер.
    pub fn moveMark(self: *Project, index: usize, at_ns: u64) Error!usize {
        if (index >= self.marks.count) return Error.NoSuchThing;
        if (self.marks.items[index].at_ns == at_ns) return index;
        var probe = self.marks;
        const where = probe.moveTo(index, at_ns) catch return Error.NoSuchThing;
        self.remember();
        self.marks = probe;
        return where;
    }

    pub fn renameMark(self: *Project, index: usize, name: []const u8) Error!void {
        if (index >= self.marks.count) return Error.NoSuchThing;
        const clean = std.mem.trim(u8, name, " ");
        if (clean.len == 0) return;
        if (std.mem.eql(u8, self.marks.items[index].title(), clean)) return;
        self.remember();
        self.marks.rename(index, clean) catch unreachable;
    }

    /// Комментарий метки: что с этим местом делать.
    ///
    /// Пустой принимается: комментарий стирают так же, как пишут, и
    /// отказываться стирать было бы странно — в отличие от имени, которое
    /// у метки есть всегда.
    pub fn setMarkComment(self: *Project, index: usize, text: []const u8) Error!void {
        if (index >= self.marks.count) return Error.NoSuchThing;
        const clean = std.mem.trim(u8, text, " ");
        if (std.mem.eql(u8, self.marks.items[index].comment(), clean)) return;
        self.remember();
        self.marks.setComment(index, clean) catch unreachable;
    }

    /// Заметка к исходнику (дублю). Пробелы по краям — не заметка.
    ///
    /// Без снимка отмены: снимок хранит дорожки и метки, а исходники —
    /// нет, и «отменить заметку» откатило бы правку клипов, а заметку
    /// оставило. Заметка — пометка на полях, её правят прямо.
    pub fn setSourceNote(self: *Project, index: u16, text: []const u8) Error!void {
        if (index >= self.source_count) return Error.NoSuchThing;
        self.sources[index].setNote(std.mem.trim(u8, text, " "));
    }

    /// Сделать метку диапазоном или вернуть её в точку.
    ///
    /// Нулевая длина — это точка, и превращается одно в другое само.
    pub fn setMarkLength(self: *Project, index: usize, len_ns: u64) Error!void {
        if (index >= self.marks.count) return Error.NoSuchThing;
        const want: u64 = if (len_ns < marks_mod.min_span_ns) 0 else len_ns;
        if (self.marks.items[index].len_ns == want) return;
        self.remember();
        self.marks.setLength(index, want) catch unreachable;
    }

    /// Подвинуть край диапазона. Возвращает новый номер метки.
    pub fn moveMarkEdge(self: *Project, index: usize, from_left: bool, to_ns: u64) Error!usize {
        if (index >= self.marks.count) return Error.NoSuchThing;
        const m = self.marks.items[index];
        if (!m.isSpan()) return Error.NoSuchThing;
        // Край не сдвинулся — снимка не тратим: мышь шлёт сообщение
        // на каждую свою точку, и упёршийся в предел край слал бы их зря.
        const edge_now = if (from_left) m.at_ns else m.endsAt();
        if (edge_now == to_ns) return index;

        var probe = self.marks;
        const where = probe.moveEdge(index, from_left, to_ns) catch return Error.NoSuchThing;
        if (std.meta.eql(probe.items[where], m) and where == index) return index;

        self.remember();
        self.marks = probe;
        return where;
    }

    /// Значок метки.
    pub fn setMarkIcon(self: *Project, index: usize, icon: marks_mod.Icons.Icon) Error!void {
        if (index >= self.marks.count) return Error.NoSuchThing;
        if (self.marks.items[index].icon == icon) return;
        self.remember();
        self.marks.setIcon(index, icon) catch unreachable;
    }

    /// Значок дорожки.
    pub fn setTrackIcon(self: *Project, track_index: usize, icon: marks_mod.Icons.Icon) Error!void {
        const t = try self.track(track_index);
        if (t.icon == icon) return;
        self.remember();
        const tr = try self.track(track_index);
        tr.icon = icon;
    }

    /// Значок клипа.
    pub fn setClipIcon(self: *Project, track_index: usize, clip_index: usize, icon: marks_mod.Icons.Icon) Error!void {
        const t = try self.track(track_index);
        if (clip_index >= t.count) return Error.NoSuchThing;
        if (t.clips[clip_index].icon == icon) return;
        self.remember();
        const tr = try self.track(track_index);
        tr.clips[clip_index].icon = icon;
    }

    pub fn setMarkColour(self: *Project, index: usize, colour: marks_mod.Colour) Error!void {
        if (index >= self.marks.count) return Error.NoSuchThing;
        if (self.marks.items[index].colour == colour) return;
        self.remember();
        self.marks.setColour(index, colour) catch unreachable;
    }

    /// Насколько тише или громче звучит дорожка в этой точке времени.
    ///
    /// Складываются три вещи: громкость дорожки, кривая и громкость того
    /// клипа, который в этой точке стоит. Заглушённая дорожка молчит,
    /// что бы ни было накручено в остальном.
    pub fn gainAt(self: *const Project, track_index: usize, at_ns: u64) volume.Db10 {
        if (track_index >= self.track_count) return volume.unity;
        const t = &self.tracks[track_index];
        if (t.muted) return volume.min_db10;

        var total = t.gain_db10;
        if (t.curve_on and !t.curve.empty()) total = volume.sum(total, t.curve.valueAt(at_ns));
        if (t.clipAt(at_ns)) |i| total = volume.sum(total, t.clips[i].gain_db10);
        return total;
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

test "вид дорожки переведён" {
    // `label()` остаётся русским: из него складывается имя новой дорожки,
    // а имя уходит в файл проекта. Окно переводит его через `lang.tr`,
    // а тот о пропаже молчит — сторож здесь (#100).
    const lang = @import("../lang.zig");
    try std.testing.expect(lang.known(TrackKind.video.label()));
    try std.testing.expect(lang.known(TrackKind.audio.label()));
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

// ------------------------------------------------------- связка видео и звука

/// Проект с одним файлом, разложенным на видео и звук одной связкой.
/// Это то, что получается при открытии обычного mp4.
fn linked() !*Project {
    const p = try std.testing.allocator.create(Project);
    p.* = .{};
    const src = try p.addSource("D:\\видео\\запись.mp4", 60 * sec);
    _ = try p.addTrack(.video, "Видео");
    _ = try p.addTrack(.audio, "Звук");
    const link = p.newLink();
    try p.placeLinked(0, src, 2 * sec, 10 * sec, link);
    try p.placeLinked(1, src, 2 * sec, 10 * sec, link);
    return p;
}

test "связка едет целиком: сдвинули видео — звук пошёл следом" {
    const p = try linked();
    defer std.testing.allocator.destroy(p);

    try p.move(0, 0, 0, 5 * sec);
    try std.testing.expectEqual(@as(u64, 5 * sec), p.tracks[0].clips[0].at_ns);
    // Звук сдвинулся ровно на столько же, а не встал в ту же точку случайно.
    try std.testing.expectEqual(@as(u64, 5 * sec), p.tracks[1].clips[0].at_ns);

    // И обратно — тоже вместе.
    try p.move(1, 0, 1, 0);
    try std.testing.expectEqual(@as(u64, 0), p.tracks[0].clips[0].at_ns);
    try std.testing.expectEqual(@as(u64, 0), p.tracks[1].clips[0].at_ns);
}

test "связка не расползается у начала дорожки" {
    // Звук стоит раньше видео. Тянем видео далеко влево: упереться должна
    // вся связка разом, сохранив расстояние между кусками. Если бы каждый
    // упирался сам за себя, звук уехал бы относительно картинки.
    const p = try std.testing.allocator.create(Project);
    defer std.testing.allocator.destroy(p);
    p.* = .{};
    const src = try p.addSource("файл.mp4", 60 * sec);
    _ = try p.addTrack(.video, "Видео");
    _ = try p.addTrack(.audio, "Звук");
    const link = p.newLink();
    try p.placeLinked(0, src, 5 * sec, 10 * sec, link);
    try p.placeLinked(1, src, 3 * sec, 10 * sec, link);

    try p.move(0, 0, 0, 0);
    // Звук стоял на две секунды раньше видео — так и остался.
    try std.testing.expectEqual(@as(u64, 2 * sec), p.tracks[0].clips[0].at_ns);
    try std.testing.expectEqual(@as(u64, 0), p.tracks[1].clips[0].at_ns);
}

test "насколько сдвинется связка: правило считается отдельно" {
    // Вправо — на сколько просят.
    try std.testing.expectEqual(@as(i64, 5 * sec), allowedShift(0, 5 * sec));
    try std.testing.expectEqual(@as(i64, 5 * sec), allowedShift(3 * sec, 5 * sec));
    // Влево — до начала дорожки и ни шагом дальше.
    try std.testing.expectEqual(@as(i64, -3 * sec), allowedShift(3 * sec, -10 * sec));
    try std.testing.expectEqual(@as(i64, -2 * sec), allowedShift(3 * sec, -2 * sec));
    // Стоящему в нуле влево двигаться некуда.
    try std.testing.expectEqual(@as(i64, 0), allowedShift(0, -10 * sec));
}

test "связка переезжает на другую дорожку одна: звук остаётся у себя" {
    const p = try linked();
    defer std.testing.allocator.destroy(p);
    _ = try p.addTrack(.video, "Видео 2");

    try p.move(0, 0, 2, 4 * sec);
    // Видео переехало на третью полосу.
    try std.testing.expectEqual(@as(usize, 0), p.tracks[0].count);
    try std.testing.expectEqual(@as(u64, 4 * sec), p.tracks[2].clips[0].at_ns);
    // Звук остался на своей, но сдвинулся во времени на те же две секунды.
    try std.testing.expectEqual(@as(usize, 1), p.tracks[1].count);
    try std.testing.expectEqual(@as(u64, 4 * sec), p.tracks[1].clips[0].at_ns);
}

test "врозь: один клип двигается, связка стоит" {
    const p = try linked();
    defer std.testing.allocator.destroy(p);

    try p.moveOne(1, 0, 1, 6 * sec);
    try std.testing.expectEqual(@as(u64, 2 * sec), p.tracks[0].clips[0].at_ns);
    try std.testing.expectEqual(@as(u64, 6 * sec), p.tracks[1].clips[0].at_ns);
    // Связка при этом никуда не делась: следующее обычное движение
    // снова тянет обоих.
    try p.move(0, 0, 0, 3 * sec);
    try std.testing.expectEqual(@as(u64, 7 * sec), p.tracks[1].clips[0].at_ns);
}

test "развязали — и звук пошёл сам по себе" {
    const p = try linked();
    defer std.testing.allocator.destroy(p);

    try p.unlink(0, 0);
    try std.testing.expectEqual(@as(u16, 0), p.tracks[0].clips[0].link);
    try std.testing.expectEqual(@as(u16, 0), p.tracks[1].clips[0].link);

    try p.move(0, 0, 0, 9 * sec);
    try std.testing.expectEqual(@as(u64, 9 * sec), p.tracks[0].clips[0].at_ns);
    try std.testing.expectEqual(@as(u64, 2 * sec), p.tracks[1].clips[0].at_ns);

    // Развязывание отменяется наравне с резкой.
    try std.testing.expect(p.undo());
    try std.testing.expect(p.undo());
    try std.testing.expect(p.tracks[0].clips[0].link != 0);
}

test "связать то, что стоит под указателем" {
    const p = try std.testing.allocator.create(Project);
    defer std.testing.allocator.destroy(p);
    p.* = .{};
    const a = try p.addSource("картинка.mp4", 60 * sec);
    const b = try p.addSource("голос.wav", 60 * sec);
    _ = try p.addTrack(.video, "Видео");
    _ = try p.addTrack(.audio, "Звук");
    try p.place(0, a, 0, 10 * sec);
    try p.place(1, b, 1 * sec, 10 * sec);

    try std.testing.expectEqual(@as(usize, 2), try p.linkUnder(5 * sec));
    const link = p.tracks[0].clips[0].link;
    try std.testing.expect(link != 0);
    try std.testing.expectEqual(link, p.tracks[1].clips[0].link);

    // Теперь два разных файла ходят вместе — так кладут голос под картинку.
    try p.move(0, 0, 0, 4 * sec);
    try std.testing.expectEqual(@as(u64, 5 * sec), p.tracks[1].clips[0].at_ns);
}

test "связывать нечего, когда под указателем один клип или пусто" {
    const p = try linked();
    defer std.testing.allocator.destroy(p);
    try std.testing.expectError(Error.NothingThere, p.linkUnder(30 * sec));

    try p.removeClipOne(1, 0);
    try std.testing.expectError(Error.NothingThere, p.linkUnder(5 * sec));
}

test "рез делит связку надвое, а не в четыре стороны" {
    const p = try linked();
    defer std.testing.allocator.destroy(p);

    try p.split(0, 6 * sec);
    try std.testing.expectEqual(@as(usize, 2), p.tracks[0].count);
    try std.testing.expectEqual(@as(usize, 2), p.tracks[1].count);

    // Левые половины в одной связке, правые — в другой.
    const left = p.tracks[0].clips[0].link;
    const right = p.tracks[0].clips[1].link;
    try std.testing.expect(left != 0 and right != 0 and left != right);
    try std.testing.expectEqual(left, p.tracks[1].clips[0].link);
    try std.testing.expectEqual(right, p.tracks[1].clips[1].link);

    // И половины ходят порознь: подвинули правую — левая на месте.
    try p.move(0, 1, 0, 9 * sec);
    try std.testing.expectEqual(@as(u64, 9 * sec), p.tracks[1].clips[1].at_ns);
    try std.testing.expectEqual(@as(u64, 2 * sec), p.tracks[1].clips[0].at_ns);
}

test "рез правой половины берёт правильный кусок исходника у обоих" {
    const p = try linked();
    defer std.testing.allocator.destroy(p);
    try p.split(0, 6 * sec);
    // Клип стоял с двух секунд: рез на шестой — это четвёртая секунда файла.
    try std.testing.expectEqual(@as(u64, 4 * sec), p.tracks[0].clips[1].in_ns);
    try std.testing.expectEqual(@as(u64, 4 * sec), p.tracks[1].clips[1].in_ns);
    try std.testing.expectEqual(@as(u64, 4 * sec), p.tracks[0].clips[0].len_ns);
    try std.testing.expectEqual(@as(u64, 4 * sec), p.tracks[1].clips[0].len_ns);
}

test "обрезали край видео — звук обрезался так же" {
    const p = try linked();
    defer std.testing.allocator.destroy(p);

    try p.trim(0, 0, false, -3 * sec);
    try std.testing.expectEqual(@as(u64, 7 * sec), p.tracks[0].clips[0].len_ns);
    try std.testing.expectEqual(@as(u64, 7 * sec), p.tracks[1].clips[0].len_ns);

    try p.trim(0, 0, true, 1 * sec);
    try std.testing.expectEqual(@as(u64, 3 * sec), p.tracks[1].clips[0].at_ns);
    try std.testing.expectEqual(@as(u64, 1 * sec), p.tracks[1].clips[0].in_ns);
}

test "связку обрезают целиком или не обрезают вовсе" {
    // У звука кусок короче. Обрезка, от которой он стал бы неразличимым,
    // не должна подрезать видео и оставить связку разной длины.
    const p = try std.testing.allocator.create(Project);
    defer std.testing.allocator.destroy(p);
    p.* = .{};
    const src = try p.addSource("файл.mp4", 60 * sec);
    _ = try p.addTrack(.video, "Видео");
    _ = try p.addTrack(.audio, "Звук");
    const link = p.newLink();
    try p.placeLinked(0, src, 0, 10 * sec, link);
    try p.placeLinked(1, src, 0, 1 * sec, link);

    const steps_before = p.past;
    try std.testing.expectError(Error.TooShort, p.trim(0, 0, false, -2 * sec));
    try std.testing.expectEqual(@as(u64, 10 * sec), p.tracks[0].clips[0].len_ns);
    try std.testing.expectEqual(@as(u64, 1 * sec), p.tracks[1].clips[0].len_ns);
    // И шага отмены на неудавшуюся обрезку не потрачено: иначе человек
    // нажал бы «Отменить» и откатил не то, что думал.
    try std.testing.expectEqual(steps_before, p.past);
}

test "удаление уносит всю связку, а врозь — только один клип" {
    const p = try linked();
    defer std.testing.allocator.destroy(p);

    try p.removeClip(0, 0);
    try std.testing.expectEqual(@as(usize, 0), p.tracks[0].count);
    try std.testing.expectEqual(@as(usize, 0), p.tracks[1].count);

    try std.testing.expect(p.undo());
    try p.removeClipOne(0, 0);
    try std.testing.expectEqual(@as(usize, 0), p.tracks[0].count);
    try std.testing.expectEqual(@as(usize, 1), p.tracks[1].count);
}

test "связка переживает отмену и возврат" {
    const p = try linked();
    defer std.testing.allocator.destroy(p);
    const link = p.tracks[0].clips[0].link;

    try p.move(0, 0, 0, 8 * sec);
    try std.testing.expect(p.undo());
    try std.testing.expectEqual(@as(u64, 2 * sec), p.tracks[1].clips[0].at_ns);
    try std.testing.expectEqual(link, p.tracks[1].clips[0].link);

    try std.testing.expect(p.redo());
    try std.testing.expectEqual(@as(u64, 8 * sec), p.tracks[1].clips[0].at_ns);
}

test "номера связок не выдаются дважды" {
    const p = try std.testing.allocator.create(Project);
    defer std.testing.allocator.destroy(p);
    p.* = .{};
    const first = p.newLink();
    const second = p.newLink();
    try std.testing.expect(first != 0 and second != 0 and first != second);
    // Переиспользованный номер склеил бы два разных файла в одну связку.
    try std.testing.expect(second > first);
}

test "порядок клипов на дорожке не сбивается после сдвига связки" {
    // На звуковой дорожке два куска. Сдвигаем первый так, чтобы он
    // перепрыгнул второй: весь остальной код ждёт клипы по порядку.
    const p = try std.testing.allocator.create(Project);
    defer std.testing.allocator.destroy(p);
    p.* = .{};
    const src = try p.addSource("файл.mp4", 60 * sec);
    _ = try p.addTrack(.video, "Видео");
    _ = try p.addTrack(.audio, "Звук");
    const link = p.newLink();
    try p.placeLinked(0, src, 0, 5 * sec, link);
    try p.placeLinked(1, src, 0, 5 * sec, link);
    try p.place(1, src, 10 * sec, 5 * sec);

    try p.move(0, 0, 0, 20 * sec);
    var last: u64 = 0;
    for (p.tracks[1].list()) |cl| {
        try std.testing.expect(cl.at_ns >= last);
        last = cl.at_ns;
    }
    try std.testing.expectEqual(@as(usize, 2), p.linkSize(link));
}

test "у пустого проекта нет ненулевых умолчаний" {
    // Проект весит восемьсот килобайт. Пока все его поля нулевые, он лежит
    // в обнуляемой области и в файле программы места не занимает. Стоило
    // поставить одному двухбайтному полю умолчание 1 — и весь этот
    // восьмисоткилобайтный ноль лёг в .exe готовыми байтами: 1318 КБ стали
    // 2145 КБ. Ошибка ничем себя не проявляет, кроме размера файла, —
    // поэтому и проверяется тестом, а не глазами.
    const plain = try std.testing.allocator.create(Project);
    defer std.testing.allocator.destroy(plain);
    const zeroed = try std.testing.allocator.create(Project);
    defer std.testing.allocator.destroy(zeroed);

    plain.* = .{};
    zeroed.* = std.mem.zeroes(Project);
    try std.testing.expect(std.meta.eql(plain.*, zeroed.*));
}

// ------------------------------------------------- громкость и кривая

test "громкость дорожки и клипа складываются, а не спорят" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    try p.place(1, 0, 0, 10 * sec);

    try p.setTrackGain(1, -60);
    try p.setClipGain(1, 0, -60);
    // Минус шесть и ещё минус шесть — это минус двенадцать.
    try std.testing.expectEqual(@as(volume.Db10, -120), p.gainAt(1, sec));
}

test "заглушённая дорожка молчит, что бы ни было накручено" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    try p.place(1, 0, 0, 10 * sec);

    try p.setTrackGain(1, 120);
    try p.setMuted(1, true);
    try std.testing.expect(volume.silent(p.gainAt(1, sec)));
}

test "громкость там, где клипа нет, — это громкость дорожки" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    try p.place(1, 0, 0, 5 * sec);
    try p.setTrackGain(1, -100);
    try p.setClipGain(1, 0, -200);

    try std.testing.expectEqual(@as(volume.Db10, -300), p.gainAt(1, sec));
    // За концом клипа его собственная громкость ни при чём.
    try std.testing.expectEqual(@as(volume.Db10, -100), p.gainAt(1, 9 * sec));
}

test "движение ползунка на то же число не тратит шаг отмены" {
    // Ползунок шлёт сообщение на каждую свою точку. Снимок на каждое
    // значил бы, что одно движение мыши выбрасывает весь журнал отмен.
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    try p.setTrackGain(1, -60);
    const after_first = p.past;
    try p.setTrackGain(1, -60);
    try p.setTrackGain(1, -60);
    try std.testing.expectEqual(after_first, p.past);
}

test "громкость отменяется наравне с резкой" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    try p.place(1, 0, 0, 10 * sec);

    try p.setTrackGain(1, -200);
    try std.testing.expectEqual(@as(volume.Db10, -200), p.tracks[1].gain_db10);
    try std.testing.expect(p.undo());
    try std.testing.expectEqual(@as(volume.Db10, 0), p.tracks[1].gain_db10);
    try std.testing.expect(p.redo());
    try std.testing.expectEqual(@as(volume.Db10, -200), p.tracks[1].gain_db10);
}

test "первая точка кривой включает кривую" {
    // Человек ткнул в линию, чтобы она заработала, а не чтобы потом искать,
    // где её включают.
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    try std.testing.expect(!p.tracks[1].curve_on);
    _ = try p.addCurvePoint(1, sec, -60);
    try std.testing.expect(p.tracks[1].curve_on);
}

test "выключенная кривая не стирается и не считается" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    try p.place(1, 0, 0, 10 * sec);
    _ = try p.addCurvePoint(1, 0, -120);
    try std.testing.expectEqual(@as(volume.Db10, -120), p.gainAt(1, sec));

    try p.setCurveOn(1, false);
    try std.testing.expectEqual(@as(volume.Db10, 0), p.gainAt(1, sec));
    // Но нарисованное на месте: выключают, чтобы сравнить, а не чтобы стереть.
    try std.testing.expectEqual(@as(usize, 1), p.tracks[1].curve.count);
}

test "кривая, дорожка и клип складываются вместе" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    try p.place(1, 0, 0, 10 * sec);

    try p.setTrackGain(1, -30);
    try p.setClipGain(1, 0, -30);
    _ = try p.addCurvePoint(1, 0, -60);
    _ = try p.addCurvePoint(1, 10 * sec, -60);

    try std.testing.expectEqual(@as(volume.Db10, -120), p.gainAt(1, 5 * sec));
}

test "точка кривой отменяется" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    _ = try p.addCurvePoint(1, sec, -60);
    _ = try p.addCurvePoint(1, 2 * sec, -120);
    try std.testing.expectEqual(@as(usize, 2), p.tracks[1].curve.count);

    try std.testing.expect(p.undo());
    try std.testing.expectEqual(@as(usize, 1), p.tracks[1].curve.count);
    try std.testing.expect(p.undo());
    try std.testing.expectEqual(@as(usize, 0), p.tracks[1].curve.count);
    // И кривая выключилась обратно вместе с первой точкой.
    try std.testing.expect(!p.tracks[1].curve_on);
}

test "точку кривой можно двигать и убирать" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    _ = try p.addCurvePoint(1, sec, 0);
    _ = try p.addCurvePoint(1, 3 * sec, 0);

    const now = try p.moveCurvePoint(1, 0, 5 * sec, -60);
    try std.testing.expectEqual(@as(usize, 1), now);
    try std.testing.expectEqual(@as(volume.Db10, -60), p.tracks[1].curve.valueAt(5 * sec));

    try p.removeCurvePoint(1, 1);
    try std.testing.expectEqual(@as(usize, 1), p.tracks[1].curve.count);
}

test "чужой номер дорожки или точки — отказ, а не порча соседней" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    try std.testing.expectError(Error.NoSuchThing, p.setTrackGain(9, -60));
    try std.testing.expectError(Error.NoSuchThing, p.setClipGain(1, 0, -60));
    try std.testing.expectError(Error.NoSuchThing, p.removeCurvePoint(1, 0));
    try std.testing.expectError(Error.NoSuchThing, p.moveCurvePoint(1, 0, sec, 0));
    // Ни одно из этих обращений не потратило шаг отмены.
    try std.testing.expectEqual(@as(usize, 0), p.past);
}

test "громкость не вылезает за пределы, откуда бы ни пришла" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    try p.setTrackGain(1, 30000);
    try std.testing.expectEqual(volume.max_db10, p.tracks[1].gain_db10);
    try p.setTrackGain(1, -30000);
    try std.testing.expectEqual(volume.min_db10, p.tracks[1].gain_db10);
}

// ------------------------------------------------------------- метки

test "метка стоит на времени проекта, а не на клипе" {
    // Подвинул клип — метка осталась там, где поставлена. Так это работает
    // в монтажных программах: метку ставят на место в готовой записи.
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    try p.place(0, 0, 0, 10 * sec);
    _ = try p.addMark(5 * sec, .red, "тут переснять");

    try p.move(0, 0, 0, 20 * sec);
    try std.testing.expectEqual(@as(u64, 5 * sec), p.marks.items[0].at_ns);
}

test "метка без имени получает своё" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    _ = try p.addMark(sec, .yellow, "");
    try std.testing.expectEqualStrings("метка 1", p.marks.items[0].title());
    _ = try p.addMark(2 * sec, .yellow, "");
    try std.testing.expectEqualStrings("метка 2", p.marks.items[1].title());
}

test "метки отменяются наравне с резкой" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    _ = try p.addMark(sec, .red, "раз");
    _ = try p.addMark(2 * sec, .green, "два");
    try std.testing.expectEqual(@as(usize, 2), p.marks.count);

    try std.testing.expect(p.undo());
    try std.testing.expectEqual(@as(usize, 1), p.marks.count);
    try std.testing.expect(p.redo());
    try std.testing.expectEqual(@as(usize, 2), p.marks.count);
    try std.testing.expectEqualStrings("два", p.marks.items[1].title());
}

test "цвет и имя метки отменяются" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    _ = try p.addMark(sec, .yellow, "было");

    try p.setMarkColour(0, .violet);
    try p.renameMark(0, "стало");
    try std.testing.expectEqual(marks_mod.Colour.violet, p.marks.items[0].colour);

    try std.testing.expect(p.undo());
    try std.testing.expectEqualStrings("было", p.marks.items[0].title());
    try std.testing.expect(p.undo());
    try std.testing.expectEqual(marks_mod.Colour.yellow, p.marks.items[0].colour);
}

test "тот же цвет и то же имя не тратят шаг отмены" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    _ = try p.addMark(sec, .red, "раз");
    const after = p.past;
    try p.setMarkColour(0, .red);
    try p.renameMark(0, "раз");
    try p.renameMark(0, "   ");
    try std.testing.expectEqual(after, p.past);
}

test "метка переезжает и остаётся по порядку" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    _ = try p.addMark(1 * sec, .red, "раз");
    _ = try p.addMark(3 * sec, .green, "два");

    const now = try p.moveMark(0, 5 * sec);
    try std.testing.expectEqual(@as(usize, 1), now);
    try std.testing.expectEqualStrings("раз", p.marks.items[1].title());
    // И это отменяется.
    try std.testing.expect(p.undo());
    try std.testing.expectEqual(@as(u64, sec), p.marks.items[0].at_ns);
}

test "чужой номер метки — отказ, а не порча соседней" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    try std.testing.expectError(Error.NoSuchThing, p.removeMark(0));
    try std.testing.expectError(Error.NoSuchThing, p.renameMark(3, "нет"));
    try std.testing.expectError(Error.NoSuchThing, p.setMarkColour(3, .red));
    try std.testing.expectError(Error.NoSuchThing, p.moveMark(3, sec));
    try std.testing.expectEqual(@as(usize, 0), p.past);
}

test "меток больше отведённого не помещается, и шаг отмены не тратится" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    var i: usize = 0;
    while (i < marks_mod.max_marks) : (i += 1) {
        _ = try p.addMark(@as(u64, i + 1) * sec, .yellow, "");
    }
    const after = p.past;
    try std.testing.expectError(Error.TooManyClips, p.addMark(10_000 * sec, .red, "лишняя"));
    try std.testing.expectEqual(after, p.past);
}

test "комментарий метки отменяется и пустой принимается" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    _ = try p.addMark(sec, .red, "раз");

    try p.setMarkComment(0, "переснять со светом");
    try std.testing.expectEqualStrings("переснять со светом", p.marks.items[0].comment());

    // Стереть комментарий можно так же, как написать.
    try p.setMarkComment(0, "");
    try std.testing.expectEqual(@as(usize, 0), p.marks.items[0].comment().len);

    try std.testing.expect(p.undo());
    try std.testing.expectEqualStrings("переснять со светом", p.marks.items[0].comment());
}

test "тот же комментарий не тратит шаг отмены" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    _ = try p.addMark(sec, .red, "раз");
    try p.setMarkComment(0, "тут");
    const after = p.past;
    try p.setMarkComment(0, "тут");
    try p.setMarkComment(0, "  тут  ");
    try std.testing.expectEqual(after, p.past);
}

test "повторная метка в том же месте не переименовывает прежнюю" {
    // Иначе счётчик имён сбивается, и рядом оказываются две «метки 2».
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    _ = try p.addMark(sec, .yellow, "");
    try std.testing.expectEqualStrings("метка 1", p.marks.items[0].title());

    _ = try p.addMark(sec, .red, "");
    try std.testing.expectEqualStrings("метка 1", p.marks.items[0].title());
    // Цвет при этом обновился: нажали ещё раз — значит, хотели что-то поменять.
    try std.testing.expectEqual(marks_mod.Colour.red, p.marks.items[0].colour);

    // И следующая метка получает следующее число, а не повтор.
    _ = try p.addMark(2 * sec, .green, "");
    try std.testing.expectEqualStrings("метка 2", p.marks.items[1].title());
}

test "метка становится диапазоном и возвращается в точку" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    _ = try p.addMark(2 * sec, .red, "вырезать");
    try std.testing.expect(!p.marks.items[0].isSpan());

    try p.setMarkLength(0, 3 * sec);
    try std.testing.expect(p.marks.items[0].isSpan());
    try std.testing.expectEqual(@as(u64, 5 * sec), p.marks.items[0].endsAt());

    // Свели края — стала точка, без отдельной команды.
    try p.setMarkLength(0, 0);
    try std.testing.expect(!p.marks.items[0].isSpan());

    try std.testing.expect(p.undo());
    try std.testing.expect(p.marks.items[0].isSpan());
}

test "край диапазона двигается через отмену" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    _ = try p.addMark(2 * sec, .red, "вырезать");
    try p.setMarkLength(0, 3 * sec);

    _ = try p.moveMarkEdge(0, false, 9 * sec);
    try std.testing.expectEqual(@as(u64, 9 * sec), p.marks.items[0].endsAt());
    try std.testing.expect(p.undo());
    try std.testing.expectEqual(@as(u64, 5 * sec), p.marks.items[0].endsAt());
}

test "край на том же месте не тратит шаг отмены" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    _ = try p.addMark(2 * sec, .red, "");
    try p.setMarkLength(0, 3 * sec);
    const after = p.past;
    _ = try p.moveMarkEdge(0, false, 5 * sec);
    _ = try p.moveMarkEdge(0, true, 2 * sec);
    try std.testing.expectEqual(after, p.past);
}

test "у точки края не двигаются, и шаг отмены не тратится" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    _ = try p.addMark(2 * sec, .red, "");
    const after = p.past;
    try std.testing.expectError(Error.NoSuchThing, p.moveMarkEdge(0, false, 9 * sec));
    try std.testing.expectEqual(after, p.past);
}

test "значки метки, дорожки и клипа ставятся и отменяются" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    try p.place(0, 0, 0, 10 * sec);
    _ = try p.addMark(2 * sec, .red, "вырезать");

    try p.setMarkIcon(0, .scissors);
    try p.setTrackIcon(1, .mic);
    try p.setClipIcon(0, 0, .eye);

    try std.testing.expectEqual(marks_mod.Icons.Icon.scissors, p.marks.items[0].icon);
    try std.testing.expectEqual(marks_mod.Icons.Icon.mic, p.tracks[1].icon);
    try std.testing.expectEqual(marks_mod.Icons.Icon.eye, p.tracks[0].clips[0].icon);

    try std.testing.expect(p.undo());
    try std.testing.expectEqual(marks_mod.Icons.Icon.none, p.tracks[0].clips[0].icon);
    try std.testing.expect(p.undo());
    try std.testing.expectEqual(marks_mod.Icons.Icon.none, p.tracks[1].icon);
}

test "тот же значок не тратит шаг отмены" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    try p.place(0, 0, 0, 10 * sec);
    _ = try p.addMark(sec, .red, "");
    try p.setMarkIcon(0, .star);
    const after = p.past;
    try p.setMarkIcon(0, .star);
    try p.setTrackIcon(0, .none);
    try p.setClipIcon(0, 0, .none);
    try std.testing.expectEqual(after, p.past);
}

test "чужой номер при постановке значка — отказ" {
    const p = try sample();
    defer std.testing.allocator.destroy(p);
    try std.testing.expectError(Error.NoSuchThing, p.setMarkIcon(0, .star));
    try std.testing.expectError(Error.NoSuchThing, p.setTrackIcon(9, .star));
    try std.testing.expectError(Error.NoSuchThing, p.setClipIcon(0, 0, .star));
}

test "аннотации отменяются наравне с резкой" {
    const p = try std.testing.allocator.create(Project);
    defer std.testing.allocator.destroy(p);
    p.* = .{};
    const i = try p.addAnnotation(.{ .at_ns = std.time.ns_per_s, .len_ns = 2 * std.time.ns_per_s, .kind = .text, .x = 100, .y = 200 });
    try p.setAnnotationText(i, "смотри");
    try std.testing.expectEqual(@as(usize, 1), p.annotations.count);
    try std.testing.expect(p.undo());
    try std.testing.expectEqualStrings("", p.annotations.list()[0].title());
    try std.testing.expect(p.undo());
    try std.testing.expectEqual(@as(usize, 0), p.annotations.count);
    try std.testing.expect(p.redo());
    try std.testing.expectEqual(@as(usize, 1), p.annotations.count);
}
