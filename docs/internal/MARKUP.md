# Markup — remaining work

Reconciled: 2026-10-18. This file contains unimplemented capabilities, unresolved
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
| Graphviz label validation | General delegated context selection, contextual color/scheme validation and pinned runtime differential verification |
| Extended markup rules | A concrete consumer and a defined vocabulary/grammar |
| Dialect-specific parsing | Void elements, case/context rules, unquoted/empty attributes and policy surface |
| Custom name/reference catalogs | Compile-time binding and independently selectable rules |
| Bounded validation | Credit accounting, resumable checks and DOT validation cancellation |
| Partial trees | Retain later safely recovered regions, distinguish locally closed scopes with partial descendants, and add per-scope pending-work maps |
| Summaries and public events | Representation, ownership, coverage and costs; proposals remain deferred |
| Native encoding execution | Native session dispatch, metered validation and native excerpt windows |
| Composed execution | Shared budgets, fixed memory and recursive/string scheduling; see [processor design](PROCESSOR_CONTRACT.md#remaining-design) |
| Delegated policies / string processing | Attribute-name/value-form selection; default-passthrough standalone string checks/custom verifier; no outer AST dependency or mandatory regex; see [delegation design](PROCESSOR_CONTRACT.md#attribute-context-policy-delegation) |
| Packaging | Whether markup should ever have a separate package/version lifecycle |

### Graphviz and extended rules

`graphviz` belongs to the markup processor, not DOT's processing-selection
policy; `extended` remains future work. Custom processors need not adopt those
mode names. Implemented vocabulary coverage is documented in
[standalone markup](../MARKUP.md#graphviz-vocabulary).

Graphviz checking needs tag vocabulary, attributes and parent/child placement,
not just a whitelist. Future delegated policy can select processing/settings for
label contexts without hard-coding those attribute names into DOT. Current
composition still processes every HTML-like operand when enabled. Context
selection must distinguish `n:<p>` (port `p`),
`label=<p>` (text `p`) and `label=<<p>x</p>>` (an element). Port-reference
resolution belongs to later graph semantics, not markup validation.

Follow Q10's specification-first approach and pinned 16.0.0 differential
reference. Remaining work is delegated context selection and contextual color
validation; local values/content/reference checks are documented publicly.
Run pinned Graphviz differential tests before claiming complete implementation
compatibility, including its permissive numeric-prefix parsing. Rendering,
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

The proposed string processor owns its value checks and custom-verifier contract,
independently of markup elements or DOT nodes. Markup may select a child policy
for an attribute value but must not make the child inspect the enclosing tree.
Preserve markup's mandatory quote/reference syntax; optional inner passthrough
does not disable it. Reuse checks standalone or after parsing as well as through
supported delegation. Element-specific/cross-attribute conditions and implicit
markup-to-text extraction are outside the first slice; see
[string processing](PROCESSOR_CONTRACT.md#optional-string-processor).

String built-ins and custom checks will use the same
[verifier contract](PROCESSOR_CONTRACT.md#shared-verifier-contract).
Comparison-based checks inherit case-sensitive defaults with optional per-check
overrides; unrelated checks need no case setting. Custom verifiers explicitly
opt into shared comparison or keep their own semantics. Optional Unicode case
folding is independent of source encoding and must compile out when unused.
Custom string checks can use generic or typed custom diagnostics without
depending on markup types; see [comparison rules](PROCESSOR_CONTRACT.md#string-comparison-rules)
and [custom diagnostics](PROCESSOR_CONTRACT.md#custom-string-diagnostics).
These proposed string settings do not change markup's existing tag/attribute
name-comparison rules or make custom verifiers inherit case folding implicitly.

SIMD batching across scopes remains an optional investigation. Define grouping,
variable-length handling, diagnostic order and cancellation before claiming a
benefit; do not add copying or mandatory queues in anticipation of it.

### Recovery and acceptance

Extend the implemented opt-in DOT/markup prefixes to retain later safely recovered
regions, with explicit gaps and correct local-versus-subtree completeness.
Keep a single Document type, safe traversal, borrowed source and separate
validity/operational outcomes. Per-scope `.not_processed` must not mean that
processing was never requested. Preserve independent outer/inner completeness;
opt-in composed child retention now owns separate buffers, while the default
workspace path still discards child trees. No guessed delimiter or repaired tree.
Current APIs: [markup prefixes](../MARKUP.md#partial-results-for-editors),
[DOT prefixes](../READING_DOCUMENTS.md#partial-results-for-editors) and
[composed retention](../LABELS.md#retaining-label-trees-for-editors).

New dialect grammar will need its own safe synchronization boundaries, especially
around void elements and unquoted/empty attributes. Preserve the distinction
between recovery for further diagnostics and accepting or repairing syntax;
Bounded current-element typo matching is implemented for diagnostic continuation,
not source or tree correction; see [closing-tag recovery](../MARKUP.md#closing-tag-typo-recovery).
Lookahead and fuzzy ancestor selection are not included. Current recovery
behaviour is documented under [parse failures](../MARKUP.md#when-parsing-fails).

### Optional summaries and retention

A per-identifier summary index is still only a proposal. Boundary scanning can
supply raw ranges and lexical facts, not element depth, counts or reference
facts. Those require context-aware markup processing, with its cost charged even
when no tree is retained. Uncomputed fields must be absent/unknown, not zero.

`<a/><b/>` has element depth 1; `<a><b/></a>` has depth 2. Both DOT envelopes
reach angle-counter depth 2. Decide whether a separate `max_elements` limit is
useful, and define summary layouts, caching owners/lifetimes and public event
consumers separately. Count-only measurement does not supply a public event API.

### Native source encodings

Compile-time capabilities, inheritance/union, BOM/explicit selection and the
initial one-shot native paths are implemented; see [source encodings](../ENCODINGS.md).
Do not retain a UTF-8 conversion/source-map requirement for native parsing.

Remaining work: native Session dispatch, metered encoding/content validation,
and source excerpt windows with physical-byte annotation mapping. Selection and
complete-unit framing precede tree creation; malformed full units now follow
the processor's `validation.invalid_encoding` severity. DOT excludes HTML
operand bodies, while markup checks its whole fragment or explicit local scope.
Preserve original bytes and compact per-document provenance; keep disabled
readers out of dispatch and measure default UTF-8 regressions separately.

Entry/binding boundary: independent profiles select/check whole-buffer framing;
bound processor workers consume aligned fragments in the inherited reader,
own their content validation, and do not expose standalone
parser/session methods. A worker may be a leaf; encoding factory hooks belong to
the factory, and diagnostic/owning-result types remain shared across encodings.

Settled selection and composition contracts are documented in
[source encodings](../ENCODINGS.md#bom-or-explicit-byte-order) and
[attached delayed results](../LABELS.md#attach-delayed-results).

Runtime-policy retention-off throughput and reader pull-in from generic document
helpers require separately measured performance work; no stable-parity claim is
made for those configurations.

Any future explicit transform must state buffer ownership, replacement/loss,
original/working size bounds, mapping and CPU/memory costs. Such a transform is
not required to recognize UTF-16/32 grammar and must not become a hidden pass on
the default raw-byte path.

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
