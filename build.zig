const std = @import("std");

const ExampleSpec = struct {
    name: []const u8,
    path: []const u8,
};

const ExampleBuild = struct {
    artifact: *std.Build.Step.Compile,
    run: *std.Build.Step.Run,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zio_dep = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });
    const zio_mod = zio_dep.module("zio");

    const mod = b.addModule("zono", .{
        .root_source_file = b.path("src/zono.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zio", .module = zio_mod },
        },
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const examples = [_]ExampleSpec{
        .{ .name = "benchmark", .path = "examples/benchmark.zig" },
        .{ .name = "upload", .path = "examples/upload.zig" },
    };

    var example_builds: [examples.len]ExampleBuild = undefined;
    inline for (examples, 0..) |example, i| {
        example_builds[i] = addExample(b, mod, target, optimize, example);
    }

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_mod_tests.step);

    const examples_step = b.step("examples", "Build all examples");
    inline for (examples, 0..) |example, i| {
        const example_build = example_builds[i];
        examples_step.dependOn(&example_build.artifact.step);

        const example_step = b.step(
            b.fmt("example-{s}", .{example.name}),
            b.fmt("Build the {s} example", .{example.name}),
        );
        example_step.dependOn(&example_build.artifact.step);

        const run_step = b.step(
            b.fmt("run-{s}", .{example.name}),
            b.fmt("Run the {s} example", .{example.name}),
        );
        run_step.dependOn(&example_build.run.step);
    }
}

fn addExample(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    example: ExampleSpec,
) ExampleBuild {
    const example_mod = b.createModule(.{
        .root_source_file = b.path(example.path),
        .target = target,
        .optimize = optimize,
        .strip = if (optimize != .Debug) true else null,
        .imports = &.{
            .{ .name = "zono", .module = mod },
        },
    });

    const artifact = b.addExecutable(.{
        .name = b.fmt("zono-{s}", .{example.name}),
        .root_module = example_mod,
    });
    const run = b.addRunArtifact(artifact);
    return .{ .artifact = artifact, .run = run };
}
