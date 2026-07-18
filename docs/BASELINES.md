# Performance baselines

Initial baselines recorded at the close of milestone 1 (R-PERF-004),
**before any optimization work** — future performance changes are measured
against these numbers, not against intuition.

## Environment

| | |
| --- | --- |
| Chip | Apple M2 Ultra, 64 GiB RAM |
| OS | macOS 26.5.2 (Darwin 25) |
| Toolchain | Zig 0.16.0 (Homebrew) |
| Workload | synthesized milestone-grammar document, 200 000 statements (~2.6 MiB), alternating node and edge statements |
| Method | 2 warm-up rounds, 9 measured rounds, **median** reported with min–max spread |
| Command | `zig build bench -Doptimize=ReleaseFast` |

These are manually recorded reference measurements, not CI gates: CI
runners are too noisy for regression gating without dedicated hardware.
Revisit that decision if stable benchmark hardware becomes available.

Provenance: the milestone-1 numbers were recorded 2026-07-17 at commit
`d48ae20`; the slice-2 numbers were recorded 2026-07-18 on the pre-tag
`0.1.0` working tree (stamp the commit hash when tagging). **Cross-run
medians on this machine vary by roughly ±8%** even with the warm-up/median
methodology — repeated same-day runs have produced 281–304 MiB/s default
and 333–356 MiB/s hinted. Treat a fresh measurement inside that band as
noise, not as a regression or improvement.

## Throughput (parse + validate end-to-end, median of 9)

| Configuration | Median | Spread (min–max) | Throughput | Per statement |
| --- | --- | --- | --- | --- |
| Default (growing pools, arena) | 8.99 ms | 8.62–10.19 ms | 290 MiB/s | 45 ns |
| With `document_capacities` hints | 7.63 ms | 7.32–7.95 ms | 342 MiB/s | 38 ns |

Re-measured after slice 2 (directed documents: 6-keyword lexer table, 9
parser states, header metadata; same workload document):

| Configuration | Median | Spread (min–max) | Throughput | Per statement |
| --- | --- | --- | --- | --- |
| Default (growing pools, arena) | 8.59 ms | 7.83–9.98 ms | 304 MiB/s | 43 ns |
| With `document_capacities` hints | 7.32 ms | 7.01–7.61 ms | 356 MiB/s | 37 ns |

Within run-to-run noise of the milestone-1 numbers: the grammar growth is
not measurable on this workload. Memory figures below are unchanged by
slice 2 (re-verified: 26.0 B/statement retained, same arena capacities).

## Memory

| Metric | Value |
| --- | --- |
| Retained document | 26.0 bytes/statement (5.2 MB for 200k statements) |
| Element sizes | `StatementId` 8 B, `NodeStatement` 8 B, `EdgeStatement` 28 B |
| Arena backing capacity, default | ~23 MB |
| Arena backing capacity, capacity hints | ~10 MB |
| Fixed pools (`parseBorrowedIn`) | exactly the declared capacity; zero allocation |
| Parser state | ≤ 320 B constant (regression-guarded by a unit test) |

Note on the arena figures: `ArenaAllocator.queryCapacity()` reports the
arena's **backing capacity** — it includes copies left behind by pool
growth and the arena's own block-sizing policy. It is neither the live
document size nor process RSS. The gap between the two configurations is
growth slack; general allocators reclaim it, fixed pools never create it.

## Binary size

`diagnostics_demo` is a hosted example, not a measurement of the parser
core. On Zig 0.16.0 / aarch64-macOS at ReleaseSmall it occupies
201,392 bytes (196.7 KiB; 184 KB at milestone 1, before the
excerpt-renderer overhaul). A substantial portion is the hosted runtime
selected by its full `std.process.Init` entry point, which initializes
allocator, environment, preopen, and threaded-I/O facilities. The
remaining incremental size cannot be attributed solely to the parser: it
includes parsing, validation, the console renderer, diagnostic catalogs,
example control flow, and any standard-library paths made reachable by
them.

`libdot_parser.a` measures 2,312 bytes (native) / 788 bytes
(riscv32-freestanding) because the library exports no eagerly
materialized ABI roots — the archive holds only a symbol table and a
near-empty object file. This is packaging metadata, not a measurement of
consumed parser code: Zig compiles lazily, and code materializes in the
*consumer's* compilation when it references the module.

Command: `zig build examples -Doptimize=ReleaseSmall` (binaries land in
`zig-out/bin/`; the run output is printed as a side effect).

Meaningful embedded size measurements require a freestanding executable
that calls a specific parser profile with a concrete entry point, storage
policy, and diagnostic sink — deferred until the compile-time profile
work fixes a target configuration (R-PORT-002 records those figures once
the board and build are chosen).

## Notes

- No optimization has been attempted (the plan forbids optimizing before
  baselines exist). Where time is actually spent is **unprofiled**; the
  guess that the lexer's byte loop dominates is a hypothesis to be tested
  with a profiler before any optimization work, not an established fact.
- Fuzzing note: on Zig 0.16.0 the verified fuzz invocation is
  `zig build -Doptimize=ReleaseFast test --fuzz=1000` (the Debug fuzz
  runner has a toolchain-side StackTrace type mismatch).
