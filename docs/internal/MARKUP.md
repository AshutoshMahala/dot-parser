# Standalone markup — structural slices

Decisions: 2026-09-26; slices 1–2 implemented 2026-09-27. Later slices below are plans, not
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
| 3 | References, comments and CDATA, including malformed-reference acceptance policy | Planned |
| 4 | Further optional checks and explicitly defined recovery | Planned |
| Integration | DOT opaque recognition followed by delayed integration; during-DOT composition later | Planned |

Each slice needs tests, truthful supported-syntax documentation and measurements.
Recognition of an excluded feature reports unsupported without validating its body.
No reserved public fields or pretend implementation of later checks are needed.

## Settled grammar direction

- Parse fragments: empty, text-only, multiple top-level elements and mixed content.
- Names are arbitrary vocabulary, matched byte-for-byte and case-sensitively.
  No implicit Unicode normalization, namespace resolution or HTML tag closing.
- Byte-oriented syntax with raw non-ASCII preservation, not full XML conformance.
  Optional encoding and stricter name checks are separate work.
- Attributes require quoted values (`'` or `"`); preserve spelling and order.
  Duplicate checking defaults to error, with warning/off choices; retain every
  occurrence. Off means uniqueness was not checked, not that it passed.
- Syntactically valid named references are preserved without requiring definitions
  in the structural grammar; known-reference checks are separate. No expansion.
- Malformed-reference acceptance is a syntax policy: reject by default; warn or
  silently accept by treating the offending `&` as literal text and resuming normal
  scanning. Never consume a subsequent `<` or closing attribute quote as reference
  content, invent a replacement value, or present tolerated input as XML-conformant.
  Exact recognition/diagnostic extents will be tested in slice 3.
- Comments and CDATA are planned. Processing instructions/declarations are
  deferred; no DTD processing, external entities, file/URL access or rendering.
- Preserve whitespace. Label-specific interpretation belongs to a later pass.
- Stop the fragment at an unrecoverable structural error; no guessed closing tags
  or published partial document. Independent fragments can still run. Validation
  findings continue where their own prerequisites remain available.

## Encoding boundary

The byte scanner expects ASCII-compatible syntax, naturally compatible with
UTF-8. UTF-8 validation is not implied by structural success. UTF-16/32 require
explicit caller-side conversion, and spans then index that converted buffer;
original-encoding mappings need a separate source map. No automatic transcoding.
Leading UTF-16/32 BOMs are detected as unsupported encoding, without promising
reliable identification of all incorrectly encoded or mixed-encoding bytes.

Slice 1's concrete lexical choices are:

- Name start: `[A-Za-z_:]` or any byte `0x80..0xFF`; continuation additionally
  permits `[0-9.-]`. Colons are raw name bytes, not namespace processing.
- Syntax whitespace: space, tab, CR, LF. Other bytes below `0x20`, including NUL,
  fail in the implemented grammar. Non-ASCII name/text bytes remain unchanged.
- A leading UTF-8 BOM is recognized and excluded from text, as in DOT; source
  offsets still include it. Elsewhere those bytes are ordinary content.
- Ordinary text is a nonempty run until `<` or `&`; it is not entity-decoded or
  subject to full XML character-data restrictions. In particular, this slice
  makes no claim to reject every XML-forbidden character-data sequence.

## Implemented architecture

`markup_parser` is a separate build module rooted at `src/markup.zig`.
Both parsers import one language-independent support module so applications can
use both without duplicating shared type identities. Shared location, reporting,
cancellation and WDP hashing do not depend on either grammar. Payloads/registries
remain processor-owned; the markup namespace is `markup_parser`.

The scalar scanner feeds one iterative event-level parser. Growable, fixed and
count-only consumers share that grammar. Events stay private/provisional, following
DOT's initial layering. Public retained data is a compact preorder forest: each
20-byte node holds a raw span, a name span (empty for text), and a subtree-end
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
duplicate-attribute validation severity, and execution choices (metering, cancellation). Limits/counts/ranges are u32; lengths
at the allocator/slice boundary use native sizes. Defaults preserve the existing
unlimited-within-representation convention. All typed combinations are meaningful,
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
the expected token is precisely `>`; `<!` already identifies an unsupported
declaration family, even without the next byte that distinguishes its subtype.
Neither recognition case validates the contents of an unsupported construct.

Metered fixed sessions charge source examinations, grammar transitions, each byte
of tag-name comparison, and individual event attempts. One credit suffices; zero
does no normal work. Cancellation is checked before each next microstep. Fixed
ordinary builds omit frontier/hook state when disabled. Callout time is excluded,
and allocator-backed operations are run-to-completion, not a bounded allocation
claim. Completed results are latched; abort occurs at most once after begin.

No Graphviz/extended validation, reference policy, UTF-8 validation,
markup fixes, additional scanner backend or processor scheduling is implemented
by this slice. See the [consumer guide](../MARKUP.md) for the actual API.

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
