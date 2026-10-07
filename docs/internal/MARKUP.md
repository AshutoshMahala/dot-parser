# Markup — remaining work

Reconciled: 2026-10-05. This file contains unimplemented capabilities, unresolved
design choices and outstanding verification, not a delivery log or a second API
guide. R-MOD-014/015 and Q40 in [Requirements](REQUIREMENTS.md) and
[OpenQuestions](OpenQuestions.md) remain the architectural requirements and
decision records. Current usage belongs in [standalone markup](../MARKUP.md),
[DOT integration](../LABELS.md) and [custom processors](../CUSTOM_PROCESSORS.md).

## Remaining design

These items are not available APIs or commitments to a particular release.
Graphviz labels remain the priority consumer; optional proposals need an explicit
decision before becoming implementation work.

| Work | Decisions or implementation still needed |
| --- | --- |
| Graphviz label validation | Child/content rules, attribute values, references, parsing compatibility and DOT context selection |
| Extended markup rules | A concrete consumer and a defined vocabulary/grammar |
| Dialect-specific parsing | Void elements, case/context rules, unquoted/empty attributes and policy surface |
| Custom name/reference catalogs | Compile-time binding and independently selectable rules |
| Bounded validation | Credit accounting, resumable checks and DOT validation cancellation |
| Partial trees, summaries and public events | Opt-in representation, ownership, coverage and costs; proposals remain deferred |
| Encoding adapters | UTF-16/32 conversion, provenance, error policy and source mapping |
| Composed execution | Shared budgets, fixed memory and recursive/string scheduling; see [processor design](PROCESSOR_CONTRACT.md#remaining-design) |
| Packaging | Whether markup should ever have a separate package/version lifecycle |

### Graphviz and extended rules

`graphviz` belongs to the markup processor, not DOT's processing-selection
policy; `extended` remains future work. Custom processors need not adopt those
mode names. Implemented vocabulary coverage is documented in
[standalone markup](../MARKUP.md#graphviz-vocabulary).

Graphviz checking needs tag vocabulary, attributes and parent/child placement,
not just a whitelist. It must apply only where Graphviz interprets an ID as a
label. Context selection must distinguish `n:<p>` (port `p`),
`label=<p>` (text `p`) and `label=<<p>x</p>>` (an element). Port-reference
resolution belongs to later graph semantics, not markup validation.

Follow Q10's specification-first approach and pinned 16.0.0 differential
reference. Remaining slices are content/placement/whitespace and element forms;
attribute values, quoting and the Graphviz reference catalog; then DOT label
context selection. ASCII-case-insensitive start/end-name matching is implemented;
other parsing differences still need explicit contracts and verification.
Do not mistake vocabulary success for full Graphviz compatibility. Rendering,
font/image availability and graph-level port resolution remain out of scope.
Specify each new check's diagnostics, coverage and bounded-work/storage costs.
The extended vocabulary needs an actual consumer and explicit tag,
attribute and nesting rules; “more HTML” is not a complete contract.

### Dialect parsing and custom rules

A compile-time dialect rule could recognize `<br>` as void at header completion,
without pushing an open frame or inventing a closing tag. This is parsing
behaviour, not a validation severity. Decide void-name selection, case/context
rules, treatment of explicit closers and the policy surface before changing
parsing.

Unquoted/empty attributes and further HTML conveniences likewise need explicit
grammar contracts. A defined subset is not full browser tree construction.
Independent name/reference choices must not impose XML rules on other dialects.
Additional catalogs and custom rule-binding APIs remain open; no external lookup
or entity-expansion facility follows from a catalog extension.

### Validation and coverage

Credit-metered/resumable validation remains needed before composition can promise
one bounded operation. This includes document and source-scope traversal,
reference/name/encoding scans and duplicate-key work. DOT validation also needs
cancellation support. Define allocation, sorting and callback boundaries rather
than treating parse credits as a bound on later validation; see
[shared-budget execution](PROCESSOR_CONTRACT.md#shared-budget-execution).

Future string processors must preserve independent scope coverage: a complete
attribute value or text region must remain checkable despite an invalid enclosing
structure, while unavailable bytes must not be certified. Existing scope APIs
are documented in [local validation](../MARKUP.md#checking-a-fragment-that-failed-to-parse).

SIMD batching across scopes remains an optional investigation. Define grouping,
variable-length handling, diagnostic order and cancellation before claiming a
benefit; do not add copying or mandatory queues in anticipation of it.

### Recovery and acceptance

Partial-tree publication remains deferred. Before adding it, define an opt-in
representation for incomplete/invalid regions, consumer-visible validity,
ownership and traversal guarantees. Do not silently weaken complete-document
results or present skipped input as accepted.

New dialect grammar will need its own safe synchronization boundaries, especially
around void elements and unquoted/empty attributes. Preserve the distinction
between recovery for further diagnostics and accepting or repairing syntax;
guessed typo correction is not an agreed extension. Current recovery behaviour
is documented under [parse failures](../MARKUP.md#when-parsing-fails).

### Optional summaries and retention

A per-identifier summary index is still only a proposal. Boundary scanning can
supply raw ranges and lexical facts, not element depth, counts or reference
facts. Those require context-aware markup processing, with its cost charged even
when no tree is retained. Uncomputed fields must be absent/unknown, not zero.

`<a/><b/>` has element depth 1; `<a><b/></a>` has depth 2. Both DOT envelopes
reach angle-counter depth 2. Decide whether a separate `max_elements` limit is
useful, and define summary layouts, caching owners/lifetimes and public event
consumers separately. Count-only measurement does not supply a public event API.

### Encoding adapters

UTF-16/32 adapters need a conversion policy and API. Future UTF-8 working buffers
must preserve original encoding, byte order and BOM provenance once per input,
including whether it was detected or supplied. Converted bytes cannot reveal
their old encoding; unknown provenance stays unknown.

Original bytes or a live source handle are needed for exact reproduction.
Replacement, normalization and discarded information must be reported rather
than called lossless. Conversion error policy, metadata and ownership APIs remain
open. Original-file diagnostics/fixes require a source map; a constant fragment
origin is not sufficient. Without a map, identify working-buffer coordinates.

Account separately for conversion CPU, output-buffer size, original-buffer
lifetime, mapping storage/rescans and dual-buffer peak memory. Bound original
and converted sizes. Unchanged raw-byte paths must not acquire these costs.

### Composition and release choices

Shared-budget/fixed-storage composition, recursive execution, a built-in string
processor and the broader profile/API proposal remain in the
[processor design](PROCESSOR_CONTRACT.md#remaining-design).

Independent markup packaging/versioning remains open in Q40. Module independence
does not itself require a separate package or version; settle the release
relationship before introducing either.

## Verification and performance gates

The current [performance baseline](../PERFORMANCE.md) records native throughput,
latency, storage/layouts and composition allocation measurements. Generating that
baseline is no longer pending. It does not close these remaining checks:

- Controlled before/after comparisons and per-profile acceptance criteria,
  rather than treating aggregate gains as parity on every path.
- Standalone metered parsing, invalid-input recovery and enabled/disabled rule
  combinations not covered by the recorded timing matrix.
- Consumed-profile binary size, including the cost of runtime-selectable
  alternatives versus compiled-out functionality.
- Standalone growable-tree allocation peaks, separately from retained pool
  payload; bounded/fixed-memory composition costs when those paths are built.

Use the same compiler, host and harness for comparisons. Cover both scanners,
fixed/runtime settings and applicable execution modes. Keep requested live bytes,
allocator-internal peaks and RSS distinct; do not infer any of them from retained
tree size. New dialects and scheduling paths need differential and resource-stop
coverage before their performance results can count as acceptance evidence.
