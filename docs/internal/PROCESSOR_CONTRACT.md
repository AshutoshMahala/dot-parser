# Processor preparation contract — internal design

Decisions reconciled 2026-09-26. This contract guides the preparation slice;
it does not claim that HTML recognition, markup parsing, processor scheduling,
or bounded validation is implemented. This document is the durable design record;
it must not depend on disposable working files. Current preparation code is
described in [the implementation notes](PROCESSOR_PREPARATION.md). The later
[standalone structural slice](MARKUP.md) is now implemented independently; DOT
recognition and stage scheduling still do not exist. This preparation contract
does not make standalone use depend on the composition APIs below.

## Binding and initialization

Processor implementations are selected at compile time. Bind configured profiles,
not implementations which DOT must configure or inspect. Each profile owns its
policy schema, compiled baseline and default-off runtime override support. Built-in
and consumer processors follow the same contract. Runtime registration/replacement
and per-fragment capability discovery are excluded.

Resolve and verify all enabled runtime policies once per operation, before any
processing or callbacks. Fixed policies are already verified at compile time and
need no runtime settings object. Initialization borrows source/storage/sinks,
checks constant-size descriptors, and performs no scan, allocation or callbacks.
Input-dependent capacity failures are checked while executing. Initialize/reuse
fragment state as needed, without retaining an instance for every identifier.

Share mechanisms with matching contracts; keep schemas, diagnostic payloads and
output types processor-owned. There is no universal largest diagnostic union.
Ordinary DOT must not gain processor metadata on every retained record. Static
composition permits inlining; forced inlining still requires measurement.

## Execution and completion

`run()` drives execution to a terminal result. A metered `advance(budget)` pauses
when credits run out and resumes without repeating work or callbacks. Child work
must be charged to the parent's remaining budget; an unbounded callback is not a
bounded processor. Current DOT validation remains unmetered until separately
implemented; this preparation slice must not claim bounded composed validation.

For retained composition, run outer DOT validation then selected inner fragments
in source order. Ordinary findings do not stop independent checks or fragments.
Missing prerequisites make dependent work unavailable, not successful. An explicit
operational stop ends remaining requested work; independently invoked operations
are unaffected. Standalone, delayed and during-DOT workflows remain supported
design goals; no retained tree is mandatory for every processor.

Keep completion, validity and diagnostic delivery separate. Requested work stopped
before starting is incomplete with a reason, not "not requested". Completed outer
results survive inner failures. Active transactional output commits or aborts once;
pausing does neither. Abort cannot undo arbitrary consumer side effects. Reading
results or repeating terminal execution must not repeat callbacks. Detailed
per-fragment results are opt-in, not a mandatory retained array.

## Diagnostic destinations and stopping

| Destination | Storage / default behavior |
| --- | --- |
| Fixed bag | Caller-owned entries; accepting the last entry requests stopping |
| Growable bag | Explicit caller allocator; default 1,024-entry limit; last accepted entry requests stopping |
| Streaming sink | Consumer decides retention, filtering and whether to continue |

General examples use growable bags. Allocation-free examples keep fixed storage.
Growth belongs to the sink, not the processor. Growable initialization need not
allocate; clearing retains capacity and explicit destruction releases it. An
entry limit is not a promise about allocator overhead or process RSS.
Finite limits use `EntryLimit.limited: u16` (0–65,535); `.unlimited` is an explicit
alternative, not a sentinel. Allocation sizes and slice lengths remain native
sizes, and factual counters are not narrowed. The limit belongs to a bag's
lifetime between resets, so sharing a bag across stages shares its remaining
budget. Growth can transiently retain old and new allocations; arenas can retain
abandoned buffers until their own teardown.

An accepted item returns continue or stop. A rejected item reports capacity,
allocation failure or delivery failure. Accepted-stop means the item was delivered
but requested work may remain incomplete. Zero-capacity bags reject the first
attempt; they do not require a readiness poll before processing. An explicit
prefix-and-count bag may continue after filling; silent filtering/discarding is
not a stop. Factual counts include discovered findings even if delivery fails,
and must never imply that unvisited input was checked.

Explicit diagnostic stop/failure terminates unfinished DOT parsing/validation,
not just future inner work. A failure being reported after an operation has
already failed does not erase that original failure; delivery remains separate.
Never recursively report a broken diagnostic sink through itself.

This revises the old default fixed-bag omission and continue-after-delivery-failure
behavior. No compatibility aliases or legacy implementations are required.

## Ownership, reset and coordinates

Processors never clear or destroy caller-owned bags or free borrowed storage.
Invalid reset leaves the old session intact; valid reset stops unfinished old
work before reusing its resources. Retained payload references must outlive their
destination; copying a diagnostic does not copy its referenced data. Bag views
expire according to documented growth/reset/destruction rules.

Raw fragments use checked u32 ranges and one local-to-original rebase for every
primary, related and fix span. Decoded/concatenated input requires a separate
source map. Source origin is per active fragment, not per DOT identifier.

Keep existing DOT source ordering. Composed ordering and selector/concatenation
rules need their own final API tests; no global source-sorted guarantee is implied
by phase order. Markup grammar and full session composition are subsequent slices.

## Acceptance checks

Before refactoring, retain a same-host/compiler benchmark executable; do not update
official standard-machine baselines. Compare fixed/runtime policies and both
scanners, throughput/latency, retained storage, session and diagnostic sizes and
binary size. Test zero/full/growing bags, allocation failure, explicit omission,
terminal latching, independent findings, reset atomicity, typed consumer schemas,
source-span rebasing and compile-time rejection of incompatible binding.
