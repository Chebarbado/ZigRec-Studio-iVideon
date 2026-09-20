//! Захват экрана: DXGI Desktop Duplication и запасной путь через GDI.
//!
//! Задача #13. DXGI — самый быстрый путь на Windows: кадры отдаются уже в
//! видеопамяти. Но у него есть условие, о котором молчат руководства: рабочий
//! стол должен **презентовать** кадры. Погашенный монитор, машина без дисплея,
//! удалённая работа — презентов нет, и `AcquireNextFrame` отдаёт таймаут вместо
//! картинки. Проверено на этой машине: за тридцать секунд с перерисовкой
//! видимого окна DXGI не отдал ни одного кадра, а GDI снял девять из десяти.
//!
//! Поэтому бэкендов два, и выбор между ними — не настройка для знатоков,
//! а поведение по умолчанию: `.auto` начинает с DXGI и, если тот **ни разу**
//! ничего не отдал, молча переходит на GDI. Однажды сработавший DXGI считается
//! рабочим и не понижается.
//!
//! Потеря доступа (смена разрешения, затемнение UAC, переключение пользователя,
//! полноэкранная игра) — не ошибка, а обычный режим: дубликация пересоздаётся
//! на месте.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;
const types = @import("capture_types.zig");
const gdi = @import("gdi.zig");

pub const Error = types.Error;
pub const Rect = types.Rect;
pub const Frame = types.Frame;
pub const Stats = types.Stats;
pub const GdiGrabber = gdi.Grabber;

pub const Backend = enum {
    /// Начать с DXGI, перейти на GDI, если тот не даёт кадров вовсе.
    auto,
    dxgi,
    gdi,

    pub fn label(self: Backend) []const u8 {
        return switch (self) {
            .auto => "авто",
            .dxgi => "DXGI",
            .gdi => "GDI",
        };
    }
};

pub const Options = struct {
    backend: Backend = .auto,
    /// Индекс монитора для DXGI.
    output: u32 = 0,
    /// Область для GDI; `null` — весь экран.
    area: ?Rect = null,
    /// Сколько ждать первого кадра от DXGI, прежде чем признать его негодным.
    downgrade_after_ms: u32 = 1500,
    /// GDI отдаёт кадр на каждый вызов, даже без изменений (#29, автопанорама).
    always_frames: bool = false,
};

/// Имя из DXGI (UTF-16 с нулём в конце) — в ASCII-буфер, чужие знаки как «?».
fn narrow(out: []u8, wide_name: []const u16) usize {
    var n: usize = 0;
    for (wide_name) |ch| {
        if (ch == 0 or n >= out.len) break;
        out[n] = if (ch < 128) @intCast(ch) else '?';
        n += 1;
    }
    return n;
}

/// Захват одного выхода (монитора) через DXGI Desktop Duplication.
pub const Duplicator = struct {
    allocator: std.mem.Allocator,
    output_index: u32,
    device: *c.ID3D11Device = undefined,
    context: *c.ID3D11DeviceContext = undefined,
    dupl: *c.IDXGIOutputDuplication = undefined,
    staging: ?*c.ID3D11Texture2D = null,
    width: u32 = 0,
    height: u32 = 0,
    /// Кадр удерживается системой между `next` и `release`.
    holding: bool = false,
    mapped: bool = false,
    stats: Stats = .{},
    /// Какой адаптер и какой выход дублируем — для отчёта стенда: на машине
    /// с двумя видеокартами дубликация молчит, если устройство не на той.
    adapter_name: [128]u8 = @splat(0),
    adapter_len: usize = 0,
    output_name: [32]u8 = @splat(0),
    output_len: usize = 0,

    pub fn adapterName(self: *const Duplicator) []const u8 {
        return self.adapter_name[0..self.adapter_len];
    }

    pub fn outputName(self: *const Duplicator) []const u8 {
        return self.output_name[0..self.output_len];
    }

    pub fn init(allocator: std.mem.Allocator, output_index: u32) Error!Duplicator {
        if (builtin.os.tag != .windows) return Error.Unsupported;
        var self = Duplicator{ .allocator = allocator, .output_index = output_index };
        try self.createDevice();
        errdefer self.releaseDevice();
        try self.createDuplication();
        return self;
    }

    pub fn deinit(self: *Duplicator) void {
        if (builtin.os.tag != .windows) return;
        self.releaseFrame();
        if (self.staging) |t| {
            _ = t.lpVtbl.*.Release.?(@ptrCast(t));
            self.staging = null;
        }
        _ = self.dupl.lpVtbl.*.Release.?(@ptrCast(self.dupl));
        self.releaseDevice();
    }

    fn releaseDevice(self: *Duplicator) void {
        _ = self.context.lpVtbl.*.Release.?(@ptrCast(self.context));
        _ = self.device.lpVtbl.*.Release.?(@ptrCast(self.device));
    }

    fn createDevice(self: *Duplicator) Error!void {
        var device: ?*c.ID3D11Device = null;
        var context: ?*c.ID3D11DeviceContext = null;
        var level: c.D3D_FEATURE_LEVEL = 0;
        // BGRA_SUPPORT: рабочий стол приходит именно в BGRA, а Direct2D для
        // отрисовки курсора и рамки потом потребует того же устройства.
        const flags: c.UINT = c.D3D11_CREATE_DEVICE_BGRA_SUPPORT;
        const hres = c.D3D11CreateDevice(
            null,
            c.D3D_DRIVER_TYPE_HARDWARE,
            null,
            flags,
            null,
            0,
            c.D3D11_SDK_VERSION,
            &device,
            &level,
            &context,
        );
        if (win32.failed(hres) or device == null or context == null) return Error.NoDevice;
        self.device = device.?;
        self.context = context.?;
    }

    fn createDuplication(self: *Duplicator) Error!void {
        var dxgi_device: ?*c.IDXGIDevice = null;
        if (win32.failed(self.device.lpVtbl.*.QueryInterface.?(
            @ptrCast(self.device),
            &c.IID_IDXGIDevice,
            @ptrCast(&dxgi_device),
        ))) return Error.NoDevice;
        defer _ = dxgi_device.?.lpVtbl.*.Release.?(@ptrCast(dxgi_device.?));

        var adapter: ?*c.IDXGIAdapter = null;
        if (win32.failed(dxgi_device.?.lpVtbl.*.GetAdapter.?(dxgi_device.?, &adapter))) return Error.NoDevice;
        defer _ = adapter.?.lpVtbl.*.Release.?(@ptrCast(adapter.?));
        var adesc: c.DXGI_ADAPTER_DESC = undefined;
        if (!win32.failed(adapter.?.lpVtbl.*.GetDesc.?(adapter.?, &adesc))) {
            self.adapter_len = narrow(&self.adapter_name, &adesc.Description);
        }

        var output: ?*c.IDXGIOutput = null;
        if (win32.failed(adapter.?.lpVtbl.*.EnumOutputs.?(adapter.?, self.output_index, &output))) return Error.NoOutput;
        defer _ = output.?.lpVtbl.*.Release.?(@ptrCast(output.?));

        var desc: c.DXGI_OUTPUT_DESC = undefined;
        if (win32.failed(output.?.lpVtbl.*.GetDesc.?(output.?, &desc))) return Error.NoOutput;
        self.output_len = narrow(&self.output_name, &desc.DeviceName);
        self.width = @intCast(desc.DesktopCoordinates.right - desc.DesktopCoordinates.left);
        self.height = @intCast(desc.DesktopCoordinates.bottom - desc.DesktopCoordinates.top);

        var output1: ?*c.IDXGIOutput1 = null;
        if (win32.failed(output.?.lpVtbl.*.QueryInterface.?(
            @ptrCast(output.?),
            &c.IID_IDXGIOutput1,
            @ptrCast(&output1),
        ))) return Error.NoOutput;
        defer _ = output1.?.lpVtbl.*.Release.?(@ptrCast(output1.?));

        var dupl: ?*c.IDXGIOutputDuplication = null;
        const hres = output1.?.lpVtbl.*.DuplicateOutput.?(output1.?, @ptrCast(self.device), &dupl);
        if (win32.failed(hres)) {
            return switch (win32.hrCode(hres)) {
                win32.hr.access_denied, win32.hr.e_access_denied => Error.AccessDenied,
                win32.hr.not_currently_available => Error.AccessDenied,
                else => Error.Failed,
            };
        }
        self.dupl = dupl.?;
    }

    /// Пересоздать дубликацию после потери доступа. Устройство переживает
    /// потерю, поэтому пересоздаём только дубликацию и staging.
    fn recover(self: *Duplicator) Error!void {
        self.releaseFrame();
        _ = self.dupl.lpVtbl.*.Release.?(@ptrCast(self.dupl));
        if (self.staging) |t| {
            _ = t.lpVtbl.*.Release.?(@ptrCast(t));
            self.staging = null;
        }
        // Экран после смены режима отдаёт дубликацию не мгновенно.
        var attempt: u32 = 0;
        while (attempt < 20) : (attempt += 1) {
            if (self.createDuplication()) |_| {
                self.stats.recoveries += 1;
                return;
            } else |err| switch (err) {
                Error.NoOutput, Error.AccessDenied, Error.Failed => c.Sleep(50),
                else => return err,
            }
        }
        return Error.Lost;
    }

    fn ensureStaging(self: *Duplicator, src: *c.ID3D11Texture2D) Error!void {
        var desc: c.D3D11_TEXTURE2D_DESC = undefined;
        src.lpVtbl.*.GetDesc.?(src, &desc);
        if (self.staging) |t| {
            var have: c.D3D11_TEXTURE2D_DESC = undefined;
            t.lpVtbl.*.GetDesc.?(t, &have);
            if (have.Width == desc.Width and have.Height == desc.Height and have.Format == desc.Format) return;
            _ = t.lpVtbl.*.Release.?(@ptrCast(t));
            self.staging = null;
        }
        var sdesc = desc;
        sdesc.Usage = c.D3D11_USAGE_STAGING;
        sdesc.BindFlags = 0;
        sdesc.CPUAccessFlags = c.D3D11_CPU_ACCESS_READ;
        sdesc.MiscFlags = 0;
        sdesc.MipLevels = 1;
        sdesc.ArraySize = 1;
        sdesc.SampleDesc.Count = 1;
        sdesc.SampleDesc.Quality = 0;
        var tex: ?*c.ID3D11Texture2D = null;
        if (win32.failed(self.device.lpVtbl.*.CreateTexture2D.?(self.device, &sdesc, null, &tex))) return Error.OutOfMemory;
        self.staging = tex.?;
        self.width = desc.Width;
        self.height = desc.Height;
    }

    /// Отпустить кадр: система не отдаст следующий, пока держим текущий.
    pub fn release(self: *Duplicator) void {
        self.releaseFrame();
    }

    fn releaseFrame(self: *Duplicator) void {
        if (self.mapped) {
            if (self.staging) |t| self.context.lpVtbl.*.Unmap.?(self.context, @ptrCast(t), 0);
            self.mapped = false;
        }
        if (self.holding) {
            _ = self.dupl.lpVtbl.*.ReleaseFrame.?(self.dupl);
            self.holding = false;
        }
    }

    /// Следующий кадр или `null`, если за `timeout_ms` экран не презентовал новый.
    pub fn next(self: *Duplicator, timeout_ms: u32) Error!?Frame {
        if (builtin.os.tag != .windows) return Error.Unsupported;
        self.releaseFrame();

        var info: c.DXGI_OUTDUPL_FRAME_INFO = undefined;
        var resource: ?*c.IDXGIResource = null;
        const hres = self.dupl.lpVtbl.*.AcquireNextFrame.?(self.dupl, timeout_ms, &info, &resource);
        if (win32.failed(hres)) {
            return switch (win32.hrCode(hres)) {
                win32.hr.wait_timeout => blk: {
                    self.stats.idle += 1;
                    break :blk null;
                },
                win32.hr.access_lost => blk: {
                    try self.recover();
                    break :blk null;
                },
                win32.hr.access_denied, win32.hr.e_access_denied => Error.AccessDenied,
                else => Error.Failed,
            };
        }
        self.holding = true;
        defer if (resource) |r| {
            _ = r.lpVtbl.*.Release.?(@ptrCast(r));
        };

        // Только курсор шевельнулся: картинка та же, кодировать нечего.
        if (info.LastPresentTime.QuadPart == 0) {
            self.stats.idle += 1;
            self.releaseFrame();
            return null;
        }

        var tex: ?*c.ID3D11Texture2D = null;
        if (win32.failed(resource.?.lpVtbl.*.QueryInterface.?(
            @ptrCast(resource.?),
            &c.IID_ID3D11Texture2D,
            @ptrCast(&tex),
        ))) return Error.Failed;
        defer _ = tex.?.lpVtbl.*.Release.?(@ptrCast(tex.?));

        try self.ensureStaging(tex.?);
        self.context.lpVtbl.*.CopyResource.?(self.context, @ptrCast(self.staging.?), @ptrCast(tex.?));

        var mapped: c.D3D11_MAPPED_SUBRESOURCE = undefined;
        if (win32.failed(self.context.lpVtbl.*.Map.?(
            self.context,
            @ptrCast(self.staging.?),
            0,
            c.D3D11_MAP_READ,
            0,
            &mapped,
        ))) return Error.Failed;
        self.mapped = true;

        const stride: u32 = mapped.RowPitch;
        const bytes: usize = @as(usize, stride) * self.height;
        const ptr: [*]const u8 = @ptrCast(mapped.pData.?);

        const accumulated: u32 = info.AccumulatedFrames;
        self.stats.frames += 1;
        if (accumulated > 1) self.stats.dropped += accumulated - 1;

        return Frame{
            .pixels = ptr[0..bytes],
            .width = self.width,
            .height = self.height,
            .stride = stride,
            .timestamp_ns = win32.nowNs(),
            .accumulated = accumulated,
        };
    }
};

/// Захват поверх обоих бэкендов: наружу одинаковый кадр, внутри — выбор пути.
pub const Capturer = struct {
    which: union(enum) {
        dxgi: Duplicator,
        gdi: GdiGrabber,
    },
    allocator: std.mem.Allocator,
    opt: Options,
    opened_ns: u64 = 0,
    downgraded: bool = false,

    pub fn open(allocator: std.mem.Allocator, opt: Options) Error!Capturer {
        if (builtin.os.tag != .windows) return Error.Unsupported;
        return switch (opt.backend) {
            .gdi => .{
                .which = .{ .gdi = try GdiGrabber.initWith(allocator, opt.area, opt.always_frames) },
                .allocator = allocator,
                .opt = opt,
                .opened_ns = win32.nowNs(),
            },
            .dxgi => .{
                .which = .{ .dxgi = try Duplicator.init(allocator, opt.output) },
                .allocator = allocator,
                .opt = opt,
                .opened_ns = win32.nowNs(),
            },
            // DXGI может не создаться вовсе (нет адаптера, выход занят) —
            // это не повод отказываться от записи, если GDI справится.
            .auto => blk: {
                if (Duplicator.init(allocator, opt.output)) |d| {
                    break :blk Capturer{
                        .which = .{ .dxgi = d },
                        .allocator = allocator,
                        .opt = opt,
                        .opened_ns = win32.nowNs(),
                    };
                } else |_| {
                    break :blk Capturer{
                        .which = .{ .gdi = try GdiGrabber.initWith(allocator, opt.area, opt.always_frames) },
                        .allocator = allocator,
                        .opt = opt,
                        .opened_ns = win32.nowNs(),
                        .downgraded = true,
                    };
                }
            },
        };
    }

    pub fn deinit(self: *Capturer) void {
        switch (self.which) {
            .dxgi => |*d| d.deinit(),
            .gdi => |*g| g.deinit(),
        }
    }

    pub fn backend(self: Capturer) Backend {
        return switch (self.which) {
            .dxgi => .dxgi,
            .gdi => .gdi,
        };
    }

    pub fn stats(self: Capturer) Stats {
        return switch (self.which) {
            .dxgi => |d| d.stats,
            .gdi => |g| g.stats,
        };
    }

    pub fn frameSize(self: Capturer) Rect {
        return switch (self.which) {
            .dxgi => |d| .{ .width = d.width, .height = d.height },
            .gdi => |g| g.area,
        };
    }

    /// Снимать только область (#30): GDI умеет и делает, DXGI отдаёт весь
    /// выход всегда. Возвращает, стал ли кадр самой областью — тогда его
    /// не режут, а берут с нуля.
    pub fn focus(self: *Capturer, area: Rect) bool {
        return switch (self.which) {
            .dxgi => false,
            .gdi => |*g| blk: {
                g.focus(area) catch break :blk false;
                break :blk true;
            },
        };
    }

    pub fn release(self: *Capturer) void {
        switch (self.which) {
            .dxgi => |*d| d.release(),
            .gdi => |*g| g.release(),
        }
    }

    /// Снятое до этого момента не отдавать (#95). Зовут после паузы записи:
    /// у GDI кадр из потока захвата пережил бы паузу со старой меткой времени.
    /// DXGI кадров впрок не держит — ему сбрасывать нечего.
    pub fn flush(self: *Capturer) void {
        switch (self.which) {
            .dxgi => {},
            .gdi => |*g| g.flush(),
        }
    }

    pub fn next(self: *Capturer, timeout_ms: u32) Error!?Frame {
        switch (self.which) {
            .gdi => |*g| return g.next(timeout_ms),
            .dxgi => |*d| {
                const frame = try d.next(timeout_ms);
                if (frame != null) return frame;
                if (self.shouldDowngrade(d.*)) try self.downgrade();
                return null;
            },
        }
    }

    /// Понижаться только если DXGI не отдал НИ ОДНОГО кадра за отведённое время.
    /// Один отданный кадр означает, что путь рабочий, и дальше молчание —
    /// это просто неподвижный экран, а не поломка.
    fn shouldDowngrade(self: Capturer, d: Duplicator) bool {
        if (self.opt.backend != .auto or self.downgraded) return false;
        if (d.stats.frames > 0) return false;
        const waited = win32.nowNs() -| self.opened_ns;
        return waited > @as(u64, self.opt.downgrade_after_ms) * std.time.ns_per_ms;
    }

    fn downgrade(self: *Capturer) Error!void {
        const kept = self.stats();
        switch (self.which) {
            .dxgi => |*d| d.deinit(),
            .gdi => return,
        }
        var g = try GdiGrabber.initWith(self.allocator, self.opt.area, self.opt.always_frames);
        // Простои DXGI не теряем: по ним видно, сколько времени ушло впустую.
        g.stats.idle = kept.idle;
        self.which = .{ .gdi = g };
        self.downgraded = true;
    }
};

test "названия бэкендов" {
    try std.testing.expectEqualStrings("DXGI", Backend.dxgi.label());
    try std.testing.expectEqualStrings("GDI", Backend.gdi.label());
}

test "типы захвата переэкспортированы" {
    const r = (Rect{ .width = 1749, .height = 1009 }).evenSized();
    try std.testing.expectEqual(@as(u32, 1748), r.width);
}
