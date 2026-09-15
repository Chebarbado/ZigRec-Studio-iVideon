//! Ядро ZigRecStudio: всё, что не про запуск процесса.
//!
//! Слои снизу вверх: `capture` даёт кадры, `encode` пишет их в mp4,
//! `audio` даёт звук, `timeline` и `edit` режут готовое, `ui` показывает.
//! Модуль импортируется как `@import("zigrec")`.
const std = @import("std");

pub const win32 = @import("win32.zig");
pub const errors = @import("errors.zig");
pub const version = @import("version.zig");
pub const capture_types = @import("capture_types.zig");
pub const capture = @import("capture.zig");
pub const cursor = @import("cursor.zig");
pub const frame_overlay = @import("frame_overlay.zig");
pub const rec_dot = @import("rec_dot.zig");
pub const recorder = @import("recorder.zig");
pub const source = @import("source.zig");
pub const gdi = @import("gdi.zig");
pub const encode = @import("encode.zig");
pub const mp4 = @import("mp4.zig");
pub const audio = @import("audio.zig");
pub const mic = @import("mic.zig");
pub const wav = @import("wav.zig");
pub const gain = @import("gain.zig");
pub const resample = @import("resample.zig");
pub const tone = @import("tone.zig");
pub const track = @import("track.zig");
pub const probe = @import("probe.zig");
pub const media = @import("media.zig");
pub const timeline = @import("timeline.zig");
pub const editor_view = @import("editor_view.zig");
pub const editor = @import("editor.zig");
pub const edit = @import("edit.zig");
pub const mcp = @import("mcp.zig");
pub const control = @import("control.zig");
pub const ui = @import("ui.zig");
pub const testbench = @import("testbench.zig");
pub const smoke = @import("smoke.zig");

test {
    // Тесты всех модулей ядра одним `zig build test`.
    std.testing.refAllDecls(@This());
}
