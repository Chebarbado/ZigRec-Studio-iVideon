//! Сборка ZigRecStudio.
//!
//!   zig build           собрать exe в zig-out/bin
//!   zig build run       собрать и запустить
//!   zig build test      прогнать все тесты
//!   zig build -Doptimize=ReleaseFast   релизная сборка
//!   zig build -Doptimize=ReleaseFast -Dbenches=false   exe для людей: без самопроверок
//!
//! Всё то же одной командой: tools\check.cmd (сборка + тесты).
const std = @import("std");

pub fn build(b: *std.Build) void {
    // ABI gnu: заголовки d3d11/dxgi берём из mingw-w64, который везёт сам Zig,
    // и таблицы методов COM приходят из настоящего заголовка (см. src/win32.zig).
    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .gnu,
    } });
    const optimize = b.standardOptimizeOption(.{});

    // Ядро: всё, что не про запуск процесса. Отдельным модулем, чтобы тесты
    // ядра шли без exe, а сам exe остался тонким.
    const core = b.addModule("zigrec", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core.linkSystemLibrary("d3d11", .{});
    core.linkSystemLibrary("dxgi", .{});
    // gdi32: окно самопроверки рисует кадр стенда (StretchDIBits, GdiFlush).
    core.linkSystemLibrary("gdi32", .{});
    core.linkSystemLibrary("user32", .{});
    // dwmapi: настоящие границы окна без невидимой рамки тени.
    core.linkSystemLibrary("dwmapi", .{});
    // shell32: значок в трее и открытие готового файла.
    core.linkSystemLibrary("shell32", .{});
    core.linkSystemLibrary("comctl32", .{});
    // comdlg32: системный диалог «открыть файл» в редакторе.
    core.linkSystemLibrary("comdlg32", .{});
    // Media Foundation: кодирование H.264 и контейнер mp4.
    core.linkSystemLibrary("mfplat", .{});
    core.linkSystemLibrary("mfreadwrite", .{});
    core.linkSystemLibrary("mfuuid", .{});
    core.linkSystemLibrary("ole32", .{});
    core.linkSystemLibrary("oleaut32", .{});
    // WASAPI: захват микрофона для индикатора уровня.
    core.linkSystemLibrary("ksuser", .{});
    // iphlpapi: адреса сетевых интерфейсов для выбора адреса MCP.
    core.linkSystemLibrary("iphlpapi", .{});

    // Самопроверки и стенды в exe. По умолчанию есть — на них стоит
    // tools\check.cmd; -Dbenches=false даёт exe для людей, без них.
    const benches = b.option(bool, "benches", "Самопроверки и стенды в exe (по умолчанию да)") orelse true;
    const build_options = b.addOptions();
    build_options.addOption(bool, "benches", benches);

    const exe = b.addExecutable(.{
        .name = "zigrec",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "zigrec", .module = core }},
        }),
    });
    // Значок вшивается ресурсом: тогда он есть и у файла в проводнике,
    // и у окна, и в трее — из одного места, а не тремя разными путями.
    exe.root_module.addOptions("build_options", build_options);
    exe.root_module.addWin32ResourceFile(.{ .file = b.path("assets/zigrec.rc") });
    b.installArtifact(exe);

    const run_step = b.step("run", "Запустить zigrec");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const core_tests = b.addTest(.{ .root_module = core });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Прогнать тесты");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
