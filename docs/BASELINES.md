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

## Throughput (parse + validate end-to-end, median of 9)

| Configuration | Median | Spread (min–max) | Throughput | Per statement |
| --- | --- | --- | --- | --- |
| Default (growing pools, arena) | 8.99 ms | 8.62–10.19 ms | 290 MiB/s | 45 ns |
| With `document_capacities` hints | 7.63 ms | 7.32–7.95 ms | 342 MiB/s | 38 ns |

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

| Artifact | Size |
| --- | --- |
| `diagnostics_demo`, ReleaseSmall, native macOS | 184 KB (includes Zig std startup and the console renderer) |

Command: `zig build examples -Doptimize=ReleaseSmall` (binaries land in
`zig-out/bin/`; the run output is printed as a side effect).

Freestanding library-size and RAM figures for the embedded profiles are
deferred until the compile-time profile work fixes a target configuration
(R-PORT-002 requires recording them once the board and build are chosen).

## Notes

- No optimization has been attempted (the plan forbids optimizing before
  baselines exist). Where time is actually spent is **unprofiled**; the
  guess that the lexer's byte loop dominates is a hypothesis to be tested
  with a profiler before any optimization work, not an established fact.
- Fuzzing note: on Zig 0.16.0 the verified fuzz invocation is
  `zig build -Doptimize=ReleaseFast test --fuzz=1000` (the Debug fuzz
  runner has a toolchain-side StackTrace type mismatch).
