// build.zig — die Zig implementation (Zig 0.16.0+)
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = optimize == .ReleaseSmall or optimize == .ReleaseFast or optimize == .ReleaseSafe;

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        // Link libc so that extern C declarations (write, read, isatty,
        // malloc/realloc/free) resolve on all targets including cross-compiled Linux.
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "die",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    // ---- Test step -----------------------------------------------------------
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
