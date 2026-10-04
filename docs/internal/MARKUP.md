# Markup — delivery status and remaining design

Reconciled: 2026-10-04. This is an internal status and design record, not a
second user guide. Current APIs are in [standalone markup](../MARKUP.md),
[DOT integration](../LABELS.md) and [custom processors](../CUSTOM_PROCESSORS.md).
R-MOD-014/015 and Q40 remain the architectural requirements and decision IDs.

Keep this file while specialized markup and integration work remain unfinished.
Completed slice diaries and superseded local measurements are available in Git;
removing their repetition here does not close outstanding performance gates.

## Priorities

- Build a genuinely standalone processor. Share language-independent mechanisms,
  not DOT grammar, graph records or a renderer dependency.
- Keep performance, binary size and low memory usage acceptance criteria, not
  afterthoughts. Optional rules must have explicit costs and disabled paths.
- Preserve source spelling and byte positions. No implicit entity expansion,
  normalization, namespace resolution, repair, rendering or external access.
- Graphviz labels are the priority consumer of an extensible markup engine.
  HTML subsets, SVG and custom dialects must not inherit unrelated rules.
- Implement concrete vertical slices before generalizing composition. Built-in
  and consumer processors use the same compile-time contract.

## Delivery status

“Implemented” describes the current development tree, not release 0.3.0.
“Agreed direction” does not mean its detailed API is settled or work has started.

| Area | Status | Evidence / remaining boundary |
| --- | --- | --- |
| Independent structural engine | Implemented | Text, multiple roots, matching/self-closing elements; [parser](../../src/markup/parser.zig), [tests](../../tests/markup.zig) |
| Attributes, references, comments, CDATA | Implemented | Retained spelling/order, malformed-reference policy; [content tests](../../tests/markup_content.zig) |
| Optional validation | Implemented | Duplicate attributes, UTF-8, XML 1.0 names, XML predefined references; [rules tests](../../tests/markup_rules.zig) |
| Storage and execution | Implemented | Growable/fixed/count-only paths; scalar/block scanners; bounded and cancellable fixed parsing; [budget tests](../../tests/markup_budgets.zig) |
| Diagnostics and resource hardening | Implemented | Shared reporting/rendering, capped bags, markup untrusted preset, suggested fixes; [diagnostic tests](../../tests/markup_diagnostics.zig) |
| Structural and malformed-header recovery | Implemented | Diagnostics only, no partial tree; [recovery tests](../../tests/markup_recovery.zig), [header tests](../../tests/markup_header_recovery.zig) |
| Independent local validation | Implemented | Public checked scopes and source traversal without a tree; [scope tests](../../tests/markup_scopes.zig) |
| DOT passthrough recognition | Implemented | Every ID position, concatenations, parts and explicit decoding; [identifier tests](../../tests/html_identifiers.zig) |
| Outer processing selection / inner mode | Implemented | DOT `.none` / `.passthrough` / `.process`; markup `.mode = .structural`; [composition tests](../../tests/during_dot.zig) |
| Delayed and one-shot during-DOT integration | Implemented | Prepared profiles, original-source diagnostics, one shared destination, independent error policies; [integration tests](../../tests/markup_integration.zig), [composition](../../src/dot/composition.zig) |
| Workspace reuse and silent unsupported reporting | Implemented | Borrowed per-call results, reusable buffers, no user-facing finding construction on the silent path; [workspace tests](../../tests/markup_workspace.zig), [error-policy tests](../../tests/error_policy.zig) |
| Specialized Graphviz / extended validation | Agreed direction; not implemented | Vocabulary, attributes, placement, context selection and extended rules need design |
| Dialect-specific parsing / custom catalogs | Under discussion; not implemented | Void elements, rule binding and compatibility scope are not implied by structural parsing |
| Resumable and fixed-buffer during-DOT composition | Agreed direction; not implemented | Shared work accounting and composed lifetimes need a dedicated contract |
| Deeper processor execution / built-in string processor | Future design; not implemented | Nested policy preparation exists; automatic recursive scheduling does not |
| Transcoding, summary index and partial-tree publication | Not implemented | Encoding constraints are agreed; maps/summaries need design; partial trees are deferred |

There is no new implementation commitment or active coding slice implied by this
documentation cleanup. Detailed processor obligations and remaining scheduling
questions are in [PROCESSOR_CONTRACT.md](PROCESSOR_CONTRACT.md).

## Current structural contract

The public grammar is an XML-like fragment subset, not full XML or browser HTML:

- Empty, text-only and multiple-root inputs are supported.
- Element names match byte-for-byte and case-sensitively. Attributes require
  quoted values; all occurrences and their order are retained.
- References remain inside text/value spans. Named-reference recognition does
  not require a definition; catalog checking is separate. Numeric references are
  checked without expansion. Tolerated malformed references treat the offending
  ampersand as literal text without swallowing a subsequent tag or value boundary.
- Comments and CDATA are distinct leaves. Processing instructions and declarations
  are unsupported; there is no DTD, external-entity loading or browser repair.
- Raw non-ASCII bytes remain unchanged. Whole-source UTF-8 checking is optional;
  Unicode name checking decodes only names and does not turn on other rules.

The retained tree uses preorder subtree intervals and a separate owner-indexed
attribute pool. This replaces the old provisional parent/child/sibling design;
it is not an outstanding representation decision. Nodes and attributes are
20 bytes each and open-element frames 12 bytes on the measured targets. An
8-byte name span is not the complete frame. Keep size assertions and measure
target-specific layouts instead of presenting these figures as portable ABI.

### Validation and coverage

Names, references, duplicate attributes and encoding retain independent
severities, completion and counts. Overlapping findings are not deduplicated by
silently weakening one rule. Name-local UTF-8 work does not transcode stored data.
Reference checking can rescan the full text/value span; optional checking is
not free merely because references have no retained index.

Opening headers, names, values and text can be checked independently of matching
closing tags. `validateScope[In]` audits caller-built spans and header metadata
in every build mode before allocation/checking; invalid metadata yields
`invalid_scope`, not a source diagnostic. Scanner-produced internal views use
the trusted path. A caller still owns lifetimes and truthful scope descriptions.

`validateSource[In]` has no element stack and does not emit syntax findings.
It validates recognizable local content despite rejected enclosing structure,
synchronizing safe malformed headers independently of the parse stopping policy.
It does not recheck closing names; callers may explicitly request a
`closing_name` scope. No successful partial document is manufactured.

Source validation runs whole-source encoding first, then local findings in
encounter order. That is not global source order across checks. Its
`incomplete: u32` is the earliest coverage gap, not a resume cursor; later
independent regions may already be checked. Fragment wrappers rebase that offset
and diagnostic spans, while tree spans remain local.

Source traversal enforces `max_source_bytes` and supplied scratch capacity;
node/attribute/nesting parse limits are not source-validation work budgets.
Markup validation is cancellable but not resumable or credit-metered. DOT
validation is neither cancellable nor credit-metered. Sorting/allocation have
their documented costs; cancellation is not a hard per-comparison time bound.

### Recovery and acceptance

`on_error = .collect` is the default; `.fail_fast` is explicit. Recovery finds
safe continuation points for diagnostics. It does not accept rejected syntax,
guess typos, invent delimiters or publish a repaired/partial tree.

For a mismatched closer, search nearest open ancestors by exact spelling, unwind
through a match, or discard an unmatched closer. Aggregate ancestor lookup is
bounded by source length; exhausted recovery work is a resource-limit result,
not permission for quadratic searching. EOF reports remaining open elements.

Selected attribute-bearing opening-header errors synchronize at explicit,
quote-aware `>` or `/>` boundaries. Preserve the pending name and the actual
delimiter's stack effect. Uncertain boundaries remain terminal; skipped regions
are not reported as validated or accepted. Staged tree output aborts once, while
safe grammar traversal and factual counters can continue. Sink/storage failures,
cancellation and enforced limits still stop affected work.

Partial-tree publication remains a separate deferred design. Local validation
already serves tooling without weakening the current complete-document contract.

### Integration, ownership and costs

DOT recognizes every HTML operand, not just label attributes. Its low-level
`none | passthrough` policy never selects an inner implementation. Bound
processors are compile-time choices; optional runtime patches configure only
that selected implementation.

Delayed calls select operands explicitly. One-shot composition checks all
recognized HTML operands allowed by DOT's gate, before the next grammar
transition, then validates DOT after successful outer parsing. Parent and child
use independent `on_error` policies; component-specific cancellation hooks do
not imply a shared cancellation/budget guarantee.

One workspace reuses tree, nesting and validation buffers. Results borrow it
until the next call or deinitialization; DOT consumes them immediately and never
deinitializes individual results. Independently retained trees use explicit
allocated or fixed-buffer calls. Fixed-buffer views expire on reuse, not only
release. Neither form changes the source-lifetime requirement.

Reuse reduces allocation churn, not necessarily peak memory. An early large
fragment can keep high-water capacity alive while the outer document grows.
There is no mandatory child-tree/result array or per-identifier processor state.
A composed bag contains only its bound diagnostic variants; ordinary bags are
not inflated by unrelated processors. See the [processor contract](PROCESSOR_CONTRACT.md)
for terminal-stop acknowledgement and silent-unsupported semantics.

## Remaining design

### Graphviz and extended rules

DOT owns `policy.markup = .none | .passthrough | .process`; the bound markup
processor owns `policy.mode = .structural` and its independent validation rules.
`extended` and `graphviz` remain future processor-owned modes, not callable values
or aliases for structural checking. Custom processors own their schemas and need
not expose this mode field.

Without a processor the DOT default is passthrough; binding one defaults to
process unless explicitly overridden (complete presets include a passthrough
leaf). Unbound process is a policy-verification failure at compile time or runtime
preflight. None/passthrough never initialize a child workspace or run inner
checks; configured policy verification still precedes scanning. A report marks
this work not requested, not successfully validated. Switching outer handling
does not change the child's policy. Process uses synchronous bounded-operand
handoff, not threads or a queue; independent error policies remain unchanged.

Graphviz checking needs tag vocabulary, attributes and parent/child placement,
not just a whitelist. It must apply only where Graphviz interprets an ID as a
label. `n:<p>` names port `p`; `label=<p>` contains text `p`;
`label=<<p>x</p>>` contains an element. Port-reference resolution belongs to
later graph semantics, not structural recognition.

Before implementation, specify the supported Graphviz compatibility target,
label-context selection, concrete rules, diagnostics and bounded-work/storage
costs. The extended vocabulary needs an actual consumer and explicit tag,
attribute and nesting rules; “more HTML” is not a complete contract.

### Dialect parsing and custom rules

A compile-time dialect rule could recognize `<br>` as void at header completion,
without pushing an open frame or inventing a closing tag. This is parsing
behaviour, not a validation severity. The structural baseline stays unchanged
until void-name selection, case/context rules, explicit closers and policy
surface are agreed.

Unquoted/empty attributes and further HTML conveniences likewise need explicit
grammar contracts. A defined subset is not full browser tree construction.
Independent name/reference choices must not impose XML rules on other dialects.
Additional catalogs and custom rule-binding APIs remain open; no external lookup
or entity-expansion facility follows from a catalog extension.

### Optional summaries and retention

A per-identifier summary index is still only a proposal. Boundary scanning can
supply raw ranges and lexical facts, not element depth, counts or reference
facts. Those require context-aware markup processing, with its cost charged even
when no tree is retained. Uncomputed fields must be absent/unknown, not zero.

`<a/><b/>` has element depth 1; `<a><b/></a>` has depth 2. Both DOT envelopes
reach angle-counter depth 2. A separate `max_elements` limit, summary layouts,
caching owners/lifetimes and public event consumers need their own designs.
Current count-only measurement is not a public event API.

### Encoding adapters

UTF-16/32 adapters are not implemented. Future UTF-8 working buffers must preserve
original encoding, byte order and BOM provenance once per input, including
whether it was detected or supplied. Converted bytes cannot reveal their old
encoding; unknown provenance stays unknown.

Original bytes or a live source handle are needed for exact reproduction.
Replacement, normalization and discarded information must be reported rather
than called lossless. Conversion error policy, metadata and ownership APIs remain
open. Original-file diagnostics/fixes require a source map; a constant fragment
origin is not sufficient. Without a map, identify working-buffer coordinates.

Account separately for conversion CPU, output-buffer size, original-buffer
lifetime, mapping storage/rescans and dual-buffer peak memory. Bound original
and converted sizes. Unchanged raw-byte paths must not acquire these costs.

### Composition and release choices

Shared-budget/fixed-storage composition, recursive execution and a built-in
string processor remain in the [processor design](PROCESSOR_CONTRACT.md#remaining-design).
The broader profile/API redesign is still a discussion, not part of the
implemented workspace change. Markup package/version independence and its
release relationship with DOT remain open in Q40; no next version is assigned.

## Verification and performance gates

Completed slices have regression coverage in the linked tests; historical test
counts and local before/after tables are in Git, not current verification claims.
This documentation reconciliation does not rerun or certify those measurements.

Keep the standard-machine gate open. Local tests have shown fixture-specific
regressions/noise, especially in cancellable and runtime-selectable paths;
aggregate gains do not establish per-profile parity. Compare both scanners,
fixed/runtime settings, plain/cancellable/bounded parsing, invalid-input recovery
and enabled/disabled checks with the same compiler, host and harness.

Use `bench/markup.zig`, `bench/composition.zig` and `bench/policies.zig`.
Report throughput/latency, allocation calls, peak requested live bytes, retained
capacity, session/diagnostic layouts and binary size separately. RSS and allocator
internal peaks are not interchangeable with instrumented requested bytes.

One useful existing reference: the 2026-10-03 native arm64 / Zig 0.16.0
ReleaseFast workspace comparison against `15bbc96` reduced allocations for
1,000 small valid labels from 4,003 to 7. The large-label-first fixture increased
peak requested live bytes from 1,389,832 to 1,670,604. These local fixtures explain
the trade-off, not a universal speed or RAM guarantee or an official baseline.

The measured DOT EOF-guard/increment optimization is implemented. The proposed
markup safe-loop and metered-arithmetic rewrites were not retained after mixed
local results. Revisit them only with separate measurements and differential
tests; do not assume an optimization reported on another build is a free win.
