# Standalone markup — structural slices

Decisions: 2026-09-26; slices 1–3, 4a and 4b implemented 2026-09-27. Later slices below are plans, not
current public capabilities. R-MOD-014/015 and Q40 remain the architectural contract.

## Delivery order

Build and measure the real standalone processor before expanding the composition
framework. The same engine will later serve standalone, delayed and during-DOT
use. This changes the earlier opaque-first implementation sequence, not the agreed
DOT `none`/`opaque` semantics. Do not extend `PolicySet` or a scheduler to justify
this parser. Independent parsing must not import DOT grammar or retained records.

| Slice | Scope | Status |
| --- | --- | --- |
| 1 | Text, arbitrary matching/self-closing elements; standalone module, source-backed output, explicit memory, policy limits, bounded/cancellable execution | Implemented |
| 2 | Quoted attributes, retained order/duplicates, independent duplicate checking | Implemented |
| 3 | References, comments and CDATA, including malformed-reference acceptance policy | Implemented |
| 4a | Optional independent UTF-8 validation, source-ordered with duplicate findings | Implemented |
| Resource hardening | Default-capped shared diagnostic retention and an untrusted-input resource preset | Implemented |
| 4b | Optional XML 1.0 name checks and known-reference checks, without imposing either on other dialects | Implemented |
| Recovery | Explicit structural-error recovery for additional diagnostics | Deferred to a separate design discussion; not part of 4b |
| Integration | DOT opaque recognition followed by delayed integration; during-DOT composition later | Planned |

Each slice needs tests, truthful supported-syntax documentation and measurements.
Recognition of an excluded feature reports unsupported without validating its body.
No reserved public fields or pretend implementation of later checks are needed.

## Settled grammar direction

- Parse fragments: empty, text-only, multiple top-level elements and mixed content.
- Names are arbitrary vocabulary, matched byte-for-byte and case-sensitively.
  No implicit Unicode normalization, namespace resolution or HTML tag closing.
- Byte-oriented syntax with raw non-ASCII preservation, not full XML conformance.
  Optional UTF-8 and XML 1.0 name validation are independent of parsing.
- Attributes require quoted values (`'` or `"`); preserve spelling and order.
  Duplicate checking defaults to error, with warning/off choices; retain every
  occurrence. Off means uniqueness was not checked, not that it passed.
- Syntactically valid named references are preserved without requiring definitions
  in the structural grammar; known-reference checks are separate. No expansion.
- Malformed-reference acceptance is a syntax policy: reject by default; warn or
  silently accept by treating the offending `&` as literal text and resuming normal
  scanning. Never consume a subsequent `<` or closing attribute quote as reference
  content, invent a replacement value, or present tolerated input as XML-conformant.
  Exact recognition/diagnostic extents are documented and tested in slice 3.
- Comments and CDATA are preserved as distinct leaves. Processing instructions/declarations are
  deferred; no DTD processing, external entities, file/URL access or rendering.
- Preserve whitespace. Label-specific interpretation belongs to a later pass.
- Stop the fragment at an unrecoverable structural error; no guessed closing tags
  or published partial document. Independent fragments can still run. Validation
  findings continue where their own prerequisites remain available.

## Slice 4b — optional validation

The processor stays generic and extensible, with Graphviz as its priority
consumer; browser implementation is not the goal. Optional XML rules are supplied
definitions, not a mandatory base dialect or a substitute for future Graphviz rules.

Decided 2026-09-27: name rules and reference catalogs are independently selected
validation behavior, not universal rules added to the scanner. HTML, SVG,
Graphviz and custom consumers such as XAML must not inherit unrelated restrictions
merely because they reuse this processor or share an executable. A profile may
explicitly reuse a rule, but enabling name validation must not implicitly select
an entity catalog, namespace processing, vocabulary checks or whole-source UTF-8
validation. The structural defaults remain unchanged; these new checks default
to off, with warning/error choices and compile-time/runtime policy parity.

This is separation of optional validation, not a claim of grammar neutrality.
The current parser still requires its documented XML-like fragment syntax. A
dialect needing different tokenization or tree construction needs an explicitly
designed grammar change or a separately bound processor; disabling a check cannot
make previously rejected syntax parse. Full browser HTML, SVG/XAML semantics and
Graphviz labels are not delivered by this slice. Consumer implementations remain
compile-time bindings, not runtime-loaded parsers or registry callbacks.

**Dialect construction clarification; extension proposal, not implemented.**
Shared markup spelling does not require identical stack behavior. In XML-like
syntax `<br>` opens an element until `</br>`; `<br/>` is empty. In HTML syntax,
`br` is a void element and needs no end tag. See [XML elements](https://www.w3.org/TR/xml/#sec-starttags)
and [HTML void elements](https://html.spec.whatwg.org/multipage/syntax.html#void-elements).
A compile-time-bound dialect rule could classify selected names as void when
their opening header ends, before pushing an open-element frame. This can reuse
the existing engine; it does not inherently require a separate full HTML parser.
It is a parsing/interpretation rule, not a validation severity or recovery from
an error. Preserve the written tag spelling; do not insert a synthetic closing tag.

The existing structural behavior and agreed XML-like built-in mode baseline
remain unchanged for now. Exact void-name selection, matching/case/context,
explicit closing-tag handling and policy surface need their own discussion.
Implementing selected HTML-like conveniences must be described as a defined
subset/custom dialect, not full browser HTML conformance. Standards apply to
the compatibility being promised; a custom dialect can deliberately differ.
The new optional name/reference checks neither implement nor prohibit this
future parsing capability. More extensive HTML parsing rules are not implied.

The first optional name rule follows [XML 1.0 Fifth Edition names](https://www.w3.org/TR/xml/#sec-common-syn)
for element, attribute and named-reference names. It does not normalize, fold case,
resolve namespaces or restrict tag vocabulary. The first known-reference catalog
contains XML's [five predefined entities](https://www.w3.org/TR/xml/#sec-predefined-ent):
`amp`, `lt`, `gt`, `quot`, `apos`. A finding means absent from the selected catalog,
not invalid in every dialect. Other catalogs and custom catalog binding APIs are
later work, not mandatory dependencies of structural parsing. Check references
only in their existing text/attribute contexts, not comments/CDATA; accepted
malformed-reference candidates remain literal text. No expansion, decoding into
stored values, DTD processing or external lookups are added.

### Name-local UTF-8 implications

Checking Unicode name rules requires decoding each examined name into temporary
code points even with the independent whole-source UTF-8 check off. This does not
transcode the source, replace bytes, change byte-based spans or retain a Unicode
copy. Malformed bytes in a name cannot pass that name rule; malformed bytes in
unrelated text/comments/values are not newly rejected by enabling name checking.
Valid UTF-8 also does not automatically mean a valid name.

Independent checks keep independent severities and completion. If both checks
are enabled, malformed bytes in a name can produce both a name-rule finding and
an encoding finding; their counts are findings, not distinct bad byte positions.
For example, a name error must not be downgraded because the encoding policy is
only warning. Both delivered findings consume sink capacity, so the same retained
entry budget can stop sooner. The completed tree is unchanged and remains usable;
validation error, warning and incomplete work retain their existing meanings.
The implemented policy shape is `validation.names.{rule,severity}` and
`validation.references.{catalog,severity}`, with `xml_1_0` and `xml_predefined`
as the initial supported selections and both severities default off. Partial
nested patches inherit leaf-by-leaf; both complete presets reset these checks.
All typed combinations remain meaningful and infallible to prepare.

Each retained element name is checked once at its opening span; matched closing
spelling is byte-identical. Attributes and syntactically complete named references
are checked individually. One name finding identifies the first bad code point
(one byte for malformed UTF-8), with the full name as related context and typed
context/reason. Unknown-reference findings cover `&name;`. Source-order ties are
encoding, duplicate, name, catalog. Encoding can still report every bad source
byte, including closing tags. No deduplication changes either check's severity.

Implementation targets are a fast ASCII path, name decoding proportional to
examined name bytes, and no per-node/name/reference pool growth. Locating reference
names also requires context-aware rescanning of existing text/value spans because
references have no retained index. That cost can be proportional to those spans'
full length even when they contain few references; it is not just name-decoding
work. A whole-source encoding pass may inspect those bytes again; shared decoding
helpers do not imply zero repeated work. Fixed-disabled checks and tables must
be excludable when no other reachable entry point needs them. Runtime-off skips
execution, but selectable code/tables can remain linked. A single preorder node
walk and monotonic attribute cursor process enabled name/reference checks. Reference
rescanning reuses the lexer's byte-name predicates and skips malformed literal
candidates without revisiting their consumed prefix. Numeric values are not decoded
again. Comments/CDATA do not participate. Without the new checks, the existing
attribute-only/encoding traversal remains selected; encoding-only still needs no
document-pool access. Duplicate scratch remains the sole validation allocation,
preflighted before checks. Precise API and cost semantics are in the
[consumer guide](../MARKUP.md#optional-name-rules-and-reference-catalogs).

### Structural recovery — deferred, not implicit acceptance

Slice 4b adds independent validation only. Keep current fail-fast handling of
unrecoverable structural syntax and do not publish a partial successful document.
Before adding recovery, discuss recoverable error classes, safe synchronization
through quoted values/comments/CDATA, mismatched-tag stack handling, progress and
work limits, diagnostic order/cascades, output validity and termination reasons.
Recovery for collecting more errors is distinct from syntax acceptance or repair.
No guessed closing tags, repaired successful tree or broad recovery switch is
authorized by this deferral. Its implementation and placement relative to later
integration will be discussed separately; no placeholder public setting is needed.

## Encoding boundary

### Current implementation

The byte scanner expects ASCII-compatible syntax, naturally compatible with
UTF-8. UTF-8 validation is not implied by structural success. UTF-16/32 require
explicit caller-side conversion, and spans then index that converted buffer;
original-encoding mappings need a separate source map. No automatic transcoding.
Leading UTF-16/32 BOMs are detected as unsupported encoding, without promising
reliable identification of all incorrectly encoded or mixed-encoding bytes.

### Future transcoding and source provenance — requirement, not implemented

When UTF-16/32 input adapters are added, UTF-8 will be the working representation,
not a replacement for the identity of the original source. Preserve original
encoding, byte order and BOM presence/absence once per input/source context, not
on every node. Keep caller-supplied or detected provenance explicit; a naked
converted UTF-8 buffer cannot reveal its previous encoding. Unknown origin must
remain unknown, not be guessed or mislabeled as originally UTF-8. Exact metadata
types, source ownership and adapter APIs are still to be designed.

Retaining an encoding label alone does not preserve original bytes or map offsets.
For exact source reproduction, keep the original caller-owned bytes or an explicit
source handle with a sufficient lifetime; do not imply that a reconstructed
encoding is byte-for-byte identical. Lossy replacement, normalization, or discarded
source/BOM information must never be silent or advertised as lossless. The initial
conversion error policy needs an explicit contract before implementation.

Parser spans continue to index the supplied working byte buffer. Original-source
diagnostics/fixes need an explicit mapping; transcoding is not a constant origin
offset. If mapping is unavailable, identify coordinates as working-buffer offsets,
not original-file positions. Mapping representation and eager versus on-demand
translation remain open, with explicit caller-owned storage/work budgets.

Document conversion CPU, UTF-8 output-buffer size, original-buffer lifetime and
mapping costs separately. Holding original and working buffers can increase peak
memory; mapping may use storage or require rescanning. Bound both input and
converted-output sizes. None of these costs should be imposed on unchanged raw-byte
input paths. Current raw-byte acceptance with optional UTF-8 validation is not
silently changed into mandatory valid-UTF-8 parsing by this future adapter direction.

### Current lexical choices

Slice 1's concrete lexical choices are:

- Name start: `[A-Za-z_:]` or any byte `0x80..0xFF`; continuation additionally
  permits `[0-9.-]`. Colons are raw name bytes, not namespace processing.
- Syntax whitespace: space, tab, CR, LF. Other bytes below `0x20`, including NUL,
  fail in the implemented grammar. Non-ASCII name/text bytes remain unchanged.
- A leading UTF-8 BOM is recognized and excluded from text, as in DOT; source
  offsets still include it. Elsewhere those bytes are ordinary content.
- Ordinary text is a nonempty run until `<`; references stay inside that span. It is not entity-decoded or
  subject to full XML character-data restrictions. In particular, this slice
  makes no claim to reject every XML-forbidden character-data sequence.

## Implemented architecture

`markup_parser` is a separate build module rooted at `src/markup.zig`.
Both parsers import one language-independent support module so applications can
use both without duplicating shared type identities. Shared location, reporting,
cancellation and WDP hashing do not depend on either grammar. Payloads/registries
remain processor-owned; the markup namespace is `markup_parser`.

Scalar and opt-in block run scanning feed one iterative event-level parser. Growable, fixed and
count-only consumers share that grammar. Events stay private/provisional, following
DOT's initial layering. Public retained data is a compact preorder forest: each
20-byte node holds a raw span, a name span (zero length with a kind discriminator for leaves), and a subtree-end
index. Direct-child iterators skip whole subtree intervals without allocations.
This chooses intervals instead of the earlier provisional parent/child/sibling
links. No parent lookup table, per-ID summary table or graph data is added.

An open-element frame contains its name span and a consumer handle: 12 bytes,
not the earlier 8-byte estimate. Self-closing elements count toward nesting depth
but need no persistent frame. Allocator-backed scratch grows independently of
output; fixed storage never allocates. Pop reuses frames, and release is bulk.
DOT and markup instantiate the same `common/stack.zig` mechanism with their own
frame types and u32 active-depth counters. Allocation sizes remain usize.
Owned stack growth uses allocator `realloc`: remapping is attempted before an
allocate/copy/free fallback. Failure leaves the original frames intact. Doubling,
fixed-storage behavior and stack layouts are unchanged; successful in-place growth
avoids an obligatory second live allocation.

Owned successful output tries an in-place capacity reduction per pool; refusal retains
the original allocation with no allocation/copy fallback. `ParseResult.retainedBytes()`
reports reserved node/attribute capacity, not just occupied records, and excludes allocator
overhead/RSS. Fixed parsing is unchanged; allocator callbacks are not budgeted work.

The policy contains implemented limits (source bytes, nodes, attributes, nesting),
malformed-reference acceptance, duplicate/encoding validation severity, optional
name rules/reference catalogs and their independent severities, scanner
selection (`scalar` default / `block`), and execution choices (metering, cancellation). Limits/counts/ranges are u32; lengths
at the allocator/slice boundary use native sizes. Defaults preserve the existing
unlimited-within-representation convention for the standard policy. The optional
`presets.untrusted` selects finite application-sized parse budgets (see below).
All typed combinations are meaningful,
including zero limits, so `validatePolicy` currently returns `valid`; no invalid
combination is invented and parsing has no policy-error union. Fixed verification is
comptime-only. Runtime overrides are opt-in, resolve once, and inherit the compiled
baseline; no settings copies on nodes or per-byte override merging.
Both parsers use `common/processor.zig`'s `PolicyBinding`. Markup exposes `Policies`
for preparation, not scheduling. Infallible schemas use `Error = error{}` and a
valid-only check, handled exhaustively; no check result is discarded. If markup
later introduces policy errors, its current infallible API must be updated to
propagate them rather than silently treating them as unreachable.

The standalone scanner checks the source-size domain at initialization, before
reading bytes, rather than at each scan step. At EOF after a self-closing slash,
the expected token is precisely `>`. With comments/CDATA implemented, `<!` alone
is an incomplete possible supported opener. Only a distinguishing byte identifies
an unsupported declaration family, whose body is not validated.

Metered fixed sessions charge source examinations, grammar transitions, each byte
of tag-name comparison, and individual event attempts. One credit suffices; zero
does no normal work. Cancellation is checked before each next microstep. Fixed
ordinary builds omit frontier/hook state when disabled. Callout time is excluded,
and allocator-backed operations are run-to-completion, not a bounded allocation
claim. Completed results are latched; abort occurs at most once after begin.
Scalar scanning remains byte-stepped when either metering or cancellation is
enabled. Bounded block scanning uses up-to-64-byte windows and scalar boundary transitions;
its credit totals/frontiers differ from scalar. Plain scanning loops to the next
token/finding. See the follow-up below for backend details and measurements.

No Graphviz/extended vocabulary validation, namespace resolution,
markup fixes or processor scheduling is implemented
by this slice. See the [consumer guide](../MARKUP.md) for the actual API.

## Resource hardening — 2026-09-27

The shared growable diagnostic bag used by both DOT and markup now defaults to
1,024 entries. `EntryLimit` is a tagged choice: `.limited: u16` (0–65,535) or
explicit `.unlimited`. Neither zero nor 65,535 is a sentinel. Accepting the final
entry requests stopping; the operation preserves known invalidity and reports
unfinished checks as incomplete. Native allocation lengths and u32/u64 factual
counters are unchanged. The cap lives in the sink, with no new parser hot-path
checks, narrower diagnostic payload or changed UTF-8 finding spans. Settings and
storage must not be mutated during a bag's lifetime; reset clears entries while
retaining its capacity and selected limit.

`presets.untrusted` is a complete ordinary standard policy with four finite
limits: 8 MiB source bytes, 100,000 nodes, 200,000 attributes and depth 256.
Compile-time enumeration of policy limits requires an explicit finite budget in
this preset for every field; extending limits cannot silently inherit unlimited.
Encoding remains off and syntax/validation meanings do not change. Fixed and
opt-in runtime profiles use the same policy resolution. The complete preset
resets all leaves when supplied as an override; callers wanting only its limits
can select that subtree. It bounds parsing/measurement, not independent validation
of an already retained document.

Resource tests isolate the diagnostic risk with a 16 MiB text source: both all
invalid bytes and alternating valid/invalid bytes stop UTF-8 validation after
1,024 findings. On the native target the bag reserves exactly 36 KiB of live
entry storage (1,024 × 36 bytes). This is not a peak-heap or RSS measurement:
old/new buffers can coexist during growth, arena allocations can accumulate,
and the source, output and scratch are separate costs. Wide-count tests with a
discarding sink still complete over 65,535 errors. Duplicate, DOT operator and
warned-reference floods also honor the cap without claiming completion.

Tests cover zero/one/max finite limits, explicit unlimited retention beyond
65,535, reset, every default-cap allocation-failure point, and exact/one-over
preset limits with fixed/runtime parity. A 65,536 finite limit is an expected
compile failure. Freestanding 32-bit probes consume finite and unlimited shared
bags using only caller-backed allocation.

449/449 tests pass in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall. Examples,
benchmark compilation, 14 expected compile failures and the consumed RISC-V32/
Wasm32 freestanding probes pass. Formatting and diff whitespace checks pass.

The [untrusted-input guide](../MARKUP.md#untrusted-input) separates input acquisition,
retention, output/scratch, parse credits and validation costs. Validation sizing,
sorting and name comparisons are not internally metered or cancellable; this is
not a bounded-validation change. ReleaseSafe guidance is defense in depth, not a
memory-safety proof. No new throughput or process-memory benchmark is claimed.

## Slice 4a implementation

`validation.invalid_utf8` is off by default, with error/warning choices and full
compile-time/runtime parity. It checks the entire borrowed source independently
of structural parsing, including comments and CDATA. Valid sequences consume
1–4 bytes; a byte not beginning a valid sequence gets one one-byte finding, then
scanning advances one byte. There is no mutation, normalization, decoding or XML
character/name conformance claim. DOT and markup share scalar decoding and its
sequence-length wrapper in `common/utf8.zig`; diagnostic identities and policies
stay local.

One monotonic u32 cursor merges encoding findings with duplicate checks by primary
source offset, UTF-8 first on ties. No queued findings, second sort or source-sized
temporary storage is added. A fixed disabled check omits its scan/cursor; runtime
off skips its scan. Encoding-only validation does not inspect attribute pools,
allocate or need scratch. Enabled duplicate scratch is preflighted before either
check; resource failure leaves enabled checks incomplete without running UTF-8.
Ordinary errors continue both checks. Sink stop/failure and enabled cancellation
stop the operation, preserving known invalidity and per-check completion. UTF-8
polls cancellation at 64-byte scan thresholds, finishing the current scalar
(up to three additional bytes). Existing unmetered sizing/sorting/name comparisons
remain unchanged. This does not add bounded validation.

Validation totals are u64, matching DOT's independent-check aggregation; source
offsets, capacities and parsing counters stay u32. The parse engine, retained
records, diagnostic payload and nesting frames are unchanged. Stricter names,
known-reference rules and structural recovery are not implicitly selected by this
check and need their own contracts before implementation.

### Slice 4a verification and costs

438/438 tests pass in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall, including
64 standalone markup tests. Examples, benchmark compilation, expected compile
failures, and consumed RISC-V32/Wasm32 fixed/runtime probes pass. New coverage
includes invalid scalar encodings/truncation, all raw source contexts, fixed/runtime
severity combinations, inherited/reset policies, source-order ties, random-byte
oracles, scanner/budget parity, cancellation, sink backpressure and scratch failures.

Native record and session sizes remain unchanged: Node/Attribute 20 bytes each,
Diagnostic 36, duplicate key 8, nesting frame 12, and fixed/bounded/runtime sessions
416/424/480 bytes. The validation result is now 32 bytes, including u64 totals and
two check statuses. UTF-8-only validation has no allocation or scratch buffer;
its source cursor is u32. Diagnostic retention is a separate caller-selected cost.
No process-RSS or allocator peak-memory measurement is claimed here.

Local ReleaseFast checks on Apple M4 Pro, Zig 0.16.0, compared `e600dab` with this
slice. The original 13-fixture harness was used for default-off comparisons (only
its validation return type was adapted), with nine measured 16-operation batches
after five warm-up batches. Two isolated runs per build used before/after then
after/before order, without concurrent compilation. Midpoints of process medians
give geometric-mean throughput changes of +0.4% for fixed scalar and +1.3% for
fixed block parsing; duplicate validation is -0.4% on unique attributes and +0.8%
on duplicates. These small aggregate differences are not claimed as speedups.

The broad harness's scalar text case reported -9.1%, so text/prose were also
checked separately with eight warm-up and nine measured batches of 64 parses,
in before/after/after/before order. Scalar text measured 2150.9 -> 2200.9 MB/s
(0.465 -> 0.454 ms); scalar prose measured 1891.6 -> 1945.2 MB/s
(0.971 -> 0.944 ms). Block text/prose differed by -0.2%/-0.8%. The broad text drop
was not reproduced in this focused check. This is separate evidence, not a
replacement for the broad result or a guarantee of parity on every workload.

The opt-in pass was timed separately using the encoding benchmark's same fixtures
and sampling, excluding parsing/allocation and using a discard sink. Cells are
**milliseconds / decimal MB/s**. Malformed input still counts every finding.

| Validation fixture | Source bytes | Fixed policy | Runtime policy | Scratch bytes |
| --- | ---: | ---: | ---: | ---: |
| ASCII | 500,000 | 0.283 / 1769.5 | 0.232 / 2152.6 | 0 |
| Valid multilingual UTF-8 | 600,000 | 1.250 / 480.2 | 1.258 / 477.0 | 0 |
| Malformed bytes, 300,000 findings | 350,000 | 1.052 / 332.7 | 1.076 / 325.2 | 0 |
| Encoding + duplicates, 100,000 findings | 1,050,000 | 1.457 / 720.8 | 1.443 / 727.4 | 16 |

Fixed/runtime differences here include code-generation and timing variability;
they do not establish that runtime selection is intrinsically faster. Standard-
machine baseline artifacts were not changed.

## Slice 3 implementation

The scalar scanner recognizes named, decimal and hexadecimal references inside
existing text/quoted-value spans. Named references use the byte-name grammar and
need no definition. Numeric references use XML 1.0's `Char` range, not HTML's
replacement/legacy rules. Saturating accumulation checks range without overflow
or expansion, including arbitrarily long or zero-padded digit sequences. No
entity table, per-reference pool, external lookup, decoding or normalization is added.

`syntax.malformed_reference` has compile-time/runtime `reject`/`warn`/`accept`
parity. The scanner returns a recoverable finding to the grammar; the public
low-level lexer maps it to a latched strict failure. Tolerance treats the first
ampersand literally; already-examined candidate bytes are safe literal content
and are not rescanned. The terminating tag/quote/ampersand is left for ordinary
scanning. This is constant continuation state and linear work, not backtracking.
Candidate diagnostic spans and typed reasons are part of the public contract.

Comments enforce `<!--...-->` without interior `--`; CDATA enforces exact
`<![CDATA[...]]>`. Bodies ignore reference/tag syntax but still reject prohibited
raw control bytes. Both are distinct retained leaves. Their kind occupies the
otherwise-unused start of a zero-length name span; node/attribute/frame layouts
remain 20/20/12 bytes. `NodeView.content()` strips leaf delimiters on request.
Empty comment/CDATA bodies count as nodes, not elements/depth. References create
neither extra nodes nor attributes. The node-kind enum also serves private leaf
events; the parser remains independent of retained syntax.

Reports/results/progress expose u32 accepted-deviation and warning counts,
including the discovered prefix on stop/failure. A fixed rejecting profile omits
active counters and runtime policy storage; a fixed silent profile omits its
active warning counter. Public result fields still exist. Diagnostic warning
delivery follows sink acknowledgment and aborts exactly once on stop/failure;
terminal syntax/resource failures keep their cause. Independent duplicate
validation and its findings/costs are unchanged.

Tests cover boundary spellings/ranges, raw preservation, capacities, every prefix,
arbitrary bytes, long candidates/bodies, fixed/runtime/growing/count-only parity,
budget partition invariance, cancellation/relocation, policy reset, diagnostic
stop/error reasons and allocation failures. Freestanding probes consume the new
leaves, runtime policy and counters. Measurements are recorded below.

## Slice 2 implementation

Quoted attribute parsing uses the same resumable scanner and event machine.
Attribute-free tags retain their whole-token path. Attribute-bearing headers
stream `open_head`, each `attribute`, then `head_end`/`empty_end`; there is no
header-sized buffer, rescanning pass or unmetered value/name loop. Each attribute
event is charged and cancellable. A pending header uses one constant-size frame
in the session; only a non-self-closing header enters the nesting stack.
The first attribute-name byte is consumed when the cached `open_head` token is
returned; there is no separate `attribute_start` reread/credit. The token retains
the opener's original name/span and excludes that consumed lookahead byte.

The separate 20-byte attribute record contains an owner u32 and two source spans
(name, quoted value). This keeps all nodes at 20 bytes, including attribute-free
elements/text. Owner-sorted storage gives O(log A) attribute lookup and O(1)
iteration; no attribute range is added to every node. Fixed document capacities
are now `{ .nodes, .attributes }`, with no legacy scalar-capacity wrapper. Counts,
limits, fixed/growing/count-only parsing, allocation failures and bounded sessions
all include attributes. Quoting, whitespace and every duplicate remain intact.

The retained view is a trusted representation with explicit preconditions, not a
builder accepting arbitrary public-field layouts. Spans and preorder intervals
must be valid; attributes must be source-ordered, owner-grouped and refer to live
elements. Safety builds assert attribute metadata/order within the existing sizing
pass. These are programming-contract checks, not new input policies or a general
document validator. ReleaseFast/ReleaseSmall add no invariant-audit pass, and
attribute lookup keeps its O(log A) cost without per-lookup whole-pool scans.

`validate`/`validateIn` are independent passes over completed syntax. Exact
case-sensitive duplicates are checked per owner; every later occurrence points
to the first, and all findings are emitted in source order. Severity defaults to
error, with warning/off policies and fixed/runtime parity. Off does no check or
allocation and explicitly reports `not_run`. Parse success is not validation
success; no implicit pass or deduplication is added.

Duplicate checking uses 8-byte scratch entries, reused for the largest attribute
list (zero for lists smaller than two). One in-place heapsort by name/index is
followed by linear scattering into the existing `first` column, indexed by source
position. The sorted-index column stays intact during scattering; there is no
second sort or larger scratch record. Retained pools remain unchanged. Comparison
cost includes name bytes; allocator-backed validation computes its scratch
requirement only once and passes it to the internal checker. Resource diagnostics
anchor to the first largest-list owner's name (allocation context, not syntax blame).
Completion, validity, check status, finding counters and delivery are distinct.
Sink stop/failure cancels further validation; an ordinary error finding does not.
This pass is not metered: cancellation checks surround groups/findings, not each
sorting comparison. Bounded validation remains later work, as with DOT.

## Initial local measurements — 2026-09-27

Apple M4 Pro, Zig 0.16.0, ReleaseFast. These are local development measurements,
not replacements for the standard-machine DOT baselines. `bench-markup` takes
the median of nine 16-operation batches after five warm-up batches, reporting
per-operation latency. Sources and fixed storage are prepared outside timing;
results are consumed. The runtime override uses the complete standard preset,
so fixed/runtime paths process equivalent settings. Decimal MB/s, not MiB/s.

| Fixture | Source bytes | Fixed ms / MB/s | Runtime baseline ms | Runtime override ms | Count-only ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| 50,000 empty elements | 200,000 | 0.938 / 213.2 | 0.955 | 0.965 | 0.838 |
| 50,000 mixed fragments, 150,000 nodes | 750,000 | 3.835 / 195.6 | 3.908 | 3.739 | 3.566 |
| One text run | 1,000,000 | 3.369 / 296.8 | 3.313 | 3.287 | 3.409 |
| 10,000 nested elements | 70,000 | 0.340 / 206.0 | 0.330 | 0.343 | 0.300 |

This is an initial baseline, not a statistically established ordering of execution
profiles or a speedup claim. The benchmark is intentionally repeatable as later
slices arrive. No force-inlining or second scanner was added to improve a fixture.

Native layouts: node 20 B, frame 12 B, markup diagnostic 36 B; ordinary fixed
session 336 B, metered fixed session 344 B, runtime session 392 B. Mixed output
retains 3,000,000 B plus 24 B of reserved fixed scratch. The deep fixture retains
200,000 B plus 120,000 B reserved scratch. These exclude source, bags, session,
allocator overhead and process RSS. Growable peak live heap/RSS was not measured;
fixed capacity and allocation-failure tests do not establish those numbers.

The shared-primitives extraction was also checked against a before-build at
`a0cdf8b`, using the existing 100,008-byte, 50,000-statement `bench/policies.zig`:
11 alternating before/after process pairs, each executable's nine-round median.

| DOT path | Before ms | After ms |
| --- | ---: | ---: |
| Scalar fixed | 0.820 | 0.817 |
| Scalar runtime baseline | 0.942 | 0.948 |
| Scalar runtime override | 0.946 | 0.950 |
| Block fixed | 0.963 | 0.963 |
| Block runtime baseline | 1.241 | 1.243 |
| Block runtime override | 1.231 | 1.237 |

Changes are within about 0.7% in this targeted run. DOT layouts remain document
232 B, diagnostic 80 B, fixed session 1,064 B, runtime session 1,288 B and runtime
options 120 B. The consumed benchmark's native `__text` is 485,428 B both before
and after. This is not the full historical 14-workload regression suite and does
not establish RSS, live-heap or allocation-count equivalence.

## Review hardening verification — 2026-09-27

390 tests pass in Debug, ReleaseFast, ReleaseSafe and ReleaseSmall, plus 12
compile-fail fixtures. Examples, standalone markup tests, benchmark builds and
consumed RISC-V32/Wasm32 profiles also pass. New regressions cover EOF diagnostic
details, unsupported prefixes, oversized descriptors without byte access,
infallible shared policy binding, runtime hook gating across operations/reset,
shared stack allocation failures, and successful/refused in-place trimming.

Local ReleaseFast comparison against `edc1eab`, same machine/toolchain as above:
nine alternating process pairs for DOT policies and three for markup, aggregating
each executable's existing median. The markup benchmark source is unchanged.

| Markup fixed fixture | Before ms | After ms |
| --- | ---: | ---: |
| 50,000 empty elements | 0.947 | 0.882 |
| 50,000 mixed fragments | 4.011 | 3.566 |
| One text run | 3.469 | 2.988 |
| 10,000 nested elements | 0.348 | 0.308 |

Across fixed/runtime/count-only markup paths, observed latency decreased roughly
5–14%; DOT policy timings stayed within about 2%. This is a targeted local check,
not a full performance-suite result or an isolated attribution to one change.
Measured node/frame/diagnostic/session sizes and fixed reserved capacities are
unchanged. Consumed benchmark `__text` grows from 485,428 to 485,468 B for DOT and
303,852 to 304,788 B for markup; these include benchmark/host code, not just parsers.

Allocator tests separately verify that a one-node owned result retains 20 B when
shrinking succeeds, and exposes its original slack when resizing is refused.
Finalization makes no additional allocation in either case and never changes a
successful parse into OOM. These are requested node-allocation bytes, not RSS or
allocator-internal reservations; growable peak live heap remains unmeasured.

## Slice 2 verification and costs — 2026-09-27

398 tests pass in Debug, ReleaseFast, ReleaseSafe and ReleaseSmall, plus the 12
compile-fail fixtures. Standalone tests, examples, benchmark builds and consumed
RISC-V32/Wasm32 profiles pass. New coverage includes quoted-value boundaries,
every truncation, exact source/owner spans, duplicate-order comparison against a
simple randomized reference, fixed/runtime policy parity, sink backpressure,
allocation failure, attribute storage exhaustion, cancellation within long values
and one-credit partition equivalence.

Same Apple M4 Pro and Zig 0.16.0, ReleaseFast. Three alternating before/after
process pairs compare `1aa2c3f` against slice 2 using the **unchanged original
benchmark source** for both builds. Each value below is the median of the three
process medians; each process takes nine 16-operation batches after five warmups.
These small local samples show variation, not a guarantee of no regression.

| Existing fixed-policy fixture | Before ms | After ms | Before MB/s | After MB/s |
| --- | ---: | ---: | ---: | ---: |
| 50,000 empty elements | 0.904 | 0.859 | 221.2 | 232.7 |
| 50,000 mixed fragments | 3.573 | 3.617 | 209.9 | 207.4 |
| One text run | 2.906 | 2.890 | 344.2 | 346.0 |
| 10,000 nested elements | 0.307 | 0.319 | 228.3 | 219.3 |

Across all 16 fixed/runtime/count-only comparisons, measured throughput ranges
from −5.4% to +5.2%. The largest decrease is mixed count-only (229.7 → 217.3 MB/s,
3.265 → 3.451 ms). No claim of recovered or universally unchanged throughput is
made. The attribute-header path is separated from ordinary tag event handling;
no second scanner, source-sized buffering or extra attribute-free retained records
were introduced. DOT/common source and DOT retained layouts are untouched.

The expanded benchmark separately adds two 1,100,000-byte fixtures: 50,000 empty
elements with three attributes each, either distinct keys or one duplicate per
element. A single local run of that expanded harness (not the matched comparison
above) measured:

| New fixture | Fixed parse ms / MB/s | Runtime baseline ms / MB/s | Count-only ms / MB/s | Validation-only ms / MB/s |
| --- | ---: | ---: | ---: | ---: |
| Distinct attributes | 4.716 / 233.2 | 4.538 / 242.4 | 4.198 / 262.0 | 1.328 / 828.2 |
| Duplicate attributes | 4.486 / 245.2 | 4.520 / 243.4 | 4.062 / 270.8 | 1.081 / 1017.2 |

Validation timings include duplicate discovery, sorting and discarded diagnostic
delivery, but exclude parsing and scratch allocation. Throughput is normalized
to full source bytes; validation reads retained name ranges, not all value bytes.
The ordinary error policy still discovers all 50,000 duplicates with the discard
sink. These fixture measurements are starting points, not profile speed rankings.

Native node/frame/diagnostic sizes remain 20/12/36 B. Each attribute is 20 B;
fixed/bounded/runtime sessions grow from 336/344/392 B to 400/408/456 B (+64 B).
Both new fixtures retain 4,000,000 B in output pools and reserve 12 B of safe
nesting scratch; self-closing-only input actually needs no persistent frame.
Duplicate-validation scratch is only 24 B for either fixture, reused across all
elements. Attribute-free output capacities are unchanged. Owned-result accounting
tests include both pools and refused-shrink slack. These are explicit storage
figures, not process RSS, allocator overhead or peak live-heap measurements.

## Slice 2 review fixes — 2026-09-27

All seven review items are addressed: explicit trusted-document invariants with
safety-build attribute metadata assertions; useful resource-diagnostic locations;
one sizing pass on allocator-backed validation; linear source-order mapping after
the name sort; a specific infallible-schema contract error; remapping-first shared
stack growth; and removal of the first-attribute reread state. The invalid-layout
case is a caller-precondition violation, not a new policy or support for arbitrary
hand-built document pools. Parser-produced documents and delayed validation retain
their existing behavior. Attribute lookup does not add a whole-pool audit.

404 tests pass in Debug, ReleaseFast, ReleaseSafe and ReleaseSmall, plus 13
compile-fail fixtures. Examples, benchmark builds, standalone tests and consumed
RISC-V32/Wasm32 profiles pass. Regressions exercise owner order, span metadata,
largest-owner diagnostic context and ties, source-ordered findings after scattering,
in-place stack growth, failed remap/allocation with a preserved stack and copying
retry, and precise header-token spans after consuming its first attribute byte.
Enum and tagged-union schemas with valid baselines but invalid-capable checks are
both rejected by the specific compile-time contract error.

ReleaseFast comparison against `f1760f9`, same Apple M4 Pro/Zig 0.16.0 and unchanged
`bench/markup.zig` on both builds. Three alternating before/after process pairs;
values are medians of the process medians. Validation uses preallocated scratch
and a discard sink, so these timings do not measure the separate allocated-path
sizing-pass improvement. Decimal MB/s is normalized to whole source bytes.

| Validation fixture (1,100,000 bytes) | Before ms | After ms | Before MB/s | After MB/s |
| --- | ---: | ---: | ---: | ---: |
| Distinct attribute keys | 1.421 | 1.323 | 774.1 | 831.4 |
| One duplicate per element | 1.123 | 0.915 | 979.7 | 1201.7 |

| Parse fixture | Fixed MB/s before → after | Runtime baseline MB/s before → after | Count-only MB/s before → after |
| --- | ---: | ---: | ---: |
| Empty elements | 229.9 → 239.2 | 228.1 → 240.3 | 251.2 → 261.9 |
| Mixed fragments | 208.6 → 213.1 | 209.2 → 215.3 | 234.2 → 229.8 |
| Text | 342.7 → 340.8 | 343.9 → 341.2 | 340.4 → 340.8 |
| Deep nesting | 220.7 → 222.0 | 217.9 → 223.7 | 236.1 → 233.9 |
| Distinct attributes | 227.0 → 229.4 | 233.8 → 227.5 | 253.2 → 248.8 |
| Duplicate attributes | 233.6 → 232.5 | 234.1 → 229.0 | 254.6 → 250.0 |

Validation throughput rises about 7.4%/22.7% in these samples. Across all 24 parse
comparisons (including runtime override), changes range from −2.7% to +5.4%; this
is not a universal parsing-speedup or no-regression claim. Three alternating DOT
policy-benchmark pairs show median latency changes within about 2.4%: scalar fixed
0.868 → 0.882 ms, scalar runtime baseline 0.972 → 0.973 ms, scalar override
0.991 → 0.976 ms, block fixed 0.971 → 0.965 ms, block runtime baseline
1.284 → 1.301 ms, and block override 1.259 → 1.289 ms. This remains a targeted
local guard, not the full DOT benchmark suite.

All retained/scratch/session layouts are unchanged: markup node/attribute 20 B,
frame 12 B, duplicate-key scratch 8 B, diagnostic 36 B; fixed/bounded/runtime
sessions 400/408/456 B. DOT document/diagnostic/session layouts are also unchanged.
The in-place growth test reaches 32 frames with one allocation and five remaps;
copying is still permitted when an allocator cannot remap. This establishes the
mechanism, not general heap/RSS savings. Consumed benchmark `__text` decreases from
338,216 to 335,212 B for markup and 485,468 to 483,504 B for DOT; these figures
include host/benchmark code, not just library code.


## Slice 3 verification and costs — 2026-09-27

Implemented references, comments/CDATA and malformed-reference acceptance.
The full suite passes **419 tests in Debug, ReleaseSafe, ReleaseFast and
ReleaseSmall**, plus 13 compile-fail fixtures, examples, benchmark builds and
consumed fixed/runtime RISC-V32/Wasm32 probes. Formatting and diff checks pass.
The DOT implementation and shared primitives are unchanged by this slice.

Apple M4 Pro, Zig 0.16.0, ReleaseFast. The common comparison uses the unchanged
six-fixture benchmark source from `f887de8`, compiled against that commit and
this slice. Three alternating process pairs (before/after, after/before,
before/after) ran serially after compilation finished. Each executable reports
its median of nine 16-operation batches after five warm-up batches; the table
uses the median of three process medians. Decimal MB/s. These local development
samples do not replace standard-machine baselines or establish confidence bounds.

| Fixture | Fixed ms, before → after | Fixed MB/s | Runtime baseline MB/s | Runtime override MB/s | Count-only MB/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| Empty elements | 0.854 → 0.872 | 234.1 → 229.3 | 233.8 → 229.0 | 235.2 → 235.5 | 253.7 → 249.3 |
| Mixed fragments | 3.641 → 3.748 | 206.0 → 200.1 | 209.1 → 202.1 | 207.9 → 200.9 | 222.6 → 217.5 |
| Text | 3.017 → 3.086 | 331.4 → 324.0 | 331.4 → 332.5 | 331.9 → 332.5 | 332.5 → 310.1 |
| Deep nesting | 0.324 → 0.314 | 215.8 → 223.3 | 216.4 → 217.0 | 222.6 → 218.2 | 231.2 → 223.0 |
| Distinct attributes | 4.947 → 5.183 | 222.4 → 212.3 | 217.8 → 212.5 | 217.8 → 211.5 | 238.3 → 219.2 |
| Duplicate attributes | 4.976 → 5.185 | 221.1 → 212.1 | 218.0 → 213.1 | 216.7 → 212.3 | 237.7 → 219.4 |

The geometric mean over the 24 parse comparisons is **2.6% lower throughput**.
Individual changes range from −8.0% to +3.5%. In particular, count-only text is
6.7% slower, and count-only distinct/duplicate attributes are 8.0%/7.7% slower.
These are remaining regressions, not a no-cost feature claim. The ordinary-text
path avoids dispatch through tag/reference continuation states while retaining
one-byte metering; no block scanner or unbudgeted scanning loop was introduced.
Further count-only/hot-path work remains a performance follow-up. Timing varied
between runs, so the small changes are not strong evidence of universal ordering.

Independent validation (preallocated scratch, discard sink, source-byte-normalized
throughput) is 814.9 → 812.1 MB/s for distinct keys and 1,186.7 → 1,165.2 MB/s for
duplicates. Its algorithm did not change; it does not validate references or
reinterpret comments/CDATA as attributes.

The expanded `bench-markup` adds four supported-content fixtures. These are one
process's nine-batch medians, not before/after comparisons (the old parser rejected
them). All use valid input and a discard diagnostic sink; warning-volume costs
are not established by these measurements.

| Fixture | Source B | Fixed ms / MB/s | Runtime baseline ms / MB/s | Runtime override ms / MB/s | Count-only ms / MB/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| References in text | 1,700,000 | 8.246 / 206.2 | 7.800 / 217.9 | 8.322 / 204.3 | 7.646 / 222.3 |
| References in attributes | 1,800,000 | 8.103 / 222.1 | 7.757 / 232.0 | 7.660 / 235.0 | 7.607 / 236.6 |
| Comments | 1,400,000 | 5.243 / 267.0 | 5.076 / 275.8 | 4.995 / 280.3 | 4.913 / 285.0 |
| CDATA | 1,550,000 | 5.411 / 286.5 | 5.440 / 284.9 | 5.561 / 278.7 | 5.354 / 289.5 |

Node/attribute/frame/validation-scratch/diagnostic sizes stay **20/20/12/8/36 B**
on the tested native layout; retained and scratch widths are also checked by the
32-bit consumed probes. No per-reference retained storage was added. The two
reference fixtures reserve 2,000,000 B of output and 12 B of fixed scratch each;
the comment and CDATA fixtures reserve 1,000,000 B of output and no nesting scratch.
The attribute-reference fixture is self-closing; its measured-depth scratch
reservation is conservative, not a claim that it needs an active frame.

| Native session | Before B | After B | Increase B |
| --- | ---: | ---: | ---: |
| Fixed ordinary | 400 | 424 | 24 |
| Fixed metered | 408 | 424 | 16 |
| Runtime policy | 456 | 480 | 24 |

Continuation, policy and factual-result state have costs even though record sizes
are unchanged. Fixed rejecting profiles omit active deviation/warning counters;
fixed silent profiles omit the active warning counter. Public result fields remain
present. The unchanged-harness executable's `__text` grows from 335,212 to 338,996 B
(+3,784 B); this includes benchmark/host code, not isolated library size. Source,
bags, allocator overhead and process RSS are excluded from retained-storage figures.
Growable peak heap/RSS and a full DOT performance rerun were not measured.

## Scanner follow-up — 2026-09-27

This subsection records the initial backend implementation at `ca718c8`.
The review follow-up below removes the window cap from plain scanning only.

Implemented `Policy.scanner = .scalar | .block`, scalar by default, with the
same compile-time/runtime selection model as DOT. The standalone strict cursor
also exposes `lexer.For(.block)`; `lexer.Lexer` keeps the scalar default.
This is not DOT HTML-token integration.

Both choices share one lexical state machine and the existing event-level grammar.
The block path vectorizes text, names (including named references), quoted values,
whitespace, comments and CDATA runs in windows of at most 64 bytes. A four-byte
scalar probe avoids vector overhead for short runs; longer runs reexamine that
fixed prefix. Vectors are target-width chunks with scalar tails, never padded
out-of-bounds loads. Numeric-reference accumulation and syntax boundaries use the
shared scalar transitions. No mask cache, token ring, source-sized index or extra
per-node metadata is introduced. This is deliberately smaller than copying DOT's
complete mask/state architecture into markup.

The scanner reports boolean readiness and keeps its result in scanner-owned
storage. Plain execution loops to the next token/finding, with tight scalar or
vector runs. Either metering or cancellation selects the bounded implementation:
scalar remains one-byte stepped; a block scan step covers at most a 64-byte
window, yielding after a nonempty run before handling its boundary. An immediate
boundary uses the scalar transition and may reread the first byte. Grammar events
and closing-name comparisons retain their existing charging. Frontiers account
for actual lookahead; partition invariance is guaranteed within each backend,
not equal credit counts between backends. Runtime selection happens at operation/
reset entry, never per byte.

Verification: 425 tests pass in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall,
plus all 13 compile-fail fixtures, examples, benchmark builds and consumed
RISC-V32/Wasm32 fixed/runtime profiles. Differential tests exercise every prefix,
raw random bytes, all byte predicates/vector lanes, shifted boundaries and tails,
all reference policies, fixed/runtime/plain/bounded/cancellable paths, reset,
cancellation, sink stopping, retained output and budget partitions.

Native retained/scratch layouts remain node 20 B, attribute 20 B, frame 12 B and
duplicate-key scratch 8 B. Scalar and block scanners have identical state sizes;
fixed plain sessions shrink 424 → 416 B, fixed metered remain 424 B, and runtime
sessions remain 480 B. Runtime-enabled code now includes the block specializations:
the unchanged original benchmark harness's executable `__text` increases
368,356 → 406,632 B (+38,276 B). These are whole-harness/host code sizes, not an
isolated fixed-profile library measurement.

The growth-memory observation is a separate concern. Zig 0.16's `ArrayList`
already attempts allocator remapping before allocating/copying/freeing a larger
pool. When remapping fails, old and new allocations temporarily coexist; capacity
slack and final in-place trimming also affect peak/final ratios. The supplied
21–47% figure was not independently reproduced here and is not a general bound.
This change does not alter growth or reduce its peak. Callers needing predictable
output allocation can already measure then supply exact fixed pools, paying for
two passes. An arena can retain abandoned growth allocations until arena teardown.
The suggested small-attribute duplicate-check fast path remains separate work;
validation behavior and its scratch contract are unchanged.

### Local performance measurements

Apple M4 Pro, Zig 0.16.0, ReleaseFast, decimal MB/s; baseline `30e8da7`.
Sources and output/scratch storage are prepared outside the timed region.
Each process reports the median of nine 16-parse batches after five warm-up
batches. Baseline below is the median of two isolated process results; the final
updated build is one process result. Both use the unchanged baseline benchmark
source. Preliminary runs and the initial block implementation are excluded.
These are local synthetic measurements, not platform-independent guarantees or
a reproduction of the externally supplied speedup ratios.

Plain fixed-profile scalar parsing, cells **milliseconds / MB/s**:

| Fixture | Before | After |
| --- | ---: | ---: |
| flat | 0.894 / 223.7 | 0.581 / 344.5 |
| mixed | 3.901 / 192.3 | 2.357 / 318.1 |
| text | 3.226 / 310.1 | 0.494 / 2023.1 |
| deep | 0.333 / 210.3 | 0.238 / 293.5 |
| attributes | 5.229 / 210.4 | 3.247 / 338.8 |
| duplicates | 5.255 / 209.4 | 3.244 / 339.1 |
| references | 8.028 / 211.8 | 3.801 / 447.2 |
| attribute_references | 7.954 / 226.3 | 4.029 / 446.8 |
| comments | 5.046 / 277.4 | 1.210 / 1157.2 |
| cdata | 5.807 / 266.9 | 1.532 / 1011.6 |

All 40 original parse measurements (10 fixtures × fixed/runtime-baseline/
runtime-override/count-only) improve in this run, with a 2.28× geometric
mean throughput ratio. This does not establish a before/after cancellable speedup:
the original harness did not time cancellation-enabled parsing.

The expanded current benchmark separately compares scalar and block in the same
executable (one process, same nine-batch method). Plain fixed-policy cells are
**milliseconds / MB/s**:

| Fixture | Scalar | Block | Throughput ratio |
| --- | ---: | ---: | ---: |
| flat | 0.576 / 347.3 | 0.660 / 303.1 | 0.87× |
| mixed | 2.298 / 326.4 | 2.658 / 282.1 | 0.86× |
| text | 0.467 / 2143.5 | 0.106 / 9456.5 | 4.41× |
| deep | 0.241 / 290.8 | 0.281 / 249.4 | 0.86× |
| attributes | 3.127 / 351.8 | 3.548 / 310.1 | 0.88× |
| duplicates | 3.098 / 355.0 | 3.482 / 315.9 | 0.89× |
| references | 3.761 / 452.0 | 4.166 / 408.1 | 0.90× |
| attribute_references | 3.907 / 460.7 | 4.194 / 429.2 | 0.93× |
| comments | 1.203 / 1163.4 | 1.113 / 1257.6 | 1.08× |
| cdata | 1.486 / 1042.8 | 1.433 / 1081.7 | 1.04× |
| prose | 1.106 / 1658.8 | 0.374 / 4911.8 | 2.96× |
| long_names | 0.236 / 2771.5 | 0.113 / 5800.9 | 2.09× |
| long_values | 1.096 / 1793.0 | 0.390 / 5041.4 | 2.81× |

The block backend gains most on long uninterrupted runs and remains slower on
dense short-tag/attribute inputs. That is why it is opt-in, not the new default.
For cancellation-enabled execution with a real polled hook, scalar → block
throughput was 318.3 → 8,074.2 MB/s on long text and 309.9 → 3,588.4 MB/s on prose,
but 208.0 → 177.9 MB/s on flat tags and 197.2 → 169.3 MB/s on short attributes.
Those compare the two new backends, not new versus old cancellable parsing.
No peak growable-heap/RSS, non-native execution performance, full DOT throughput
rerun, or small-attribute validation improvement is claimed.

## Scanner review follow-up — 2026-09-27

- Plain block scanning now continues through the full uninterrupted run. Only
  metered/cancellable block calls retain the 64-byte window cap. This removes
  periodic scalar state dispatch and repeated short probes on long plain runs.
  Token/finding boundaries and control-byte/reference checks are unchanged.
- In plain mode, when less than a native vector remains, the scalar tail starts
  after the successful short probe rather than checking those bytes twice. Bounded
  consumption/frontiers and work partitioning stay unchanged. Plain short source
  tails exit before the vector loop; plain scanning also checks its first vector before
  entering the long-run loop. These fast exits avoid the short-comment regression
  measured in the initial unbounded-loop implementation. The block tail and the
  scalar backend's original loop stay separate to preserve both fast paths.
  Bounded scanning retains its original probe/tail path, including possible
  repeated probe bytes. Extending the tail optimization to that path caused a
  repeatable roughly 9% long-text regression locally, so it is not included.
- Markup's private execution variants use DOT's three-bit layout (cancellation,
  metering, backend), with matching union order. Runtime dispatch still occurs
  only at operation/reset entry; fixed profiles remain specialized.
- Reset captures its active variant by pointer when retrieving caller memory.
  This removes the by-value capture; no claim is made that every optimized build
  previously emitted a physical whole-session copy.
- The shared BOM/CDATA marker counter is named `marker_index` and documents
  its mutually exclusive lifetimes and u3 range. No new state field is added.

The trusted-document contract is unchanged: arbitrary invalid leaf encodings,
spans or delimiters are not accepted via public-field construction. No fallback
silently changes an unknown kind into text. Lexical token kinds and retained
node kinds remain distinct concepts; their existing explicit mapping is retained.
Diagnostic bags also keep stop-at-capacity behavior. The warning example now
states its continuing-sink precondition, and an exact-one-warning test contrasts
fixed-stop, growable, discard and explicit omit destinations.

Tests additionally cover all 64 old/new runtime-variant reset pairs, memory reuse,
polling and metering selection, long runs across grammar contexts, and every
short-tail boundary for every run classifier in both execution modes.

Verification: 430/430 tests pass in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall.
Examples, benchmark compilation, all 13 expected compile failures, and the
RISC-V32/Wasm32 freestanding fixed/runtime probes pass. Formatting and diff checks
also pass. The default scalar loop remains local: extracting its tail into the
block helper added native induction instructions in a trial. The final scalar
`stepReady` instruction sequence matches the baseline apart from relocated
code/data addresses in the native benchmark binary. The cancellation-enabled
block scanner's instruction sequence is likewise preserved after excluding the
bounded-tail optimization.

Native sizes are unchanged: Node/Attribute 20 bytes each, validation key 8 bytes,
parser frame 12 bytes, Diagnostic 36 bytes; fixed/bounded/runtime sessions
416/424/480 bytes. No new buffers or allocation paths were added. The complete
comparison benchmark's `__text` section is 515,752 bytes versus 514,252 bytes
(+1,500 bytes, about 0.29%); this is not the size of a minimal consumer binary.
Peak growable allocation and process RSS were not measured by this follow-up.

### Follow-up measurements

Apple M4 Pro, Zig 0.16.0, ReleaseFast; baseline `ca718c8`. The same
13-fixture benchmark was built against both revisions, with only sampling reduced
to seven eight-parse batches after two warm-up batches. Each reported value is
the midpoint of two isolated process medians for that build; compilation did not
overlap timed runs. Rejected intermediate implementations are excluded.

Plain fixed-profile **block** parsing, cells **milliseconds / decimal MB/s**:

| Fixture | Before | After | Throughput change |
| --- | ---: | ---: | ---: |
| flat | 0.623 / 320.9 | 0.596 / 335.6 | +4.5% |
| mixed | 2.591 / 289.6 | 2.455 / 305.4 | +5.5% |
| text | 0.098 / 10207.4 | 0.080 / 12460.8 | +22.1% |
| deep | 0.268 / 262.0 | 0.253 / 276.7 | +5.6% |
| attributes | 3.500 / 314.3 | 3.369 / 326.6 | +3.9% |
| duplicates | 3.492 / 315.0 | 3.378 / 325.6 | +3.4% |
| references | 4.218 / 403.0 | 4.112 / 413.4 | +2.6% |
| attribute_references | 4.132 / 435.6 | 4.112 / 437.8 | +0.5% |
| comments | 1.128 / 1240.8 | 1.115 / 1254.8 | +1.1% |
| cdata | 1.450 / 1069.6 | 1.397 / 1109.8 | +3.8% |
| prose | 0.370 / 4956.4 | 0.281 / 6528.1 | +31.7% |
| long_names | 0.116 / 5674.6 | 0.093 / 7043.1 | +24.1% |
| long_values | 0.400 / 4915.1 | 0.304 / 6473.0 | +31.7% |

The geometric mean throughput gain across these 13 cases is 10.3%; the four
long-run cases improve 22–32%. Runtime-enabled baseline selection also retains
those long-run gains (15–35% across those four cases). Small positive changes
should not be read as universal or statistically established speedups. Bounded
block timings ranged from about -4.8% to +7.1% across fixtures; no bounded-path
speedup is claimed.

The broad harness's first scalar/flat case was unstable and reported an 11.1%
drop in this pair. A separate flat-only, warmed steady-state check used eight
64-parse warm-up batches followed by seven measured 64-parse batches, in
before/after/after/before order. Fixed scalar measured 363.3 -> 364.4 MB/s
(0.551 -> 0.549 ms); fixed block measured 322.0 -> 338.9 MB/s
(0.622 -> 0.590 ms). That check does not reproduce the apparent scalar regression.
It is a separate measurement, not a replacement inserted into the broad table.
These remain local synthetic observations, not a guarantee of end-to-end parity
on every input or target.

## Slice 4b verification and costs — 2026-09-27

Verification: **464/464 tests pass in Debug, ReleaseSafe, ReleaseFast and
ReleaseSmall**, including 75 standalone consumer tests. Examples, benchmark
compilation, 14 expected compile failures and consumed RISC-V32/Wasm32 fixed and
runtime probes pass. Coverage includes XML character-range boundaries, Unicode
names and invalid encodings, catalog case/context, literal malformed candidates,
all nine name/catalog severity combinations with encoding/duplicate findings,
source-order ties, fixed/runtime parity, scalar/block and bounded parse output,
allocation failure, capped/omitting/stopping sinks, and cancellation inside long
names/reference candidates. Seeded mixed-context tests exercise counts and order.

Native Node/Attribute/Diagnostic sizes remain 20/20/36 bytes. The nesting frame
stays 12 bytes, duplicate-key scratch 8 bytes per entry, ValidationResult 32 bytes,
and fixed/bounded/runtime sessions 416/424/480 bytes. New checks add no retained
pool, reference index or required scratch. Name/catalog-only validation succeeds
with a failing allocator. Optional diagnostic retention still has its own cost;
independent findings can overlap and consume the configured bag limit sooner.
Peak process RSS and growable allocator overhead were not measured in this slice.

Fixed policy selection is explicitly inlined so disabled passes are eliminated
during semantic analysis, not dependent on optimizer inlining heuristics. Binary
inspection confirms that fixed-disabled name/reference helpers are absent from
the comparison executable; runtime-selectable helpers remain. The same consumed
benchmark's native `__text` grows from 593,260 to 601,672 bytes (+8,412 bytes,
1.42%); this includes runtime validators and host/benchmark code, not the size
of a minimal fixed-profile consumer. Parser/scanner source is unchanged.

### Enabled-check measurements

Apple M4 Pro, Zig 0.16.0, ReleaseFast. `zig build bench-markup
-Doptimize=ReleaseFast -- --rules-only` times validation separately: parsing,
source/pool construction and scratch allocation are outside the timer. Five
warm-up batches precede nine measured batches of 16 validations; values are one
process's median. The discard sink counts findings without retaining them; these
are not full parse-plus-bag timings. Cells are **milliseconds / decimal MB/s**.

| Fixture / enabled checks | Source bytes | Fixed policy | Runtime policy | Scratch bytes / findings |
| --- | ---: | ---: | ---: | ---: |
| ASCII element/attribute names | 1,400,000 | 1.987 / 704.5 | 2.065 / 677.8 | 0 / 0 |
| Unicode element/attribute names | 1,100,000 | 1.395 / 788.3 | 1.554 / 708.0 | 0 / 0 |
| XML reference catalog | 1,250,000 | 1.382 / 904.8 | 1.456 / 858.3 | 0 / 100,000 |
| Names, catalog, UTF-8 and duplicates | 1,200,000 | 3.438 / 349.0 | 3.556 / 337.5 | 16 / 250,000 |
| Names enabled; plain text with no references | 1,750,000 | 0.028 / 62,922.5 | 0.025 / 69,216.5 | 0 / 0 |
| Names enabled; tolerated malformed candidates | 900,000 | 1.000 / 899.9 | 1.014 / 888.0 | 0 / 0 |

The prose case measures a warmed delimiter search with no names to decode, not
general Unicode validation throughput. Name checking still must search text/value
spans for reference names; disabling the catalog does not remove that scan. These
fixtures differ in shape and findings, so their throughput is not a direct
ASCII-versus-Unicode or fixed-versus-runtime universal cost ratio.

### Default-path comparison

Baseline `a897745` versus final 4b code, using the **same unchanged 13-fixture
benchmark source from the baseline** for both executables. Two isolated process
medians per build were collected in before/after/after/before order, with no
compilation overlapping timings. Each process uses five warm-up batches and nine
measured batches of 16 operations. Percentages below are geometric means of
per-fixture throughput ratios, using the midpoint of each build's two medians.
These local measurements are not an update to the standard-machine baseline.

| Parsing mode | Scalar throughput change | Block throughput change |
| --- | ---: | ---: |
| Fixed profile | +0.98% | -0.33% |
| Runtime enabled, compiled baseline selected | +1.43% | -0.78% |
| Runtime enabled, explicit standard-policy override | -0.39% | -0.68% |
| Count-only | -1.46% | -0.73% |
| Cancellable | +0.40% | +0.61% |

Representative cases and the larger losses are retained below rather than hidden
by the means. Cells are **milliseconds / decimal MB/s**, each the midpoint of the
two independently reported process medians (rounded latency is not used to
reconstruct throughput).

| Fixture / mode | Before | After | Throughput change |
| --- | ---: | ---: | ---: |
| flat / scalar fixed | 0.564 / 354.9 | 0.563 / 355.4 | +0.1% |
| mixed / scalar fixed | 2.327 / 322.4 | 2.296 / 326.7 | +1.3% |
| text / scalar fixed | 0.575 / 1773.2 | 0.477 / 2097.9 | +18.3% |
| attribute references / scalar fixed | 4.049 / 444.6 | 4.213 / 427.4 | -3.9% |
| flat / block fixed | 0.609 / 328.2 | 0.598 / 334.8 | +2.0% |
| text / block fixed | 0.080 / 12518.1 | 0.083 / 12126.3 | -3.1% |
| references / block runtime override | 4.117 / 413.0 | 4.324 / 393.2 | -4.8% |
| CDATA / scalar count-only | 1.463 / 1059.9 | 1.600 / 973.3 | -8.2% |
| prose / block count-only | 0.254 / 7238.8 | 0.282 / 6565.3 | -9.3% |

Default duplicate-only validation is near the baseline: unique-attribute input
829.4 -> 827.9 MB/s (1.326 -> 1.329 ms), duplicate input 1197.1 -> 1190.0 MB/s
(0.919 -> 0.924 ms), each with unchanged 24-byte scratch. Existing fixed UTF-8
checks became faster in these executables after exposing fixed settings during
semantic analysis: ASCII 2083.0 -> 4110.5 MB/s, Unicode 468.1 -> 876.6 MB/s and
invalid bytes 340.8 -> 790.3 MB/s. This is not a new UTF-8 algorithm or a universal
speedup guarantee; the same diagnostic counts and semantics are exercised.

An earlier development build, before explicit policy inlining, showed about 5%
scalar-runtime geometric-mean loss and a roughly 21% long-text loss in the broad
harness. A separate warmed parse-only consumer did not reproduce that large
loss (fixed long text about unchanged, runtime -2.6%); those trial measurements
are not substituted into the final table. The final scalar scanner has the same
1,233 instructions as the baseline after accounting for relocated code/data
addresses. The parser source was not changed to tune one executable's layout.
The variation of even the unchanged baseline and these fixture-level differences
preclude a universal zero-regression or parsing-speedup claim. Recheck actual
consumer binaries and representative inputs before drawing such a conclusion.

## Slice 4b review hardening — 2026-09-27

The review fixes retain the trusted-document boundary, not an arbitrary-pool
validation or legacy leaf representation:

- Name/reference walks assert consumed node metadata before `kind()` in safety
  builds, check attribute metadata even with duplicates off, and assert that the
  attribute cursor consumed the whole pool before claiming completion. Source and
  pool length assertions cover the enabled paths. Encoding-only validation still
  does not audit unused pools; all-off validation still does not inspect input.
- Cancellation uses a local u32 threshold every 64 scanned bytes, allowing at most
  three additional bytes to complete a scalar/reference delimiter. Long names and
  malformed reference candidates also poll; reference-free text uses bounded
  delimiter searches. Diagnostic stops remain immediate. This is cooperative
  validation, not a metered/sorting/allocator deadline guarantee.
- Shared inline `utf8.decode` returns scalar and length in one packed 4-byte
  temporary. `sequenceLength` wraps it for encoding-only consumers. Name and
  encoding checks no longer implement decoding independently. An intermediate
  non-inlined helper caused an out-of-line call and a large Unicode slowdown;
  ordinary padded returns also slowed name checking. Neither form was retained.
- Duplicate emission has one definition, preserving encoding-first ties, related
  spans, severity, factual totals and sink stops. The default attribute-only walk
  remains separate from the optional forest walk.
- `untrusted` budgets are an explicit compile-time field list checked against
  every policy limit. A temporary negative compilation adding a new limit without
  a budget fails with `untrusted preset needs an explicit budget for future_limit`.

Verification: **469/469 tests pass in Debug, ReleaseSafe, ReleaseFast and
ReleaseSmall**, including 78 standalone consumer tests. Five separate-process
assertion probes run in both safety modes: reordered attributes, short quoted
values, invalid leaf discriminator, out-of-bounds node span and orphan attribute.
They require rejection, not successful validation of corrupt metadata. Shared
decoder boundaries, chunk boundaries, long scans, sink stops and fixed/runtime
cancellation parity are covered. Examples, benchmark compilation, 14 expected
compile failures and consumed RISC-V32/Wasm32 probes pass.

Node/Attribute/Diagnostic remain 20/20/36 bytes; key scratch remains 8 bytes,
nesting frames 12 bytes, ValidationResult 32 bytes, and fixed/bounded/runtime
sessions 416/424/480 bytes. No retained allocation or scratch requirement is added.
Polling state is local to active validation scans, not stored per node or
reference. Peak process RSS and allocator overhead were not measured here.

### Review-fix measurements

Apple M4 Pro, Zig 0.16.0, ReleaseFast; baseline `9e94f92` versus the review fixes.
Both use the same extended `bench/markup.zig` with `--validation-only`. Compilation
finished before timings. Two isolated process medians per build, in
before/after/after/before order; each has five warm-up batches and nine measured
batches of 16 validations. Cells below are midpoints of the two reported medians,
**milliseconds / decimal MB/s**. Parsing, construction, allocation and diagnostic
retention are outside the timer. The observable callback increments a volatile
counter and never requests cancellation; an atomic/deadline callback may cost more.

All cancellation fixtures below are 100,000 source bytes: plain text for reference
and encoding checks, one long ASCII element name for name checking.

| Cancellable validation | Before | After | Calls before → after |
| --- | ---: | ---: | ---: |
| Reference scan / fixed | 0.0745 / 1351.4 | 0.0065 / 14866.4 | 100002 → 1565 |
| Reference scan / runtime | 0.0710 / 1407.4 | 0.0070 / 15140.1 | 100002 → 1565 |
| UTF-8 scan / fixed | 0.0930 / 1074.7 | 0.0720 / 1384.9 | 100001 → 1564 |
| UTF-8 scan / runtime | 0.1570 / 636.2 | 0.0340 / 2934.7 | 100001 → 1564 |
| Name scan / fixed | 0.2435 / 410.8 | 0.2250 / 444.7 | 99999 → 1565 |
| Name scan / runtime | 0.2415 / 414.2 | 0.2275 / 440.4 | 99999 → 1565 |

Callback counts fall about 64-fold. Throughput improves about 11×/10.8× for the
reference scan, 1.29×/4.61× for encoding, and 1.08×/1.06× for names (fixed/runtime).
These are validation-only synthetic observations, not parsing speedups or an
exact callback-count API. Name classification, and UTF-8 decoding on Unicode
input, still run; fewer callbacks do not imply a proportional total speedup.

Representative non-cancellable checks, including the larger losses, remain visible:

| Validation / policy | Before | After | Throughput change |
| --- | ---: | ---: | ---: |
| ASCII names / fixed | 1.9205 / 729.4 | 1.9355 / 723.5 | -0.8% |
| Unicode names / fixed | 1.3730 / 801.0 | 1.3385 / 821.8 | +2.6% |
| Unicode names / runtime | 1.4935 / 736.6 | 1.5210 / 723.3 | -1.8% |
| Unicode encoding / fixed | 0.6225 / 964.4 | 0.6230 / 963.1 | -0.1% |
| Unicode encoding / runtime | 0.6780 / 884.7 | 0.6780 / 884.9 | +0.0% |
| Encoding + duplicates / fixed | 1.3115 / 800.8 | 1.3385 / 784.6 | -2.0% |
| All checks / fixed | 3.1805 / 377.4 | 3.1950 / 375.6 | -0.5% |
| 100 KB plain reference-free search / fixed | 0.0010 / 71530.8 | 0.0015 / 67699.1 | -5.4% |

The last case is an approximately 1–2 microsecond warmed search, so coarse reported
latency and process variation matter. Across all 20 non-cancellable rules/encoding
rows in the harness, changes range from -2.0% to +4.5%; the smaller 100 KB search
probe is listed separately above. No universal zero-regression claim is made.

A separate DOT consumer checked the shared decoder with a single quoted node
containing 50,000 repetitions of ASCII `x`, `é東京😀`, or byte `FF`. It uses the same
alternating order, five warm-ups/nine measured batches, 32 validations per batch,
and no timed parsing. Unicode fixed throughput is 948.6 → 948.2 MB/s; runtime
943.8 → 948.4 MB/s. Invalid-byte fixed throughput is 354.3 → 359.0 MB/s; runtime
235.0 → 247.7 MB/s. The first ASCII after-process was unstable (2389.3 MB/s versus
4498.3 in the second; before 4404.0–4498.7), so it does not support a reliable ASCII
change estimate. These measurements do not update the standard-machine baselines
or substitute for end-to-end DOT/markup parsing benchmarks.
