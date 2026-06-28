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
    // Expose build.zig.zon as an importable module so `die --version` can
    // read the canonical version (single source of truth at the repo root).
    root_module.addAnonymousImport("zon", .{
        .root_source_file = b.path("build.zig.zon"),
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
    test_module.addAnonymousImport("zon", .{
        .root_source_file = b.path("build.zig.zon"),
    });

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
