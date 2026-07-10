// SPDX-FileCopyrightText: 2026 Iyad
//
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sonyflake_module = b.addModule("sonyflake", .{
        .root_source_file = b.path("src/sonyflake.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Only run tests matching the given filter",
    ) orelse &.{};

    const tests = b.addTest(.{
        .root_module = sonyflake_module,
        .filters = test_filters,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    const examples = [_][]const u8{
        "basic",
    };

    const examples_step = b.step("examples", "Build all examples");
    for (examples) |name| {
        const example = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "sonyflake", .module = sonyflake_module },
                },
            }),
        });
        examples_step.dependOn(&example.step);

        const run_example = b.addRunArtifact(example);
        if (b.args) |args| run_example.addArgs(args);

        const run_step = b.step(
            b.fmt("example-{s}", .{name}),
            b.fmt("Run the {s} example", .{name}),
        );
        run_step.dependOn(&run_example.step);
    }
}
