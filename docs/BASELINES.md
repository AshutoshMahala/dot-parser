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
`d48ae20`; the slice-2 numbers were recorded 2026-07-18 at commit
`32d6838` (the `0.1.0` code). **Cross-run
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

The following table is the historical slice-2 snapshot; current attribute-slice
costs are recorded immediately below it.

| Metric | Value |
| --- | --- |
| Retained document | 26.0 bytes/statement (5.2 MB for 200k statements) |
| Element sizes | `StatementId` 8 B, `NodeStatement` 8 B, `EdgeStatement` 28 B |
| Arena backing capacity, default | ~23 MB |
| Arena backing capacity, capacity hints | ~10 MB |
| Fixed pools (`parseBorrowedIn`) | exactly the declared capacity; zero allocation |
| Parser state | ≤ 320 B constant at slice 2 (then guarded by a unit test) |

Note on the arena figures: `ArenaAllocator.queryCapacity()` reports the
arena's **backing capacity** — it includes copies left behind by pool
growth and the arena's own block-sizing policy. It is neither the live
document size nor process RSS. The gap between the two configurations is
growth slack; general allocators reclaim it, fixed pools never create it.

### Attribute-slice measurements (2026-09-12)

The tables above remain historical baselines. On the same 200k-statement
attribute-free workload, one before/after smoke run measured:

| Configuration | Before (identifiers) | After (attributes) |
| --- | --- | --- |
| Default median | 9.50 ms / 274 MiB/s | 11.13 ms / 234 MiB/s |
| Hinted median | 8.37 ms / 312 MiB/s | 9.38 ms / 278 MiB/s |
| Retained bytes | 5,200,000 (26/statement) | 6,800,000 (34/statement) |
| Default arena backing capacity | 23,146,328 | 37,620,470 |
| Hinted arena backing capacity | 10,200,148 | 8,400,148 |

This run indicates a roughly 11–15% throughput cost; it is not a dedicated
performance gate or an attribute-heavy workload measurement. Arena block
sizing is nonlinear: the lower hinted backing capacity does **not** mean lower
retained memory. Do not generalize those arena figures to RSS or all allocators.

Attribute-slice native layout: StatementId 8 B, NodeStatement 16 B, EdgeStatement
36 B, Attribute/Assignment 16 B, AttributeStatement 20 B. Parser state was
400 B on aarch64-macOS, then guarded at ≤416 B. It remains independent of source
length, list length, and group count. Attribute pools are unused on this
workload, but every node/edge retains an 8-byte attribute range. Compile-time
profile removal and target-specific budgets remain future work.

### Resumable-lexer measurements (2026-09-12)

This is the initial resumable-scanner snapshot, before the driver cleanup below.

Same native toolchain and 200k-statement workload, before/after smoke runs
using the ordinary, **unmetered** public parser. Each number is the median of
nine rounds after two warm-ups, not a dedicated performance gate:

| Configuration | Before | Resumable scanner |
| --- | --- | --- |
| Default | 10.76 ms / 242 MiB/s (9.89–11.25 ms) | 13.92 ms / 187 MiB/s (13.05–15.10 ms) |
| Capacity hints | 9.35 ms / 279 MiB/s (8.68–9.67 ms) | 12.50 ms / 208 MiB/s (11.53–13.31 ms) |
| Ordinary lexer state | 48 B | 168 B |
| Whole parser state | 400 B | 520 B (guarded at ≤536 B) |
| `diagnostics_demo`, ReleaseSmall, native | 202,496 B | 202,944 B |

This is roughly a **23–25% throughput regression** (29–34% more elapsed time)
on this workload, larger than the historical noise band. An earlier before
run measured 235/290 MiB/s; a preceding after run measured 184/207 MiB/s.
The shared continuation machinery is not free merely because counters compile
out. Investigate this cost before extending the bounded driver; no acceptable
overhead threshold has been settled yet.

The internal metered scanner is 176 B native (+8 B for `source_frontier`);
its remaining-credit counter is call-local. Test-only independent examination
instrumentation adds another 8 B and is absent in both production specializations.
The 120 B persistent parser-state increase is constant, not per statement or
per yielded call. These layout sizes do not measure peak stack usage.
Retained document memory (34 B/statement on this workload), arena backing
capacities and fixed-pool requirements are unchanged.

The binary comparison is a consumed hosted example, **not** an isolated core
size or an enabled-vs-disabled metering comparison. Public examples do not
consume the private bounded fixture. Consumed ordinary and bounded scanner
probes compiled for `riscv32-freestanding-none` and `wasm32-freestanding-none`;
this verifies scanner compilation, not board runtime, peak stack, or whole-parser
boundedness. Full enabled/disabled driver benchmarks await the driver slice.

### Driver cleanup (2026-09-12)

The scanner now uses an explicit transient completion tag and constructs the
completed result at one shared exit, outside the compile-time-expanded state
branches. Work accounting, public outcomes and saved continuation behavior are
unchanged. The completion tag is never saved across a yield.

Validation used the same staging source location and cache for both versions,
with the existing 200k-statement benchmark. These are ranges of the reported
medians from three invocations per version; each invocation uses two warm-ups
and nine measured rounds:

| Configuration | Initial resumable driver | After cleanup |
| --- | --- | --- |
| Default parse + validate | 13.79–14.31 ms | 12.63–13.36 ms |
| Capacity-hinted parse + validate | 12.09–12.67 ms | 11.12–11.63 ms |

Comparing the middle reported median gives roughly 7–10% less elapsed time.
Earlier investigation runs found approximately 9–10%. These remain smoke
measurements, not a guarantee: build-location/cache runs showed additional
absolute variation, so compare like-for-like builds. The cleanup does not
fully recover the previous whole-token lexer's throughput; short-token and
trivia paths still need focused work before extending the bounded driver.

In an aarch64-macOS ReleaseFast lexer-only checksum consumer, optimized LLVM IR
showed repeated `Result` temporaries in the expanded state branches. The
observed driver stack frame (including its saved registers) fell from 1,664 B
to 240 B after cleanup. This is one function frame in that consumed build, not
whole-parser peak stack or an embedded-target RAM measurement. A common exit
alone reduced the frame to 256 B but recovered little speed; stack reduction
does not by itself explain the throughput change.

Persistent state remains 168 B for the ordinary lexer, 176 B for the metered
lexer, and 520 B for the native parser. Retained documents, arena capacities,
and fixed-pool requirements are unchanged. The hosted ReleaseSmall
`diagnostics_demo` measured 202,832 B after cleanup versus 202,944 B before it.
All 194 tests pass in Debug and ReleaseSafe, all five examples run, and consumed
ordinary/metered scanner probes compile for RISC-V32 and Wasm32 freestanding.

## Binary size

The figures in this section are the historical post-renderer snapshot; newer
consumed-example measurements appear in the slice-specific tables above.

`diagnostics_demo` is a hosted example, not a measurement of the parser
core. On Zig 0.16.0 / aarch64-macOS at ReleaseSmall it occupied
201,392 bytes (196.7 KiB; 184 KB at milestone 1, before the
excerpt-renderer overhaul). A substantial portion is the hosted runtime
selected by its full `std.process.Init` entry point, which initializes
allocator, environment, preopen, and threaded-I/O facilities. The
remaining incremental size cannot be attributed solely to the parser: it
includes parsing, validation, the console renderer, diagnostic catalogs,
example control flow, and any standard-library paths made reachable by
them.

`libdot_parser.a` measured 2,312 bytes (native) / 788 bytes
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

- Initial baselines preceded optimization. The resumable-lexer slice includes
  measured loop/return-value bookkeeping adjustments, but time attribution
  remains **unprofiled**. Do not treat a suspected byte-loop bottleneck as an
  established explanation for the remaining throughput cost.
- Fuzzing note: on Zig 0.16.0 the verified fuzz invocation is
  `zig build -Doptimize=ReleaseFast test --fuzz=1000` (the Debug fuzz
  runner has a toolchain-side StackTrace type mismatch).
