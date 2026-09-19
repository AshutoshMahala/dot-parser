# Performance baselines

Initial baselines recorded at the close of milestone 1 (R-PERF-004),
**before any optimization work** — future performance changes are measured
against these numbers, not against intuition.

Historical sections retain their original measurements. For the latest comparison,
see [byte-offset spans and the scalar default](#byte-offset-spans-and-scalar-default-2026-09-19).

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

## Subgraph endpoints (2026-09-14)

Measured with Zig 0.16.0 on the same native 64-bit macOS host. This slice retains
subgraph syntax and mixed chains; it does not resolve membership or materialize
Cartesian edge products. Historical sections above describe their named snapshots.

| Native retained record | Bytes |
| --- | ---: |
| Node-only edge / chain / link | 36 / 44 / 20 (unchanged) |
| StatementId | 8 (unchanged) |
| Endpoint (by-value view) | 12 |
| Generalized owner (`ScopedEdgeStatement`) | 64 |
| Generalized continuation (`ScopedEdgeLink`) | 44 |
| Subgraph | 36 (was 32) |
| Temporary nesting frame | 272 (was 32) |

A node-only prefix stays in the original 20-byte link pool; promotion records a
range without copying it. A generalized owner uses one order entry; its endpoint
scopes do not each add an order entry. Standalone scopes still do. For example,
`a -> {b; c} -> d` retains 200 bytes of occupied pools, excluding source, metadata,
allocator slack and temporary scratch. It represents two syntactic edge operators,
not four expanded node-to-node edges.

The larger scratch frame preserves outer-edge continuation while nested bodies
parse. This is a real cost for all reserved nesting levels, even standalone-only
input. Flat input needs no frame backing allocation. Sequential siblings reuse
one frame; depth D requires D frames, without recursive calls.

| FixedSession profile: metering / cancellation | Session | Driver |
| --- | ---: | ---: |
| Off / Off | 1,560 B | 824 B |
| Off / On | 1,632 B | 896 B |
| On / Off | 1,632 B | 896 B |
| On / On | 1,656 B | 920 B |

Flat mixed node/edge parse+validate, 2,733,345 bytes / 200,000 statements,
ReleaseFast. Two serial invocations per revision, each with two warm-ups and nine
timed rounds; table gives the range of invocation medians, not confidence intervals.

| Pools | Before (`b187c6c`) | Endpoint implementation |
| --- | ---: | ---: |
| Default | 13.51–14.89 ms | 14.65–15.27 ms |
| Hinted | 13.03–13.10 ms | 13.47–13.50 ms |

These noisy local runs show some overhead, not evidence of a zero-cost syntax
extension. Retained occupied pools remain **6,800,000 bytes (34 B/statement)**;
backing arena capacity remains **37,620,470 B default / 8,400,148 B hinted**.
Unused generalized pools allocate no backing memory, but their metadata and the
wider traversal views have fixed costs. Compile-time syntax removal remains future
work. No large subgraph-product throughput claim is made by this flat fixture.

Reproduce with `zig build bench -Doptimize=ReleaseFast` and
`zig build bench-session -Doptimize=ReleaseFast`. The throughput harness prints
native endpoint/scratch layouts. Verification: 265 tests (171 unit, 94 public
integration), Debug and ReleaseSafe; ten runnable examples; eight consumed
RISC-V32/Wasm32 freestanding profile probes. Prefix partitioning, nested operator
ordering, long-prefix promotion, pool/OOM failures and boundary cancellation are
covered. These are compile probes, not MCU runtime measurements.

## Scanner backends and 32-bit positions (2026-09-18)

Fresh same-host measurements, not a comparison against old wall-clock timings:

- **0.2.0:** `84166eb`.
- **Main scalar / Main block:** `4fa9eee`, with the scanner backend explicitly
  selected. Native `auto` selects **block** on this target; this was checked
  through the normal build target.
- Host: native aarch64 macOS 27.0 (26A428), Zig 0.16.0, ReleaseFast for both the
  benchmark root and library module. The Environment section above is historical.
- Five invocations per revision/backend and fixture, each with two warm-ups and
  nine timed rounds. Revision order rotates between invocations. Compilation and
  tests finished before timing; benchmark processes ran sequentially.
- Cells below are **median of the five invocation medians**, followed by their
  **min–max range**, in milliseconds. These ranges are not confidence intervals.
  No CPU affinity or frequency controls were used; small differences remain noise.
- The checked-in fixtures, sizes, loops and timing boundaries are unchanged from
  0.2.0. Main adds backend selection and a printed backend label outside timing.
  All lexer checksums agree across revisions/backends and invocations.

### End-to-end parse and validation

`bench/throughput.zig`: 2,733,345 source bytes / 200,000 alternating node and
single-edge statements, default parse/validation policies. The hinted run
pre-reserves document pools. This is not a mixed-feature or malformed-input corpus.

| Document allocation | 0.2.0 | Main scalar | Main block |
| --- | ---: | ---: | ---: |
| default pools | 14.870 (14.250–15.090) | 13.830 (12.950–14.080) | 15.740 (15.540–16.060) |
| capacity hints | 13.270 (13.220–13.470) | 12.360 (12.110–12.560) | 14.140 (13.940–14.390) |

On this fixture, main block takes **13.8–14.4% more time than main scalar**. Its roughly 166 MiB/s default / 184 MiB/s hinted throughput is therefore
not a speedup here. Relative to 0.2.0, main block takes about 6% more time; main
scalar takes about 7% less. These are elapsed-time changes, not throughput-change
percentages.

### Fixed sessions

`bench/session.zig`: 200,000 `a;` statements, preallocated fixed pools;
construction/allocation excluded from timing. Metered calls use 256 credits.

**Metering** limits work per call: exhausting credits yields with state preserved
so the caller can resume. **Cancellation** enables cooperative stop checks: an
observed request terminates the parse as `.cancelled`, without publishing a
partial document; it cannot resume that parse. The two capabilities are independent.
Neither imposes a memory budget or wall-clock deadline. See [bounded execution](EXECUTION.md).

| Metering / cancellation | 0.2.0 | Main scalar | Main block |
| --- | ---: | ---: | ---: |
| metering false, cancellation false | 6.570 (6.250–6.600) | 5.530 (5.310–5.660) | 7.320 (7.110–7.500) |
| metering false, cancellation true | 9.440 (9.140–9.510) | 8.560 (8.240–8.670) | 9.290 (9.140–9.520) |
| metering true, cancellation false | 7.910 (7.850–8.000) | 7.440 (7.260–7.620) | 8.600 (8.410–8.700) |
| metering true, cancellation true | 9.530 (9.440–9.570) | 8.910 (8.520–9.080) | 9.040 (8.720–9.180) |

Block is not uniformly faster under metering: without cancellation this fixture
takes about **16% more time than main scalar**; with cancellation the median
difference is small and invocation ranges overlap. The ordinary block session
takes about **32% more time than main scalar**.

A credit is backend-specific: scalar examines a byte; block classifies a
64-byte block or performs a bounded within-block advance. Equal credit counts
do not imply equal source work, latency or cancellation granularity. In the
metered+cancellable fixture, polls are 1,405,484 for scalar and 1,217,247 for
block; fewer polls did not produce a clear elapsed-time win. This run did not
test one-credit calls or establish a general bounded-session speedup.

### Lexer fixtures

`bench/lexer.zig`: five repeated lexical patterns, source construction excluded.

| Lexical pattern | 0.2.0 | Main scalar | Main block |
| --- | ---: | ---: | ---: |
| short IDs/punctuation | 8.850 (8.740–8.960) | 12.180 (11.890–12.320) | 11.500 (11.410–11.600) |
| short IDs/trivia | 5.490 (5.420–5.660) | 4.860 (4.720–5.050) | 5.600 (5.370–5.740) |
| keywords/numerals | 10.620 (10.420–11.120) | 10.720 (10.320–10.810) | 11.970 (11.620–12.070) |
| quotes/comments | 5.680 (5.480–5.810) | 7.140 (6.580–7.290) | 8.030 (7.940–8.150) |
| long identifier | 7.700 (7.640–7.730) | 7.670 (7.050–7.870) | 3.790 (3.580–3.890) |

The clear block-scanner gain is **long identifiers: about 51% less time than
main scalar (approximately 2.0x throughput)**. The short-ID/punctuation fixture
improves by about 6% relative to main scalar, but both main backends remain slower
than 0.2.0 on that fixture. Short-ID/trivia, keywords/numerals
and quotes/comments take about 12–15% more time on block than main scalar.
The quotes/comments pattern combines short quoted tokens with short comments;
it is not a standalone long-comment parse benchmark.

The scalar short-ID/punctuation regression (8.850 → 12.180 ms relative to
0.2.0) also warrants attention; pinning scalar does not restore every old
microbenchmark result. Attribution to specific implementation details remains
unprofiled.

### Empty subgraph fixtures

`bench/subgraphs.zig`: fixed storage, empty sibling or fully nested scopes.
No endpoint products or semantic expansion are timed.

| Shape / scope count | 0.2.0 | Main scalar | Main block |
| --- | ---: | ---: | ---: |
| siblings, 1000 scopes | 0.056 (0.048–0.079) | 0.044 (0.043–0.050) | 0.042 (0.038–0.047) |
| siblings, 10000 scopes | 0.506 (0.495–0.542) | 0.441 (0.392–0.481) | 0.435 (0.412–0.469) |
| siblings, 100000 scopes | 5.659 (5.325–5.763) | 4.585 (4.553–4.779) | 4.455 (4.319–4.492) |
| nested, 1000 scopes | 0.055 (0.051–0.060) | 0.046 (0.041–0.054) | 0.040 (0.040–0.052) |
| nested, 10000 scopes | 0.578 (0.518–0.620) | 0.477 (0.445–0.516) | 0.466 (0.418–0.496) |
| nested, 100000 scopes | 5.905 (5.699–5.944) | 4.625 (4.472–4.910) | 4.605 (4.539–4.679) |

At 100,000 scopes, main scalar and block are close: roughly 0–3% median
differences, with overlapping invocation ranges. Both remain faster than 0.2.0,
but these measurements do not establish a material block-specific nesting win.

### Memory and scope of conclusions

- The flat fixture retains **6,800,000 bytes (34 B/statement)** in every version.
  Arena backing capacity is unchanged at **37,620,470 B default / 8,400,148 B
  hinted**; this is not process RSS.
- Retained record sizes remain `StatementId=8`, `NodeStatement=16`,
  `EdgeStatement=36`, `Endpoint=12`, `ScopedEdgeStatement=64`,
  `ScopedEdgeLink=44`, `Subgraph=36` bytes.
- The native nesting frame is **272 B in 0.2.0; 164 B in both main
  backends**. At 100,000 active levels, exact fixed scratch falls from 27.2 MB to
  16.4 MB (decimal), saving 10.8 MB; retained scope/statement payload stays 4.4 MB.
  This saving precedes block scanning. Growing-arena peaks for nested input
  were not measured in this run.
- Main block adds **104 B** to each session/driver relative to main scalar:

| Metering / cancellation | Main scalar session / driver | Main block session / driver |
| --- | ---: | ---: |
| Off / Off | 1,264 / 544 B | 1,368 / 648 B |
| Off / On | 1,312 / 592 B | 1,416 / 696 B |
| On / Off | 1,312 / 592 B | 1,416 / 696 B |
| On / On | 1,336 / 616 B | 1,440 / 720 B |

**Conclusion:** this is a workload-dependent backend trade-off, not a universal
improvement. Long-identifier scanning benefits; the default native backend
regresses the current short-token-heavy parse fixture. No default/backend/code
changes were made as part of this measurement. Invalid-input recovery, diagnostic
rendering, additional comment-heavy parse fixtures, code size and MCU runtime
performance are outside this run.

Verification: **302 tests** (200 unit, 102 public integration) pass in Debug and
ReleaseSafe; all eight consumed RISC-V32/Wasm32 freestanding profile checks pass.
Formatting and diff-whitespace checks also pass.

### Reproduction

For each main backend, run each target separately (do not run the four
benchmarks concurrently):

```sh
zig build bench -Doptimize=ReleaseFast -Dlexer=scalar
zig build bench-lexer -Doptimize=ReleaseFast -Dlexer=scalar
zig build bench-session -Doptimize=ReleaseFast -Dlexer=scalar
zig build bench-subgraphs -Doptimize=ReleaseFast -Dlexer=scalar
```

Repeat with `-Dlexer=block`. For 0.2.0, omit `-Dlexer`.
The recorded comparison compiled executables first and then invoked them
directly in rotating revision order, excluding compilation from measured runs.
A build-target smoke check confirmed native `-Dlexer=auto` selects block.

## Byte-offset spans and scalar default (2026-09-19)

Latest measured source: **`4c494b9`**; release reference: **0.2.0, `84166eb`**.
Scalar is now the default on every target; block scanning is opt-in. This section
supersedes the default-backend description in the dated September 18 snapshot,
which remains a historical measurement of `4fa9eee`.

### Method and comparison boundaries

- Native aarch64 macOS 27.0 (26A428), Zig 0.16.0; ReleaseFast explicitly selected
  for both benchmark root and library modules.
- Fresh builds from clean revision snapshots. All compilation and tests completed
  before timing. Five invocations per revision/backend/fixture, each with two
  warm-ups and nine measured rounds. Profiles rotate in order; executables run
  sequentially, with no concurrent benchmark or compiler processes from this run.
- Tables show **median of five invocation medians (min–max of those medians)**,
  in milliseconds. Ranges are not confidence intervals. No CPU affinity or
  frequency controls; small differences and overlapping ranges remain inconclusive.
- Throughput, session and subgraph fixture construction/timing are unchanged from
  0.2.0. Latest sources add backend selection and a label printed outside timing.
- **Lexer checksum normalization:** in a temporary 0.2.0 benchmark copy only,
  remove the additions of `token.span.start.line` and
  `token.span.start.byte_column` to `checksum`. Both revisions then checksum
  token tag, byte offset and byte length. Latest spells those fields
  `token.span.start` / `token.span.len`; 0.2.0 spells them
  `token.span.start.byte_offset` / `token.span.byte_len`. All resulting
  checksums match across revisions, backends and invocations. Lexer timings
  below are **not directly comparable** with the earlier, unnormalized tables.
  No library source or current benchmark source was modified.
- Latest scanning no longer maintains line/column positions per byte; spans
  contain byte offsets and lengths. Position derivation and diagnostic rendering
  are not timed here. This is a consumer-visible work-placement change, not a
  claim that every downstream task gets the same speedup.
- Fixtures contain valid ASCII input. This run does not measure the newly
  supported non-ASCII bare identifiers, malformed-input recovery, arbitrary
  callbacks, real-world corpora, code size or MCU runtime performance.
- Native `zig build bench -Doptimize=ReleaseFast -Dlexer=auto` was checked
  separately and reports `scalar`; its smoke-run timings are not pooled below.

### Parse and validate

`bench/throughput.zig`: 2,733,345 bytes / 200,000 alternating node and
single-edge statements. Default policies; document capacity hints in the second
row. Source construction is outside timing.

| Document allocation | 0.2.0 | `4c494b9` scalar | `4c494b9` block |
| --- | ---: | ---: | ---: |
| Default pools | 14.870 (14.380–15.270) | 12.260 (12.190–12.500) | 12.540 (12.080–12.660) |
| Capacity hints | 13.450 (13.180–13.570) | 10.680 (10.370–10.850) | 10.970 (10.680–11.210) |

The scalar default takes **17.6% less time with growing pools** and **20.6% less
with hints** than 0.2.0, approximately **213 / 244 MiB/s** respectively.
Block has about 2–3% higher medians than scalar here, but the invocation ranges
overlap; these runs do not establish a large end-to-end backend difference.

### Fixed sessions

`bench/session.zig`: 200,000 `a;` statements, fixed preallocated pools;
session construction and allocation excluded. Metered calls use 256 credits.

Metering pauses resumably when a per-call work budget is exhausted. Cancellation
cooperatively checks for a permanent stop request. They are independent; neither
is a memory budget or wall-clock deadline. Cancellation is enabled but never
requested in these benchmarks, so the measured cost is polling, not abort latency.

| Metering / cancellation | 0.2.0 | `4c494b9` scalar | `4c494b9` block |
| --- | ---: | ---: | ---: |
| metering false, cancellation false | 6.430 (6.380–6.560) | 5.000 (4.850–5.050) | 6.170 (5.990–6.520) |
| metering false, cancellation true | 9.530 (9.090–9.570) | 8.040 (7.880–8.250) | 7.580 (7.420–7.830) |
| metering true, cancellation false | 7.770 (7.720–7.870) | 6.920 (6.750–7.010) | 7.590 (7.390–7.820) |
| metering true, cancellation true | 9.520 (9.250–9.700) | 8.690 (8.540–8.870) | 7.850 (7.580–8.010) |

The ordinary scalar session takes about **22% less time than 0.2.0** and
**19% less than block**. Block is slower than scalar for metering without
cancellation, but faster in the two cancellation-enabled profiles on this
fixture (about 6% without metering and 10% with it). No blanket backend winner
is inferred.

Credits are backend-specific, so 256 credits does not mean identical source work
or cancellation granularity. Metered+cancellable polling counts remain
1,405,484 for scalar and 1,217,247 for block. One-credit calls were not measured.

### Lexer

`bench/lexer.zig`: the same five repeated byte patterns, with the normalized
checksum described above. No allocation/source construction inside the timer.

| Lexical pattern | 0.2.0 normalized | `4c494b9` scalar | `4c494b9` block |
| --- | ---: | ---: | ---: |
| short IDs/punctuation | 8.760 (8.640–9.160) | 9.220 (9.080–9.290) | 8.410 (8.140–8.780) |
| short IDs/trivia | 4.420 (4.350–4.770) | 4.410 (4.200–4.790) | 4.640 (4.480–4.760) |
| keywords/numerals | 9.830 (9.620–10.060) | 8.870 (8.440–8.930) | 8.780 (8.730–8.970) |
| quotes/comments | 6.810 (6.290–7.040) | 4.670 (4.450–4.920) | 7.410 (7.110–7.480) |
| long identifier | 7.710 (7.170–7.860) | 4.710 (4.470–4.840) | 3.400 (3.230–3.520) |

Main scalar improves keywords/numerals, quotes/comments and long identifiers
relative to the normalized release reference; short-ID/trivia is effectively
unchanged. Short-ID/punctuation has a roughly 5% higher scalar median, with
slightly overlapping invocation ranges.

Block's long-identifier fixture takes **28% less time than main scalar**
(about **1.39x throughput**), while its quotes/comments fixture takes **59% more
time**. Short-ID/punctuation favors block by about 9%; other small backend
differences should be read with their ranges. The quotes/comments pattern mixes
short quotes and short comments; it is not a long-comment-only parsing benchmark.

### Subgraphs

`bench/subgraphs.zig`: fixed storage, empty sibling or fully nested scopes;
the 100,000-scope cases are summarized here.

| Shape / scope count | 0.2.0 | `4c494b9` scalar | `4c494b9` block |
| --- | ---: | ---: | ---: |
| siblings, 100000 scopes | 5.712 (5.539–5.874) | 3.951 (3.791–3.993) | 4.082 (3.945–4.206) |
| nested, 100000 scopes | 5.708 (5.622–6.048) | 3.917 (3.778–3.983) | 4.068 (3.923–4.183) |

Scalar takes about **31% less time than 0.2.0** for both shapes. Scalar/block
medians differ by roughly 3–4%, with overlapping invocation ranges; no strong
backend-specific nesting conclusion is drawn.

### Memory

Retained data is unchanged: the flat fixture occupies **6,800,000 bytes
(34 B/statement)**. Arena backing capacity is **37,620,470 B default /
8,400,148 B hinted** in all profiles. This includes growth slack/copies and is
not process RSS.

Retained record sizes remain `StatementId=8`, `NodeStatement=16`,
`EdgeStatement=36`, `Endpoint=12`, `ScopedEdgeStatement=64`,
`ScopedEdgeLink=44`, `Subgraph=36` bytes.

The native temporary nesting frame is **116 B** for both current backends,
versus **272 B in 0.2.0** (57% smaller). At 100,000 active nesting levels,
exact fixed scratch is **11.6 MB versus 27.2 MB**, saving **15.6 MB** (decimal).
Retained scope/statement payload remains 4.4 MB. These are fixed-storage figures,
not growing-arena peaks.

| Metering / cancellation | Scalar session / driver | Block session / driver |
| --- | ---: | ---: |
| Off / Off | 1,080 / 368 B | 1,176 / 464 B |
| Off / On | 1,120 / 408 B | 1,216 / 504 B |
| On / Off | 1,120 / 408 B | 1,216 / 504 B |
| On / On | 1,144 / 432 B | 1,240 / 528 B |

Block costs **96 B** more fixed session/driver state in each profile. The
ordinary scalar session is 31% smaller than 0.2.0's 1,560 B session.

### Verification and reproduction

**309 tests** (204 unit, 105 public integration) pass in Debug and ReleaseSafe.
All eight consumed RISC-V32/Wasm32 freestanding profile compile checks pass,
as do formatting and diff-whitespace checks. These are compile probes, not
embedded runtime benchmarks.

Run each command separately for each backend; do not execute benchmark targets
concurrently:

```sh
zig build bench -Doptimize=ReleaseFast -Dlexer=scalar
zig build bench-lexer -Doptimize=ReleaseFast -Dlexer=scalar
zig build bench-session -Doptimize=ReleaseFast -Dlexer=scalar
zig build bench-subgraphs -Doptimize=ReleaseFast -Dlexer=scalar
```

Repeat with `-Dlexer=block`. For 0.2.0 omit `-Dlexer` and normalize only
the lexer benchmark checksum as described above. For repeated comparisons,
compile first, then run binaries directly in rotating revision/backend order.
Historical wall-clock numbers are not substituted for fresh release runs.
Raw timing dumps are intentionally not committed.
