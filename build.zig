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

    // Public policy constraints must fail for actual consumers, not just pass
    // reflection checks in unit tests. Expected-error builds run with test.
    for ([_]struct { name: []const u8, message: []const u8 }{
        .{ .name = "fixed_policy_override", .message = "tests/compile_fail/fixed_policy_override.zig:3:36: error: no field named 'policy' in struct /?/" },
        .{ .name = "runtime_check_on_fixed_profile", .message = "error: unable to evaluate comptime expression" },
        .{ .name = "digraph_treatment", .message = "error: no field named 'treated_as' in struct 'policy.Policy.Operators'" },
        .{ .name = "invalid_policy_mismatch", .message = "error: invalid policy: graph_operator_mismatch_not_applicable" },
        .{ .name = "invalid_policy_reading", .message = "error: invalid policy: graph_operator_reading_not_applicable" },
        .{ .name = "fixed_parse_override", .message = "tests/compile_fail/fixed_parse_override.zig:3:41: error: no field named 'policy' in struct /?/" },
        .{ .name = "unmetered_advance", .message = "error: metering is disabled; use run()" },
    }) |fixture| {
        const rejected = b.addObject(.{
            .name = fixture.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tests/compile_fail/{s}.zig", .{fixture.name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "dot_parser", .module = mod }},
            }),
        });
        rejected.expect_errors = .{ .contains = fixture.message };
        test_step.dependOn(&rejected.step);
    }

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
        "policies",
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

    // Benches pin Policy.scanner (`auto` uses the scalar default). The library
    // module itself carries no build option or root-file configuration hook.
    const lexer_choice = b.option([]const u8, "lexer", "Scanner backend for the benches: auto (default), scalar, or block") orelse "auto";
    const bench_options = b.addOptions();
    bench_options.addOption([]const u8, "lexer", lexer_choice);
    const bench_options_module = bench_options.createModule();

    // Throughput baseline (R-PERF-004). `zig build bench -Doptimize=ReleaseFast`.
    const bench_exe = b.addExecutable(.{
        .name = "throughput",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/throughput.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dot_parser", .module = mod },
                .{ .name = "build_options", .module = bench_options_module },
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
            .imports = &.{
                .{ .name = "dot_parser", .module = mod },
                .{ .name = "build_options", .module = bench_options_module },
            },
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
            .imports = &.{
                .{ .name = "dot_parser", .module = mod },
                .{ .name = "build_options", .module = bench_options_module },
            },
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
            .imports = &.{
                .{ .name = "dot_parser", .module = mod },
                .{ .name = "build_options", .module = bench_options_module },
            },
        }),
    });
    b.step("bench-subgraphs", "Measure sibling and nested scope parsing")
        .dependOn(&b.addRunArtifact(subgraph_bench).step);

    const policy_bench = b.addExecutable(.{
        .name = "policy_throughput",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/policies.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "dot_parser", .module = mod }},
        }),
    });
    b.step("bench-policy", "Compare fixed/runtime policy costs on the standard benchmark machine")
        .dependOn(&b.addRunArtifact(policy_bench).step);
    const check_benches = b.step("check-benches", "Compile benchmarks without updating or running baselines");
    for ([_]*std.Build.Step.Compile{ bench_exe, lexer_bench, session_bench, subgraph_bench, policy_bench }) |bench| {
        _ = bench.getEmittedBin();
        check_benches.dependOn(&bench.step);
    }

    const freestanding = b.step("check-freestanding", "Compile consumed session and policy profiles for RISC-V32 and Wasm32");
    for ([_]std.Target.Cpu.Arch{ .riscv32, .wasm32 }) |arch| {
        const portable_target = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .freestanding });
        const portable = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = portable_target,
            .optimize = .ReleaseSmall,
        });
        for ([_]bool{ false, true }) |runtime_policy| {
            const options = b.addOptions();
            options.addOption(bool, "runtime_policy", runtime_policy);
            const probe = b.addObject(.{
                .name = b.fmt("policy_{s}_r{d}", .{ @tagName(arch), @intFromBool(runtime_policy) }),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/freestanding_policy.zig"),
                    .target = portable_target,
                    .optimize = .ReleaseSmall,
                    .imports = &.{
                        .{ .name = "dot_parser", .module = portable },
                        .{ .name = "policy_features", .module = options.createModule() },
                    },
                }),
            });
            _ = probe.getEmittedBin();
            freestanding.dependOn(&probe.step);
        }
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
