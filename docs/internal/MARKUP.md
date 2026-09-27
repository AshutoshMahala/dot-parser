# Standalone markup — structural slices

Decisions: 2026-09-26; slice 1 implemented 2026-09-27. Later slices below are plans, not
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
| 2 | Quoted attributes, retained order/duplicates, independent duplicate checking | Planned |
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

`markup_parser` is a separate build module rooted at `src/markup/root.zig`.
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

The policy contains only implemented limits (source bytes, nodes, nesting) and
execution choices (metering, cancellation). Limits/counts/ranges are u32; lengths
at the allocator/slice boundary use native sizes. Defaults preserve the existing
unlimited-within-representation convention. All typed combinations are meaningful,
including zero limits, so `validatePolicy` currently returns `valid`; no invented
invalid combination or configuration error set is exposed. Fixed verification is
comptime-only. Runtime overrides are opt-in, resolve once, and inherit the compiled
baseline; no settings copies on nodes or per-byte override merging.

Metered fixed sessions charge source examinations, grammar transitions, each byte
of tag-name comparison, and individual event attempts. One credit suffices; zero
does no normal work. Cancellation is checked before each next microstep. Fixed
ordinary builds omit frontier/hook state when disabled. Callout time is excluded,
and allocator-backed operations are run-to-completion, not a bounded allocation
claim. Completed results are latched; abort occurs at most once after begin.

No Graphviz/extended validation, attribute/reference policy, UTF-8 validation,
markup fixes, additional scanner backend or processor scheduling is implemented
by this slice. See the [consumer guide](../MARKUP.md) for the actual API.

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
