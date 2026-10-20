# Processor contract — remaining design

Reconciled: 2026-10-19. This file retains only unfinished composition/API design
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
| Recursive / quoted-content execution | Compile-time binding; processor-owned schemas/content rules | Scheduling boundaries, selection, aggregation and host-to-string adapters |
| Broader profile/API surface | Keep low-level ownership and costs explicit | Outer-only versus composed operations, a whole-composition `validatePolicy` entry point and convenience result/ownership choices |
| Attribute-context policy delegation | First slice uses attribute name and value form only; parent hands over child-owned policies at compile time | Typed syntax, omitted-form behavior, precedence and interaction with existing runtime overrides |
| String host integration | Default host passthrough; explicit reader/validator binding, mapped findings and reader-prerequisite coverage are implemented | Host-aware fixes, automatic routing/aggregation and measured composition costs; [agreed direction](STRING_INTEGRATION.md) |
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
scheduler and host adapters. Specify scope selection,
ordering, stage compatibility, result aggregation and diagnostic context across
multiple active levels. Keep implementations compile-time-bound with independent
policy schemas; do not introduce runtime discovery to select an inner parser.

The remaining division of responsibility with existing scanners is described
[below](#standalone-strings-and-remaining-host-integration).

The [logical-value interface](STRING_INTEGRATION.md) selects streamed logical
contents for string validation, with an optional unchanged contiguous fast path.
Original-operand provenance remains distinct; locations are not logical offsets
and are not rebased repeatedly at each parent. Host adapters own safe fix spelling.
Exact location/range APIs and mixed quoted/markup concatenations remain open;
the agreed direction does not imply that source mapping is implemented.

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

### Attribute-context policy delegation

**Direction agreed 2026-10-17; narrowed/clarified 2026-10-18; not implemented.**
Attribute context may select `none`, `passthrough` or `process` and supply a
typed child policy. It does not choose the value's syntactic form:
`label="..."` is quoted content, while `label=<...>` is markup content.
The attribute name must not force both through the markup
processor, nor make DOT interpret markup-specific rules. Markup can likewise
delegate checks for its own attribute values; DOT does not reach inside them.

| Term | Responsibility |
| --- | --- |
| Owned policy | The processor defines the schema, verifies settings and enforces their meaning |
| Inherited settings | Supported unspecified settings take their defaults from the enclosing configuration |
| Delegated policy | A parent explicitly supplies a child-owned policy for a particular context, bound at compile time |

These describe ownership and configuration sources, not three execution modes.
Delegation is local to the selected context; it must not mutate the child's
baseline or another attribute's settings. Processor bindings, selectors and
custom policy handover are defined at compile time. Runtime input still requires
context matching and execution of that compiled arrangement, but no dynamic
processor installation, discovery, schema inspection or rebinding.

The first slice should select by attribute name and value form, not by element
identity, owner-specific conditions or another attribute's presence/value.
For example, `label`, `color` and `description` can each delegate a different
string policy. These are independent rules; a later `color` attribute does not
change how an earlier `label` is checked. A per-attribute configuration overrides
the base handling for its selected form; this is not a synonym for runtime
policy overrides. Do not build a general selector/expression language.

The parent owns selection, not the child's rules. It must not inspect
`one_of`, `equals`, `contains`, a regex or markup's `.graphviz` mode to decide
what to do. The child owns its policy schema, verification, diagnostics and
execution. A replacement processor supplies its own schema through the same
binding contract. Custom string verification must not require parent attributes,
node identity or element types; attribute matching stays outside that validator.

Illustrative host syntax only; the attribute-routing surface does not exist yet.
The child policy below uses the implemented standalone string schema:

```zig
.attributes = .{
    .label = .{
        .string = .{
            .process = strings.Policy{
                .validation = .{ .one_of = .{ .values = &.{ "SF", "Seattle" }, .severity = .err } },
            },
        },
        .markup = .{
            .process = markup.Policy{ .mode = .graphviz },
        },
    },
},
```

`label="SF"` follows the string branch; `label=<...>` follows the markup branch.
No implicit tag stripping, visible-text extraction or raw-markup regex matching
is implied. To require a string form, explicitly select `.none` for markup;
the ordinary unsupported-reporting policy controls that outcome, not a claimed
DOT syntax error. In particular, a child `one_of = &.{""}` accepts the empty
string but tells DOT nothing about whether an empty markup operand is allowed.
A failed selected child rule must not fall back to passthrough as though
no rule matched.

Before implementing, decide selector syntax and host-owned name-comparison
rules, when the required attribute context becomes available, handling of
omitted form branches, duplicate rule definitions, and precedence between
child baselines, inheritance, delegation and permitted runtime overrides.
Existing runtime-policy support is not removed by this direction; its interaction
with delegated settings remains undecided. Do not promise zero matching cost
merely because the rule set is compile-time-bound.

Current composition still processes every HTML-like operand when processing is
enabled. Do not introduce a hard-coded `label`/`headlabel` selection rule as an
interim implementation. Attribute-aware selection should use this general
contract; the markup processor retains its own Graphviz grammar and settings.
Delayed caller-selected processing remains available independently.

### Standalone strings and remaining host integration

The standalone first slice is implemented in `string_processor`; the current
[public string contract](../STRINGS.md) documents borrowed contents, fixed/runtime
policy, the shared validator contract, Unicode 17.0.0 comparison, custom reporting,
completion and costs. Built-in `equals`/`one_of` and custom validators share the
resumable `State`/`step` contract, with optional pending-step batching and unmetered
fast checks. Batches retain scalar credits and cannot cross budget/poll boundaries;
their context cannot report or poll. Standalone
sessions meter encoding and validation and support cancellation; synchronous-only
custom validators cannot be activated under metering. This does not implement
host selection or transfer host syntax.

**Logical-value direction agreed 2026-10-19; explicit binding implemented.** The dedicated
[string integration design](STRING_INTEGRATION.md) records the bounded
cursor, custom diagnostic/future-fix example, mapping safety and memory/performance
requirements. It preserves the shared validator contract without requiring
contiguous decoded contents or an allocated mapping table. Plain/DOT/markup
readers share bounded steps and original-source item locations. `Profile.WithReader`
connects them to validators and checked primary/related findings, with metering,
cancellation and typed unavailable-input outcomes. Raw edits are rejected on
decoded host values; safe logical fix materialization remains pending.

Host integration still needs:

- Automatic selection/dispatch of the implemented reader-bound validators, so
  quotes, escapes/references, bare and numeral forms use the selected policy.
- Original-operand provenance through adapter-produced locations, with exact
  ranges distinguished from enclosing highlights. Standalone origins apply only
  to contiguous, unchanged contents; logical replacements require explicit
  host-aware materialization rather than raw byte edits.
- A rule for quoted/markup concatenations; per-operand validation does not mean
  validation of the combined logical value. No implicit markup flattening.
- Independent scope coverage and selection of which host-owned checks, if any,
  transfer to a child without duplicate findings.
- The attribute delegation precedence and omitted-form choices above.
- Parent scheduling/aggregation of the standalone string session, including
  mapping its bounded-step credits to the shared-budget contract. Runtime policy
  preparation and consumer callbacks are outside standalone execution budgets.

Future host string handling defaults to passthrough, even when a processor is
bound; explicit processing enables checks. The standalone operation explicitly
validates string contents and is not itself a host passthrough operation.
Host scanners retain mandatory quote, escape/reference, boundary and recovery
rules. Optional string processors do not redefine their syntax.

`contains`, other built-ins and independently contributed custom WDP catalogs
beyond the custom-rule family/typed detail contract can be considered separately;
do not silently expand the shipped equality/membership slice.

### Validation timing and intended use

Keep rule meaning independent of scheduling. String/attribute checks should be
usable on retained values afterwards as well as through optional during-parse
delegation where the needed context is available. A single `parseAndValidate`
call may sequence stages; it does not require all validation to run inside the
grammar loop. Keep the validator separate from host grammar machinery.

During-parse checking can offer earlier findings/stopping, reuse current context
and support event consumers without a retained tree. It does not automatically
lower memory or improve throughput for callers already retaining the document;
post-parse validation is a valid simpler choice. Cross-attribute conditions,
applied graph defaults and repeated-declaration semantics may require later
resolved data and are outside the initial slice.

Target uses are application-specific input contracts and editor/linter support:
workflow statuses, constrained diagram values, and consumer text checks with
original-source diagnostics. Consumers could implement these checks themselves;
the benefit is reusable typed configuration and reporting, not making ordinary
DOT opinionated or turning the parser into a mandatory linter. Demonstrate one
realistic consumer before expanding the framework.

### Delegation and string performance gates

Performance gates must compare no processor bound, passthrough, and enabled
processing. Measure attribute-selection cost, repeated scans/decoding, parser
state, scratch/retained/peak memory, binary size and throughput, with short and
long values, escapes/references, concatenations and native encodings. Preserve
metering and cancellation guarantees on any supported bounded path. Unused
processing must add no mandatory allocation, per-value state or content pass;
compile-time binding and inlining are implementation opportunities, not measured
zero-cost evidence. Keep new work separate from the current Graphviz checks.

For comparison, verify exact-only builds exclude Unicode folding code/tables
and have no mandatory folding state. Separately measure Unicode-enabled binary
size, state/scratch/peak memory and throughput on ASCII and non-ASCII inputs in
each compiled encoding. Distinguish compile-time exclusion from choosing exact
comparison at runtime. Include generic and structured custom reporting in
disabled-check and allocation tests.
Also compare built-in and consumer implementations through the same validator
path, and confirm non-comparison checks do not require folding machinery or
per-check case configuration.

### New token spellings

Custom token spellings require a separate lexical-extension contract covering
boundaries, escaping, collisions with existing DOT tokens, safe recovery and
bounded work. Replacing an inner processor does not supply that contract.
New DOT statements or operators are outside inner-processor composition.

### Source transforms and retained summaries

Decoded/concatenated maps, optional explicit conversion maps, summary caches and public
events still need explicit representations and lifetimes. Follow the
[encoding constraints](MARKUP.md#native-source-encodings) and
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
- Delegation for the same attribute with quoted versus markup values, custom
  attribute contexts, fallback behavior and no policy leakage between siblings;
  standalone and bound string checks must agree without duplicate findings.
- String passthrough preserves current host behavior even with a bound validator;
  enum/custom checks do not reinterpret markup, inspect outer AST types, or fall
  back to passthrough after failure. Test original-source diagnostics for logical
  values and parity between standalone, delayed and supported during-parse checks.
- Case-sensitive defaults, Unicode caseless results across source encodings,
  non-ASCII cases and folding expansions, original spans/source preservation,
  and explicit rejection of runtime requests for compiled-out comparison work.
- Generic versus custom diagnostics, severity/validity independence from sink
  filtering, no duplicate fallback finding, related/fix span mapping and
  cancellation/sink stops during custom checks.
- The [logical-value acceptance checks](STRING_INTEGRATION.md#remaining-details-and-acceptance-tests),
  including bounded decoding of long references/glue, original-byte locations,
  invalid custom ranges in ReleaseFast and safe, explicit fix materialization.
- Built-in/custom validator contract parity; comparison-aware checks inherit the
  baseline and honor per-check overrides, while non-comparison checks and
  independent custom matchers receive no implicit folding or comparison state.

Use the recorded [performance baseline](../PERFORMANCE.md) for reproducible
comparisons and preserve the outstanding
[verification gates](MARKUP.md#verification-and-performance-gates). Measure
state size and storage overlap as well as throughput; static composition does
not by itself establish zero overhead. Standalone operation must stay independent
of these extensions. Compile-time binding does not sandbox custom code, so its
budget, callback and ownership obligations need explicit tests.
