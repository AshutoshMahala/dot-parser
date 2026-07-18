const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The public library module. It must stay free of OS, filesystem, thread,
    // and network dependencies (R-PORT-001).
    const mod = b.addModule("dot_parser", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The default step builds (and installs) the portable static library
    // for the selected target — including freestanding targets, which have
    // no entry point for host programs. Examples and benchmarks are host
    // programs behind their own explicit steps.
    const lib = b.addLibrary(.{
        .name = "dot_parser",
        .linkage = .static,
        .root_module = mod,
    });
    b.installArtifact(lib);

    // Unit tests live beside the code they exercise and run via the module.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Public integration tests import only the "dot_parser" module, exactly
    // like an external consumer would.
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dot_parser", .module = mod },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run unit and public integration tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    // Example targets. `zig build examples` builds and runs them.
    const examples_step = b.step("examples", "Build and run the examples");
    const example_names = [_][]const u8{
        "parse_undigraph",
        "fixed_buffer",
        "diagnostics_demo",
    };
    for (example_names) |name| {
        const example = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "dot_parser", .module = mod },
                },
            }),
        });
        // Installed under the examples step only, so a freestanding
        // `zig build` never tries to link host executables.
        examples_step.dependOn(&b.addInstallArtifact(example, .{}).step);
        const run_example = b.addRunArtifact(example);
        examples_step.dependOn(&run_example.step);
    }

    // Throughput baseline (R-PERF-004). `zig build bench -Doptimize=ReleaseFast`.
    const bench_exe = b.addExecutable(.{
        .name = "throughput",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/throughput.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dot_parser", .module = mod },
            },
        }),
    });
    const bench_step = b.step("bench", "Run the throughput baseline");
    bench_step.dependOn(&b.addRunArtifact(bench_exe).step);
}
