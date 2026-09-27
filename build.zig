const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const support = b.createModule(.{
        .root_source_file = b.path("src/support.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The public library module. It must stay free of OS, filesystem, thread,
    // and network dependencies (R-PORT-001).
    const mod = b.addModule("dot_parser", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "parser_support", .module = support }},
    });

    // Independently importable: markup depends only on shared primitives, not DOT.
    const markup = b.addModule("markup_parser", .{
        .root_source_file = b.path("src/markup.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "parser_support", .module = support }},
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
    const markup_tests = b.addTest(.{ .root_module = markup });
    const run_markup_tests = b.addRunArtifact(markup_tests);
    test_step.dependOn(&run_markup_tests.step);
    const support_tests = b.addTest(.{ .root_module = support });
    test_step.dependOn(&b.addRunArtifact(support_tests).step);
    const markup_integration = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/markup.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "markup_parser", .module = markup }},
        }),
    });
    const markup_step = b.step("test-markup", "Test standalone markup without building DOT");
    const run_markup_integration = b.addRunArtifact(markup_integration);
    markup_step.dependOn(&run_markup_tests.step);
    markup_step.dependOn(&run_markup_integration.step);
    test_step.dependOn(&run_markup_integration.step);
    const both_parsers = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/parser_modules.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "dot_parser", .module = mod }, .{ .name = "markup_parser", .module = markup } },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(both_parsers).step);
    for ([_]struct { name: []const u8, message: []const u8 }{
        .{ .name = "markup_fixed_override", .message = "tests/compile_fail/markup_fixed_override.zig:3:72: error: no field named 'policy' in struct /?/" },
        .{ .name = "markup_unmetered", .message = "error: metering is disabled; use run()" },
    }) |fixture| {
        const rejected = b.addObject(.{
            .name = fixture.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tests/compile_fail/{s}.zig", .{fixture.name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "markup_parser", .module = markup }},
            }),
        });
        rejected.expect_errors = .{ .contains = fixture.message };
        test_step.dependOn(&rejected.step);
        markup_step.dependOn(&rejected.step);
    }

    // Public policy constraints must fail for actual consumers, not just pass
    // reflection checks in unit tests. Expected-error builds run with test.
    for ([_]struct { name: []const u8, message: []const u8 }{
        .{ .name = "fixed_policy_override", .message = "tests/compile_fail/fixed_policy_override.zig:3:36: error: no field named 'policy' in struct /?/" },
        .{ .name = "runtime_check_on_fixed_profile", .message = "error: unable to evaluate comptime expression" },
        .{ .name = "digraph_treatment", .message = "error: no field named 'treated_as' in struct 'dot.policy.Policy.Operators'" },
        .{ .name = "invalid_policy_mismatch", .message = "error: invalid policy: graph_operator_mismatch_not_applicable" },
        .{ .name = "invalid_policy_reading", .message = "error: invalid policy: graph_operator_reading_not_applicable" },
        .{ .name = "fixed_parse_override", .message = "tests/compile_fail/fixed_parse_override.zig:3:41: error: no field named 'policy' in struct /?/" },
        .{ .name = "unmetered_advance", .message = "error: metering is disabled; use run()" },
        .{ .name = "processor_fixed_override", .message = "tests/compile_fail/processor_fixed_override.zig:4:35: error: no field named 'policy' in struct /?/" },
        .{ .name = "processor_invalid_binding", .message = "error: configured processor profile must expose Policies" },
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
    const markup_example = b.addExecutable(.{
        .name = "markup",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/markup.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "markup_parser", .module = markup }},
        }),
    });
    examples_step.dependOn(&b.addRunArtifact(markup_example).step);
    examples_step.dependOn(&b.addInstallArtifact(markup_example, .{}).step);
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
    const markup_bench = b.addExecutable(.{
        .name = "markup_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/markup.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "markup_parser", .module = markup }},
        }),
    });
    b.step("bench-markup", "Benchmark standalone structural markup (decimal MB/s)").dependOn(&b.addRunArtifact(markup_bench).step);
    check_benches.dependOn(&markup_bench.step);
    for ([_]*std.Build.Step.Compile{ bench_exe, lexer_bench, session_bench, subgraph_bench, policy_bench }) |bench| {
        _ = bench.getEmittedBin();
        check_benches.dependOn(&bench.step);
    }

    const freestanding = b.step("check-freestanding", "Compile consumed session and policy profiles for RISC-V32 and Wasm32");
    for ([_]std.Target.Cpu.Arch{ .riscv32, .wasm32 }) |arch| {
        const portable_target = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .freestanding });
        const portable_support = b.createModule(.{
            .root_source_file = b.path("src/support.zig"),
            .target = portable_target,
            .optimize = .ReleaseSmall,
        });
        const portable = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = portable_target,
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "parser_support", .module = portable_support }},
        });
        const portable_markup = b.createModule(.{
            .root_source_file = b.path("src/markup.zig"),
            .target = portable_target,
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "parser_support", .module = portable_support }},
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
            const markup_probe = b.addObject(.{
                .name = b.fmt("markup_{s}_r{d}", .{ @tagName(arch), @intFromBool(runtime_policy) }),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("tests/freestanding_markup.zig"),
                    .target = portable_target,
                    .optimize = .ReleaseSmall,
                    .imports = &.{
                        .{ .name = "markup_parser", .module = portable_markup },
                        .{ .name = "policy_features", .module = options.createModule() },
                    },
                }),
            });
            _ = markup_probe.getEmittedBin();
            freestanding.dependOn(&markup_probe.step);
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
