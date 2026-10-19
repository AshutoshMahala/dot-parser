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

    const strings = b.addModule("string_processor", .{
        .root_source_file = b.path("src/string.zig"),
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
    const check_tools = b.step("check-tools", "Test and compile the offline Zig Unicode generators");
    const unicode_data = b.option([]const u8, "unicode-data", "Local Unicode 17.0.0 UCD directory for read-only regeneration checks");
    const check_unicode = b.step("check-unicode", "Compare regenerated tables with checked-in files (-Dunicode-data=UCD)");
    for ([_]struct { name: []const u8, source: []const u8, inputs: []const []const u8, output: []const u8 }{
        .{ .name = "generate-console-widths", .source = "tools/generate_console_widths.zig", .inputs = &.{ "EastAsianWidth.txt", "extracted/DerivedGeneralCategory.txt" }, .output = "src/common/console_widths.zig" },
        .{ .name = "generate-string-casefold", .source = "tools/generate_string_casefold.zig", .inputs = &.{"CaseFolding.txt"}, .output = "src/string/casefold.zig" },
    }) |generator| {
        const tool = b.addExecutable(.{ .name = generator.name, .root_module = b.createModule(.{
            .root_source_file = b.path(generator.source),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }) });
        check_tools.dependOn(&tool.step);
        const tests = b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(generator.source),
            .target = b.graph.host,
            .optimize = optimize,
        }) }));
        check_tools.dependOn(&tests.step);
        test_step.dependOn(&tests.step);
        const generate = b.addRunArtifact(tool);
        if (b.args) |args| generate.addArgs(args);
        generate.has_side_effects = true; // Explicit stdout operation, never a cached no-op.
        b.step(generator.name, "Generate pinned Unicode Zig source on stdout; pass local input paths after --")
            .dependOn(&generate.step);
        if (unicode_data) |directory| {
            const verify = b.addRunArtifact(tool);
            for (generator.inputs) |input| verify.addFileArg(.{ .cwd_relative = b.pathJoin(&.{ directory, input }) });
            if (generator.inputs.len == 2) verify.addFileArg(b.path("src/string/UNICODE_LICENSE.txt"));
            verify.addArg("--check");
            verify.addFileArg(b.path(generator.output));
            check_unicode.dependOn(&verify.step);
        }
    }
    if (unicode_data == null) check_unicode.dependOn(&b.addFail("check-unicode requires -Dunicode-data=/path/to/Unicode-17.0.0/ucd; no data is downloaded by the build").step);
    const string_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/string.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "string_processor", .module = strings }},
    }) });
    const run_string_tests = b.addRunArtifact(string_tests);
    const string_step = b.step("test-string", "Test the standalone string processor");
    const string_unit = b.addRunArtifact(b.addTest(.{ .root_module = strings }));
    string_step.dependOn(&string_unit.step);
    test_step.dependOn(&string_unit.step);
    string_step.dependOn(&run_string_tests.step);
    test_step.dependOn(&run_string_tests.step);
    for ([_]struct { name: []const u8, message: []const u8 }{
        .{ .name = "string_folding_disabled", .message = "invalid policy: unicode_folding_disabled" },
        .{ .name = "string_invalid_pattern", .message = "invalid policy: invalid_pattern_encoding" },
        .{ .name = "string_unknown_setting", .message = "unknown string policy field: typo" },
        .{ .name = "string_comparison_contract", .message = "validator must opt into uses_comparison" },
        .{ .name = "string_unmetered", .message = "advance requires execution.metering" },
        .{ .name = "string_sync_metering", .message = "invalid policy: non_resumable_validator" },
        .{ .name = "string_cancellation_interval", .message = "invalid policy: invalid_cancellation_interval" },
        .{ .name = "string_step_comparison", .message = "resumable validators must use equalsStep" },
    }) |fixture| {
        const rejected = b.addObject(.{ .name = fixture.name, .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("tests/compile_fail/{s}.zig", .{fixture.name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "string_processor", .module = strings }},
        }) });
        rejected.expect_errors = .{ .contains = fixture.message };
        string_step.dependOn(&rejected.step);
        test_step.dependOn(&rejected.step);
    }
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
    // Assertion failures terminate a process, not a normal Zig test. Never run
    // corrupt-representation probes with runtime safety disabled.
    if (optimize == .Debug or optimize == .ReleaseSafe) {
        const invariants = b.addExecutable(.{
            .name = "markup-invariants",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/markup_invariants.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "markup_parser", .module = markup }},
            }),
        });
        for (0..8) |case| {
            const probe = b.addRunArtifact(invariants);
            probe.addArg(b.fmt("{d}", .{case}));
            probe.expectExitCode(0);
            test_step.dependOn(&probe.step);
            markup_step.dependOn(&probe.step);
        }
    }
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
        .{ .name = "markup_cancellation_interval", .message = "error: invalid policy: invalid_cancellation_interval" },
        .{ .name = "markup_duplicate_diagnostic", .message = "error: duplicate diagnostic identity" },
        .{ .name = "markup_invalid_diagnostic", .message = "error: invalid diagnostic registry metadata" },
        .{ .name = "markup_extended_mode", .message = "has no member named 'extended'" },
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
        .{ .name = "diagnostic_limit", .message = "type 'u16' cannot represent integer value '65536'" },
        .{ .name = "fixed_policy_override", .message = "tests/compile_fail/fixed_policy_override.zig:3:36: error: no field named 'policy' in struct /?/" },
        .{ .name = "runtime_check_on_fixed_profile", .message = "error: unable to evaluate comptime expression" },
        .{ .name = "digraph_treatment", .message = "error: no field named 'treated_as' in struct 'dot.policy.Policy.Operators'" },
        .{ .name = "invalid_policy_mismatch", .message = "error: invalid policy: graph_operator_mismatch_not_applicable" },
        .{ .name = "invalid_policy_reading", .message = "error: invalid policy: graph_operator_reading_not_applicable" },
        .{ .name = "cancellation_interval", .message = "error: invalid policy: invalid_cancellation_interval" },
        .{ .name = "markup_processor_required", .message = "error: invalid policy: markup_processor_required" },
        .{ .name = "fixed_parse_override", .message = "tests/compile_fail/fixed_parse_override.zig:3:41: error: no field named 'policy' in struct /?/" },
        .{ .name = "unmetered_advance", .message = "error: metering is disabled; use run()" },
        .{ .name = "processor_fixed_override", .message = "tests/compile_fail/processor_fixed_override.zig:4:35: error: no field named 'policy' in struct /?/" },
        .{ .name = "processor_invalid_binding", .message = "error: configured processor profile must expose Policies" },
        .{ .name = "processor_invalid_infallible_schema", .message = "error: infallible policy schema must declare a valid-only Check" },
        .{ .name = "processor_infallible_union_schema", .message = "error: infallible policy schema must declare a valid-only Check" },
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
    const partial_example = b.addExecutable(.{
        .name = "markup_partial",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/markup_partial.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "markup_parser", .module = markup }},
        }),
    });
    examples_step.dependOn(&b.addRunArtifact(partial_example).step);
    examples_step.dependOn(&b.addInstallArtifact(partial_example, .{}).step);
    const graphviz_example = b.addExecutable(.{
        .name = "graphviz_vocabulary",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/graphviz_vocabulary.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "markup_parser", .module = markup }},
        }),
    });
    examples_step.dependOn(&b.addRunArtifact(graphviz_example).step);
    examples_step.dependOn(&b.addInstallArtifact(graphviz_example, .{}).step);
    const delayed_example = b.addExecutable(.{
        .name = "delayed_markup",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/delayed_markup.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "dot_parser", .module = mod }, .{ .name = "markup_parser", .module = markup } },
        }),
    });
    examples_step.dependOn(&b.addRunArtifact(delayed_example).step);
    examples_step.dependOn(&b.addInstallArtifact(delayed_example, .{}).step);
    const composed_example = b.addExecutable(.{
        .name = "composed_markup",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/composed_markup.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "dot_parser", .module = mod }, .{ .name = "markup_parser", .module = markup } },
        }),
    });
    examples_step.dependOn(&b.addRunArtifact(composed_example).step);
    examples_step.dependOn(&b.addInstallArtifact(composed_example, .{}).step);
    const editor_example = b.addExecutable(.{
        .name = "partial_documents",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/partial_documents.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "dot_parser", .module = mod }, .{ .name = "markup_parser", .module = markup } },
        }),
    });
    examples_step.dependOn(&b.addRunArtifact(editor_example).step);
    examples_step.dependOn(&b.addInstallArtifact(editor_example, .{}).step);
    const attached_example = b.addExecutable(.{
        .name = "attached_markup",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/attached_markup.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "dot_parser", .module = mod }, .{ .name = "markup_parser", .module = markup } },
        }),
    });
    examples_step.dependOn(&b.addRunArtifact(attached_example).step);
    examples_step.dependOn(&b.addInstallArtifact(attached_example, .{}).step);
    const custom_processor_example = b.addExecutable(.{
        .name = "custom_processor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/custom_processor.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "dot_parser", .module = mod }, .{ .name = "markup_parser", .module = markup } },
        }),
    });
    examples_step.dependOn(&b.addRunArtifact(custom_processor_example).step);
    examples_step.dependOn(&b.addInstallArtifact(custom_processor_example, .{}).step);
    const string_example = b.addExecutable(.{ .name = "string_processor", .root_module = b.createModule(.{
        .root_source_file = b.path("examples/string_processor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "string_processor", .module = strings }},
    }) });
    examples_step.dependOn(&b.addRunArtifact(string_example).step);
    examples_step.dependOn(&b.addInstallArtifact(string_example, .{}).step);
    const example_names = [_][]const u8{
        "quick_start",
        "parse_undigraph",
        "fixed_buffer",
        "diagnostics_demo",
        "identifiers",
        "comments",
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

    const cancellation_bench = b.addExecutable(.{
        .name = "cancellation_intervals",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/cancellation.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "dot_parser", .module = mod }, .{ .name = "markup_parser", .module = markup } },
        }),
    });
    b.step("bench-cancellation", "Compare cancellation intervals for both parsers")
        .dependOn(&b.addRunArtifact(cancellation_bench).step);

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
    const run_markup_bench = b.addRunArtifact(markup_bench);
    if (b.args) |args| run_markup_bench.addArgs(args);
    b.step("bench-markup", "Benchmark standalone structural markup (decimal MB/s)").dependOn(&run_markup_bench.step);
    check_benches.dependOn(&markup_bench.step);
    const string_bench = b.addExecutable(.{ .name = "string_bench", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/string.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "string_processor", .module = strings }},
    }) });
    b.step("bench-string", "Measure standalone exact/folding and custom string checks")
        .dependOn(&b.addRunArtifact(string_bench).step);
    check_benches.dependOn(&string_bench.step);
    const string_sessions_bench = b.addExecutable(.{ .name = "string_sessions_bench", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/string_sessions.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "string_processor", .module = strings }},
    }) });
    b.step("bench-string-sessions", "Measure opt-in string metering and cancellation")
        .dependOn(&b.addRunArtifact(string_sessions_bench).step);
    check_benches.dependOn(&string_sessions_bench.step);
    const string_sizes = b.step("string-size-probes", "Install consumed exact/folding/predicate Wasm size probes");
    const wasm_check = b.addSystemCommand(&.{"node"});
    wasm_check.addFileArg(b.path("tools/check_string_sizes.mjs"));
    const check_wasm = b.step("check-wasm", "Execute consumed Wasm exports and check optional Unicode table retention (requires Node)");
    check_wasm.dependOn(&wasm_check.step);
    for ([_][]const u8{ "exact", "folding", "predicate" }) |variant| {
        const wasm = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
        const shared = b.createModule(.{ .root_source_file = b.path("src/support.zig"), .target = wasm, .optimize = .ReleaseSmall });
        const text = b.createModule(.{ .root_source_file = b.path("src/string.zig"), .target = wasm, .optimize = .ReleaseSmall, .imports = &.{.{ .name = "parser_support", .module = shared }} });
        const features = b.addOptions();
        features.addOption(bool, "folding", !std.mem.eql(u8, variant, "exact"));
        features.addOption(bool, "predicate", std.mem.eql(u8, variant, "predicate"));
        const probe = b.addExecutable(.{ .name = b.fmt("string_{s}", .{variant}), .root_module = b.createModule(.{
            .root_source_file = b.path("tests/freestanding_string.zig"),
            .target = wasm,
            .optimize = .ReleaseSmall,
            .strip = true,
            .imports = &.{ .{ .name = "string_processor", .module = text }, .{ .name = "string_features", .module = features.createModule() } },
        }) });
        probe.entry = .disabled;
        probe.rdynamic = true;
        string_sizes.dependOn(&b.addInstallArtifact(probe, .{}).step);
        wasm_check.addArtifactArg(probe);
    }
    const composition_bench = b.addExecutable(.{
        .name = "composition_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/composition.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "dot_parser", .module = mod }, .{ .name = "markup_parser", .module = markup } },
        }),
    });
    b.step("bench-composition", "Measure composed throughput, allocation calls and peak requested bytes")
        .dependOn(&b.addRunArtifact(composition_bench).step);
    check_benches.dependOn(&composition_bench.step);
    for ([_]*std.Build.Step.Compile{ bench_exe, lexer_bench, session_bench, cancellation_bench, subgraph_bench, policy_bench }) |bench| {
        _ = bench.getEmittedBin();
        check_benches.dependOn(&bench.step);
    }

    const freestanding = b.step("check-freestanding", "Compile consumed session and policy profiles for RISC-V32 and Wasm32");
    const check = b.step("check", "Run tests, examples, tool/benchmark/portable checks and Wasm execution (requires Node)");
    for ([_]*std.Build.Step{ test_step, examples_step, check_tools, check_benches, freestanding, check_wasm }) |step| check.dependOn(step);
    if (unicode_data != null) check.dependOn(check_unicode);
    for ([_]std.Target.Cpu.Arch{ .riscv32, .wasm32 }) |arch| {
        const portable_target = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .freestanding });
        const portable_support = b.createModule(.{
            .root_source_file = b.path("src/support.zig"),
            .target = portable_target,
            .optimize = .ReleaseSmall,
        });
        const portable_strings = b.createModule(.{
            .root_source_file = b.path("src/string.zig"),
            .target = portable_target,
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "parser_support", .module = portable_support }},
        });
        const string_session_probe = b.addObject(.{ .name = b.fmt("string_session_{s}", .{@tagName(arch)}), .root_module = b.createModule(.{
            .root_source_file = b.path("tests/freestanding_string_session.zig"),
            .target = portable_target,
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "string_processor", .module = portable_strings }},
        }) });
        _ = string_session_probe.getEmittedBin();
        freestanding.dependOn(&string_session_probe.step);
        for ([_]bool{ false, true }) |folding| {
            const features = b.addOptions();
            features.addOption(bool, "folding", folding);
            const probe = b.addObject(.{ .name = b.fmt("string_{s}_{s}", .{ @tagName(arch), if (folding) "folding" else "exact" }), .root_module = b.createModule(.{
                .root_source_file = b.path("tests/freestanding_string.zig"),
                .target = portable_target,
                .optimize = .ReleaseSmall,
                .imports = &.{ .{ .name = "string_processor", .module = portable_strings }, .{ .name = "string_features", .module = features.createModule() } },
            }) });
            _ = probe.getEmittedBin();
            freestanding.dependOn(&probe.step);
        }
        const reporting_probe = b.addObject(.{
            .name = b.fmt("reporting_{s}", .{@tagName(arch)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/freestanding_reporting.zig"),
                .target = portable_target,
                .optimize = .ReleaseSmall,
                .imports = &.{.{ .name = "parser_support", .module = portable_support }},
            }),
        });
        _ = reporting_probe.getEmittedBin();
        freestanding.dependOn(&reporting_probe.step);
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
        const console_probe = b.addObject(.{
            .name = b.fmt("console_{s}", .{@tagName(arch)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/freestanding_console.zig"),
                .target = portable_target,
                .optimize = .ReleaseSmall,
                .imports = &.{.{ .name = "markup_parser", .module = portable_markup }},
            }),
        });
        _ = console_probe.getEmittedBin();
        freestanding.dependOn(&console_probe.step);
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
