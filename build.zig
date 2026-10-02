const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const phrases = b.dependency("phrases", .{ .target = target, .optimize = optimize });
    const resonator = b.dependency("resonator", .{ .target = target, .optimize = optimize });
    const lightmix = b.dependency("lightmix", .{ .target = target, .optimize = optimize });

    // Library module declaration
    const mod = b.addModule("sequencer", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "phrases", .module = phrases.module("phrases") },
            .{ .name = "resonator", .module = resonator.module("resonator") },
            .{ .name = "lightmix", .module = lightmix.module("lightmix") },
        },
    });

    // Library installation
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "sequencer",
        .root_module = mod,
    });
    b.installArtifact(lib);

    // Library unit tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Test step
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);
}
