//! Ядро ZigRecStudio: всё, что не про запуск процесса.
//!
//! Слои снизу вверх: `capture` даёт кадры, `encode` пишет их в mp4,
//! `audio` даёт звук, `timeline` и `edit` режут готовое, `ui` показывает.
//! Модуль импортируется как `@import("zigrec")`.
//!
//! Эти же слои разложены по папкам, и папка — не украшение, а ответ на
//! вопрос «куда класть новое»:
//!
//!     src/            точки входа и общее для всех: main, win32, версия
//!     src/capture/    снятие экрана: экран, курсор, рамка, точка записи
//!     src/sound/      звук: микрофон, пересчёт частоты, усиление, кольцо
//!     src/file/       чтение и запись файлов: mp4, png, волна, проект
//!     src/edit/       монтаж: дорожки, окно редактора, попадания мышью
//!     src/app/        программа целиком: окна, настройки, сервер, стенды
const std = @import("std");

pub const win32 = @import("win32.zig");
pub const errors = @import("errors.zig");
pub const version = @import("version.zig");
pub const settings = @import("app/settings.zig");
pub const paths = @import("app/paths.zig");
pub const hotkey = @import("app/hotkey.zig");
pub const tray_menu = @import("app/tray_menu.zig");
pub const listen = @import("app/listen.zig");
pub const interfaces = @import("app/interfaces.zig");
pub const devices = @import("sound/devices.zig");
pub const mic_probe = @import("sound/probe.zig");
pub const clock_play = @import("sound/clock_play.zig");
pub const stepping = @import("edit/stepping.zig");
pub const mcp_corner = @import("app/mcp_corner.zig");
pub const boost = @import("app/boost.zig");
pub const remote = @import("app/remote.zig");
pub const remote_win = @import("app/remote_win.zig");
pub const recent = @import("app/recent.zig");
pub const capture_types = @import("capture/capture_types.zig");
pub const capture = @import("capture/capture.zig");
pub const cursor = @import("capture/cursor.zig");
pub const frame_overlay = @import("capture/frame_overlay.zig");
pub const rec_dot = @import("capture/rec_dot.zig");
pub const recorder = @import("app/recorder.zig");
pub const source = @import("capture/source.zig");
pub const gdi = @import("capture/gdi.zig");
pub const encode = @import("file/encode.zig");
pub const mp4 = @import("file/mp4.zig");
pub const audio = @import("sound/audio.zig");
pub const mic = @import("sound/mic.zig");
pub const wav = @import("sound/wav.zig");
pub const gain = @import("sound/gain.zig");
pub const volume = @import("sound/volume.zig");
pub const blend = @import("sound/blend.zig");
pub const play = @import("sound/play.zig");
pub const drift = @import("sound/drift.zig");
pub const resample = @import("sound/resample.zig");
pub const tone = @import("sound/tone.zig");
pub const track = @import("sound/track.zig");
pub const probe = @import("file/probe.zig");
pub const media = @import("file/media.zig");
pub const timeline = @import("edit/timeline.zig");
pub const project_file = @import("file/project_file.zig");
pub const zip = @import("file/zip.zig");
pub const project_pack = @import("file/project_pack.zig");
pub const waveform = @import("file/waveform.zig");
pub const audio_read = @import("file/audio_read.zig");
pub const player = @import("file/player.zig");
pub const frames = @import("file/frames.zig");
pub const png = @import("file/png.zig");
pub const gif = @import("file/gif.zig");
pub const gif_write = @import("file/gif_write.zig");
pub const icons = @import("edit/icons.zig");
pub const marks = @import("edit/marks.zig");
pub const mixdown = @import("edit/mixdown.zig");
pub const editor_view = @import("edit/editor_view.zig");
pub const editor = @import("edit/editor.zig");
pub const edit = @import("edit/edit.zig");
pub const mcp = @import("app/mcp.zig");
pub const control = @import("app/control.zig");
pub const ui = @import("app/ui.zig");
pub const testbench = @import("app/testbench.zig");
pub const smoke = @import("app/smoke.zig");

test {
    // Тесты всех модулей ядра одним `zig build test`.
    std.testing.refAllDecls(@This());
}
