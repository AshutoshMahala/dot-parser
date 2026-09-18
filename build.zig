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
        "identifiers",
        "attributes",
        "bounded",
        "edge_chains",
        "ports",
        "subgraphs",
        "subgraph_endpoints",
        "check_file",
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

    const lexer_bench = b.addExecutable(.{
        .name = "lexer_throughput",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/lexer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "dot_parser", .module = mod }},
        }),
    });
    b.step("bench-lexer", "Run lexical throughput fixtures")
        .dependOn(&b.addRunArtifact(lexer_bench).step);

    const session_bench = b.addExecutable(.{
        .name = "session_throughput",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/session.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "dot_parser", .module = mod }},
        }),
    });
    b.step("bench-session", "Compare fixed-session execution policies")
        .dependOn(&b.addRunArtifact(session_bench).step);

    const subgraph_bench = b.addExecutable(.{
        .name = "subgraph_throughput",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/subgraphs.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "dot_parser", .module = mod }},
        }),
    });
    b.step("bench-subgraphs", "Measure sibling and nested scope parsing")
        .dependOn(&b.addRunArtifact(subgraph_bench).step);

    const freestanding = b.step("check-freestanding", "Compile consumed session profiles for RISC-V32 and Wasm32");
    for ([_]std.Target.Cpu.Arch{ .riscv32, .wasm32 }) |arch| {
        const portable_target = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .freestanding });
        const portable = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = portable_target,
            .optimize = .ReleaseSmall,
        });
        for ([_]bool{ false, true }) |metering| {
            for ([_]bool{ false, true }) |cancellation| {
                const options = b.addOptions();
                options.addOption(bool, "metering", metering);
                options.addOption(bool, "cancellation", cancellation);
                const probe = b.addObject(.{
                    .name = b.fmt("session_{s}_m{d}_c{d}", .{ @tagName(arch), @intFromBool(metering), @intFromBool(cancellation) }),
                    .root_module = b.createModule(.{
                        .root_source_file = b.path("tests/freestanding_session.zig"),
                        .target = portable_target,
                        .optimize = .ReleaseSmall,
                        .imports = &.{
                            .{ .name = "dot_parser", .module = portable },
                            .{ .name = "execution_features", .module = options.createModule() },
                        },
                    }),
                });
                // Force object emission, not just semantic analysis of exports.
                _ = probe.getEmittedBin();
                freestanding.dependOn(&probe.step);
            }
        }
    }
}
