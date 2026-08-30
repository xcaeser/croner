const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const libcron = b.addModule("libcron", .{
        .root_source_file = b.path("src/libcron.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_tests = b.addTest(.{
        .root_module = libcron,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);
    run_lib_tests.has_side_effects = true;

    const test_step = b.step("test", "Run libcron and croner tests");
    test_step.dependOn(&run_lib_tests.step);

    const docs_step = b.step("docs", "Build the libcron library docs");
    const docs_obj = b.addObject(.{
        .name = "libcron",
        .root_module = libcron,
    });
    const docs = docs_obj.getEmittedDocs();
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);
    docs_step.dependOn(&b.addInstallFile(b.path("croner.schema.json"), "docs/croner.schema.json").step);

    if (b.isRoot()) {
        const zli = b.dependency("zli", .{
            .target = target,
            .optimize = optimize,
        });
        const cli = b.createModule(.{
            .root_source_file = b.path("src/croner.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .debug,
            .imports = &.{
                .{ .name = "libcron", .module = libcron },
                .{ .name = "zli", .module = zli.module("zli") },
            },
        });
        const exe = b.addExecutable(.{
            .name = "croner",
            .root_module = cli,
        });
        b.installArtifact(exe);

        const cli_tests = b.addTest(.{
            .root_module = cli,
        });
        const run_cli_tests = b.addRunArtifact(cli_tests);
        run_cli_tests.has_side_effects = true;
        test_step.dependOn(&run_cli_tests.step);
    }
}
