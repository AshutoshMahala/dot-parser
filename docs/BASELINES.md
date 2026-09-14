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

## Internal grammar/event metering (2026-09-13)

On Zig 0.16.0 / aarch64-macOS, persistent parser-machine storage is 520 B for
ordinary parsing (unchanged), 592 B for metered parsing, and 616 B with test-only
independent audit counters. The 72 B optional increase includes scanner frontier,
cached token/action, phase and accepted-output counters. This is machine storage,
not whole-call peak stack. Ordinary pending-work/audit fields have type `void`.
No allocation, retained-document change, or event queue is added by this slice.

Sequential ReleaseFast smoke runs used the same staging path/cache before and
after, 2,733,345 source bytes and 200,000 statements. Each invocation reports a
median of nine rounds after two warm-ups; ranges below cover three invocations.

| Ordinary parse + validate | Before | After |
| --- | --- | --- |
| Default pools, reported median range | 12.98–13.19 ms | 11.91–13.95 ms |
| Capacity hints, reported median range | 11.40–11.60 ms | 11.34–11.95 ms |

These noisy, overlapping ranges do not establish a throughput improvement or a
zero-cost claim. Comparing the middle reported medians gives roughly 2% more
elapsed time for default pools and 4% for hints; treat that as a smoke signal,
not a stable regression estimate. Retention remains 6,800,000 B, with arena
backing capacities 37,620,470 B (default) / 8,400,148 B (hinted).

All 202 tests pass in Debug and ReleaseSafe; the five examples run. A consumed,
unaudited metered-parser probe using a counting sink compiles to object code
for RISC-V32 and Wasm32 freestanding. This is a compilation check, not a board
runtime, complete embedded memory measurement, or public bounded-session claim.
The hosted ReleaseSmall `diagnostics_demo` is 202,944 B in this build; it consumes
the ordinary parser, not the private metered specialization.

## Short-token entry specialization (2026-09-13)

Ordinary `Lexer.next()` now enters its known trivia state directly instead of
loading and dispatching a saved continuation on each token. It cannot suspend;
nonterminal completion always restores trivia. Metered scanners still resume
saved state. There is no second lexical grammar, new source read, bulk scan,
allocation, counter, or additional persistent field.

Reproduce lexical measurements with `zig build bench-lexer -Doptimize=ReleaseFast`.
The benchmark constructs sources outside the timer, scans without allocation,
and consumes tags, spans and positions through a checksum. Each fixture repeats
65,536 times. Same-path/cache sequential before/after batches on the environment
above produced these ranges of reported medians (three invocations per version;
each invocation has nine timed rounds after two warm-ups):

| Fixture | Source bytes | Before | After |
| --- | --- | --- | --- |
| Short IDs/punctuation | 1,114,112 | 15.27–15.49 ms | 8.06–8.48 ms |
| Short IDs/trivia | 983,040 | 5.36–5.51 ms | 5.12–6.01 ms |
| Keywords/numerals | 3,670,016 | 11.15–11.20 ms | 9.91–10.50 ms |
| Quotes/comments | 2,228,224 | 6.75–6.92 ms | 5.54–5.58 ms |
| Longer identifier (64-byte ID) | 4,259,840 | 6.87–7.12 ms | 7.40–7.41 ms |

Punctuation-heavy scanning takes roughly 47% less time comparing the middle
reported medians. This is **not** an across-the-board speedup: the longer-ID
fixture is about 5% slower by the same comparison, and trivia-heavy results
overlap. These are compiler/workload-specific smoke measurements, not portable
guarantees. Check all fixtures when revisiting code generation.

Two uncontended end-to-end benchmark invocations per version reported default
medians of 12.65–13.62 ms before / 12.29–12.59 ms after, and hinted medians of
10.98–11.83 ms before / 10.64–10.95 ms after. The spread is too large to attribute
a stable whole-parser improvement to this change.

Persistent state and retained-document memory are unchanged. Hosted ReleaseSmall
`diagnostics_demo` measures 202,912 B. All 204 tests pass in Debug and ReleaseSafe,
all five examples run, and consumed ordinary/metered parser probes compile for
RISC-V32 and Wasm32 freestanding. Tests explicitly check the ordinary entry
invariant and resuming a metered scanner through unbounded `next()`.

## Public fixed sessions and cancellation (2026-09-13)

`zig build bench-session -Doptimize=ReleaseFast` compares the four independently
selected execution combinations. The fixture is 200,000 `a;` node statements
(400,008 bytes); source and fixed pools are allocated outside the timer. Metered
variants advance in 256-credit calls. The cancellation fixture increments a poll
counter and never requests cancellation, so its callout cost is included here.
Two invocations, each with nine measured rounds after two warm-ups, reported:

| Metering | Cancellation | Native session | Native parser machine | Median range |
| --- | --- | --- | --- | --- |
| Off | Off | 936 B | 520 B | 5.06–5.52 ms |
| Off | On | 1,008 B | 592 B | 8.41–8.81 ms |
| On | Off | 1,008 B | 592 B | 6.86–7.21 ms |
| On | On | 1,032 B | 616 B | 8.45–8.86 ms |

Session storage includes its fixed builder and cached terminal result, but not
source, caller pools, diagnostic bag, hook context, or transient call stack.
The ordinary parser remains 520 B. Cancellation-only execution needs saved
token/action state for safe points, but has no metering/frontier counters.
Disabled hook fields have type `void`; the RISC-V object symbol table contains
the probe request predicate only in cancellation-enabled builds.

Cancellation is deliberately not free: it polls between individual lexical
examinations as well as grammar and dispatch steps. The current implementation
uses one-examination scanner calls for that path. Larger budgets cannot remove
this polling cost. Uncancellable sessions retain bulk scanner driving and
ordinary one-shot parsing retains its immediate fast path.

`zig build check-freestanding` emits eight consumed ReleaseSmall objects from
`tests/freestanding_session.zig`, one per architecture/feature combination:

| Metering / cancellation | RISC-V32 object | Wasm32 object |
| --- | --- | --- |
| Off / off | 17,852 B | 19,921 B |
| Off / on | 18,108 B | 20,641 B |
| On / off | 17,928 B | 20,756 B |
| On / on | 18,304 B | 21,088 B |

These are **object-file totals**, including metadata, relocations, probe code
and helper references, not linked firmware flash or peak RAM. RISC-V objects
still reference compiler memory helpers (`memcpy`/`memset`); the check does not
link a board runtime or execute hardware. The source contains no core clock,
thread, signal or atomic dependency.

The hosted ReleaseSmall diagnostics example is 202,880 B and the new bounded
example is 184,344 B; these select different renderer/runtime paths and are not
comparable core-size measurements. A one-shot end-to-end smoke run measured
12.17 ms default / 10.50 ms hinted versus 12.05 / 10.41 ms on the preceding
checkout at another build path. That comparison is within normal variation and
does not establish an ordinary-path regression or improvement.

All 215 tests pass in Debug and ReleaseSafe; all six examples run. Coverage
includes budget partitions, every lexical cancellation state, callback/diagnostic
failure precedence, commit precedence, zero-credit cleanup, movement between
calls, pool reuse/exhaustion, and megabyte inputs. No parser storage allocation
is introduced. The lexer implementation now lives in `lexer.zig`, with its
public namespace selected in `root.zig`.

## Identifier-only edge chains (2026-09-13)

Zig 0.16.0 / aarch64-macOS. Retained element sizes are regression-tested:
`StatementId` 8 B, ordinary `EdgeStatement` 36 B (unchanged),
`EdgeChainStatement` 44 B, and continuation `EdgeLink` 20 B. A chain of
N edges uses one owner, N-1 continuations and one order entry:
`52 + 20 * (N - 1)` bytes, excluding attributes and borrowed source.
There is no temporary chain list or eager expansion.

The ordinary parser machine is now 560 B, up from 520 B for the extra saved
continuation operator/span; its regression guard is 576 B. The new pool slices,
lengths and cached document metadata add fixed overhead even when chains are
unused. Pool elements allocate nothing when unused and unhinted.

`zig build bench-session -Doptimize=ReleaseFast` on the unchanged 200,000-node
fixture reported this single-run snapshot (not a chain-throughput benchmark):

| Metering | Cancellation | Session | Parser machine | Median |
| --- | --- | --- | --- | --- |
| Off | Off | 1,064 B | 560 B | 5.07 ms |
| Off | On | 1,136 B | 632 B | 8.73 ms |
| On | Off | 1,136 B | 632 B | 7.16 ms |
| On | On | 1,160 B | 656 B | 9.06 ms |

The ordinary parse+validate smoke benchmark retained 6,800,000 B
(34 B/statement), with arena backing capacities unchanged at 37,620,470 B
default and 8,400,148 B hinted. Sequential pre-slice / post-slice invocations
at different build paths measured 12.80 / 12.83 ms default and
10.98 / 11.31 ms hinted. These overlapping sample ranges do not establish a
speedup or regression. Edge traversal merges only the edge and chain pools,
not unrelated node/attribute records.

Verification: 227 tests in Debug and ReleaseSafe, seven runnable examples,
and eight consumed freestanding execution-profile builds. New coverage includes
4,096-edge chains, partition equivalence, cancellation boundaries, every chain
callback failure, typed pool/index exhaustion, allocation-failure injection,
truncated prefixes, generated chains and source-order validation. The
freestanding check remains a compile check, not an on-device measurement.

## Port syntax and compact references (2026-09-13)

`NodeReference` is 8 B; one `PortedReference` is 28 B. Native node/edge/link/chain
records remain 16/36/20/44 B. Bare input allocates no unhinted port pool, but the
document's new slice adds 16 B of metadata. Parser continuation grows from
560 to 720 B; the regression guard is 736 B. Pool metadata and the cached result
also grow the fixed session. Measured with `zig build bench-session
-Doptimize=ReleaseFast` on the same native Zig 0.16.0 host:

| Metering | Cancellation | Session | Driver |
| --- | --- | ---: | ---: |
| Off | Off | 1,264 B | 720 B |
| Off | On | 1,336 B | 792 B |
| On | Off | 1,336 B | 792 B |
| On | On | 1,360 B | 816 B |

The existing port-free 200k-statement benchmark still retains 6,800,000 B
(34 B/statement), with arena capacities 37,620,470 B default and 8,400,148 B
hinted. These are retained payload/backing-capacity measurements, not RSS.
Two local invocations per version of `zig build bench -Doptimize=ReleaseFast`
(2 warm-ups, 9 measured rounds each) gave the following ranges of medians:

| Port-free parse + validate | Before ports (`d60c936`) | Port slice |
| --- | ---: | ---: |
| Default pools | 12.87–13.00 ms | 14.41–14.86 ms |
| Capacity hints | 11.00–11.50 ms | 12.99–13.10 ms |

This small host-specific sample shows roughly 13–16% more elapsed time using
the midpoint of each range, not a zero-cost or universal performance claim.
Ordinary lookahead replay is iterative; a recursive-helper prototype was removed
after it showed additional overhead. Further hot-path tuning remains future work.

Port-heavy throughput and embedded runtime/stack measurements remain unmeasured;
the 8/28-byte payload tradeoff is explained in [ownership](OWNERSHIP.md#node-references-and-ports).

Verification: 241 tests (168 unit, 73 public integration), Debug and ReleaseSafe;
eight runnable examples and eight consumed riscv32/wasm32 execution-profile
objects. New coverage includes mixed inline/pooled fuzz input, long qualified
chains, all source prefixes, partition equivalence, callback/allocation failure
injection, cancellation at every work boundary, typed capacity failures and
pool reset. Freestanding compilation is not a hardware runtime or RAM-fit test.

## Standalone subgraphs (2026-09-13)

Native Zig 0.16.0 / aarch64-macOS measurements:

- `Subgraph`: 32 B, plus an 8 B global `StatementId`: **40 B/occurrence**.
- Nesting frame: 32 B per active level; fixed capacity uses reserved depth.
- Existing node/edge/link/chain records remain 16/36/20/44 B.
- No extra scope ID on each node or edge. The document gains one 16 B pool
  slice; builders/sessions also gain fixed metadata and scratch-stack state.
- Ordinary parser: 808 B, up from 720 B; regression guard: 832 B.

`zig build bench-session -Doptimize=ReleaseFast` reports:

| Metering | Cancellation | Session | Driver |
| --- | --- | ---: | ---: |
| Off | Off | 1,448 B | 808 B |
| Off | On | 1,520 B | 880 B |
| On | Off | 1,520 B | 880 B |
| On | On | 1,544 B | 904 B |

These sizes exclude source, output pools, diagnostic storage, and the frame
buffer itself. Flat syntax uses zero scratch frames and no unhinted scope pool,
but still pays metadata/grammar costs; compile-time syntax removal is not shipped.

The existing flat 200k-statement parse+validate fixture still retains 6,800,000 B
(34 B/statement). Arena backing capacity remains 37,620,470 B default /
8,400,148 B hinted. Two sequential local invocations per version (2 warm-ups,
9 timed rounds each) gave:

| Flat parse + validate | Before scopes (`de7ca0f`) | Standalone scopes |
| --- | ---: | ---: |
| Default pools, range of medians | 14.19–14.25 ms | 14.81–14.87 ms |
| Capacity hints, range of medians | 12.23–12.67 ms | 12.65–13.02 ms |

This small host sample suggests roughly 4% default / 3% hinted overhead using
range midpoints, with noise/overlapping individual rounds. It is not a universal
regression estimate or a claim of zero-cost syntax support.

`zig build bench-subgraphs -Doptimize=ReleaseFast` measures fixed-pool parsing
with caller storage/source construction outside timing. One invocation after
the final index checks (2 warm-ups, 9 measured rounds) reported:

| Empty scopes | Sibling median | Fully nested median | Retained payload | Sibling scratch | Nested scratch |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1,000 | 0.079 ms | 0.036 ms | 40,000 B | 32 B | 32,000 B |
| 10,000 | 0.347 ms | 0.371 ms | 400,000 B | 32 B | 320,000 B |
| 100,000 | 3.413 ms | 3.714 ms | 4,000,000 B | 32 B | 3,200,000 B |

The 100k measured ranges were 3.168–3.702 ms for siblings and 3.336–4.062 ms
for nesting. Small fixtures are noisy; these synthetic empty scopes are not a
representative attribute-heavy graph workload. Global traversal is checked
outside timing, not included in these parse medians. The explicit stack avoids
input-dependent call recursion even at 100k depth; this is a host test, not proof
that those buffers fit an embedded board.

Verification: 257 tests (171 unit, 86 public integration), Debug and ReleaseSafe;
nine runnable examples and eight consumed RISC-V32/Wasm32 profile objects.
Coverage includes all source prefixes, generated parent/child invariants, deep
nesting, sibling scratch reuse, allocation/callback failures, capacity/index
boundaries, cancellation at every work boundary, scratch reuse, and nested
validation order. Runtime/stack/flash measurements on an actual board remain open.

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
