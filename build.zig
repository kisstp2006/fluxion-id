// SPDX-License-Identifier: CC0-1.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // fluxion-encoding: hex, which is the text a UUID is written in.
    const encoding = b.dependency("fluxion_encoding", .{
        .target = target,
        .optimize = optimize,
    });

    // The importable module. Consumers do:
    //   const ids = @import("fluxion_id");
    const mod = b.addModule("fluxion_id", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_encoding", .module = encoding.module("fluxion_encoding") },
        },
    });

    // zig build test
    const tests = b.addTest(.{
        .name = "fluxion-id-tests",
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the library test suite");
    test_step.dependOn(&run_tests.step);

    // zig build example
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/demo.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fluxion_id", .module = mod }},
    });
    const example = b.addExecutable(.{
        .name = "fluxion-id-demo",
        .root_module = example_mod,
    });
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(b.getInstallStep());
    const example_step = b.step("example", "Build and run the demo program");
    example_step.dependOn(&run_example.step);

    // zig build docs -> zig-out/docs
    const docs_lib = b.addLibrary(.{
        .name = "fluxion-id",
        .root_module = mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);
}
