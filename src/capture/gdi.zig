//! Запасной захват экрана через GDI (`BitBlt` с рабочего стола).
//!
//! Задача #13. DXGI быстрее и не грузит процессор, но у него есть условие:
//! рабочий стол должен **презентовать** кадры. Если физический монитор погашен,
//! машина стоит без дисплея или человек работает с неё удалённо, презентов нет,
//! и `AcquireNextFrame` честно отдаёт таймаут — снимать в такой ситуации DXGI
//! просто нечего.
//!
//! GDI читает текущее содержимое рабочего стола и работает в этих условиях.
//! Он медленнее и тратит процессор, зато снимает всегда. Именно так снимал
//! CamStudio, и для него это был единственный путь.
//!
//! Отсюда правило выбора: DXGI, когда он даёт кадры; GDI, когда нет.
//!
//! Снимок идёт в своём потоке (#95). `BitBlt` с рабочего стола под DWM ждёт
//! композитора и стоит ровно один его такт — 16,7 мс при 60 Гц, с `CAPTUREBLT`
//! и без него одинаково (замер на 1920×1080; копия и сравнение тех же 8 МБ —
//! 0,3 и 0,1 мс, дело не в них). Пока снимок и обработка кадра шли по очереди,
//! на кадр уходило 16,7 мс ожидания плюс ~10 мс работы — 36 кадров в секунду
//! вместо 60. В потоке ожидание композитора идёт одновременно с кодированием
//! предыдущего кадра, и темп упирается в сам `BitBlt`.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;
const types = @import("capture_types.zig");

pub const Error = types.Error;
pub const Frame = types.Frame;
pub const Rect = types.Rect;
pub const Stats = types.Stats;

/// Реже тридцати в секунду кадр при `always` не нужен, чаще — цикл записи
/// крутился бы на всю катушку ради одинаковых кадров.
const always_gap_ns: u64 = 33 * std.time.ns_per_ms;
/// Пауза перед повторным снимком, когда экран стоит (не изменился дважды подряд).
const unchanged_sleep_ms: u32 = 4;
/// Сколько поток ждёт, пока заберут готовый кадр, прежде чем проверить `stop`.
const taken_wait_ms: u32 = 50;
/// Сколько ждём, пока поток захвата поднимет свои поверхности.
const pipe_start_ms: u32 = 2000;
/// Старше этого готовый кадр не отдаём, а снимаем свежий. При ровной записи
/// кадр ждёт в потоке такт-другой (17–33 мс). Дольше — значит,
/// потребитель надолго отходил (стенд между шагами, медленный кодировщик),
/// и ему, как при прежнем синхронном снимке, нужен экран «сейчас», а не
/// «когда-то». Потерей это не считается: синхронный захват таких кадров
/// просто не снимал.
const stale_ns: u64 = 100 * std.time.ns_per_ms;

/// Поверхность GDI: контекст в памяти и DIB, куда `BitBlt` кладёт снимок.
const Surface = struct {
    mem_dc: c.HDC,
    dib: c.HBITMAP,
    old_obj: c.HGDIOBJ,
    bits: [*]const u8,

    fn create(screen_dc: c.HDC, width: u32, height: u32) Error!Surface {
        const mem_dc = c.CreateCompatibleDC(screen_dc) orelse return Error.NoDevice;
        errdefer _ = c.DeleteDC(mem_dc);

        var bmi = std.mem.zeroes(c.BITMAPINFO);
        bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = @intCast(width);
        // Минус — строки сверху вниз, как у DXGI и у нашего стенда.
        bmi.bmiHeader.biHeight = -@as(i32, @intCast(height));
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = c.BI_RGB;

        var bits: ?*anyopaque = null;
        const dib = c.CreateDIBSection(screen_dc, &bmi, c.DIB_RGB_COLORS, &bits, null, 0) orelse return Error.OutOfMemory;
        const old_obj = c.SelectObject(mem_dc, dib);
        return .{ .mem_dc = mem_dc, .dib = dib, .old_obj = old_obj, .bits = @ptrCast(bits.?) };
    }

    fn destroy(self: Surface) void {
        _ = c.SelectObject(self.mem_dc, self.old_obj);
        _ = c.DeleteObject(self.dib);
        _ = c.DeleteDC(self.mem_dc);
    }

    /// CAPTUREBLT: без него не попадают слоистые окна (подсказки, меню).
    fn blit(self: Surface, screen_dc: c.HDC, x: i32, y: i32, width: u32, height: u32) bool {
        const ok = c.BitBlt(self.mem_dc, 0, 0, @intCast(width), @intCast(height), screen_dc, x, y, c.SRCCOPY | c.CAPTUREBLT);
        // Пиксели DIB читаем напрямую: пусть GDI сперва допишет своё.
        _ = c.GdiFlush();
        return ok != 0;
    }
};

fn packOrigin(x: i32, y: i32) u64 {
    return (@as(u64, @as(u32, @bitCast(x))) << 32) | @as(u32, @bitCast(y));
}

fn originX(packed_xy: u64) i32 {
    return @bitCast(@as(u32, @truncate(packed_xy >> 32)));
}

fn originY(packed_xy: u64) i32 {
    return @bitCast(@as(u32, @truncate(packed_xy)));
}

/// Годен ли готовый кадр: снят после `fresh_after_ns` и ждал не дольше `stale_ns`.
fn isFresh(stamp_ns: u64, now_ns: u64, fresh_after_ns: u64) bool {
    if (stamp_ns < fresh_after_ns) return false;
    return now_ns -| stamp_ns <= stale_ns;
}

/// Сколько поверхностей у потока захвата: одна у потребителя, одна под
/// снимок и одна про запас — готовый кадр, который ещё не забрали.
const surface_count = 3;

/// Учёт поверхностей потока захвата: кто какой сейчас владеет (#95).
///
/// Потерь нет по построению: поток снимает только в свободную поверхность,
/// готовые кадры отдаются в порядке съёмки, и ни один не перезаписывается,
/// пока его не забрали. Забранный кадр потребитель держит до следующего
/// `take` — к тому времени поток пишет уже в другую. Запас в один готовый
/// кадр нужен ради всплесков: стоит потребителю задержаться на такт (звук,
/// диск), и поток без запаса простаивал бы, теряя такт композитора — при
/// двух поверхностях на этом уходило 12% времени записи.
///
/// Чистая логика без Windows: проверяется тестами, замок — снаружи.
const Ledger = struct {
    const Owner = enum { free, writing, ready, held };

    owner: [surface_count]Owner = @splat(.free),
    /// Порядок публикации: из готовых забирают самый ранний.
    seq: [surface_count]u64 = @splat(0),
    published: u64 = 0,

    /// Поток: взять свободную поверхность под снимок.
    fn claim(self: *Ledger) ?usize {
        for (&self.owner, 0..) |*o, i| {
            if (o.* == .free) {
                o.* = .writing;
                return i;
            }
        }
        return null;
    }

    /// Поток: снимок не пригодился (картинка не изменилась).
    fn abandon(self: *Ledger, index: usize) void {
        std.debug.assert(self.owner[index] == .writing);
        self.owner[index] = .free;
    }

    /// Поток: снимок готов, можно забирать.
    fn publish(self: *Ledger, index: usize) void {
        std.debug.assert(self.owner[index] == .writing);
        self.published += 1;
        self.seq[index] = self.published;
        self.owner[index] = .ready;
    }

    /// Потребитель: самый ранний готовый кадр. Прошлый забранный с этого
    /// момента свободен.
    fn take(self: *Ledger) ?usize {
        var oldest: ?usize = null;
        for (self.owner, 0..) |o, i| {
            if (o != .ready) continue;
            if (oldest == null or self.seq[i] < self.seq[oldest.?]) oldest = i;
        }
        const index = oldest orelse return null;
        for (&self.owner) |*o| {
            if (o.* == .held) o.* = .free;
        }
        self.owner[index] = .held;
        return index;
    }
};

/// Поток захвата со своими поверхностями (#95).
///
/// С «не изменилось» сравнивается последний опубликованный кадр: он новее
/// всех остальных, потребитель отпустит его последним, так что к моменту
/// сравнения он цел — отдельной копии «прошлого кадра» больше нет.
///
/// Живёт в куче: `Grabber` передают по значению, а потоку нужен адрес,
/// который не уедет.
const Pipe = struct {
    const State = enum(u8) { starting, running, failed_start, failed_capture };
    const Taken = struct { bits: [*]const u8, stamp_ns: u64 };

    width: u32,
    height: u32,
    origin: std.atomic.Value(u64),
    lock: c.SRWLOCK,
    ledger: Ledger = .{},
    stamp_ns: [surface_count]u64 = @splat(0),
    state: std.atomic.Value(u8) = .init(@intFromEnum(State.starting)),
    stop: std.atomic.Value(bool) = .init(false),
    bits: [surface_count][*]const u8 = undefined,
    ev_ready: c.HANDLE,
    ev_taken: c.HANDLE,
    thread: std.Thread = undefined,

    fn start(allocator: std.mem.Allocator, area: Rect) Error!*Pipe {
        const ev_ready = c.CreateEventW(null, 0, 0, null) orelse return Error.Failed;
        errdefer _ = c.CloseHandle(ev_ready);
        const ev_taken = c.CreateEventW(null, 0, 0, null) orelse return Error.Failed;
        errdefer _ = c.CloseHandle(ev_taken);

        const p = allocator.create(Pipe) catch return Error.OutOfMemory;
        errdefer allocator.destroy(p);
        p.* = .{
            .width = area.width,
            .height = area.height,
            .origin = .init(packOrigin(area.x, area.y)),
            .lock = std.mem.zeroes(c.SRWLOCK),
            .ev_ready = ev_ready,
            .ev_taken = ev_taken,
        };
        p.thread = std.Thread.spawn(.{}, run, .{p}) catch return Error.Failed;

        var waited: u32 = 0;
        while (p.getState() == .starting and waited < pipe_start_ms) : (waited += 1) c.Sleep(1);
        if (p.getState() != .running) {
            p.stop.store(true, .release);
            p.thread.join();
            return Error.Failed;
        }
        return p;
    }

    fn finish(self: *Pipe, allocator: std.mem.Allocator) void {
        self.stop.store(true, .release);
        _ = c.SetEvent(self.ev_taken);
        self.thread.join();
        _ = c.CloseHandle(self.ev_ready);
        _ = c.CloseHandle(self.ev_taken);
        allocator.destroy(self);
    }

    fn getState(self: *const Pipe) State {
        return @enumFromInt(self.state.load(.acquire));
    }

    fn setState(self: *Pipe, s: State) void {
        self.state.store(@intFromEnum(s), .release);
    }

    /// Потребитель: забрать самый ранний готовый кадр — поверхность и метку.
    fn take(self: *Pipe) ?Taken {
        c.AcquireSRWLockExclusive(&self.lock);
        const taken = self.ledger.take();
        const stamp = if (taken) |i| self.stamp_ns[i] else 0;
        c.ReleaseSRWLockExclusive(&self.lock);
        const index = taken orelse return null;
        _ = c.SetEvent(self.ev_taken);
        return .{ .bits = self.bits[index], .stamp_ns = stamp };
    }

    /// Контексты и поверхности поток заводит и убирает сам: `ReleaseDC`
    /// положено звать из того же потока, что и `GetDC`.
    fn run(self: *Pipe) void {
        const screen_dc = c.GetDC(null) orelse return self.setState(.failed_start);
        defer _ = c.ReleaseDC(null, screen_dc);
        var surfaces: [surface_count]Surface = undefined;
        var made: usize = 0;
        defer for (surfaces[0..made]) |s| s.destroy();
        while (made < surface_count) : (made += 1) {
            surfaces[made] = Surface.create(screen_dc, self.width, self.height) catch return self.setState(.failed_start);
            self.bits[made] = surfaces[made].bits;
        }
        self.setState(.running);

        const bytes = @as(usize, self.width) * @as(usize, self.height) * 4;
        var last: ?usize = null;
        var unchanged_in_row: u32 = 0;
        while (!self.stop.load(.acquire)) {
            c.AcquireSRWLockExclusive(&self.lock);
            const claimed = self.ledger.claim();
            c.ReleaseSRWLockExclusive(&self.lock);
            // Все поверхности заняты: потребитель отстал на два кадра.
            const into = claimed orelse {
                _ = c.WaitForSingleObject(self.ev_taken, taken_wait_ms);
                continue;
            };
            const at = self.origin.load(.acquire);
            if (!surfaces[into].blit(screen_dc, originX(at), originY(at), self.width, self.height)) {
                self.setState(.failed_capture);
                _ = c.SetEvent(self.ev_ready);
                return;
            }
            if (last != null and std.mem.eql(u8, self.bits[into][0..bytes], self.bits[last.?][0..bytes])) {
                c.AcquireSRWLockExclusive(&self.lock);
                self.ledger.abandon(into);
                c.ReleaseSRWLockExclusive(&self.lock);
                // Один повтор среди движения — не повод спать: `BitBlt` и сам
                // ждёт композитора, а сон стоил бы ещё одного его такта.
                // Спим, когда экран действительно стоит.
                unchanged_in_row += 1;
                if (unchanged_in_row > 1) c.Sleep(unchanged_sleep_ms);
                continue;
            }
            unchanged_in_row = 0;
            const stamp = win32.nowNs();
            c.AcquireSRWLockExclusive(&self.lock);
            self.stamp_ns[into] = stamp;
            self.ledger.publish(into);
            c.ReleaseSRWLockExclusive(&self.lock);
            last = into;
            _ = c.SetEvent(self.ev_ready);
        }
    }
};

/// Снимок рабочего стола средствами GDI.
pub const Grabber = struct {
    allocator: std.mem.Allocator,
    screen_dc: c.HDC = undefined,
    /// Поверхность синхронного снимка. Нужна при `always`; при обычной записи
    /// освобождается, как только поднялся поток со своими двумя.
    sync: ?Surface = null,
    pipe: ?*Pipe = null,
    area: Rect,
    /// Весь стол — то, относительно чего задана область.
    screen: Rect,
    stats: Stats = .{},
    /// Отдавать кадр на каждый вызов, даже когда картинка не изменилась,
    /// но не чаще тридцати в секунду (#29): при автопанораме область едет
    /// и при неподвижном столе, и кадр нужен всегда. Снимок тут синхронный:
    /// область должна быть снята ровно там, где её только что попросили,
    /// а кадр из потока отставал бы от неё на один сдвиг.
    always: bool = false,
    last_ns: u64 = 0,
    /// Кадры, снятые раньше этого момента, не отдаём (см. `flush`).
    fresh_after_ns: u64 = 0,

    pub fn initWith(allocator: std.mem.Allocator, area_opt: ?Rect, always: bool) Error!Grabber {
        var g = try init(allocator, area_opt);
        g.always = always;
        return g;
    }

    pub fn init(allocator: std.mem.Allocator, area_opt: ?Rect) Error!Grabber {
        if (builtin.os.tag != .windows) return Error.Unsupported;
        _ = c.SetProcessDPIAware();

        const full = Rect{
            .x = 0,
            .y = 0,
            .width = @intCast(c.GetSystemMetrics(c.SM_CXSCREEN)),
            .height = @intCast(c.GetSystemMetrics(c.SM_CYSCREEN)),
        };
        const area = (area_opt orelse full).clampTo(full.width, full.height).evenSized();
        if (area.isEmpty()) return Error.NoOutput;

        const screen_dc = c.GetDC(null) orelse return Error.NoOutput;
        errdefer _ = c.ReleaseDC(null, screen_dc);
        const sync = try Surface.create(screen_dc, area.width, area.height);

        return .{
            .allocator = allocator,
            .screen_dc = screen_dc,
            .sync = sync,
            .area = area,
            .screen = full,
        };
    }

    /// Снимать только этот прямоугольник стола (#30). Сдвиг при том же
    /// размере — бесплатно, меняется лишь откуда брать; новый размер —
    /// новая поверхность. Снимок всего 4K-стола ради области 1080p стоил
    /// вчетверо дороже самой области и держал запись на 17 кадрах в секунду.
    pub fn focus(self: *Grabber, want: Rect) Error!void {
        if (builtin.os.tag != .windows) return Error.Unsupported;
        const area = want.clampTo(self.screen.width, self.screen.height).evenSized();
        if (area.isEmpty()) return Error.NoOutput;
        if (area.width == self.area.width and area.height == self.area.height) {
            self.area = area;
            // Кадр, уже снятый потоком, придёт со старого места — отстанет
            // на один, как и при переносе окна под DXGI.
            if (self.pipe) |p| p.origin.store(packOrigin(area.x, area.y), .release);
            return;
        }
        var fresh = try init(self.allocator, area);
        fresh.always = self.always;
        fresh.stats = self.stats;
        self.deinit();
        self.* = fresh;
    }

    pub fn deinit(self: *Grabber) void {
        if (builtin.os.tag != .windows) return;
        if (self.pipe) |p| p.finish(self.allocator);
        self.pipe = null;
        if (self.sync) |s| s.destroy();
        self.sync = null;
        _ = c.ReleaseDC(null, self.screen_dc);
    }

    /// Следующий кадр или `null`, если картинка не изменилась.
    ///
    /// `timeout_ms` — верхняя граница ожидания изменения. Кадр живёт до
    /// следующего `next`.
    pub fn next(self: *Grabber, timeout_ms: u32) Error!?Frame {
        if (builtin.os.tag != .windows) return Error.Unsupported;
        if (self.always) return self.nextSync();
        return self.nextPiped(timeout_ms);
    }

    fn nextSync(self: *Grabber) Error!?Frame {
        const s = self.sync orelse return Error.Failed;
        if (!s.blit(self.screen_dc, self.area.x, self.area.y, self.area.width, self.area.height)) return Error.Failed;
        const since = win32.nowNs() -| self.last_ns;
        if (since < always_gap_ns) c.Sleep(@intCast((always_gap_ns - since) / std.time.ns_per_ms));
        self.last_ns = win32.nowNs();
        return self.frameOf(s.bits, self.last_ns);
    }

    fn nextPiped(self: *Grabber, timeout_ms: u32) Error!?Frame {
        const p = self.pipe orelse blk: {
            const started = try Pipe.start(self.allocator, self.area);
            self.pipe = started;
            // Поток снимает в свои поверхности — синхронная больше не нужна.
            if (self.sync) |s| s.destroy();
            self.sync = null;
            break :blk started;
        };
        const deadline = win32.nowNs() + @as(u64, timeout_ms) * std.time.ns_per_ms;
        while (true) {
            if (p.take()) |got| {
                // Несвежий кадр просто отпускаем: следующий `take` освободит
                // его поверхность.
                if (isFresh(got.stamp_ns, win32.nowNs(), self.fresh_after_ns)) return self.frameOf(got.bits, got.stamp_ns);
                continue;
            }
            if (p.getState() == .failed_capture) return Error.Failed;
            const now = win32.nowNs();
            if (now >= deadline) {
                self.stats.idle += 1;
                return null;
            }
            const left_ms: u32 = @intCast(@max((deadline - now) / std.time.ns_per_ms, 1));
            _ = c.WaitForSingleObject(p.ev_ready, left_ms);
        }
    }

    fn frameOf(self: *Grabber, bits: [*]const u8, timestamp_ns: u64) Frame {
        self.stats.frames += 1;
        const bytes = @as(usize, self.area.width) * @as(usize, self.area.height) * 4;
        return .{
            .pixels = bits[0..bytes],
            .width = self.area.width,
            .height = self.area.height,
            .stride = self.area.width * 4,
            .timestamp_ns = timestamp_ns,
            .accumulated = 1,
        };
    }

    /// У GDI нет удерживаемого кадра: метод есть только ради общего интерфейса.
    /// Кадр из потока отпускает следующий `next`.
    pub fn release(self: *Grabber) void {
        _ = self;
    }

    /// Всё, что поток снял до этого момента, больше не нужно. Зовут после
    /// паузы записи: кадр, снятый в её начале, дождался бы в потоке конца
    /// паузы, и его время — за вычетом самой паузы — ушло бы назад
    /// относительно предыдущего кадра.
    pub fn flush(self: *Grabber) void {
        if (builtin.os.tag != .windows) return;
        self.fresh_after_ns = win32.nowNs();
    }
};

test "объявления GDI-захвата компилируются" {
    try std.testing.expect(@hasDecl(Grabber, "init"));
    try std.testing.expect(@hasDecl(Grabber, "next"));
}

test "учёт поверхностей: кадры отдаются в порядке съёмки, забранный не перезаписывается" {
    var l = Ledger{};
    const a = l.claim().?;
    l.publish(a);
    const b = l.claim().?;
    l.publish(b);
    try std.testing.expect(a != b);

    // Забрали первый: он у потребителя, под снимок остаётся только третья.
    try std.testing.expectEqual(a, l.take().?);
    const third = l.claim().?;
    try std.testing.expect(third != a and third != b);
    // Писать больше некуда: одна у потребителя, одна готова, одна снимается.
    try std.testing.expectEqual(@as(?usize, null), l.claim());
    l.publish(third);

    // Следующий по порядку — второй; первый с этого момента свободен.
    try std.testing.expectEqual(b, l.take().?);
    try std.testing.expectEqual(a, l.claim().?);
    l.abandon(a);
    try std.testing.expectEqual(third, l.take().?);
    try std.testing.expectEqual(@as(?usize, null), l.take());
}

test "учёт поверхностей: случайный порядок шагов не теряет, не дублирует и не портит кадры" {
    var prng = std.Random.DefaultPrng.init(95);
    const rnd = prng.random();
    var l = Ledger{};
    var writing: ?usize = null;
    var held: ?usize = null;
    // Что «снято» в каждую поверхность: номер кадра.
    var content: [surface_count]u64 = @splat(0);
    var shot: u64 = 0;
    var expect_next: u64 = 1;
    var step: u32 = 0;
    while (step < 20000) : (step += 1) {
        switch (rnd.uintLessThan(u8, 4)) {
            0 => if (writing == null) {
                if (l.claim()) |i| {
                    // Поток никогда не получает поверхность потребителя.
                    try std.testing.expect(held == null or held.? != i);
                    writing = i;
                }
            },
            1 => if (writing) |i| {
                shot += 1;
                content[i] = shot;
                l.publish(i);
                writing = null;
            },
            2 => if (writing) |i| {
                l.abandon(i);
                writing = null;
            },
            else => if (l.take()) |i| {
                // Строго по порядку съёмки, без пропусков и повторов.
                try std.testing.expectEqual(expect_next, content[i]);
                expect_next += 1;
                held = i;
            },
        }
        // Кадр в руках потребителя остаётся тем же, что он забрал.
        if (held) |i| try std.testing.expectEqual(expect_next - 1, content[i]);
    }
    try std.testing.expect(expect_next > 1000);
}

test "готовый кадр годен, пока свеж и снят после сброса" {
    const ms = std.time.ns_per_ms;
    // Ровная запись: кадр ждал один такт.
    try std.testing.expect(isFresh(1000 * ms, 1017 * ms, 0));
    // Ровно на пределе — ещё годен, на миллисекунду дольше — уже нет.
    try std.testing.expect(isFresh(1000 * ms, 1000 * ms + stale_ns, 0));
    try std.testing.expect(!isFresh(1000 * ms, 1000 * ms + stale_ns + ms, 0));
    // Снят до сброса (пауза 30 мс, по возрасту ещё свеж) — не годен.
    try std.testing.expect(!isFresh(1000 * ms, 1030 * ms, 1025 * ms));
    // Снят после сброса — годен.
    try std.testing.expect(isFresh(1026 * ms, 1030 * ms, 1025 * ms));
    // Метка позже «сейчас» (часы читались в другом порядке) — не ошибка.
    try std.testing.expect(isFresh(1001 * ms, 1000 * ms, 0));
}

test "начало области упаковывается и распаковывается, включая отрицательное" {
    for ([_][2]i32{ .{ 0, 0 }, .{ 1920, 1080 }, .{ -1920, 0 }, .{ 0, -1 }, .{ -7, -3000 }, .{ std.math.maxInt(i32), std.math.minInt(i32) } }) |xy| {
        const at = packOrigin(xy[0], xy[1]);
        try std.testing.expectEqual(xy[0], originX(at));
        try std.testing.expectEqual(xy[1], originY(at));
    }
}
