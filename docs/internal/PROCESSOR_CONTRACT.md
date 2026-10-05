# Processor contract — remaining design

Reconciled: 2026-10-05. This file retains only unfinished composition/API design
and acceptance work. Current binding, preparation, workspace, reporting and
ownership contracts are documented in [custom processors](../CUSTOM_PROCESSORS.md),
[DOT integration](../LABELS.md) and [standalone markup](../MARKUP.md).
R-MOD-015 and Q40 in [Requirements](REQUIREMENTS.md) and
[OpenQuestions](OpenQuestions.md) remain binding.

## Remaining design

These are not available APIs or a claim that implementation is in progress.

| Work | Constraint for the new work | Decisions still required |
| --- | --- | --- |
| Shared-budget composition | Child work counts against the parent budget | Metered validation, budget units, yield/resume state, cancellation propagation and failure precedence |
| Fixed-memory during-DOT composition | Caller-owned bounded storage; exhaustion stays explicit | Resource descriptors, scratch sharing, capacities and result lifetimes |
| Recursive / quoted-content execution | Compile-time binding; processor-owned schemas/content rules | Scheduling boundaries, selection, aggregation and a real string-processor contract |
| Broader profile/API surface | Keep low-level ownership and costs explicit | Outer-only versus composed operations, a whole-composition `validatePolicy` entry point and convenience result/ownership choices |
| Context-specific label selection | Graphviz label rules must not apply to unrelated IDs | Selection metadata/API and when enough DOT context is available |
| New token spellings | An inner processor cannot redefine its outer parser's lexical boundaries | A separate contract for escaping, collisions, recovery and work |
| Source transforms / retained summaries | Explicit owners, mapping and costs; no hidden per-ID state | Decoded/transcoded maps, caching, summary layout and public events |

### Shared-budget execution

First make required validation work resumable and credit-metered. Markup
validation needs metering/resumption; DOT validation additionally needs
cancellation. A composed bounded operation cannot call an unbounded library pass
and still claim its budget was respected.

Define:

- Work units across scanning, parsing, validation, sorting and scope revisits;
  where allocation and consumer callbacks sit outside any bounded-work promise.
- Parent/child budget allocation, suspension points and state retained while a
  child is paused. Nested policy preparation alone is not an execution scheduler.
- Shared cancellation propagation through every active stage and validation pass.
- Completion, diagnostic delivery and failure precedence when a stop follows
  earlier syntax/validation errors, including work not yet started.
- How prepared policies/resources remain latched across yields and how reset
  handles suspended outer and inner work atomically.

For future composed sessions, `run()` must reach a terminal result and
`advance(budget)` must yield without repeating work or callbacks. Pausing is not
aborting; transactional output must commit/abort only once. An invalid reset must
leave the old operation intact; a valid reset must clean up unfinished work.
Independent parent/child error policies must retain their meaning across yields.

### Fixed-memory during-DOT composition

Define caller-supplied resource descriptors for outer pools, active child
storage, nesting and validation scratch. Decide which storage can be reused
without overwriting state still needed by a suspended parent or child, and how
capacities are established before execution.

Specify the lifetime of views across child completion, parent resumption, reset
and storage reuse. Keep independently retained child results opt-in, rather than
requiring an array or processor instance per identifier. Exhaustion must remain
an explicit incomplete operation, not silent truncation or fallback allocation.

### Recursive and quoted-content execution

Automatic DOT → markup → string and DOT → string execution still needs a
scheduler and a concrete string-processor contract. Specify scope selection,
ordering, stage compatibility, result aggregation and diagnostic context across
multiple active levels. Keep implementations compile-time-bound with independent
policy schemas; do not introduce runtime discovery to select an inner parser.

Quoted or concatenated content needs an explicit choice of raw versus decoded
input. If decoding changes offsets, define source maps and their ownership/costs
before promising original-source diagnostics or fixes. Each original operand's
origin must remain distinguishable; offsets must not be rebased repeatedly at
each parent.

Cross-scope SIMD or parallel scheduling is only a possible later optimization.
Do not add copying, mandatory queues or retained child arrays to prepare for it.
Measure any concrete proposal with differing scope lengths, cancellation and
diagnostic ordering.

### Broader profile/API surface

Revisit the deferred facade proposal explicitly: access to outer-only operations
from a composed profile, a whole-composition `validatePolicy` entry point, and a
simpler user-facing parse/result API. This is a public API decision, not missing
verification during preparation. Ownership/copying, diagnostic destination
defaults and acceptance versus document state need decisions before choosing
that surface.

A future consumer-data adapter is separate from these execution changes. Do not
couple a convenience wrapper or user-defined graph construction to the first
bounded-composition implementation.

### Context-specific label selection

Design selection metadata and its availability relative to operand boundaries.
Graphviz-specific checks must distinguish labels from ordinary identifiers and
ports; their grammar is in the [markup plan](MARKUP.md#graphviz-and-extended-rules).
This is automatic context-aware selection, not another implementation of explicit
delayed calls.

### New token spellings

Custom token spellings require a separate lexical-extension contract covering
boundaries, escaping, collisions with existing DOT tokens, safe recovery and
bounded work. Replacing an inner processor does not supply that contract.
New DOT statements or operators are outside inner-processor composition.

### Source transforms and retained summaries

Decoded/concatenated maps, UTF-16/32 conversion maps, summary caches and public
events still need explicit representations and lifetimes. Follow the
[encoding constraints](MARKUP.md#encoding-adapters) and
[summary proposal](MARKUP.md#optional-summaries-and-retention); raw-fragment offset
rebasing is not a replacement for those designs. Do not impose their storage or
rescan costs on callers that use only contiguous raw bytes.

## Acceptance checks

For the new execution paths, add coverage for:

- Zero/tiny/exact budgets and suspension in each outer/inner phase, with no
  repeated work, findings or callbacks after resume or terminal completion.
- Shared cancellation, full/failing sinks and storage exhaustion during child
  parsing and validation; factual prefix results must remain incomplete when
  requested work stops.
- Parent/child `collect` / `fail_fast` combinations across yields and nested
  execution, keeping unsupported classification separate from processing.
- Invalid-reset atomicity, valid-reset cleanup, fixed-buffer reuse and optional
  retained-result lifetimes.
- Typed custom processor compatibility, compile-time rejection of incompatible
  stage/resource contracts and source mapping across more than two levels.

Use the recorded [performance baseline](../PERFORMANCE.md) for reproducible
comparisons and preserve the outstanding
[verification gates](MARKUP.md#verification-and-performance-gates). Measure
state size and storage overlap as well as throughput; static composition does
not by itself establish zero overhead. Standalone operation must stay independent
of these extensions. Compile-time binding does not sandbox custom code, so its
budget, callback and ownership obligations need explicit tests.
