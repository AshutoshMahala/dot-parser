# Processor contract — current guarantees and remaining design

Reconciled: 2026-10-04. Keep this internal contract while composed execution
still has unfinished designs. User-facing APIs are in
[custom processors](../CUSTOM_PROCESSORS.md) and [label integration](../LABELS.md).
Standalone parsing does not depend on composition.

| Capability | Delivery status |
| --- | --- |
| Schema-owned policy binding and nested policy preparation | Implemented; preparation is not execution |
| Checked fragments and original-source diagnostics | Implemented for contiguous raw bytes |
| Standalone and delayed processing | Implemented, including explicit fixed-memory calls |
| One-shot during-DOT processing and shared reporting | Implemented, with a compile-time-selected processor |
| Workspace reuse and silent unsupported handling | Implemented |
| Fixed-memory / resumable during-DOT composition | Agreed direction; not implemented |
| Recursive execution, quoted-content scheduling and profile redesign | Further design required |

The completed preparation implementation notes have been consolidated here;
there is no separate preparation task remaining. Future work is listed under
[remaining design](#remaining-design), not implied by the implemented interface.

## Binding and initialization

Processor implementations are selected at compile time. Bind configured profiles,
not implementations which DOT must configure or inspect. Each profile owns its
policy schema, compiled baseline and default-off runtime override support. Built-in
and consumer processors follow the same contract. Runtime registration/replacement
and per-fragment capability discovery are excluded.

DOT's `policy.markup` selects `.none`, `.passthrough` or `.process`; it does not
select a child grammar. Binding a child defaults to process, otherwise the default
is passthrough. Explicit leaves, including complete presets, take precedence.
The built-in markup child currently exposes only `policy.mode = .structural`;
replacement schemas need not have this field. Unbound process fails policy
verification. Runtime processing selection cannot install or replace a child.

Resolve and verify all enabled runtime policies once per operation, before any
processing or callbacks. Fixed policies are already verified at compile time and
need no runtime settings object. Initialization borrows source/storage/sinks,
checks constant-size descriptors, and performs no scan, allocation or callbacks.
Input-dependent capacity failures are checked while executing. Initialize/reuse
fragment state as needed, without retaining an instance for every identifier.

The one-shot facade uses `Prepared.initWorkspace(allocator, resources)` once and
`workspace.parseAndValidate(fragment, sink)` for each selected operand. Workspace
initialization is allocation-free; growth belongs to execution. The child owns
its reusable buffers and `deinit` releases them on every exit. Results borrow that
workspace until the next call/deinit; the facade consumes results immediately and
does not deinitialize them or retain trees. Custom processors implement this same
structural contract without exposing buffer layouts or runtime capability queries.

Share mechanisms with matching contracts; keep schemas, diagnostic payloads and
output types processor-owned. There is no universal largest diagnostic union.
A composed profile may generate a tagged union of only its bound processors for
one caller-facing bag/sink. Each entry then fits the largest bound payload plus
tag/alignment; ordinary processor bags retain their independent compact layouts.
Ordinary DOT must not gain processor metadata on every retained record. Static
composition permits inlining; forced inlining still requires measurement.

### Schema-owned preparation

`processor.PolicyBinding(Schema, config)` supplies baseline verification,
`validatePolicy`, `Options`, `State` and `prepare`. The schema owns `Policy`,
`Effective`, `defaults`, `resolve`, `check` and `Error`. A fallible check carries
an issue with `asError()`; an infallible schema uses `error{}` and a valid-only
check. Handle results exhaustively rather than inventing an invalid case or
silently discarding future cases.

Resolution/checking are pure and allocation-free. The original patch reaches
`check`, so explicit and inherited fields remain distinguishable. Public and
effective layouts need not match; deriving one mechanically from the other is
not a settled requirement. Fixed bindings have `State = void`, empty options and
compile-time-only verification. Runtime support is default-off; enabled bindings
resolve/check once per preparation, never replace an implementation.

`PolicySet` takes named configured profile types exposing `Policies`; sets expose
that same binding and may nest. Preparing a root visits each runtime leaf once;
all-fixed subtrees need no runtime settings storage. Repeated implementations at
different paths have independent settings. This supports DOT → markup → string
and sibling string policies without implementing a recursive execution scheduler
or supplying a built-in string processor.

Ordinary DOT methods still prepare their own options: calling `PolicySet.prepare`
first does not make them reuse that state. Markup can reuse its state through
`Prepared{ .policies = state.path }` or its own `prepare`. The composed facade
prepares outer and child policies once before entering the engine. Workspace
calls reuse prepared policies and buffers without capability discovery.

None/passthrough still verify configured policies but skip child workspace
initialization, parsing, validation and cancellation callbacks. Reports mark
markup `requested = false`, `complete = false` and `allValid() = false`; combined
validity checks only the requested work. A process operation marks requested true
even if a stop prevents the first visit. It does not claim completion in that case.

Evidence: [binding and fragment implementation](../../src/common/processor.zig),
[consumer tests](../../tests/processors.zig),
[workspace tests](../../tests/markup_workspace.zig) and
[composition](../../src/dot/composition.zig).

## Execution and completion

The current composed facade runs to completion and exposes no `Session` or
`advance`. Existing standalone bounded sessions do not make composition bounded.
Markup validation supports cancellation but is not credit-metered/resumable;
DOT validation is neither cancellable nor credit-metered/resumable. Child hooks
are component-specific: an outer hook alone cannot interrupt an uncancellable
child. Shared accounting belongs to the future contract below.

The delayed recipe runs outer DOT validation then selected inner fragments in
source order; explicit independent calls remain caller-ordered. During-DOT
one-shot composition instead processes each
recognized HTML operand at its scanner boundary, before the next DOT grammar
transition, then validates outer DOT after parsing succeeds. These are distinct
phase orders, not a global source-sort promise. Default `.on_error = .collect` keeps independent checks/fragments
running after ordinary errors; explicit `.fail_fast` ends the active operation
at its first error. Recovery is the internal safe synchronization needed to
collect syntax findings, not another public policy. Warnings do not trigger
fail-fast and sink filtering never changes error classification.
Missing prerequisites make dependent work unavailable, not successful. An explicit
operational stop ends remaining requested work; independently invoked operations
are unaffected. Standalone, delayed and one-shot during-DOT workflows are supported;
the composed helper resets each temporary child tree and reuses its capacity,
freeing workspace buffers at operation exit. Retaining independent child
trees remains an explicit delayed operation; no per-fragment result array is added.
Reuse reduces allocator traffic; retained high-water buffers can increase peak
live memory when a large early child is followed by growing outer output. Measure
allocation calls and peak requested bytes separately; neither is process RSS.

Keep completion, validity and diagnostic delivery separate. Requested work stopped
before starting is incomplete with a reason, not "not requested". Already completed
outer results survive later inner failures; a stop during outer parsing need not
leave a document. Active transactional output commits or aborts once;
pausing does neither. Abort cannot undo arbitrary consumer side effects. Reading
results or repeating terminal execution must not repeat callbacks. Detailed
per-fragment results are opt-in, not a mandatory retained array.

Parent and child error handling are independent. The child completes/stops under
its own policy, then the parent decides whether to visit the next child. Parent
collect/child fail-fast continues with the next fragment; parent fail-fast/child
collect retains all findings from that child before stopping. Local policy limits
stop the child and count as errors, not unconditional batch stops. Sink stops,
allocation/storage failures and cancellation remain operational batch stops.

`diagnostics.unsupported = .err | .warning | .silent` (default `.err`) controls
classification/reporting, not acceptance or processing. Preserve the factual
unsupported outcome; warning/silence cannot make unprocessed bytes valid. Unsafe
boundaries may end the fragment under any reporting choice. Supported passthrough
recognition is distinct from silent unsupported input. Both parsers skip
user-facing diagnostic construction/delivery on the silent unsupported path;
only internal classification needed for control flow remains. There is no hidden
first-unsupported diagnostic metadata. Delayed markup implements
`has_errors` and `shouldStop(parent_on_error)`; `.stopped()` denotes operational
stops only. Fail-fast combined calls do not start validation after a syntax error.

### Local validation scopes

Recognizing a boundary, checking its content, and matching its enclosing structure
are separate responsibilities. A check needs trustworthy bytes for its own scope,
not a valid enclosing tree. An opening header, attribute name, attribute-value
content, text, closing name and element matching have different prerequisites.
An unfinished enclosing header may still contain complete strings or recognized
names; report known findings without claiming coverage of unavailable regions.
No inferred delimiter, typo correction or partial-tree publication follows from
this separation. Operational stops still end the requested operation.

Standalone markup implements borrowed `ValidationScope` inputs and independent
source-scope traversal, sharing document validation's kernels. Neither changes
parse-only calls or creates a composed scheduler. Future compile-time-bound string
processors can consume these local views; they are not implemented by this slice.
Detailed results remain opt-in calls rather than a retained object per scope.

Caller-built scope metadata is checked at the public boundary in every build
mode; invalid metadata is `invalid_scope`, not a source finding. Internally
produced spans bypass the audit. An incomplete local result carries the earliest
coverage gap in supplied-source bytes (rebased by fragment wrappers), not a
resume cursor: other independent checks and regions can have completed beyond it.

The source walk checks opening names, not closing names already covered by
syntax. An explicit `closing_name` scope remains available. Source validation
runs encoding first and then local checks; deterministic emission does not mean
global source sorting. It enforces the source-byte limit, not tree/nesting parse
limits or a shared execution budget.

Uniform byte spans may help SIMD within a region and future batching of scopes
using the same rule/profile. Cross-input SIMD is not automatic: lengths, alignment,
state, diagnostic ordering and cancellation differ. No batching, parallel execution
or performance improvement is promised without measurement; do not add copying or
mandatory queues for that possibility.

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
Both parsers preserve terminal acknowledgments in `diagnostic_stop`,
separate from the original outcome and delivery status. Fragment wrappers check
it before starting validation, including when the terminal syntax finding filled
a bag and was successfully delivered. No additional readiness callback is needed.

## Ownership, reset and coordinates

Processors never clear or destroy caller-owned bags or free borrowed storage.
Invalid reset leaves the old session intact; valid reset stops unfinished old
work before reusing its resources. Retained payload references must outlive their
destination; copying a diagnostic does not copy its referenced data. Bag views
expire according to documented growth/reset/destruction rules.

Raw fragments use checked u32 ranges and one local-to-original rebase for every
primary, related and fix span. Decoded/concatenated input requires a separate
source map. Source origin is per active fragment, not per DOT identifier.
`Fragment.init`, `fromSource` and `child` check ranges; the caller establishes
provenance. Valid coordinates do not prove that arbitrary bytes came from that
file. Child origins already refer to the original source: do not rebase at each
parent again. Fixed-buffer views expire when storage is reused or released.

Future UTF-16/32 adapters may supply UTF-8 working bytes, but must preserve original
encoding/byte-order/BOM provenance at the source level. The existing raw-fragment
rebase is not a transcoding map. Distinguish original-file and working-buffer
coordinates; exact original rendering needs live original bytes or a source handle.
Adapter metadata, conversion-error behavior and mapping APIs remain unimplemented;
their allocation and rescan costs must be explicit, not added to every raw fragment.

Keep existing DOT source ordering. Delayed calls explicitly select preserved
operands; each is parsed then validated independently. No global source-sorted
guarantee is implied by phase order. Automatic one-shot selection visits every
recognized HTML operand; application-specific selection remains explicit delayed
work. Fixed-memory and full resumable session composition remain subsequent slices.

## Remaining design

These are not available APIs or a claim that implementation is in progress.

| Work | Settled constraint | Decisions still required |
| --- | --- | --- |
| Shared-budget composition | Child work must count against the parent budget; no unbounded library callback inside a bounded operation | Metered validation, budget units, yield/resume state, cancellation propagation and failure precedence |
| Fixed-memory during-DOT composition | Caller-owned bounded storage; exhaustion stays explicit | Resource descriptors, scratch sharing, capacities and workspace/result lifetimes |
| Recursive / quoted-content execution | Compile-time binding; each processor owns its schema and content rules | Scheduling boundaries, selection, result aggregation and a real string-processor contract |
| Broader profile/API surface | Existing `.processors.markup` is implemented | Revisit the deferred API proposal explicitly; workspace reuse did not decide it |
| Context-specific label selection | Graphviz label rules must not apply to unrelated IDs | Selection metadata/API; delayed selection already works |
| New token spellings | Replacing an inner processor cannot change DOT's lexical boundaries | Separate lexical contract for escaping, collisions, recovery and work; new statements/operators are outside this contract |
| Source transforms / retained summaries | Explicit owners, mapping and costs; no hidden per-ID state | Decoded/transcoded maps, caching and summary layout; see [markup design](MARKUP.md#remaining-design) |

For future composed sessions, `run()` must reach a terminal result, and
`advance(budget)` must yield without repeating work or callbacks. Pausing is not
aborting. Reset must be atomic on invalid configuration; valid reset cleans up
unfinished work. Shared cancellation and exhausted budgets must preserve factual
prefix results without claiming completion. Custom code is not sandboxed by
compile-time binding; its adherence to these contracts must be tested.

Keep standalone operation independent of these extensions. Do not add queues,
instance metadata, retained child arrays or mandatory dynamic dispatch to prepare
for hypothetical deeper execution or SIMD batching.

## Acceptance checks

Before refactoring, retain a same-host/compiler benchmark executable; do not update
official standard-machine baselines. Compare fixed/runtime policies and both
scanners, throughput/latency, retained storage, session and diagnostic sizes and
binary size. Test zero/full/growing bags, allocation failure, explicit omission,
terminal latching, independent findings, reset atomicity, typed consumer schemas,
source-span rebasing and compile-time rejection of incompatible binding.
