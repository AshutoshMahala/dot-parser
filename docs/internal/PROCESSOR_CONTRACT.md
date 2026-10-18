# Processor contract — remaining design

Reconciled: 2026-10-18. This file retains only unfinished composition/API design
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
| Attribute-context policy delegation | First slice uses attribute name and value form only; parent hands over child-owned policies at compile time | Typed syntax, omitted-form behavior, precedence and interaction with existing runtime overrides |
| Optional string processor | Default passthrough; standalone content checks/custom verifier, independent of DOT/markup context | Logical-value input, source mapping, verifier contract and measured disabled/enabled costs |
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

The proposed string processor and the division of responsibility with existing
scanners are described [below](#optional-string-processor).

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
node identity or element types; attribute matching stays outside that verifier.

Illustrative syntax only; `strings.Policy` and this attribute-routing surface
do not exist yet, and the exact Zig schema remains open:

```zig
.attributes = .{
    .label = .{
        .string = .{
            .process = strings.Policy{
                .validation = .{ .one_of = &.{ "SF", "Seattle" } },
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

### Optional string processor

**Proposed first slice clarified 2026-10-18; not a delivered API.** There is no
built-in string processor today. This is optional inner content processing, not
a replacement quote parser or a wholesale extraction of host string syntax.
String handling defaults to `.passthrough`, including when a processor is bound;
explicit `.process` or an attribute-specific selection enables its checks.
Passthrough preserves current behavior rather than claiming content validation.

Useful initial string-owned checks are `equals`, `contains`, `one_of` and a
compile-time-bound custom verifier. Exact names, check combinations, severity
fields and which built-ins ship in the first slice remain to be finalized;
`equals`/`one_of` plus custom verification are the suggested minimum. `one_of`
means allowed string values, not a DOT-specific enum or implicit type conversion.
Simple membership checks need no string tree or regex engine.

#### Shared verifier contract

**Direction agreed 2026-10-18; not implemented.** Built-in `equals`, `one_of`,
`contains` and consumer-supplied checks must use the same compile-time-bound
verifier contract. Built-ins are supplied implementations, not a privileged
second validation path. Convenient named policy fields may select these
implementations without exposing extra adapter work to consumers. Do not add
runtime function-pointer dispatch or a registry to achieve this uniformity;
individual implementations can still specialize their algorithms at compile time.

| Contract part | Responsibility |
| --- | --- |
| Typed settings | The check's parameters, such as an expected value or allowed-value set |
| `check(value, settings, context)` | Execute the check; exact Zig signature remains open |
| Result | Distinguish success, validation failure and an operational stop |
| Optional custom diagnostics | Supply typed explanations instead of requiring the generic failure message |
| Optional shared comparison | Explicit compile-time participation in the string processor's comparison facilities |

Simple predicates may use an adapter that supplies the ordinary result and
generic diagnostic. Structured verifiers use the same execution/reporting
machinery and may explain their failures without a duplicate generic finding.
The mechanism must preserve severity, validity, source mapping, sink stops and
execution guarantees equally for built-ins and consumer code. Exact settings,
capability declarations and result types still need definition before coding.

The string processor defines this shared verifier contract. The verifier receives
a value and string-owned policy/execution/reporting facilities, not
`(element, element_type, attribute_name, attribute_type, attribute_value)`.
Source ranges, source provenance/encoding, diagnostic sinks and cancellation
facilities are legitimate shared support; they do not require DOT or markup
AST types. The same verifier must work standalone and when bound under either
host. Consumer implementations are bound at compile time, not installed as new
processor types or discovered through a runtime registry.

Regex is an optional consumer implementation of that verifier, not a mandatory
library engine/dependency or a regex field interpreted by DOT. Prepare a reusable
pattern outside per-value validation (at compile time where supported); declare
its resource costs. Compile-time binding does not make arbitrary regex execution
safe or bounded. A single opaque regex call cannot satisfy step-level cancellation
or metering merely because its caller does; specify supported execution contracts
and reject incompatible bounded configurations rather than weaken guarantees.

Keep host-language grammar in the host: DOT and markup must still recognize
quotes, escapes/references that affect lexical validity, concatenation where
supported, safe boundaries and recovery. A disabled or passthrough child must
not disable mandatory host syntax checks. Optional string-content rules belong
to the child; do not silently reinterpret DOT escapes as markup references or
vice versa. Shared decoding primitives are useful only where semantics match.

Logical-value checks should treat equivalent non-markup spellings consistently:
`color=red` and `color="red"` should have the same membership result. Expose raw
ranges and prefer lazy logical-value access over mandatory decoded buffers;
the exact input/view contract and coverage of bare/numeral/concatenated forms
remain open. Original-operand provenance and transformed-span mapping must be
defined before promising diagnostics/fixes within logical strings. Mixed
quoted/markup concatenations need an explicit rule: checking each operand is
not equivalent to checking a combined value. No automatic copies, normalization,
concatenation buffers, markup flattening or per-value trees.

Decide which existing content checks, if any, transfer to the child, avoiding
duplicate work/findings while preserving standalone behavior and independent
scope coverage. The outer parser must not claim an unavailable child check ran,
and a child finding must not erase a successfully parsed outer scope.

#### String comparison rules

**Direction agreed 2026-10-18; not implemented.** Case sensitivity is a
string-owned comparison setting, separate from source encoding and outer
attribute-name matching. It applies only to checks that use case-aware text
comparison, not to every verifier. Comparison-based built-ins (`equals`,
`contains`, `one_of`) inherit the string baseline's setting, with an optional
per-check override. Consumers need not repeat it in every rule or choose
separate case-insensitive versions of each operation:

| Comparison | Meaning |
| --- | --- |
| `.case_sensitive` | Default; compare logical values without case folding |
| `.case_insensitive` | Unicode default case folding, not ASCII-only lowercasing |

Both must work with every source encoding compiled into the profile. ASCII
letters can occur in UTF-8, UTF-16 or UTF-32; encoding selection must not change
comparison results for the same valid logical text. An ASCII fast path is an
implementation optimization, not a restriction on `.case_insensitive`. An
explicit ASCII-only comparison remains an optional later choice, not the meaning
of the general case-insensitive option. See the
[Unicode case-folding explanation](https://www.unicode.org/faq/casemap_charprop.html).

Comparison must not rewrite retained source or implicitly normalize it. Unicode
normalization and locale-tailored matching are separate, not implied options.
Pin/document the Unicode data version and precise folding contract before
implementation, including matching and source-span behavior when folding expands
a character. Prefer streaming logical-value/folded views over whole-value copies;
preserve original-source diagnostics and account for the actual work performed.
Specify handling of malformed encoded values; do not claim a successful Unicode
comparison from an undecodable value or silently substitute replacement text.

Unicode folding code and mapping data must be compiled out when unused. An
exact-only build must not pull in those tables or add folding state/dispatch to
its path merely because it supports UTF-8/16/32. If a compiled profile permits
runtime selection of Unicode folding, that implementation necessarily remains
in the binary even on case-sensitive calls. The compile-time capability and
runtime-policy surface must make this distinction explicit; a runtime request
for excluded functionality must fail verification, never silently fall back to
ASCII or exact matching. Exact public configuration syntax remains open.

Participation in shared comparison is explicit at compile time. A participating
custom verifier may call a service conceptually like
`context.compare.equals(value, expected)`, inheriting the selected comparison
semantics and source-encoding support without reimplementing Unicode folding.
This service spelling is illustrative; it must also respect the operation's
failure/cancellation/metering contract. The capability declaration and how
per-check settings resolve remain API design work.

Checks such as value length or character count do not need a case-sensitivity
field or folding work. Their presence must not by itself retain comparison
state or Unicode folding code/data. Custom verifiers that do not opt into shared
comparison own their semantics; do not lowercase/fold their input automatically
or claim that the baseline comparison setting changes an arbitrary callback.
A regex verifier may expose its own supported matching options rather than use
the shared comparator. All comparison code remains inside the string layer,
independent of outer attribute selection.

#### Custom string diagnostics

**Direction agreed 2026-10-18; not implemented.** Provide useful failure reporting
without requiring every consumer to define a diagnostic catalog:

| Verifier level | Failure reporting |
| --- | --- |
| Simple predicate | A failed check produces a generic string-owned finding, such as `custom_check_failed`, at the value's original span |
| Structured custom verifier | Supplies its own typed diagnostic details and rendering, with optional hints, related spans and fixes, through the string processor's reporting contract |

The generic code/name is illustrative, not a frozen API. Custom reporting
definitions and adapters are bound at compile time. Keep stable diagnostic
identity distinct from message wording; decide how custom codes/details join
the bound catalog and how a simple consumer overrides generic wording without
mutating shared/global state. Reuse common sinks/bags and rendering machinery;
do not impose a separate bag, dynamic registration or allocated message strings
on every verifier. Custom findings require no DOT/markup AST types or parent
attribute context, and the same reporting must work standalone and when bound.

Validation failure is a finding, not automatically a thrown Zig error. The
selected rule's severity determines rejection versus warning; an off check is
not performed. Validity must not depend on whether a sink prints, filters or
retains that finding. Operational failures, including cancellation, storage or
sink failure, keep their separate stop/completion meaning. A rejected value
must not be reported as valid merely because a custom verifier omitted text.

Finalize the callback/result shape, support for multiple findings, and the
relationship between custom severity and rule severity before coding. Avoid
duplicate generic findings when a verifier has already reported the failure.
All custom spans must obey the same checked original-source mapping contract;
fixes describe explicit edits rather than applying them automatically.

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
Also compare built-in and consumer implementations through the same verifier
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
- String passthrough preserves current host behavior even with a bound verifier;
  enum/custom checks do not reinterpret markup, inspect outer AST types, or fall
  back to passthrough after failure. Test original-source diagnostics for logical
  values and parity between standalone, delayed and supported during-parse checks.
- Case-sensitive defaults, Unicode caseless results across source encodings,
  non-ASCII cases and folding expansions, original spans/source preservation,
  and explicit rejection of runtime requests for compiled-out comparison work.
- Generic versus custom diagnostics, severity/validity independence from sink
  filtering, no duplicate fallback finding, related/fix span mapping and
  cancellation/sink stops during custom checks.
- Built-in/custom verifier contract parity; comparison-aware checks inherit the
  baseline and honor per-check overrides, while non-comparison checks and
  independent custom matchers receive no implicit folding or comparison state.

Use the recorded [performance baseline](../PERFORMANCE.md) for reproducible
comparisons and preserve the outstanding
[verification gates](MARKUP.md#verification-and-performance-gates). Measure
state size and storage overlap as well as throughput; static composition does
not by itself establish zero overhead. Standalone operation must stay independent
of these extensions. Compile-time binding does not sandbox custom code, so its
budget, callback and ownership obligations need explicit tests.
