//! Служба кадров: окно просит кадр и продолжает жить.
//!
//! Задача #68. Перемотка — дорогое дело: Media Foundation ищет ближайший
//! опорный кадр и раскодирует до нужного места. Пока это идёт в потоке окна,
//! окно не отвечает: не перерисовывается, не слышит колесо, не двигает
//! указатель. На длинном файле это заметно, а при перетаскивании указателя
//! невыносимо.
//!
//! Поэтому декодер живёт в стороне. Окно говорит «хочу кадр на такой-то
//! секунде» и сразу возвращается к своим делам; когда кадр готов, служба
//! стучится в окно сообщением.
//!
//! **Просьбы склеиваются.** Пока тянут указатель, просьб набегает по десятку
//! в секунду, и раскодировать надо ПОСЛЕДНЮЮ, а не все подряд. Иначе декодер
//! отстаёт всё сильнее и показывает то, что человек просил секунду назад.
//!
//! **Готовый кадр живёт до следующего.** Пустота на месте кадра хуже, чем
//! кадр, устаревший на треть секунды: по пустоте не видно даже, в ту ли
//! сторону ты едешь.
const std = @import("std");
const builtin = @import("builtin");
const player_mod = @import("player.zig");

pub const max_path = 512;

/// Просьба показать кадр.
pub const Ask = struct {
    path: [max_path]u8 = @splat(0),
    path_len: usize = 0,
    when_ns: u64 = 0,
    /// Номер просьбы. Растёт, чтобы отличать новую от уже выполненной.
    number: u64 = 0,

    pub fn file(self: *const Ask) []const u8 {
        return self.path[0..self.path_len];
    }
};

/// Очередь из одной просьбы: новая вытесняет прежнюю.
///
/// Чистый счёт, поэтому живёт отдельно от потоков и проверяется тестами.
/// Ошибка здесь стоит дорого и незаметно: декодер начнёт разбирать очередь
/// подряд и отстанет от человека на секунды.
pub const Latest = struct {
    ask: Ask = .{},
    /// Есть ли невыполненная просьба.
    pending: bool = false,
    /// Сколько просьб пришло всего — и сколько из них выполнено.
    asked: u64 = 0,
    done: u64 = 0,

    /// Попросить кадр. Прежняя невыполненная просьба пропадает.
    pub fn want(self: *Latest, path: []const u8, when_ns: u64) void {
        const n = @min(path.len, max_path);
        @memcpy(self.ask.path[0..n], path[0..n]);
        self.ask.path_len = n;
        self.ask.when_ns = when_ns;
        self.asked += 1;
        self.ask.number = self.asked;
        self.pending = true;
    }

    /// Забрать просьбу в работу. `null` — просить нечего.
    pub fn take(self: *Latest) ?Ask {
        if (!self.pending) return null;
        self.pending = false;
        return self.ask;
    }

    /// Отметить просьбу выполненной.
    pub fn finish(self: *Latest, number: u64) void {
        if (number > self.done) self.done = number;
    }

    /// Отстаём ли: пришло больше просьб, чем выполнено.
    pub fn behind(self: *const Latest) u64 {
        return self.asked -| self.done;
    }
};

// ------------------------------------------------------------- служба

/// Что делать, когда кадр готов. Зовётся из чужого потока, поэтому
/// внутри можно только послать окну сообщение — трогать окно нельзя.
pub const Notify = *const fn (userdata: ?*anyopaque) void;

pub const Service = struct {
    allocator: std.mem.Allocator,

    /// Замок и ожидание берём из `std.Io`: в этой версии Zig они живут там,
    /// и им нужен свой обработчик ввода-вывода.
    threaded: std.Io.Threaded = undefined,
    io: std.Io = undefined,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),

    /// Что просили последним.
    queue: Latest = .{},

    /// Готовый кадр: BGRA, строки сверху вниз, шаг равен ширине.
    frame: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    at_ns: u64 = 0,
    /// Есть ли что показывать.
    ready: bool = false,
    /// Длительность открытого файла.
    duration_ns: u64 = 0,
    /// Последняя беда, о которой стоит сказать человеку.
    trouble: ?anyerror = null,

    notify: ?Notify = null,
    userdata: ?*anyopaque = null,

    pub fn start(self: *Service, notify: Notify, userdata: ?*anyopaque) !void {
        if (self.thread != null) return;
        self.notify = notify;
        self.userdata = userdata;
        self.threaded = .init(self.allocator, .{});
        self.io = self.threaded.io();
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, work, .{self});
    }

    pub fn stop(self: *Service) void {
        if (self.thread == null) return;
        self.running.store(false, .release);
        self.mutex.lockUncancelable(self.io);
        self.wake.broadcast(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |t| t.join();
        self.thread = null;
        self.threaded.deinit();

        if (self.frame.len > 0) self.allocator.free(self.frame);
        self.frame = &.{};
        self.ready = false;
    }

    /// Попросить кадр и сразу вернуться.
    ///
    /// Здесь не должно быть ничего дорогого: это зовётся из потока окна
    /// на каждое движение мыши.
    pub fn want(self: *Service, path: []const u8, when_ns: u64) void {
        if (self.thread == null) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.queue.want(path, when_ns);
        self.wake.signal(self.io);
    }

    /// Сделать что-нибудь с готовым кадром, не выпуская его из-под замка.
    ///
    /// Так рисование видит целый кадр, а не наполовину переписанный.
    pub fn withFrame(self: *Service, comptime T: type, ctx: T, use: *const fn (T, []const u8, u32, u32, u64) void) bool {
        if (self.thread == null) return false;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.ready or self.frame.len == 0) return false;
        use(ctx, self.frame, self.width, self.height, self.at_ns);
        return true;
    }

    /// Сколько просьб ждёт своей очереди.
    pub fn behind(self: *Service) u64 {
        if (self.thread == null) return 0;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.queue.behind();
    }

    fn work(self: *Service) void {
        var open: ?player_mod.Player = null;
        var open_path: [max_path]u8 = @splat(0);
        var open_len: usize = 0;
        defer if (open) |*p| p.close();

        while (self.running.load(.acquire)) {
            // Берём последнюю просьбу под замком и отпускаем его: декодер
            // работает долго, и держать замок всё это время значило бы
            // остановить окно ровно так же, как раньше.
            self.mutex.lockUncancelable(self.io);
            var job = self.queue.take();
            while (job == null and self.running.load(.acquire)) {
                self.wake.waitUncancelable(self.io, &self.mutex);
                job = self.queue.take();
            }
            self.mutex.unlock(self.io);

            const ask = job orelse continue;
            if (!self.running.load(.acquire)) return;

            // Файл сменился — открываем заново.
            if (open == null or !std.mem.eql(u8, open_path[0..open_len], ask.file())) {
                if (open) |*p| p.close();
                open = null;
                open_len = 0;

                open = player_mod.Player.open(self.allocator, ask.file()) catch |err| {
                    self.report(err, ask.number);
                    continue;
                };
                const n = @min(ask.path_len, open_path.len);
                @memcpy(open_path[0..n], ask.file()[0..n]);
                open_len = n;
            }

            const p = &open.?;
            p.showAt(ask.when_ns) catch |err| {
                self.report(err, ask.number);
                continue;
            };
            if (!p.ready) continue;
            self.publish(p, ask.number);
        }
    }

    /// Переложить готовый кадр к себе и сказать окну.
    fn publish(self: *Service, p: *const player_mod.Player, number: u64) void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            const need = p.pixels.len;
            if (self.frame.len != need) {
                if (self.frame.len > 0) self.allocator.free(self.frame);
                self.frame = self.allocator.alloc(u8, need) catch {
                    self.frame = &.{};
                    self.ready = false;
                    return;
                };
            }
            @memcpy(self.frame, p.pixels);
            self.width = p.width;
            self.height = p.height;
            self.at_ns = p.at_ns;
            self.duration_ns = p.duration_ns;
            self.ready = true;
            self.trouble = null;
            self.queue.finish(number);
        }
        if (self.notify) |call| call(self.userdata);
    }

    fn report(self: *Service, err: anyerror, number: u64) void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.trouble = err;
            self.ready = false;
            self.queue.finish(number);
        }
        if (self.notify) |call| call(self.userdata);
    }
};

// ---------------------------------------------------------------- тесты

const testing = std.testing;

test "из череды просьб берётся последняя" {
    // Пока тянут указатель, просьб набегает по десятку в секунду.
    // Раскодировать надо последнюю: иначе декодер отстаёт всё сильнее
    // и показывает то, что человек просил секунду назад.
    var q = Latest{};
    q.want("а.mp4", 1 * std.time.ns_per_s);
    q.want("а.mp4", 2 * std.time.ns_per_s);
    q.want("а.mp4", 3 * std.time.ns_per_s);

    const job = q.take().?;
    try testing.expectEqual(@as(u64, 3 * std.time.ns_per_s), job.when_ns);
    try testing.expectEqualStrings("а.mp4", job.file());
    // Больше брать нечего: промежуточные просьбы вытеснены, а не накоплены.
    try testing.expect(q.take() == null);
}

test "пустая очередь ничего не отдаёт" {
    var q = Latest{};
    try testing.expect(q.take() == null);
}

test "взятая просьба не берётся дважды" {
    var q = Latest{};
    q.want("а.mp4", 5);
    try testing.expect(q.take() != null);
    try testing.expect(q.take() == null);

    // А новая — берётся.
    q.want("а.mp4", 6);
    try testing.expectEqual(@as(u64, 6), q.take().?.when_ns);
}

test "смена файла доходит до декодера" {
    var q = Latest{};
    q.want("первый.mp4", 1);
    q.want("второй.mov", 2);
    const job = q.take().?;
    try testing.expectEqualStrings("второй.mov", job.file());
}

test "видно, насколько декодер отстаёт" {
    var q = Latest{};
    try testing.expectEqual(@as(u64, 0), q.behind());

    q.want("а.mp4", 1);
    q.want("а.mp4", 2);
    q.want("а.mp4", 3);
    try testing.expectEqual(@as(u64, 3), q.behind());

    const job = q.take().?;
    q.finish(job.number);
    // Три просьбы, одна выполнена — но выполнена ПОСЛЕДНЯЯ, и догонять
    // больше нечего.
    try testing.expectEqual(@as(u64, 0), q.behind());
}

test "запоздавший ответ не отматывает счёт назад" {
    var q = Latest{};
    q.want("а.mp4", 1);
    q.want("а.mp4", 2);
    const job = q.take().?;
    q.finish(job.number);
    // Ответ на давнюю просьбу приходит после свежей — он ничего не меняет.
    q.finish(1);
    try testing.expectEqual(@as(u64, 2), q.done);
}

test "слишком длинный путь обрезается, а не портит память" {
    var q = Latest{};
    const long = "я" ** 600;
    q.want(long, 1);
    try testing.expect(q.take().?.file().len <= max_path);
}

test "номера просьб растут" {
    // По ним отличают свежий ответ от запоздавшего.
    var q = Latest{};
    q.want("а.mp4", 1);
    const first = q.take().?.number;
    q.want("а.mp4", 2);
    const second = q.take().?.number;
    try testing.expect(second > first);
}
