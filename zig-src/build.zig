const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options - defaults to native, but can cross-compile
    const target = b.standardTargetOptions(.{});

    // Standard optimization options
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "mole",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link against libc for macOS API access
    exe.linkLibC();

    // Install the executable
    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run mole");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Build universal binary for macOS (arm64 + x86_64)
    const universal_step = b.step("universal", "Build macOS universal binary");

    const arm64_exe = b.addExecutable(.{
        .name = "mole-arm64",
        .root_source_file = b.path("src/main.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .aarch64,
            .os_tag = .macos,
        }),
        .optimize = .ReleaseFast,
    });
    arm64_exe.linkLibC();

    const x86_exe = b.addExecutable(.{
        .name = "mole-x86_64",
        .root_source_file = b.path("src/main.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .x86_64,
            .os_tag = .macos,
        }),
        .optimize = .ReleaseFast,
    });
    x86_exe.linkLibC();

    // Use lipo to create universal binary
    const lipo_cmd = b.addSystemCommand(&.{
        "lipo",
        "-create",
        "-output",
    });
    lipo_cmd.addArg("zig-out/bin/mole");
    lipo_cmd.addArtifactArg(arm64_exe);
    lipo_cmd.addArtifactArg(x86_exe);

    universal_step.dependOn(&lipo_cmd.step);
}
