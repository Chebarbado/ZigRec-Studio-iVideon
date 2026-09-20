//! Устройства ввода звука: какие микрофоны есть и как их звать.
//!
//! Задача #22. Микрофон брался «по умолчанию» — тот, что выбран в Windows.
//! У кого их два (гарнитура и веб-камера), тот записывал не в тот и узнавал
//! об этом после. Здесь список устройств захвата с именами и номерами,
//! по которым Windows их отличает; выбор запоминается в настройках.
//!
//! Правила — чистые функции с тестами; Windows спрашивается только в `list`.
const std = @import("std");
const lang = @import("../lang.zig");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const c = win32.c;

/// Больше микрофонов на машине не бывает в разумной жизни.
pub const max_devices = 16;
/// Номер устройства у Windows — строка вида `{0.0.1.00000000}.{guid}`,
/// в ней около шестидесяти знаков; берём с запасом.
pub const max_id = 256;
/// Имя устройства: «Микрофон (Realtek High Definition Audio)».
pub const max_name = 128;

/// Как называется строка «как в Windows».
pub const default_label = "по умолчанию (как в Windows)";
/// Что показать, если запомненного устройства сейчас нет.
pub const missing_label = "запомненный микрофон не найден — берётся тот, что по умолчанию";

pub const Device = struct {
    id: [max_id]u8 = @splat(0),
    id_len: usize = 0,
    name: [max_name]u8 = @splat(0),
    name_len: usize = 0,

    pub fn deviceId(self: *const Device) []const u8 {
        return self.id[0..self.id_len];
    }

    pub fn deviceName(self: *const Device) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Собрать запись руками: для тестов и стендов.
    pub fn make(id: []const u8, name: []const u8) Device {
        var d = Device{};
        d.id_len = @min(id.len, d.id.len);
        @memcpy(d.id[0..d.id_len], id[0..d.id_len]);
        d.name_len = @min(name.len, d.name.len);
        @memcpy(d.name[0..d.name_len], name[0..d.name_len]);
        return d;
    }
};

/// Где в списке устройство с таким номером. Пустой номер — «по умолчанию»,
/// его в списке нет.
pub fn indexOf(found: []const Device, id: []const u8) ?usize {
    if (id.len == 0) return null;
    for (found, 0..) |*d, i| {
        if (std.mem.eql(u8, d.deviceId(), id)) return i;
    }
    return null;
}

/// Как назвать выбранное: имя устройства, «по умолчанию» или честное
/// «не найден».
pub fn nameFor(found: []const Device, id: []const u8) []const u8 {
    if (id.len == 0) return lang.tr(default_label);
    if (indexOf(found, id)) |i| return found[i].deviceName();
    return lang.tr(missing_label);
}

// PKEY_Device_FriendlyName: {a45c254e-df1c-4efd-8020-67d146a850e0}, 14.
// Заголовок с ключами (functiondiscoverykeys_devpkey.h) в сборку не берём:
// один ключ проще записать, чем тащить ещё один заголовок.
const friendly_name_key = c.PROPERTYKEY{
    .fmtid = .{
        .Data1 = 0xa45c254e,
        .Data2 = 0xdf1c,
        .Data3 = 0x4efd,
        .Data4 = .{ 0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0 },
    },
    .pid = 14,
};

/// `PROPVARIANT` translate-c отдаёт с безымянным объединением; нам из него
/// нужны тип и указатель на строку — записываем сами, размер тот же (24).
const PropVariant = extern struct {
    vt: u16 = 0,
    r1: u16 = 0,
    r2: u16 = 0,
    r3: u16 = 0,
    text: ?[*:0]u16 = null,
    pad: u64 = 0,
};
const vt_lpwstr: u16 = 31;

/// Спросить у Windows устройства захвата, которые сейчас включены.
pub fn list(out: *[max_devices]Device) []Device {
    if (builtin.os.tag != .windows) return out[0..0];

    _ = c.CoInitializeEx(null, c.COINIT_MULTITHREADED);
    defer c.CoUninitialize();

    var enumerator: ?*c.IMMDeviceEnumerator = null;
    if (win32.failed(c.CoCreateInstance(
        &c.CLSID_MMDeviceEnumerator,
        null,
        c.CLSCTX_ALL,
        &c.IID_IMMDeviceEnumerator,
        @ptrCast(&enumerator),
    ))) return out[0..0];
    defer _ = enumerator.?.lpVtbl.*.Release.?(@ptrCast(enumerator.?));

    var collection: ?*c.IMMDeviceCollection = null;
    if (win32.failed(enumerator.?.lpVtbl.*.EnumAudioEndpoints.?(
        enumerator.?,
        c.eCapture,
        c.DEVICE_STATE_ACTIVE,
        &collection,
    ))) return out[0..0];
    defer _ = collection.?.lpVtbl.*.Release.?(@ptrCast(collection.?));

    var count: c.UINT = 0;
    if (win32.failed(collection.?.lpVtbl.*.GetCount.?(collection.?, &count))) return out[0..0];

    var n: usize = 0;
    var i: c.UINT = 0;
    while (i < count and n < out.len) : (i += 1) {
        var device: ?*c.IMMDevice = null;
        if (win32.failed(collection.?.lpVtbl.*.Item.?(collection.?, i, &device))) continue;
        defer _ = device.?.lpVtbl.*.Release.?(@ptrCast(device.?));

        var id_w: ?[*:0]u16 = null;
        if (win32.failed(device.?.lpVtbl.*.GetId.?(device.?, @ptrCast(&id_w)))) continue;
        defer c.CoTaskMemFree(@ptrCast(id_w));
        var id_buf: [max_id]u8 = undefined;
        const id_len = std.unicode.utf16LeToUtf8(&id_buf, std.mem.span(id_w.?)) catch continue;
        if (id_len == 0) continue;

        // Имя — из свойств устройства; без него строка «{0.0.1…}» никому
        // ничего не скажет.
        var name_buf: [max_name]u8 = undefined;
        var name_len: usize = 0;
        var store: ?*c.IPropertyStore = null;
        if (!win32.failed(device.?.lpVtbl.*.OpenPropertyStore.?(device.?, c.STGM_READ, &store))) {
            defer _ = store.?.lpVtbl.*.Release.?(@ptrCast(store.?));
            var value = PropVariant{};
            if (!win32.failed(store.?.lpVtbl.*.GetValue.?(store.?, &friendly_name_key, @ptrCast(&value)))) {
                defer _ = c.PropVariantClear(@ptrCast(&value));
                if (value.vt == vt_lpwstr) {
                    if (value.text) |t| name_len = std.unicode.utf16LeToUtf8(&name_buf, std.mem.span(t)) catch 0;
                }
            }
        }
        if (name_len == 0) {
            const fallback = lang.t("микрофон без имени");
            @memcpy(name_buf[0..fallback.len], fallback);
            name_len = fallback.len;
        }
        out[n] = Device.make(id_buf[0..id_len], name_buf[0..name_len]);
        n += 1;
    }
    return out[0..n];
}

// ---------------------------------------------------------------- тесты

const testing = std.testing;

fn fake() [2]Device {
    return .{
        Device.make("{0.0.1.00000000}.{aaaa}", "Микрофон (гарнитура)"),
        Device.make("{0.0.1.00000000}.{bbbb}", "Микрофон (веб-камера)"),
    };
}

test "устройство ищется по номеру, пустой номер — это «по умолчанию»" {
    const found = fake();
    try testing.expectEqual(@as(?usize, 1), indexOf(&found, "{0.0.1.00000000}.{bbbb}"));
    try testing.expectEqual(@as(?usize, null), indexOf(&found, ""));
    try testing.expectEqual(@as(?usize, null), indexOf(&found, "{0.0.1.00000000}.{cccc}"));
}

test "подписи выбора микрофона переведены" {
    // Обе идут через `lang.tr`, а он о пропаже молчит: сторож — здесь (#100).
    try testing.expect(lang.known(default_label));
    try testing.expect(lang.known(missing_label));
}

test "имя для выбранного: устройство, умолчание или честное «не найден»" {
    const found = fake();
    try testing.expectEqualStrings("Микрофон (веб-камера)", nameFor(&found, "{0.0.1.00000000}.{bbbb}"));
    try testing.expectEqualStrings(default_label, nameFor(&found, ""));
    // Гарнитуру отключили — говорим об этом, а не молча пишем в другой.
    try testing.expectEqualStrings(missing_label, nameFor(&found, "{0.0.1.00000000}.{zzzz}"));
}

test "длинное имя и номер обрезаются, а не ломают запись" {
    const long = "x" ** 600;
    const d = Device.make(long, long);
    try testing.expectEqual(@as(usize, max_id), d.deviceId().len);
    try testing.expectEqual(@as(usize, max_name), d.deviceName().len);
}

test "PROPVARIANT нашей записи того же размера, что у Windows" {
    // Иначе GetValue написал бы за край.
    try testing.expectEqual(@sizeOf(c.PROPVARIANT), @sizeOf(PropVariant));
}

test "на этой машине список читается: номера непустые и не повторяются" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var out: [max_devices]Device = undefined;
    const got = list(&out);
    for (got, 0..) |*d, i| {
        try testing.expect(d.deviceId().len > 0);
        try testing.expect(d.deviceName().len > 0);
        try testing.expectEqual(@as(?usize, i), indexOf(got, d.deviceId()));
    }
}
