# Performance

How fast the parsers are and how much memory they use. Everything here was
measured for 0.5.0 on 2026-10-12, at commit `2ea1311`, except where a section
says otherwise. Measurements use one machine and made-up test files. Use the
numbers as a rough guide: your files, hardware and settings will give different
results.
[How these were measured](#how-these-were-measured) has the details.

The development toolchain is now Zig 0.17.0. Tables labelled Zig 0.16.0 are
historical measurements, not claims about 0.17 performance. Current build
commands use `fast`, `safe` and `small` (previously `ReleaseFast`,
`ReleaseSafe` and `ReleaseSmall`). Re-measure with the same compiler on both
sides when comparing revisions.

Reading the tables:

- **MB** means 1,000,000 bytes, and **MB/s** means MB per second.
- A timing cell like `7.85 / 348.2` means **7.85 ms, which is 348.2 MB/s**.
  Both numbers describe the same run.
- **Fast** and **Safe** mean `ReleaseFast` and `ReleaseSafe` builds.

## At a glance

- **DOT:** parsing and validating a 2.7 MB file takes 7.9 ms (about 350 MB/s)
  in a Fast build, or 6.8 ms (about 400 MB/s) with size hints.
- **Memory:** the document takes about 34 bytes per statement, and your source
  is never copied. With an arena, size hints cut the memory for that file from
  37.6 MB to 8.4 MB.
- **Scanners:** the default scalar scanner is faster end to end. The block
  scanner wins on long runs of plain text.
- **Small steps:** with both metering and cancel checks on, parsing takes about
  1.6 times as long.
- **Markup:** about 300 to 430 MB/s for markup full of tags and attributes, and
  much faster for mostly plain text. These are structural-mode parsing numbers.
  Checking Graphviz tag and attribute names afterwards ran at about 1,700 MB/s
  on the test labels.
- **Labels in DOT:** a file with 1,000 small labels is parsed and checked at
  about 150 MB/s, with only 7 allocations (labels in structural mode).

## Document-to-IR topology (Unreleased, 2026-10-21)

First production baseline, not a comparison against a shipped IR. Apple M4 Pro,
Zig 0.17.0; `zig build bench-ir -Doptimize=ReleaseFast` and `ReleaseSafe`.
Nine timed samples after two warmups, median shown. Parsing/source construction
and destruction are outside lowering timing. Allocations during lowering are
included; this uses the process general-purpose allocator.

| Workload | Source bytes | Fast ms / MB/s | Safe ms / MB/s |
| --- | ---: | ---: | ---: |
| 10,000 singleton connections | 127,794 | 1.960 / 65.2 | 1.923 / 66.5 |
| 10,000 three-member set connections | 148,900 | 2.558 / 58.2 | 2.796 / 53.3 |
| 1,000 reopened scope connections | 21,900 | 0.163 / 134.3 | 0.182 / 120.5 |
| 10,000 nesting levels, one connection | 20,015 | 0.301 / 66.6 | 0.464 / 43.1 |
| 50,000 × 50,000 symbolic product | 688,906 | 5.412 / 127.3 | 7.069 / 97.5 |

The last row retains **100,000 nodes and one connection**, not 2.5 billion
edges. Materialization is deliberately not requested for it. Explicit Fast
materialization took 0.178 ms for 10,000 singleton edges, 0.215 ms for 30,000
small-set edges, and 2.822 ms for the reopened case's 500,500 edge occurrences.
These are synthetic baseline measurements; small timing differences are not
claims about one optimization mode always winning.

| Workload | Retained MB | Peak requested MB, Fast / Safe | Arena capacity MB (Fast) |
| --- | ---: | ---: | ---: |
| Singleton connections | 1.662 | 1.671 / 1.671 | 2.402 |
| Three-member sets | 3.386 | 3.565 / 3.565 | 9.689 |
| Reopened scopes | 0.218 | 0.223 / 0.223 | 0.414 |
| Deep nesting | 0.693 | 1.136 / 1.136 | 1.907 |
| Symbolic product | 8.901 | 8.901 / 10.313 | 27.399 |

Retained bytes include pool capacity. Requested peaks include temporary scratch
and old/new growth overlap; allocator resize success can change that overlap.
Neither is RSS, and both exclude the already-built Document and borrowed source.
The separate arena measurement includes reserved chunks and unreclaimed growth
buffers: **arena usage is not claimed to equal retained payload**. Deep ordinary
nesting uses 16-byte continuation frames instead of reserving an edge-sized
frame for every scope.

Unused-feature check against `8615e9f`: generated ReleaseFast assembly was
byte-identical for both `bench/identifiers.zig` (event-only parsing/indexing) and
`examples/quick_start.zig` (retained parsing/validation). No existing parser,
metering or cancellation implementation changed. IR itself has one-shot work
limits and cooperative cancellation, not resumable sessions.

Correctness checks include 16 focused tests in Debug/ReleaseSafe, allocation
failure injection, a generated eager-set oracle, and 200 existing Graphviz
16.0.0 reference graphs: all 95,033 materialized edge occurrences agreed.
See [IR coverage and costs](IR.md); effective attributes/defaults are not yet
part of these measurements.

### Streaming edge consumption (2026-10-21)

Same machine/toolchain, ReleaseFast. Five alternating process runs against
`5c36bd3`, each reporting the median of nine timed samples after two warmups;
the table uses the median of those five reports. Expansion includes scratch
and output allocation, but excludes parsing, lowering, consumer output/I/O
and destruction. `zig build bench-ir -Doptimize=ReleaseFast` now reports both
owning and streaming expansion, including their requested allocation peaks.

| Workload | Emitted edges | Materialize before ms | Materialize now ms | Stream ms | Materialize peak bytes | Stream peak bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Singleton connections | 10,000 | 0.123 | 0.078 | 0.086 | 323,072 | 0 |
| Three-member sets | 30,000 | 0.197 | 0.173 | 0.215 | 1,131,936 | 40,144 |
| Reopened scopes | 500,500 | 2.768 | 2.594 | 3.157 | 18,672,020 | 11,036 |
| Strict reopened scopes | 1,000 | — | 2.989 | 2.902 | 44,292 | 33,564 |
| First 1,000 of the 50,000 × 50,000 product | 1,000 | — | — | 0.395 | — | 1,096,892 |

Streaming avoids the output array; it is not inherently faster. Pull calls and
per-visited-pair limit checks have costs. The strict row still visits 500,500
candidate pairs and retains deduplication keys for 1,000 unique edges. It was
added to the benchmark here, so no earlier number is shown in this comparison.
The product row stops after 1,000 edges: it enumerates both endpoint sets but
does **not** visit the other 2,499,999,000 pairs. These are operation-requested
peaks, excluding the IR, source, consumer storage, allocator overhead and RSS.

The owning path shares traversal with streaming without retaining duplicate
output/key arrays. Its existing workloads did not regress in this run. Default
quick-start ReleaseFast code/data remained identical to `5c36bd3` after
excluding debug/source-location metadata; parser metering and cancellation
implementations were untouched. Thirty focused IR tests pass in Debug,
ReleaseSafe and ReleaseFast, including allocation failures, early cleanup,
cumulative limits, cancellation, strict overlap and an independent eager oracle.

### Effective attributes and defaults (2026-10-22)

Apple M4 Pro, Zig 0.17.0, against `08537a9`. Five alternating process runs
per configuration; each reports the median of nine samples after two warmups.
The tables use the median of those five reports. Parsing, source generation,
output and destruction are outside lowering time. Reproduce the topology and
attribute reports together with:

```sh
zig build bench-ir -Doptimize=ReleaseFast
zig build bench-ir -Doptimize=ReleaseSafe
```

**This is additional semantic work:** the baseline retained raw attributes but
could not answer effective-value queries. The new lowering interns keys,
captures creation defaults and folds node/graph updates into shared immutable
maps. It still does not expand edge products or copy source strings.

| Attribute workload | Fast raw-only ms | Fast effective ms | Safe raw-only ms | Safe effective ms |
| --- | ---: | ---: | ---: | ---: |
| 64 defaults shared by 10,000 nodes | 0.470 | 0.476 | 0.656 | 0.722 |
| 10,000 nodes, two keys then one update each | 0.848 | 1.696 | 1.154 | 2.329 |
| 1,000 reopened scopes with changing defaults | 0.165 | 0.254 | 0.233 | 0.346 |
| 10,000 nested scopes sharing defaults | 0.285 | 0.319 | 0.439 | 0.509 |
| 50,000 × 50,000 symbolic product with defaults | 5.123 | 5.228 | 6.416 | 6.512 |

Memory below is decimal MB, measured in ReleaseFast. Each pair is baseline →
effective-attribute implementation. Requested payload/peaks exclude source,
Document storage, stack frames, allocator metadata and RSS. Arena capacity is
measured separately; its growth boundaries can move in either direction.

| Workload | Retained MB | Requested peak MB | Arena capacity MB |
| --- | ---: | ---: | ---: |
| Shared defaults | 0.944 → 0.959 | 1.051 → 1.065 | 2.679 → 2.636 |
| Node updates | 1.764 → 3.072 | 1.925 → 3.444 | 4.375 → 8.742 |
| Reopened defaults | 0.309 → 0.420 | 0.353 → 0.464 | 0.851 → 1.659 |
| Deep defaults | 0.693 → 0.973 | 1.136 → 1.416 | 1.907 → 2.133 |
| Symbolic product | 8.900684 → 8.901156 | 10.313012 → 10.313484 | 27.399 → 27.399 |

The symbolic product adds **472 retained bytes**, not 2.5 billion attribute
records. Conversely, repeated per-node updates retain path-copied map cells:
that workload's roughly doubled lowering time and increased memory are real
costs, not claimed improvements. `max_attribute_states`, work and allocation
limits bound this construction.

Repeated hot-key queries, excluding name lookup, expansion and value rendering,
take 10–16 ns for nodes and 20–23 ns for non-strict edges in ReleaseFast;
ReleaseSafe takes 13–18 ns and 24–28 ns respectively. A strict edge query over
1,000 reopened contributions takes **8.66 µs / 9.01 µs** (Fast/Safe). Queries
allocate nothing, but strict queries scan contributions: repeated per-edge
queries are not a bulk attribute materializer.

**Attribute-free costs:** all six existing topology workloads retain exactly
the same requested heap payload, peaks and arena capacities as the baseline.
The measured 64-bit node record remains 24 bytes. Lowering timings:

| Workload | Fast before → after ms | Safe before → after ms |
| --- | ---: | ---: |
| Singleton connections | 1.046 → 1.033 | 1.306 → 1.351 |
| Three-member sets | 1.982 → 2.026 | 2.512 → 2.688 |
| Reopened scopes | 0.143 → 0.141 | 0.169 → 0.175 |
| Strict reopened scopes | 0.136 → 0.143 | 0.171 → 0.178 |
| Deep nesting | 0.285 → 0.272 | 0.430 → 0.447 |
| Symbolic product | 5.084 → 5.174 | 6.568 → 6.580 |

This is **not a blanket zero-regression claim for optional IR execution**.
Expansion remains sensitive to code generation despite unchanged heap use.
The iterator now retains only its applicable limits and inlines its shared
engine into the error-state wrapper; budgets, polling and terminal-error
behavior are unchanged. The remaining expansion movements include:

| Expansion | Fast before → after ms | Safe before → after ms |
| --- | ---: | ---: |
| Materialize 10,000 singleton edges | 0.071 → 0.075 | 0.128 → 0.141 |
| Stream 10,000 singleton edges | 0.080 → 0.086 | 0.091 → 0.099 |
| Stream 30,000 set edges | 0.211 → 0.214 | 0.249 → 0.269 |
| Stream 500,500 reopened-scope edges | 3.024 → 3.289 | 3.869 → 3.724 |
| Stream 1,000 strict reopened-scope edges | 2.770 → 2.688 | 2.883 → 2.952 |
| Stream first 1,000 product edges | 0.374 → 0.383 | 0.347 → 0.362 |

Ordinary DOT parsing does not use this layer: default quick-start ReleaseFast
code/data is identical to `08537a9` after excluding debug/source-location
metadata. No parser metering/cancellation implementation changed. Verification
adds allocation-failure and mid-operation cancellation checks, native values,
512-key persistent-map stress, 10,000 nested scopes, a symbolic product under
a small memory/state cap, and 48 generated graphs compared with an independent
eager attribute oracle. See [IR contracts and remaining work](IR.md).

### Borrowed component views and attribute iteration (2026-10-22)

Compared with the working effective-attribute implementation immediately before
adding views (not the raw-only `08537a9` baseline above), on the same machine
and toolchain, using five alternating runs and nine-sample medians. `bench-ir`
now includes view lookups, whole-attribute iteration and iterator scratch.

All twelve topology/attribute workloads have **identical retained heap,
lowering peak and arena capacity** before/after. Default-parser ReleaseFast
code/data and topology-benchmark ReleaseFast/ReleaseSafe code/data are identical
after excluding debug/source-location metadata. Existing topology timing
variation therefore does not indicate a view-induced change to that code.
Parser metering/cancellation implementations are untouched.

Views aren't a claim of free result wrapping: a hot node lookup measured about
13–16 ns through a view versus 11–16 ns directly in ReleaseFast; non-strict edge
lookups measured 23–25 ns through a view versus 20–23 ns directly. Neither
allocates. Full iteration includes initialization, preparation, consuming every
entry and cleanup, but excludes key/value formatting and edge expansion:

| Effective attributes consumed | Fast | Safe | Peak scratch |
| --- | ---: | ---: | ---: |
| Node with 64 defaults | 630 ns | 810 ns | 0 B |
| Node with two updated keys | 28 ns | 33 ns | 0 B |
| Non-strict edge with one written key | 30 ns | 32 ns | 0 B |
| Strict edge, 1,000 reopened contributions, inherited key | 8.42 µs | 8.24 µs | 0 B |
| Strict edge, 1,000 explicit updates, 33 effective keys | 11.73 µs | 12.88 µs | 396 B |
| One edge of the 50,000 × 50,000 product, two keys | 36 ns | 44 ns | 0 B |

Strict merging scans symbolic contributions once per attribute iterator and
uses 12 bytes per distinct edge key, not per update or expanded pair. Returned
entries borrow the IR, not that scratch. These costs are optional and separate
from the retained graph. This is still not a bulk attribute index across all
edges. The 54 focused IR tests pass in Debug, ReleaseFast and ReleaseSafe,
including native Unicode keys/values, terminal stops, allocation failures and
iteration checked against both direct queries and the eager attribute oracle.

## Attribute string integration (Unreleased)

Measured on 2026-10-19 against `fb64cc9`, Apple M4 Pro, Zig 0.16.0. The same
[`bench/string_integration.zig`](../bench/string_integration.zig) was compiled
for both snapshots. Five alternating process runs per side; each uses nine
timed batches after three warmups. Source construction is excluded; host
parsing, validation, allocation and disposal are included. Diagnostics are
discarded.

### Unused-feature cost

Profiles with no active string route—including a bound string processor with
passthrough handling—resolve to the original host profile type. Tests assert
this identity. The isolated `host-defaults` executables had **identical machine
code sections and identical executable sizes** before/after in all three modes:

| Mode | Executable bytes, before / after | Geometric mean time change, 8 fixtures |
| --- | ---: | ---: |
| ReleaseFast | 353,872 / 353,872 | +0.06% |
| ReleaseSafe | 386,784 / 386,784 | +0.95% |
| ReleaseSmall | 257,328 / 257,328 | −2.74% |

These timings still contain noise: the long DOT case varied substantially
despite identical generated code. No isolated default case crossed the report's
5% slowdown threshold with non-overlapping run ranges. This supports an
unchanged default path, not a universal timing guarantee.

The original mixed `integration` binary also included active processing, so
its code layout and optimization decisions differ from the older default-only
binary. Its default rows changed by −0.11% / +4.04% / +19.98% in Fast / Safe /
Small; the last result included two flagged DOT slowdowns. Those samples remain
in the report, but this mixed comparison does not isolate unused-feature cost.
The follow-up below addresses the DOT mixed-profile regression. Applications
compiling both active and inactive variants should still measure their own
combination, especially with ReleaseSmall.

### Enabled processing cost

Each document below contains 2,000 selected `label` values and 2,000 untouched
attributes. The selected child checks logical encoding and exact equality.
Markup uses structural mode. These ReleaseFast cells show **ms / MB/s** for
whole-document operations in the initial candidate binary:

| Host / value | Physical bytes | Bound passthrough | Process equality |
| --- | ---: | ---: | ---: |
| DOT / `Seattle` | 60,007 | 0.158 / 379.6 | 0.727 / 82.5 |
| DOT / quoted concatenation | 74,007 | 0.164 / 451.0 | 0.847 / 87.3 |
| DOT / Unicode | 84,007 | 0.160 / 525.4 | 1.167 / 72.0 |
| DOT / long ASCII values | 4,654,007 | 1.685 / 2,761.3 | 85.856 / 54.2 |
| Markup / `Seattle` | 66,013 | 0.139 / 476.5 | 0.527 / 125.2 |
| Markup / reference decoding | 66,013 | 0.151 / 437.7 | 0.510 / 129.5 |
| Markup / Unicode | 100,013 | 0.188 / 532.3 | 1.143 / 87.5 |
| Markup / long ASCII values | 4,660,013 | 2.426 / 1,921.2 | 80.942 / 57.6 |

These are the initial integration measurements, before the optimization below.
That version used scalar reader-bound steps throughout. Active logical checks
are still **not free** and can traverse a value again for each check, but unchanged
ASCII runs can now batch equivalent steps. None of this work runs for passthrough.

Allocation probes verify identical allocator-request counts and cumulative
requested bytes for default, passthrough and processing on every fixture.
All DOT fixtures used 3 allocations / 147,632 cumulative requested bytes;
all markup fixtures used 4 / 138,228.
Routing and built-in string checks allocate no extra heap storage or decoded
copy. They do add fixed-size aggregate/cursor state. This is not a peak-stack
or process-RSS measurement; retained diagnostics and custom callbacks have
their own costs.

A separate standalone comparison covered 54 native and 84 session cases per
mode: aggregate time changes ranged from −0.59% to +0.40%, with no changed
session sizes, metering credits or cancellation-poll counts.

Reproduce the host study with one command:

```sh
zig build perf-string -- --baseline fb64cc9 \
  --suites host-defaults,integration \
  --modes ReleaseFast,ReleaseSafe,ReleaseSmall --runs 5
```

Use `--suites native,sessions` for the standalone study, and `logical` for
explicit reader-bound sessions; all five suites can share one report.
`zig build bench-string-integration -Doptimize=ReleaseFast`
also prints allocator-request totals. See [string integration](STRINGS.md#attribute-processing-in-dot-and-markup)
for precedence, scheduling and partial-result semantics.

### Reader-bound processing follow-up (2026-10-20)

Compared against `b58db00` with Zig 0.16.0 on the same ARM64 Mac. Three
alternating process runs per side; the integration harness and accounting
method above are unchanged. Each long-ASCII document contains 2,000 checked
values: 4,654,007 source bytes for DOT and 4,660,013 for markup.

| Mode / host | Before ms / MB/s | After ms / MB/s |
| --- | ---: | ---: |
| ReleaseFast / DOT | 82.731 / 56.25 | 8.226 / 565.76 |
| ReleaseFast / markup | 79.920 / 58.31 | 6.548 / 711.68 |
| ReleaseSafe / DOT | 93.026 / 50.03 | 9.597 / 484.93 |
| ReleaseSafe / markup | 88.529 / 52.64 | 7.932 / 587.49 |
| ReleaseSmall / DOT | 200.408 / 23.22 | 13.173 / 353.30 |
| ReleaseSmall / markup | 206.417 / 22.58 | 11.761 / 396.21 |

The logical prerequisite and equality passes now group 16 unchanged ASCII
steps. They retain the original credits and do not cross a budget, cancellation
poll, decoding boundary or terminal transition. References, escapes, folding
expansions and short values still use scalar work. Only the encoding-reader
leaf is forced inline; the larger state machines remain independently compiled.

The mixed-profile ReleaseSmall regression also had a separate cause: routing
called the public, input-validating identifier iterator on already parsed
attribute values. Besides scanning those values again, that extra scanner
caller changed the optimizer's sharing decisions for ordinary DOT parsing.
Internal document traversal now uses trusted operands directly; public
identifier helpers still validate arbitrary input.

These are the **default DOT rows inside the mixed-profile binary**, which also
contains active string processing:

| Value fixture | Before ms | After ms | Time change |
| --- | ---: | ---: | ---: |
| Short | 0.237 | 0.175 | −26.1% |
| Concatenated | 0.251 | 0.198 | −21.1% |
| Unicode | 0.250 | 0.188 | −24.9% |
| Long ASCII | 3.356 | 1.738 | −48.2% |

The isolated `host-defaults`, standalone `native` and standalone `sessions`
executables have identical before/after machine-code hashes in Fast, Safe and
Small. The isolated default executable sizes also remain identical. Some
timings still cross the report threshold despite identical code: repeated runs
of the **same** Small default-only executable put the long DOT case in two
bands (candidate 1.602–2.254 ms; baseline 1.753–2.281 ms). Those timing flags
are not evidence of a changed default implementation.
The mixed Fast long-DOT default/passthrough rows also flagged roughly 35–37%
in the first report. Three further alternating runs of those unchanged binaries
gave 1.555–1.563 ms before and 1.531–1.718 ms after: the original large flag did
not persist. Keep the raw variation separate from the repeatable Small recovery.

No measured session sizes, credits or poll counts changed. The bound equality
sessions remain 344 bytes for plain readers and 464 for DOT/markup readers.
Integration's allocation-count/requested-byte parity checks still pass; this
is not a peak-stack or RSS claim. The mixed integration executable is unchanged
in size for Fast/Safe; Small grows from 316,560 to 334,416 bytes, **17,856 bytes**
for this multi-profile harness. Unused-feature binaries do not pay that cost.

This is not a blanket win on every enabled-reader workload. The Small logical
suite still flags comment-heavy DOT at about 8–10% more time (roughly 7 µs/value)
and explicit plain-reader Unicode binding at 12–14% (about 0.08–0.09 µs/value).
The latter is `WithReader(LogicalReader(...))`, not standalone string parsing.
These non-target control cases remain recorded, not hidden by the long-value
gains. The final suite has no flagged Small end-to-end integration slowdowns.

Reproduce the complete comparison:

```sh
zig build perf-string -- --baseline b58db00 \
  --suites host-defaults,integration,logical,native,sessions \
  --modes ReleaseFast,ReleaseSafe,ReleaseSmall --runs 3
```

## Parser-recognized names (Unreleased)

Measured on this machine with Zig 0.16.0 on 2026-10-20 using
`zig build bench-identifiers -Doptimize=ReleaseFast` (and `ReleaseSafe` /
`ReleaseSmall`). Each fixture contains 10,000 node statements and 1,000 unique
names. The event consumer builds a hash-based reference index, without a syntax
tree. Source generation and equal table reservations are outside timing.
Numbers are medians of nine alternating samples, four parses per sample.

| Name spelling | ReleaseFast checked → trusted | ReleaseSafe checked → trusted | ReleaseSmall checked → trusted |
| --- | ---: | ---: | ---: |
| Quoted | 0.647 → 0.460 ms | 0.728 → 0.502 ms | 1.254 → 0.776 ms |
| Concatenated | 0.944 → 0.639 ms | 1.029 → 0.700 ms | 1.621 → 1.029 ms |
| Unicode quoted | 0.914 → 0.647 ms | 0.981 → 0.677 ms | 1.651 → 1.001 ms |
| Long quoted (10.36 MB input) | 23.818 → 14.421 ms | 23.689 → 14.442 ms | 37.271 → 17.417 ms |

Here “trusted” means `identifier.assumeParsed(raw)` on complete identifier fields
delivered by the parser. It skips repeated syntax checks, not logical-value
hashing/equality. Across all six fixtures (also bare and escaped names),
parse-plus-index time fell 24–40% in Fast, 29–40% in Safe and 33–53% in Small.
These are indexing-workload results, **not** a speedup to ordinary parsing.
Both paths reserved 43,032 bytes in one allocation for the index, with no
allocations during parsing. The helper itself is one borrowed slice and adds
no parser/event/document storage. The existing checked helpers are unchanged.
Before/after builds of the fixed/runtime-policy benchmark had identical machine
code in ReleaseFast, ReleaseSafe and ReleaseSmall when the new API was unused.

## Early outline events (Unreleased)

Checked on 2026-10-20, Apple M4 Pro, Zig 0.16.0, against a working-tree
snapshot immediately before adding early observations (including the recognized
name helpers above). The unchanged `bench/policies.zig` and `bench/metering.zig`
harnesses produced **identical machine-code sections before/after** in
ReleaseFast, ReleaseSafe and ReleaseSmall. This covers both scanners, fixed and
runtime policies, ordinary parsing, one-credit/batched metering and cancellation
intervals 1 and 64. Disabled early events add no session storage or allocation.

The fixed/runtime-policy harness executable sizes were 616,520 → 616,520 bytes
(Fast), 665,848 → 665,848 (Safe), and 428,368 → 428,360 (Small). Three alternating
process runs per side showed no default-path regression attributable to the
feature. Identical code still has timing noise, especially in short long-text
microbenchmarks; timing variation is not a claimed speedup. The event-only name
index also retained identical Fast/Small machine code; its Safe build changed
slightly, with no measured slowdown across its six fixtures.
An additional same-executable-path session rerun had much larger timing swings,
including broad Safe slowdowns. The Safe binaries' entire contents up to their
code signatures were byte-identical, not just their code sections. These runs
therefore cannot establish a feature-induced slowdown or a precise percentage
guarantee; use the code-generation comparison as the disabled-path evidence.

**Enabling** `wants_early_events` does add work. A fixed-scratch event consumer
counting callbacks on 10,000 `a[x=1];` statements (80,010 bytes, including a named
header) measured the following in ReleaseFast. Nine alternating timed batches
of four parses followed three warmup batches; source construction was excluded.

| Execution | Scalar off → on | Block off → on |
| --- | ---: | ---: |
| Unmetered | 0.552 → 0.586 ms | 0.528 → 0.823 ms |
| One-credit resumes | 1.286 → 1.423 ms | 1.297 → 1.511 ms |
| 4,096-credit resumes | 0.568 → 0.623 ms | 0.708 → 0.711 ms |
| 4,096-credit resumes, cancellation interval 1 | 0.644 → 0.690 ms | 0.693 → 0.729 ms |

That opt-in delivered 50,003 callbacks instead of 30,002. Metered work increased
by exactly the 20,001 added callbacks: 230,020 → 250,021 scalar credits and
191,263 → 211,264 block credits, independently of resume budget. No credits were
coarsened or polling sites removed. Consumer callback execution remains outside
parser work-credit accounting, not a wall-clock time guarantee.

On this target the opt-in still fits existing session padding: scalar session
sizes remain 448 / 488 / 512 bytes (plain / metered / metered+cancellable), block
544 / 584 / 608. A single event-consumer nesting frame remains 100 bytes and
`Event` remains 116 bytes. The parser stores no event list or provisional tree;
retaining outline entries costs whatever the consumer chooses to store. These
are target-specific layout observations, not a stable ABI or RSS measurement.

## Unfinished-token previews (Unreleased)

Checked against `75ce950` on 2026-10-20 with Zig 0.17.0, Apple M4 Pro.
With previews disabled, `bench/policies.zig` and `bench/metering.zig` produced
identical machine-code sections before/after in `fast`, `safe` and `small`.
These exercise both scanners, fixed/runtime policies, ordinary/fixed-pool
parsing, tiny/batched budgets and cancellation. The identifier-index benchmark
also produced identical Fast/Small code; Safe changed only two enum-range
comparison constants for the two new public event tags, with no extra
instructions. Ordinary document/session layout guards pass unchanged.

The opt-in uses no new allocation or source copy. In the Fast-mode fixed event sessions
measured here, it adds 16 bytes: scalar 448 → 464 (plain), 488 → 504 (metered),
block 544 → 560 and 584 → 600. These are target/mode-qualified instance sizes,
not RSS or a portable ABI. Consumer-owned outline storage is separate.

Run `zig build bench-previews -Doptimize=fast` (or `safe` / `small`) for one CSV
report of enabled/disabled timing, decimal MB/s, callback counts, exact credits
and session sizes. Source construction is excluded; the allocation-free event
consumer counts callbacks and consumes preview spans. Seven alternating sample
medians follow two warmup rounds, with eight parses per sample.

Selected Fast-mode observations from that report (milliseconds per parse):

| Input / execution | Scalar off → on | Block off → on |
| --- | ---: | ---: |
| 5,000 `a[x=1];` statements, unmetered (35,007 bytes) | 0.207 → 0.220 | 0.236 → 0.238 |
| Same dense input, 4,096-credit resumes | 0.238 → 0.325 | 0.294 → 0.336 |
| Long Unicode quoted value, 4,096-credit resumes (95,018 bytes) | 0.0396 → 0.0392 | 0.0387 → 0.0391 |
| Same Unicode value, one-credit resumes | 0.470 → 1.382 | 0.0422 → 0.0687 |
| Unterminated Unicode value, unmetered (95,015 bytes) | 0.0461 → 0.0456 | 0.0395 → 0.0396 |

Enabled execution is not free even when a pause happens to align with a token
boundary and no preview is delivered: the enabled dispatch/control path still
has checks. These are local measurements, not universal percentage guarantees;
sub-microsecond differences are noise, not claimed speedups.

Unlike complete-name early observations, pause-preview counts **depend on the
resume budget and backend**. Every added update/retirement is a separately
charged callback; the benchmark verifies `enabled credits = ordinary credits +
preview callbacks`. A one-credit scalar session can deliver an update for each
additional byte and therefore materially increase time/callback volume. Larger
budgets coalesce observations without coarsening lexical credits or cancellation
guarantees. Use the report to choose a UI resume budget, not to infer a regression
in ordinary parsing with previews disabled.

## Standalone strings (Unreleased)

Measured on 2026-10-18, Apple M4 Pro, Zig 0.16.0, ReleaseFast, using
[`bench/string.zig`](../bench/string.zig). These are new-module baselines, not
DOT/markup before-and-after numbers. Each cell is the median of three runs;
each run uses seven measured batches after two warmups. Source allocation is
outside timing. Each call verifies encoding, runs equality and consumes the
result with a discard sink. Profiles compile UTF-8/16/32 readers, with fixed
policies. Case folding is enabled only in the folding variants.

For the same logical value, `Straße 中文 😀`:

| Source encoding | Physical bytes | Exact, ns/value (MB/s) | Unicode folding, ns/value (MB/s) |
| --- | ---: | ---: | ---: |
| UTF-8 | 19 | 14.4 (1,319) | 119.3 (159) |
| UTF-16LE | 24 | 55.5 (432) | 116.8 (205) |
| UTF-32LE | 44 | 40.6 (1,084) | 102.5 (429) |

MB/s counts physical bytes, so wider encodings are not directly comparable by
throughput alone; compare ns/value too. For seven-byte ASCII `Seattle`, UTF-8
exact checking took about 7.2 ns/value and folding 40.5 ns/value. On a 4,200-byte
ASCII value, exact checking took about 235 ns/value (17,895 MB/s), using the
standard validator's ASCII fast path and validated byte equality. Folding took
about 25 µs/value, with appreciable run variation (19–29 µs): these microbenchmarks
are not guarantees for arbitrary text or diagnostics-heavy work.

The harness also binds the supplied Equals validator through the custom slot.
It uses the same verification/comparison/reporting contract; code generation
and timings are not promised identical. For the 19-byte UTF-8 value, exact custom
checking took about 17.6 ns/value versus 14.4 ns for the named built-in. Membership,
runtime-policy preparation, callbacks and retained diagnostic costs depend on
their configuration; they are not represented by the equality table.

Processor/comparator heap allocations: **zero**. Source stays borrowed, with no
tree or decoded/folded string buffer. On this target `Result` is 24 bytes and
the default diagnostic is 72 bytes; custom details can enlarge diagnostics.
Growable bags and consumer callbacks can allocate independently. Folding uses
bounded three-scalar buffers per comparison side plus cursors, not input-sized
scratch. These are library payload/cost facts, not process RSS measurements.

Consumed, stripped Wasm32 ReleaseSmall probes, without console rendering:

| Probe | Module bytes | Folding table |
| --- | ---: | --- |
| Exact UTF-8 equality | 3,136 | absent |
| Unicode-folded equality | 10,091 | present |
| Non-comparison predicate, folding capability enabled but unused | 2,833 | absent |

Reproduce with `zig build check-wasm` (requires Node; also included in
`zig build check`). The script executes the exports and checks
table retention, not just file size. This change does not modify DOT, markup or
shared parsing/validation code. Their existing throughput tables below are
unchanged; no new DOT/markup regression measurement is claimed here.

### String execution: metering and default-path check

Measured on Apple M4 Pro, Zig 0.16.0, 2026-10-18 against `b59a9a0` (before bounded
batching). Compilation is excluded from timing. The default UTF-8 encoding-only
path, with all content rules and execution features off, measured as follows in
a paired ReleaseFast harness (15 measured batches after four warmups, alternating
order):

| Input | Before, ns/value | After, ns/value |
| --- | ---: | ---: |
| 7-byte ASCII | 4.26 | 4.28 |
| 19-byte Unicode | 8.05 | 8.63 |
| 4,200-byte ASCII | 80.79 | 81.36 |

The default path retains bulk encoding validation and no session state/counters.
Standalone probes exporting default encoding, exact equality and Unicode-folded
equality produced **identical machine-code sections before and after**, in both
ReleaseFast and ReleaseSafe. Processor allocations remain zero, Result/Diagnostic
sizes remain 24/72 bytes, and all three Wasm probes above remain exactly the same
size. The paired ReleaseSafe encoding-only measurements were 5.02 → 5.02 ns,
10.12 → 10.12 ns and 82.69 → 82.83 ns respectively.

With equality enabled but execution features still off, paired long exact
checking measured 249.35 → 251.31 ns in ReleaseFast and 311.70 → 312.18 ns in
ReleaseSafe. Timing still depends on layout: the paired executable measured
long folding +4.6% / +6.7%, despite the standalone probes having identical code.
These hot-buffer microbenchmarks do not establish a universal percentage bound
for every application/profile; no new default-path work or instructions were added.

For opt-in execution, run
`zig build bench-string-sessions -Doptimize=ReleaseFast`. These are medians of
three alternating before/after runs, each with seven measured batches after two
warmups. They include session init, execution and consuming the result; inputs
are allocated outside timing, and diagnostics are discarded. Values use exact
UTF-8 equality. Times below are for the 4,200-byte ASCII input, in ReleaseFast.

| Execution | Before, µs | After, µs | Session bytes (unchanged) |
| --- | ---: | ---: | ---: |
| Unmetered one-shot | 0.255 | 0.257 | none |
| Metered, budget 1 | 48.01 | 46.63 | 128 |
| Metered, budget 64 | 46.54 | 1.96 | 128 |
| Session run to completion | 46.36 | 2.03 | 128 |
| Budget 64, cancellation interval 1 | 47.54 | 46.74 | 152 |
| Budget 64, cancellation interval 64 | 41.26 | 2.33 | 152 |
| Budget 1, runtime policies | 70.70 | 51.11 | 256 |
| Budget 64, runtime policies | 46.70 | 2.55 | 256 |
| Budget 1, Equals bound as custom | 62.50 | 47.58 | 128 |
| Budget 64, Equals bound as custom | 40.87 | 1.95 | 128 |
| Budget 64, step-only custom equality | 41.20 | 33.84 | 128 |
| Budget 64, two-candidate membership | 43.34 | 2.28 | 136 |

ReleaseSafe large-ASCII budget 1 improved 65.66 → 61.31 µs, runtime-policy
budget 1 improved 76.47 → 68.09 µs, and budget 64 improved 53.03 → 2.47 µs.
The seven-byte budget-one check measured 95.0 → 92.4 ns in ReleaseFast and
143.4 → 128.0 ns in ReleaseSafe.

Unicode fallback checks, using the same run protocol:

| Contents | ReleaseFast budget 1, before → after µs | ReleaseFast budget 64, before → after µs | ReleaseSafe budget 64, before → after µs |
| --- | ---: | ---: | ---: |
| 1,216-byte mixed Unicode | 11.45 → 11.27 | 11.37 → 11.44 | 12.68 → 12.67 |
| 384-byte Chinese | 2.85 → 2.87 | 2.89 → 2.92 | 3.24 → 3.27 |
| 256-byte emoji | 1.56 → 1.55 | 1.55 → 1.55 | 1.50 → 1.46 |
| 1,728-byte mostly ASCII with Chinese | 18.98 → 19.11 | 19.20 → 4.70 | 22.07 → 5.31 |

Session size is fixed caller-owned payload, not process RSS or total stack use;
custom states/folding can increase it. There are no processor heap allocations.
The seven-byte and large-ASCII inputs cost 26 and 12,605 credits respectively, independent of budget
partition and cancellation interval. On the large value, interval 1 polled
12,605 times and interval 64 polled 197 times. Runtime policy preparation is
included in these timings but is outside the credit budget.

The fast lane groups 16 equivalent pending ASCII steps, charging all 16 credits.
It never crosses the caller's remaining budget or next cancellation poll. Budget
one has a direct scalar path; cancellation interval one also stays scalar.
Failed ASCII probes fall back for a bounded group of scalar steps, avoiding a
new overlapping probe at every Unicode character. Built-in and custom validators
share the optional batch contract; step-only custom validators remain supported.
Dense Unicode and folding still require scalar work, and metering remains much
slower than unmetered bulk validation there. Use it for bounded responsiveness;
no step/counter overhead is added when both execution features are off.

### ASCII comparison regression follow-up

Measured on 2026-10-19, Apple M4 Pro, Zig 0.16.0, against `6661630`
(before ASCII-insensitive comparison). The single-command report used three
alternating process runs per side, seven timed batches after two warmups, and
the same captured harness for both source trees:

```sh
zig build perf-string -- --baseline 6661630 --modes ReleaseFast,ReleaseSafe,ReleaseSmall --runs 3
```

Geometric mean **time** changes; negative means faster. These are overlapping
groups, not quantities to add. The 18 newly available native ASCII-comparison
cases per build have no baseline and are excluded from the means.

| Matched group | Fast | Safe | Small |
| --- | ---: | ---: | ---: |
| 18 runtime-policy cases | −12.9% | −13.7% | −15.0% |
| 36 native-encoding/comparison cases | −4.0% | −6.1% | −20.2% |
| 84 execution/session cases, including runtime policies | −9.4% | −9.2% | −13.9% |

Matching scalars and ASCII batches no longer dispatch into ASCII folding.
The private scalar-read result fits one word, and Small builds retain useful
comparison-loop boundaries instead of outlining tiny operations inside the loop.
Unmetered, uncancellable exact UTF-8/ASCII checks can reuse the input's encoding
proof for byte-identical patterns; mismatches still validate the entire pattern.
These changes do not remove validation from metered or cancellable checks.

For example, Small mixed-text one-shot equality improved from 0.869 to 0.546 µs
against the pre-feature baseline (the initial regressed candidate measured
1.109 µs). Small Unicode runtime-policy checks at budget 64 improved from
24.417 to 20.226 µs. Fast long-ASCII runtime checks at budget 64 measured
2.593 to 2.558 µs. All compared session sizes, work-credit totals and poll counts
were unchanged; the discard-sink processor paths still allocate no heap memory.

**This is not an all-green regression result.** The broad harness still flagged
Small long-ASCII runtime/budget-64 checks at +9.5%, tiny UTF-32 exact checks at
+8.6%/+10.2%, and emoji checks with cancellation interval 64 at +7.1%.
It also flagged a long Unicode-folded custom check in Fast at +59.1%, a short
folded custom check in Safe at +8.7%, and Fast default-only long ASCII at +11.9%.
Do not hide these behind the aggregate improvements or dismiss every flag as noise.

Isolation changes the picture: the Fast default-only and Unicode-folded custom
probes have byte-identical machine-code sections before and after. Default-only
code also matches in Safe and Small. A paired default-only harness (nine timed
batches after two warmups, alternating sides, one million calls per batch) gave:

| 4,200-byte ASCII, default encoding check | Before ns/value | After ns/value |
| --- | ---: | ---: |
| Fast | 79.23 | 79.78 |
| Safe | 79.62 | 79.74 |
| Small | 87.26 | 87.19 |

A longer-running isolated Small runtime/budget-64 check measured 2.86–2.87 µs
before and 2.75–2.81 µs after, with the same 256-byte session and 12,605 credits.
Thus the broad executable's layout/code-generation effects matter; the remaining
mixed-profile outliers are not a demonstrated default-path algorithm change,
but still need investigation before claiming every configuration is regression-free.

There is a code-size tradeoff for enabled execution profiles: the consumed Small
session harness grew from 321,088 to 342,248 bytes, while the native harness
shrank from 281,048 to 258,296 bytes despite adding 18 ASCII-comparison cases.
These are whole multi-profile executables, not library or heap sizes. Current
consumed Small Wasm probes are 3,240 bytes for exact equality, 3,370 for ASCII
folding and 10,247 for Unicode folding; only the last retains the Unicode table.

### Simulated string passthrough versus processing

`zig build bench-string-passthrough -Doptimize=ReleaseFast` uses the **actual DOT
lexer** to scan one quoted identifier through EOF, then optionally hands the
borrowed contents to the standalone string processor. Every timed variant calls
the same scanner helper. This is a benchmark simulation, not implemented
DOT/string composition. There is no tree construction, escape decoding,
concatenation or retained diagnostics. Inputs contain neither escapes nor
concatenations, so raw and logical contents agree without a copy.

Apple M4 Pro, Zig 0.16.0, 2026-10-18. Median of three runs; each run has nine
measured batches after two warmups and alternates variant order. Compilation
and input allocation are outside timing. The default scalar scanner measured:

| UTF-8 contents | Passthrough scan | Scan + encoding | Scan + encoding/equality | Scan + metered encoding/equality, budget 64 |
| --- | ---: | ---: | ---: | ---: |
| 7-byte ASCII | 10.13 ns | 14.89 ns | 18.47 ns | 89.06 ns |
| 19-byte Unicode | 13.40 ns | 23.32 ns | 29.43 ns | 182.25 ns |
| 4,200-byte ASCII | 1.409 µs | 1.515 µs | 1.671 µs | 3.501 µs |
| 1,216-byte Unicode | 0.560 µs | 0.997 µs | 1.379 µs | 10.228 µs |

The ASCII fixtures are `Seattle` and repeated `The quick brown fox. `; Unicode
uses `Straße 中文 😀` once or repeated 64 times. Exact comparisons match the whole
value, without case folding. All processor paths are allocation-free and use
fixed policies, with cancellation off.

For the 4,200-byte ASCII contents, these medians correspond to approximately
**2,980 / 2,773 / 2,513 / 1,200 MB/s**, respectively (decimal content bytes; excludes
the two quotes from the byte count, but includes scanning them in the time).
Unmetered encoding/equality adds about 19% time over scanning; metered equality
takes about 2.5× the scan time. Long-ASCII scalar scan medians varied from
1.332–1.929 µs across runs, so treat these as approximate hot-buffer measurements,
not sustained whole-file throughput or precise regression thresholds.

The opt-in block scanner also runs in the harness:

| Contents | Block passthrough | Block scan + encoding/equality | Block scan + metered encoding/equality |
| --- | ---: | ---: | ---: |
| 7-byte ASCII | 31.26 ns | 38.11 ns | 109.48 ns |
| 19-byte Unicode | 32.48 ns | 46.16 ns | 201.73 ns |
| 4,200-byte ASCII | 1.664 µs | 1.951 µs | 3.828 µs |
| 1,216-byte Unicode | 0.506 µs | 1.375 µs | 10.190 µs |

Passthrough does inspect bytes for quotes, escapes and host lexical restrictions;
it is **not encoding validation**. The harness verifies that quoted `0xff` passes
the quote scanner but fails the standalone encoding check. If a caller already
has the bounded contents, retaining that span requires no additional contents
scan; do not add the host scan twice. These figures cannot predict whole DOT
parse times or the eventual costs of decoding, source mapping and integration.

## Parse and validate

The [DOT throughput benchmark](../bench/throughput.zig) uses a 2.733 MB file
with 200,000 statements: numbered nodes alternating with `--` edges. Settings
are the defaults. Times include `parseAndValidate` and its allocations into a
fresh arena, but not freeing the arena.

"Hinted" passes exact size hints, taken from the known contents of the file.
The time it would take `measure` to work them out is **not** included.

| Build | Scanner | Growing | Hinted |
| --- | --- | --- | --- |
| Fast | scalar | 7.85 / 348.2 | 6.82 / 400.8 |
| Fast | block | 8.04 / 340.0 | 7.04 / 388.3 |
| Safe | scalar | 8.91 / 306.8 | 7.36 / 371.4 |
| Safe | block | 10.06 / 271.7 | 8.42 / 324.6 |

## Memory

For the same 200,000-statement file. The sizes were the same for both scanners
and both builds:

| What | Size |
| --- | ---: |
| Your source (borrowed, not copied) | 2.733 MB |
| The document | 6.800 MB (34 bytes per statement) |
| Arena memory, no size hints | 37.620 MB |
| Arena memory, exact size hints | 8.400 MB |

The document size doesn't include the source, because the source is never
copied. Arena memory also counts unused space and old copies left behind when
lists grow. It isn't the document's own size, and it isn't the program's total
memory use. See [arenas](MEMORY.md#option-2-an-arena).

Record sizes on this machine: node statement 16 bytes, edge statement 36 bytes,
subgraph 36 bytes, statement entry 8 bytes, nesting frame 116 bytes. Plan memory
for the source, diagnostics, sessions and nesting space separately.

## Type sizes

`@sizeOf` values for 0.5.0 on this machine (aarch64 macOS,
Zig 0.16.0), checked 2026-10-12. They are the size of each value itself, not
memory used while parsing, and they can differ on other targets or Zig
versions. A [layout test](../tests/layouts.zig) checks this table in all four
build modes.

| Type | Debug / Safe | Fast / ReleaseSmall |
| --- | ---: | ---: |
| `dot.Profile(.{}).Session` | 1,128 bytes | 1,120 bytes |
| DOT session with metering and cancellation | 1,192 bytes | 1,184 bytes |
| `dot.lexer.For(.scalar)` | 64 bytes | 56 bytes |
| `dot.lexer.For(.block)` | 152 bytes | 152 bytes |

The second row turns on `.execution = .{ .metering = true, .cancellation = true }`
and leaves every other setting at its default. Session sizes don't include the
source, document buffers, nesting space or diagnostics, which you supply
separately. Use `@sizeOf` on your own profile and target rather than copying
these numbers.

Keeping comments makes the document and storage types a little
larger even when it is off. With the additional DOT completeness metadata, the
default fixed session is now 40 bytes bigger than in 0.4.0. Scanner sizes and per-statement records are unchanged. With
comment retention off, no comment records are allocated. With it on, each
comment takes 12 bytes, plus spare room in growing lists unless you give exact
sizes or fixed buffers. The comment text itself is never copied.

Additional type sizes in the Zig 0.16 baseline, the same in Fast and Safe builds:

| Type | Size (bytes) |
| --- | ---: |
| DOT session with run-time settings (Unreleased) | 1,424 |
| Markup node / attribute | 20 / 20 |
| Markup nesting frame / attribute-key scratch entry | 12 / 8 |
| Markup diagnostic / validation result | 36 / 32 |
| Markup session: default / bounded / run-time settings | 440 / 448 / 528 |
| Markup `Document` | 56 |
| Markup node / attribute view | 64 / 64 |
| Markup root/child iterator / attribute iterator | 64 / 64 |

**Zig 0.17 development layouts:** the two `ArrayList` safety locks in the
markup builder add 16 bytes in `debug` and `safe`: default / bounded /
run-time sessions are **456 / 464 / 544 bytes**. With exact closing-tag
recovery, default / bounded are **448 / 456 bytes**. `fast` and `small`
retain the sizes above. These are constant session costs, not per-node
allocations; DOT's guarded session and scanner sizes are unchanged.
Other growable builders/workspaces also inherit the per-list safety-lock
overhead; these locks are compiled out in `fast` and `small`.

Changes since 0.4.0 to these sizes:

- **Closing-tag typo recovery**, on by default, adds 8 bytes to sessions with
  fixed settings and 24 bytes to the run-time-settings session. With a fixed
  `closing_tag_recovery = .exact`, the default and bounded sessions are 432 and
  440 bytes again; run-time settings keep room for every choice. No choice
  allocates or makes node or attribute records bigger.
- **Markup partial results** add 8 bytes to the run-time-settings session; other
  sessions are unchanged. The markup `Document` grew from 48 to 56 bytes, even
  with partial results off, so views and iterators that hold it grew by 8 bytes
  too. Copying a view still copies no source or tree and doesn't allocate.
  Node and attribute records are still 20 bytes. Keeping the finished part after
  a failure reuses the same buffers, without allocating. Growing buffers keep
  their spare room after a failure: an owned result holds it until `deinit()`,
  and a workspace keeps it for the next call.
- **DOT partial results and kept label trees** have their own
  [memory costs](EDITORS.md#memory). The default DOT session grew by 8 bytes,
  and run-time-settings sessions by 56 bytes, because they must be able to keep
  partial results too. Default node and edge allocations are unchanged, and no
  list of label results is allocated unless label trees are kept.

## Cost of opt-in features

> The compile-time numbers in this section were measured during 0.5.0
> development, on the same machine, and weren't re-run for the release.

**Partial DOT results** ([editors](EDITORS.md#keep-the-finished-part-of-a-dot-file)):

- **Off:** with compile-time settings, no measurable change (−1.0% to +0.5%
  across scanners, storage and both builds). Profiles with run-time settings
  weren't compared with the version before this feature.
- **On:** parsing is a few percent slower. Scalar scanner, Fast build:

| Input | Fixed buffers | Growing buffers |
| --- | ---: | ---: |
| Nodes | −6.0% | −2.5% |
| Edges | −5.3% | −6.9% |
| Subgraph edge ends | −7.9% | −8.9% |

- **On, with run-time settings:** 0–2% slower than the same profile with it
  off (`runtime_partial` against `runtime_baseline` in the
  [settings tables](#compile-time-and-run-time-settings)).
- **Memory, on:** fixed buffers use nothing extra. Growing buffers use 104 bytes
  more at their peak, and keep 26–34% more memory afterwards, because the lists
  aren't trimmed when parsing ends. Exact size hints or fixed buffers avoid that.

**Keeping label trees** costs memory for every kept tree; how much depends on
the labels. It hasn't been timed yet.

## Scanners

The [lexer benchmark](../bench/lexer.zig) times the DOT scanner on its own, in
a Fast build. Each pattern is repeated 65,536 times. The `long HTML label` row
only measures how fast DOT finds where a `<...>` value ends, not checking what
is inside it.

| Pattern | Source (MB) | Scalar | Block |
| --- | ---: | --- | --- |
| short names and punctuation | 1.114 | 7.22 / 154.3 | 5.65 / 197.2 |
| short names, spaces and line breaks | 0.983 | 2.87 / 342.5 | 2.72 / 361.4 |
| keywords and numbers | 3.670 | 5.90 / 622.0 | 5.85 / 627.4 |
| quoted strings and comments | 2.228 | 2.78 / 801.5 | 4.55 / 489.7 |
| long HTML label | 80.806 | 40.98 / 1,971.8 | 8.62 / 9,374.2 |
| long name | 4.260 | 3.32 / 1,283.1 | 2.06 / 2,067.9 |

The block scanner wins on long runs, but scalar wins on quoted strings and
comments. A faster scanner alone doesn't mean a faster parse overall: end to
end, scalar is faster (see [parse and validate](#parse-and-validate)). Scalar
stays the default; see [two scanners](EXECUTION.md#two-scanners).

## Step-by-step sessions

The [session benchmark](../bench/session.zig) parses 200,000 `a;` statements
(0.400 MB) in a fixed-buffer session with the scalar scanner, without
validation. Metered sessions spend 256 credits per `advance` call; the others
use `run()`.

| Metering | Cancellation | Fast | Safe | Cancel checks |
| --- | --- | --- | --- | ---: |
| off | off | 3.28 / 122.0 | 3.80 / 105.3 | 0 |
| on | off | 4.06 / 98.5 | 4.23 / 94.6 | 0 |
| off | on | 4.83 / 82.8 | 4.80 / 83.3 | 1,400,016 |
| on | on | 5.15 / 77.7 | 5.12 / 78.1 | 1,405,484 |

The cancel callback counts how often it is called but never asks to stop. So
these numbers show the cost of checking, not how quickly a cancel takes
effect. Your own callback's work adds to it. Setting up the session and its
memory isn't timed.

### Cancellation intervals (unreleased)

Measured on 2026-10-17 with Zig 0.16.0 on Apple M4 Pro, 48 GiB RAM.
The interval-relative tables below are the initial `ca71148` snapshot, before
the interval-1 follow-up described below; they are not updated-build speedups.
The [interval benchmark](../bench/cancellation.zig) covers intervals 1, 4, 16,
64 and 256, both parsers/scanners, fixed/runtime policies, and metering on/off.
It uses dense 30,000-statement inputs (DOT 0.210 MB, markup 0.300 MB) and
1.350 MB of long quoted/text content. Markup uses structural mode; validation
is not timed. Pools and session initialization are outside timing. Each case
warms for at least 150 ms, then takes the median of nine samples. The numbers
below take the median across three interleaved runs. Metered calls grant 4,096
credits; the callback counts polls and never requests cancellation.

Throughput change relative to **interval 1 in the same build**, geometric mean
across both inputs, fixed/runtime policies and metering on/off:

| Parser / scanner | Build | 4 | 16 | 64 | 256 |
| --- | --- | ---: | ---: | ---: | ---: |
| DOT scalar | Fast | +45.4% | +76.3% | +82.2% | +87.9% |
| DOT scalar | Safe | +40.3% | +65.6% | +83.2% | +85.6% |
| DOT block | Fast | +0.4% | +3.3% | +6.2% | +6.2% |
| DOT block | Safe | -0.7% | -0.3% | +2.8% | +4.2% |
| Markup scalar | Fast | +6.3% | +5.7% | +9.4% | +10.5% |
| Markup scalar | Safe | +3.8% | +3.3% | +5.2% | +6.5% |
| Markup block | Fast | +4.9% | +4.5% | +4.6% | +4.8% |
| Markup block | Safe | +2.2% | +2.7% | +2.2% | +4.4% |

Long text drives much of DOT's gain; this is not a representative-file average.
For context, these are actual **Fast, scalar, fixed-policy, metered** timings:

| Input | Interval 1: ms / MB/s | Interval 64: ms / MB/s |
| --- | --- | --- |
| DOT dense | 1.763 / 119.1 | 1.346 / 156.1 |
| DOT long text | 3.021 / 446.9 | 0.766 / 1,762.4 |
| Markup dense | 1.567 / 191.5 | 1.403 / 213.9 |
| Markup long text | 4.017 / 336.0 | 3.734 / 361.5 |

Credits were identical at every interval. For dense DOT, interval 1/64 used
600,161/9,522 polls but **600,015 credits** in both cases. Dense markup used
480,153/7,618 polls and **480,036 credits**. Entry checks account for extra polls
at resume boundaries. Measured session sizes were unchanged against the previous
commit; the countdown is local to a drive call, with no new heap allocations or
per-record storage. This is not a process peak-RAM measurement.

**DOT interval-1 follow-up.** The initial implementation changed LLVM's inlining:
sharing grammar helpers between one-credit and batched loops introduced calls
on the runtime default's hot path. DOT now selects the polling class once at
operation start/session init/reset. The interval-1 machine has no countdown work;
its runtime scalar scanner executes the same single lexical microstep directly.
Document, event-only and proactive-composition entry points share this approach.
No work unit, polling boundary, pause budget or terminal precedence changed.

Matched interval-1-only builds compare `702d4ea` (pre-interval), `ca71148` and
the follow-up. Dense and long-text inputs use five alternating runs; four extra
30,000-statement inputs use three: nodes (`a;`), subgraph endpoints
(`{a;}->{b;};`), ports/attributes (`a:p->b:q[x=1];`) and passthrough HTML-like
identifiers (`a[label=<<b>x</b>>];`). The latter does not process markup.
Warmup, sampling and budget rules are as above. Geometric mean throughput changes
against **pre-interval `702d4ea`**, across six inputs and metering on/off:

| DOT scanner | Fast fixed | Fast runtime | Safe fixed | Safe runtime |
| --- | ---: | ---: | ---: | ---: |
| Scalar | -0.6% | +10.9% | +1.5% | +5.4% |
| Block | +1.0% | -0.7% | -0.1% | -0.4% |

Against the regressed `ca71148`, runtime scalar improves **20.7% Fast / 16.2%
Safe**, and runtime block improves **5.2% / 10.0%**. Cancellation-disabled
controls average +1.9% / -0.5% against pre-interval. Exact poll counts, metered
credit totals and session sizes match all three versions, with no new heap
allocation or retained-record storage.

**Residual variation is not a blanket performance sign-off.** The mixed-profile
binary still has individual slower cases: dense runtime-metered block is -6.6%
Fast / -4.0% Safe, and fixed unmetered scalar reaches -4.5% Fast on ports.
Separate single-profile binaries also use five alternating runs. Their dense
input comparisons against pre-interval are:

| Isolated profile | Fast | Safe |
| --- | ---: | ---: |
| Fixed scalar, unmetered | -3.5% | +6.6% |
| Runtime scalar, unmetered | +8.0% | +2.2% |
| Runtime block, unmetered | -5.0% | +0.6% |
| Runtime block, metered | +0.1% | -1.7% |

This sensitivity to the surrounding compiled profiles matters: compare the
actual application, not just an aggregate. Assembly inspection also finds the
same fixed scalar default hot loop structure as pre-interval, apart from
relocated addresses and error-code mapping. We have removed the added
default-path work, not demonstrated zero regression for every configuration.

The mixed-profile benchmark's `__TEXT` grows by 29.0 KiB Fast / 32.9 KiB Safe
against `ca71148`, from specializing runtime polling classes. This is not a
fixed-policy-only cost: the isolated fixed scalar binary differs from
pre-interval by only 40 bytes Fast / 48 bytes Safe of `__TEXT`. Markup is unchanged
by this follow-up; its initial interval-1 comparisons ranged from +0.4% to -2.3%
by configuration.

Interval **1 remains the default**. Larger intervals trade responsiveness for
fewer polls; they neither increase work budgets nor guarantee faster parsing.
See the [interval contract](EXECUTION.md#cancellation-interval).

## Compile-time and run-time settings

The [settings benchmark](../bench/policies.zig) parses three files into fixed
buffers, without validation:

- `nodes`: 50,000 lines of `a;` (0.150 MB)
- `edges`: 50,000 lines of `a -> b;` (0.400 MB)
- `subgraph ends`: 50,000 lines of `{a;} -> {b;};` (0.700 MB)

Each is parsed with four kinds of settings:

- `fixed` uses compile-time settings.
- `runtime_baseline` turns on run-time settings but changes nothing.
- `runtime_override` passes the same scanner choice as a run-time setting.
- `runtime_partial` also turns on [partial results](EDITORS.md#keep-the-finished-part-of-a-dot-file)
  at run time.

Fast build:

| Scanner | Settings | `nodes` | `edges` | `subgraph ends` |
| --- | --- | --- | --- | --- |
| scalar | fixed | 0.835 / 179.7 | 1.551 / 257.9 | 6.361 / 110.0 |
| scalar | runtime_baseline | 0.944 / 158.9 | 1.767 / 226.4 | 6.666 / 105.0 |
| scalar | runtime_override | 0.946 / 158.6 | 1.772 / 225.7 | 6.638 / 105.5 |
| scalar | runtime_partial | 0.952 / 157.6 | 1.771 / 225.9 | 6.740 / 103.9 |
| block | fixed | 0.858 / 174.8 | 1.687 / 237.1 | 6.309 / 111.0 |
| block | runtime_baseline | 1.345 / 111.5 | 2.779 / 143.9 | 9.150 / 76.5 |
| block | runtime_override | 1.333 / 112.5 | 2.777 / 144.0 | 9.154 / 76.5 |
| block | runtime_partial | 1.357 / 110.5 | 2.783 / 143.7 | 9.224 / 75.9 |

Safe build:

| Scanner | Settings | `nodes` | `edges` | `subgraph ends` |
| --- | --- | --- | --- | --- |
| scalar | fixed | 0.972 / 154.3 | 1.667 / 240.0 | 7.179 / 97.5 |
| scalar | runtime_baseline | 1.003 / 149.6 | 1.857 / 215.4 | 7.461 / 93.8 |
| scalar | runtime_override | 1.000 / 150.0 | 1.851 / 216.1 | 7.428 / 94.2 |
| scalar | runtime_partial | 1.016 / 147.6 | 1.871 / 213.8 | 7.419 / 94.4 |
| block | fixed | 1.183 / 126.8 | 2.003 / 199.7 | 7.765 / 90.1 |
| block | runtime_baseline | 1.223 / 122.7 | 2.384 / 167.8 | 8.368 / 83.7 |
| block | runtime_override | 1.222 / 122.8 | 2.387 / 167.6 | 8.314 / 84.2 |
| block | runtime_partial | 1.235 / 121.5 | 2.402 / 166.5 | 8.369 / 83.6 |

These time the whole parse, not just the cost of reading the settings. Each
row is compiled differently, so part of the difference is just different
machine code. The files are small, so this can't tell you the cost of run-time
settings in general. Measure the settings and files you actually use.

## Subgraphs

The [subgraph benchmark](../bench/subgraphs.zig) parses empty subgraphs into
fixed buffers with the scalar scanner. Each `{}` is two bytes, plus eight bytes
for the surrounding graph. `siblings` puts them side by side; `nested` puts
each one inside the previous one.

| Shape | Count | Fast | Safe | Document (MB) | Nesting space (bytes) |
| --- | ---: | --- | --- | ---: | ---: |
| siblings | 1,000 | 0.029 / 69.2 | 0.028 / 71.7 | 0.044 | 116 |
| nested | 1,000 | 0.029 / 69.2 | 0.033 / 60.8 | 0.044 | 116,000 |
| siblings | 10,000 | 0.290 / 69.0 | 0.310 / 64.5 | 0.440 | 116 |
| nested | 10,000 | 0.307 / 65.2 | 0.341 / 58.7 | 0.440 | 1,160,000 |
| siblings | 100,000 | 2.930 / 68.3 | 3.169 / 63.1 | 4.400 | 116 |
| nested | 100,000 | 3.081 / 64.9 | 3.481 / 57.5 | 4.400 | 11,600,000 |

Deep nesting can't overflow the call stack, but it does need nesting space for
every open level. 100,000 nested subgraphs need **11.6 MB** of nesting space,
on top of the 4.4 MB document. Setting up that memory isn't timed, and an
allocator that grows as it goes may use more at its peak.

## Markup on its own

The [markup benchmark](../bench/markup.zig) parses markup into fixed buffers of
exactly the right size, with compile-time settings in structural mode. Parsing
in Graphviz mode, the default since 0.5.0, hasn't been timed; its name checks
are timed under [Graphviz vocabulary checks](#graphviz-vocabulary-checks). Times
don't include sizing or setting up the buffers, or any validation.

| Fixture | Source (MB) | Fast, scalar | Fast, block | Safe, scalar | Safe, block |
| --- | ---: | --- | --- | --- | --- |
| flat | 0.200 | 0.575 / 347.8 | 0.601 / 332.5 | 0.638 / 313.3 | 0.668 / 299.5 |
| mixed | 0.750 | 2.344 / 319.9 | 2.568 / 292.0 | 2.553 / 293.8 | 2.672 / 280.6 |
| text | 1.000 | 0.567 / 1,764.5 | 0.080 / 12,466.8 | 0.725 / 1,380.0 | 0.079 / 12,717.8 |
| deep | 0.070 | 0.236 / 296.6 | 0.253 / 276.9 | 0.263 / 266.1 | 0.281 / 249.1 |
| attributes | 1.100 | 3.256 / 337.9 | 3.427 / 321.0 | 3.434 / 320.3 | 3.619 / 304.0 |
| duplicates | 1.100 | 3.232 / 340.4 | 3.447 / 319.1 | 3.445 / 319.3 | 3.657 / 300.8 |
| references | 1.700 | 3.926 / 433.0 | 4.090 / 415.7 | 4.170 / 407.6 | 4.241 / 400.8 |
| attribute_references | 1.800 | 4.149 / 433.8 | 4.167 / 432.0 | 4.178 / 430.9 | 4.281 / 420.5 |
| comments | 1.400 | 1.199 / 1,167.4 | 1.100 / 1,273.1 | 1.330 / 1,052.8 | 1.214 / 1,153.0 |
| cdata | 1.550 | 1.505 / 1,029.7 | 1.425 / 1,087.9 | 1.705 / 909.3 | 1.579 / 981.4 |
| prose | 1.835 | 0.996 / 1,843.2 | 0.284 / 6,470.4 | 1.378 / 1,331.2 | 0.317 / 5,795.5 |
| long_names | 0.655 | 0.247 / 2,647.9 | 0.095 / 6,919.1 | 0.334 / 1,960.6 | 0.115 / 5,706.3 |
| long_values | 1.965 | 1.109 / 1,771.4 | 0.304 / 6,457.9 | 1.528 / 1,285.8 | 0.332 / 5,914.6 |

The fixture names match the benchmark source:

- Most fixtures repeat an item 50,000 times. `prose`, `long_names` and
  `long_values` repeat theirs 5,000 times.
- `deep` is 10,000 nested elements, and `text` is one million bytes of plain
  text.
- `mixed` repeats `<a><b/>text</a>`.
- `attributes` and `duplicates` have three attributes per element. Parsing
  keeps both copies of a duplicate.
- References are checked for form only. They aren't expanded or looked up.

### Memory

The document and nesting space for each fixture. They were the same for both
scanners and both builds. They don't include the source, session state,
diagnostics, validation scratch or allocator overhead, and they aren't the peak
of a growing allocation.

| Fixture | Nodes | Attributes | Document (bytes) | Nesting space (bytes) |
| --- | ---: | ---: | ---: | ---: |
| flat | 50,000 | 0 | 1,000,000 | 12 |
| mixed | 150,000 | 0 | 3,000,000 | 24 |
| text | 1 | 0 | 20 | 0 |
| deep | 10,000 | 0 | 200,000 | 120,000 |
| attributes | 50,000 | 150,000 | 4,000,000 | 12 |
| duplicates | 50,000 | 150,000 | 4,000,000 | 12 |
| references | 100,000 | 0 | 2,000,000 | 12 |
| attribute_references | 50,000 | 50,000 | 2,000,000 | 12 |
| comments | 50,000 | 0 | 1,000,000 | 0 |
| cdata | 50,000 | 0 | 1,000,000 | 0 |
| prose | 10,000 | 0 | 200,000 | 12 |
| long_names | 5,000 | 0 | 100,000 | 12 |
| long_values | 5,000 | 5,000 | 200,000 | 12 |

### Execution options

Fast build, scalar scanner, on the `attributes` and `prose` fixtures:

| How it runs | `attributes` | `prose` |
| --- | --- | --- |
| fixed | 3.256 / 337.9 | 0.996 / 1,843.2 |
| runtime_baseline | 3.287 / 334.7 | 0.991 / 1,852.6 |
| runtime_override | 3.263 / 337.1 | 0.949 / 1,933.9 |
| count_only | 2.865 / 383.9 | 0.937 / 1,958.6 |
| cancellable | 6.070 / 181.2 | 6.091 / 301.2 |

- `runtime_baseline` and `runtime_override` use the same settings as `fixed`,
  passed at run time.
- `count_only` runs `measureIn`. It keeps no tree, but still needs nesting
  space.
- `cancellable` checks a cancel callback that never asks to stop. Metering
  stays off.
- The rows that keep a tree use the same memory as the table above.

### Validation on its own

Optional checks on a document that is already parsed, with compile-time
settings and scratch arrays set up in advance. Parsing, and storing or printing
diagnostics, are not timed. These fixtures are separate from the parsing ones.

| Check | Source (MB) | Fast | Safe | Scratch (bytes) |
| --- | ---: | --- | --- | ---: |
| Duplicate attributes | 1.100 | 0.922 / 1,193.1 | 1.431 / 768.7 | 24 |
| ASCII names | 1.400 | 1.514 / 924.7 | 1.876 / 746.1 | 0 |
| Unicode names | 1.100 | 1.020 / 1,078.9 | 1.395 / 788.6 | 0 |
| Reference list | 1.250 | 1.343 / 930.5 | 1.515 / 825.2 | 0 |
| Encoding, ASCII text in UTF-8 | 0.500 | 0.117 / 4,284.3 | 0.127 / 3,929.7 | 0 |
| Encoding, Unicode text in UTF-8 | 0.600 | 0.670 / 895.5 | 0.735 / 816.2 | 0 |
| Encoding, invalid UTF-8 | 0.350 | 0.366 / 956.7 | 0.513 / 682.4 | 0 |
| All checks together | 1.200 | 2.727 / 440.1 | 3.372 / 355.8 | 16 |

- The duplicate fixture has 50,000 repeated keys.
- Name checks use the XML 1.0 rules. The reference check uses the five XML
  names (`amp`, `lt`, `gt`, `quot`, `apos`).
- The encoding rows use `invalid_encoding` on UTF-8 input.
- "All checks together" turns on names, references, the encoding check and
  duplicate keys.
- Findings in the invalid inputs are counted and thrown away, not stored.

### Checking markup that failed to parse

[`validateSourceIn`](MARKUP.md#checking-a-fragment-that-failed-to-parse) checks
the parts it can recognise, without building a tree. This is the
`--scopes-only` run. Each fixture repeats an item 10,000 times and reports
20,000 validation errors.

| Fixture | Source (MB) | Fast, scalar | Safe, scalar | Scratch (bytes) |
| --- | ---: | --- | --- | ---: |
| complete | 0.260 | 1.093 / 237.9 | 1.301 / 199.8 | 72 |
| bad_closer | 0.300 | 1.118 / 268.2 | 1.307 / 229.6 | 72 |
| bad_header | 0.360 | 1.562 / 230.4 | 1.874 / 192.1 | 72 |

- `complete`: every tag is finished, though attributes and references still
  have errors.
- `bad_closer`: closing tags are wrong, but every tag can still be checked on
  its own. This says nothing about whether the tags nest correctly.
- `bad_header`: some tags are cut off, so checking skips ahead and reports that
  it couldn't check everything.

Don't compare these with full-document validation times; they do different
work.

### Graphviz vocabulary checks

This is the `--graphviz-only` run. It validates an already parsed document in
each mode, with duplicate checking on in both. Parsing and storing diagnostics
aren't timed.

- `tables`: 10,000 copies of a small valid Graphviz table, with `<TABLE>`,
  `<TR>`, `<TD>`, `<B>` and `<BR>` and their attributes.
- `invalid`: 10,000 copies of an unknown element and two disallowed
  attributes. Graphviz mode reports three errors per copy.

| Input | Mode | Settings | Source (MB) | Fast | Safe | Scratch (bytes) |
| --- | --- | --- | ---: | --- | --- | ---: |
| tables | structural | fixed | 0.980 | 0.142 / 6,898.6 | 0.228 / 4,303.6 | 16 |
| tables | structural | run-time | 0.980 | 0.143 / 6,854.8 | 0.230 / 4,259.0 | 16 |
| tables | graphviz | fixed | 0.980 | 0.575 / 1,705.3 | 0.772 / 1,270.1 | 16 |
| tables | graphviz | run-time | 0.980 | 0.658 / 1,489.0 | 0.913 / 1,073.0 | 16 |
| invalid | structural | fixed | 0.380 | 0.034 / 11,066.5 | 0.063 / 6,056.1 | 0 |
| invalid | structural | run-time | 0.380 | 0.035 / 10,728.7 | 0.068 / 5,625.3 | 0 |
| invalid | graphviz | fixed | 0.380 | 0.256 / 1,484.4 | 0.361 / 1,052.3 | 0 |
| invalid | graphviz | run-time | 0.380 | 0.340 / 1,119.2 | 0.469 / 809.8 | 0 |

- Each element and attribute is looked up with a few short comparisons. The
  checks keep nothing extra in the document and allocate nothing themselves.
- Validating a document still walks its elements and attributes once.
  Duplicate checking costs what it did before.
- `validateSource` needs no buffer for tags when duplicate checking is off.
- A profile fixed at compile time to structural mode leaves the Graphviz checks
  and case-insensitive matching out of the program. A profile with run-time
  settings includes both modes, which makes the program larger.
- Validation still can't run in small steps. Cancelling and stopping work as
  before.

## DOT with label checking

The [composition benchmark](../bench/composition.zig) uses a DOT profile with
the markup parser bound as its
[label checker](LABELS.md#check-every-label-while-parsing), in structural mode,
and calls `parseAndValidate`. Times include parsing the DOT, checking the labels,
validating, and freeing the result. Both parsers use the scanner shown.
Diagnostics are thrown away.

The benchmark covers both fixed and runtime policies for both parsers, labelled
`fixed` and `runtime` in its output. The recorded table below uses fixed policies.

- `plain`: 1,000 nodes and no labels. The label checker is bound but has
  nothing to do.
- `labels`: 1,000 labels of `<b x='1' y='2'>t</b>`.
- `invalid`: 1,000 labels, each with a repeated attribute and a wrong closing
  tag. The DOT itself is fine, but the file as a whole is invalid.
- `large_first`: one label with 10,000 elements, followed by 50,000 plain
  nodes.

| Fixture | Scanner | Source (bytes) | Fast | Safe | Peak (bytes) | Allocations / resizes / remaps |
| --- | --- | ---: | --- | --- | ---: | --- |
| plain | scalar | 2,010 | 0.024 / 84.2 | 0.024 / 82.7 | 27,064 | 2 / 0 / 19 |
| plain | block | 2,010 | 0.026 / 77.7 | 0.029 / 70.1 | 27,064 | 2 / 0 / 19 |
| labels | scalar | 32,010 | 0.216 / 148.2 | 0.228 / 140.1 | 44,260 | 7 / 0 / 29 |
| labels | block | 32,010 | 0.247 / 129.7 | 0.280 / 114.4 | 44,260 | 7 / 0 / 29 |
| invalid | scalar | 35,010 | 0.305 / 114.6 | 0.338 / 103.7 | 44,404 | 8 / 0 / 29 |
| invalid | block | 35,010 | 0.345 / 101.6 | 0.385 / 91.0 | 44,404 | 8 / 0 / 29 |
| large_first | scalar | 140,029 | 1.313 / 106.7 | 1.354 / 103.4 | 1,670,604 | 5 / 0 / 55 |
| large_first | block | 140,029 | 1.396 / 100.3 | 1.543 / 90.8 | 1,670,604 | 5 / 0 / 55 |

**Peak** is the most memory the library had asked for at any one moment
during a call, measured with a separate counting allocator. It doesn't include
the source, the allocator's own bookkeeping or the copies it makes while
resizing, or the program's total memory use. The last column counts calls to the allocator, not requests to the
operating system.

The label checker's buffers can stay allocated while DOT's own buffers grow;
`large_first` tests exactly that. After each call, the counting allocator
confirms that everything was freed.

## How these were measured

- **Machine:** Apple M4 Pro, 14 CPU cores, 48 GiB RAM, native aarch64 macOS
  27.0 (26A428). The CPU was not pinned and its speed was not fixed.
- **Builds:** Zig 0.16.0, `ReleaseFast` and `ReleaseSafe`.
- **Running:** the [benchmark programs](../bench/) were built before timing and
  ran one at a time, with no builds or other benchmarks running.
- **Repeats:** each time is the median of five runs, and each run reports the
  median of its own timed rounds. The order of scanners and builds alternated
  between repeats, and no runs were thrown away.
- **Rounding:** numbers are rounded as the benchmark programs print them. DOT
  speeds are worked out from the source size and the time, rather than copied
  from the programs' MiB/s output.

| Benchmark | Warm-up rounds per run | Timed rounds | Operations per round |
| --- | ---: | ---: | ---: |
| DOT parse and validate, lexer, sessions, subgraphs | 2 | 9 | 1 |
| Settings | at least 150 ms | 9 | 4 |
| Markup parsing and validation | 5 | 9 | 16 |
| DOT with label checking | 3 | 9 | 10 |

When a round does several operations, the time shown is per operation.

**What isn't timed:** building the test input, reading files, and storing or
printing diagnostics. Diagnostics are counted but thrown away. Fixed-buffer
benchmarks also leave out sizing and setting up the buffers.

**What isn't covered:** real-world files, `ReleaseSmall` speed, step-by-step
markup parsing, the peak memory of markup trees built with an allocator, and
comparisons with older versions.

**How much runs varied.** The five DOT parse-and-validate runs fell within
these ranges. They are just the lowest and highest results, not confidence
intervals:

| Build / scanner | Growing (ms) | Hinted (ms) |
| --- | ---: | ---: |
| Fast / scalar | 7.81–8.26 | 6.50–6.88 |
| Fast / block | 8.01–8.30 | 6.77–7.27 |
| Safe / scalar | 8.74–9.25 | 7.30–7.45 |
| Safe / block | 9.90–10.17 | 8.14–8.51 |

Short tests varied more. The `plain` label-checking case ranged from 0.024 to
0.065 ms in the Fast build, and 1,000 sibling subgraphs from 0.026 to 0.035 ms.
Some markup cases also moved between runs: plain `text` with the scalar scanner
in a Safe build ranged from 0.636 to 0.849 ms. Treat small differences between settings or
builds as noise, not as dependable speedups.

In the settings benchmark, run-time settings are read in a way the compiler
can't see in advance, so it can't optimize them away. That reading happens
outside the timer.

## Running the benchmarks

### One-command string comparison

> **Unreleased.**

Use the Zig-native reporter to compare the working tree against a Git revision:

```sh
zig build perf-string -- --baseline HEAD
zig build perf-string -- --baseline HEAD --modes fast,safe,small --runs 5
zig build perf-string -- --baseline HEAD --suites sessions --modes fast
```

The default is both `native` and `sessions`, Fast and Safe builds, three process
runs per side. Each benchmark run uses seven timed batches after two warmups.
`native` covers UTF-8/16LE/32LE, available comparison modes and built-in/custom
equality. `sessions` covers UTF-8 default encoding validation, exact equality,
runtime policies, budgets 1 and 64, cancellation intervals 1 and 64, custom
stepped/batched validators and membership. `--help` lists the options.
The optional `logical` suite compares plain/DOT/markup logical readers on
short, long, Unicode and glue/reference-heavy values, including budgets 1 and
64 and exact credit/session-size accounting. It uses five timed batches after
two warmups. `integration` and `host-defaults` use nine after three.

The runner captures both source trees and the current harness, builds everything
with the **same compiler**, then executes one benchmark at a time in alternating
before/after order. It reads Git objects without checking out or changing a
branch. Both snapshots must support the selected compiler: a pre-migration
Zig 0.16 snapshot cannot be compared using the 0.17 reporter without porting
that snapshot first. A baseline predating the required API fails the build explicitly; it is
not silently treated as passing. Newly supported comparison modes are reported
as **new**, with no invented baseline or percentage.

Reports go into a new `zig-out/perf-string/<timestamp>/` directory, or a new
directory specified by `--output`. Existing report directories are refused.
Each report includes:

- `summary.md`: group summaries and case-by-case timings and decimal MB/s.
- `results.csv` and `raw/`: medians, observed ranges, per-run results, session
  sizes, credit totals and cancellation poll counts.
- `metadata.txt`, source manifests and captured harness/sources: compiler,
  architecture/OS, revision, dirty-tree status and exact inputs to reproduce it.
- `binaries.csv`: consumed benchmark executable sizes, **not library size**.

A time increase above `--threshold` (default 5%) with non-overlapping observed
run ranges is flagged `slower`. Overlapping ranges crossing the threshold are
`inconclusive`. Neither this heuristic nor a geometric mean replaces inspecting
individual cases; `within_threshold` is not a blanket no-regression guarantee.
The suites use hot buffers and discard diagnostics. Zero processor heap
allocations in these fixtures do not imply zero process memory, zero stack
usage, or zero allocations with growable bags/custom callbacks. All builds
finish before timing; avoid other heavy work while the measurements run.

The existing benchmark commands remain useful for individual measurements;
the two string benchmarks also accept `-- --csv` for machine-readable output.
The reporter itself is tested by `zig build check-tools` and `zig build test`.
It does not yet orchestrate DOT/markup suites, RSS sampling or Wasm size checks.

### Individual benchmarks

Run one benchmark at a time, with no builds or other heavy work running:

```sh
zig build bench -Doptimize=fast -Dlexer=scalar
zig build bench-lexer -Doptimize=fast -Dlexer=scalar
zig build bench-session -Doptimize=fast -Dlexer=scalar
zig build bench-cancellation -Doptimize=fast
zig build bench-subgraphs -Doptimize=fast -Dlexer=scalar
zig build bench-policy -Doptimize=fast
zig build bench-markup -Doptimize=fast
zig build bench-markup -Doptimize=fast -- --scopes-only
zig build bench-markup -Doptimize=fast -- --graphviz-only
zig build bench-composition -Doptimize=fast
zig build bench-logical-strings -Doptimize=fast
zig build check-benches  # only checks that they compile
```

Repeat everything with `-Doptimize=safe`. Repeat the first four with
`-Dlexer=block` too; the others already cover both scanners where it matters.
Run each one five times and take the median. `bench-markup` also accepts
`-- --rules-only` and `-- --validation-only` for shorter runs.

`bench-policy` warms each case for at least 150 ms and averages four parses per
sample, because two short warm-up parses didn't reliably settle the first case.
