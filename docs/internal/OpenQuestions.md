# Open design decisions

Last reconciled: 2026-10-03 (documentation consolidation; current policy, markup and one-shot composition delivery reconciled).

Split out of `REQUIREMENTS.md` §16 (2026-07-18). Question numbers (Q1–Q40)
are stable: they are never renumbered, deleted, or reused, and new questions
append with fresh numbers. Answered questions are not removed — the
**Decided** section doubles as the project's decision log, each entry naming
where the decision is embodied.

Status meanings:

- **Decided** — policy is settled; changing it is a deliberate reversal, not drift.
- **Partially decided** — a direction or first slice exists; the rest stays open.
- **Open** — genuinely undecided; usually gated on a future slice.

Policy status is separate from delivery status. Entries identify pending
implementation or verification explicitly; a decided policy does not claim
that every supporting feature or test already exists. Requirements describe
the intended contract, while [supported syntax](../SUPPORTED_SYNTAX.md) describes
the current development grammar. Release capabilities follow the versioned
documentation and changelog, not every implemented entry in this file.

---

## Current delivery and unfinished decisions

This table is a navigation aid, not a new feature commitment. Implemented means
the development tree, not necessarily release 0.3.0. No “in progress” status is
assigned merely because a topic has been discussed.

| Area | Implemented | Still undecided or undelivered |
| --- | --- | --- |
| Policies — Q35/Q36 | Typed baselines/overrides, verification, settings migration, initial lenient syntax and optional checks | Keyword-as-name contexts, optional deviation history, semantic rules and performance gates |
| Markup — Q40 | Structural parsing/checks/recovery, local scopes, passthrough IDs | Graphviz/extended rules, dialect grammar, catalogs, summaries and partial-tree design |
| Processors — Q40 | Custom compile-time bindings, nested policy preparation, delayed/one-shot integration and workspace reuse | Recursive/string execution, fixed/resumable composition and broader profile API |
| Execution — Q27 | Fixed bounded parsing, cancellation; markup validation cancellation | Metered/resumable validation, DOT validation cancellation, shared budgets and chunked input |
| Encoding — Q23 | Raw bytes, optional UTF-8 and byte-coordinate diagnostics | UTF-16/32 conversion, provenance/mapping APIs |
| Graph layer — Q5/Q17/Q35 | Source-shaped syntax for downstream consumers | Semantic lowering, consumer adapters and marshal/unmarshal |
| Footprint/release — Q7/Q14/Q15/Q16/Q24/Q40 | Fixed storage and compile-time specialization | Board budgets, broader grammar exclusion, acceptance thresholds, stability and markup versioning |

Decision status and delivery status remain separate. Preserve question IDs and
settled rationale; the historical reconciliation log records old checkpoints,
not the current backlog. Current user contracts are in the public guides;
unfinished markup detail remains in [MARKUP.md](MARKUP.md) and
[PROCESSOR_CONTRACT.md](PROCESSOR_CONTRACT.md).

## Decided

**Q39 — Are line and column tracked while scanning, or derived on demand?**
**Decided (2026-09-18):** derived. Every position the library stores is a
`Span` — byte offset and length, eight bytes, the same type as the retained
records' `Range` — in tokens, events, scratch frames and diagnostics alike;
`location.locate` / `Span.locate` derive line and byte column from the
source for one position and `PositionCursor` for many (queries in any
order, one shared scan when they ascend), and the renderers do so when
given the source, printing offsets otherwise. Measured on Apple silicon:
`Span` 16 → 8 B, token 20 → 12 B, `Diagnostic` 112 → 80 B, nesting frame
164 → 116 B, scalar scanner 104 → 56 B, block scanner 208 → 160 B, parser
state 544 → 368 B (scalar) and 648 → 472 B (block), fixed session 1264 →
1080 B; the 200k-statement bench 275 → 336 MiB/s default and 326 → 397
hinted with the scalar scanner (the per-byte tracker was a fifth of its
lexing time), the corpus files 3–33% faster, the empty-subgraph fixtures
21–26% faster; the block scanner gains 2–20%.
No numeric accounting changes. *(Embodied: `src/common/location.zig`,
`src/dot/lexer/`, `src/dot/console.zig` `Positions`; R-MEM-008 and R-DIAG-001
amended.)*

**Presentation refinement (2026-09-29):** optional shared console rendering now
shows printable UTF-8 in Unicode style and uses bounded byte-to-display-cell maps
for annotations. ASCII style retains byte escapes; controls and invalid encoding
remain escaped in both. Locations/fix spans still use original byte coordinates.
Tabs use eight-cell excerpt-local stops; scalar widths use pinned Unicode 17.0
tables, not grapheme shaping. The maps consume 260 bytes of presentation scratch,
not parser state. Compact output includes the caller's source name for clickable
locations. See [the rendering contract](../ERRORS.md#printing-diagnostics).

**Q38 — Which scanner backend is the default, and how is a backend chosen?**
**Decided (2026-09-18):** two implementations behind one interface, selected
at compile time: the scalar byte-at-a-time scanner on every target, with
the block scanner (64-byte vector classification into bit masks, tokens
extracted from the masks, backslash parity carried across blocks) opt-in
originally through a root file's `dot_parser_options.lexer_backend` (superseded
by the policy extension below). Evidence at the
parse level on Apple silicon, with positions derived on demand (Q39):
running to completion the scalar scanner is 3–15% faster on every corpus
file and on the 200k-statement bench (336 vs 292 MiB/s), and faster at 256
credits per call; the block scanner wins only at very small budgets (2–4x
at one credit per call, needing 2–6x fewer credits for the same input) and
on long runs of one byte class (2x on the long-identifier fixture). Costs
of block: 160 B of scanner state against 56 B (each machine and session
+104 B); code 6–8 KB larger per native build and 9 KB on wasm32 with
simd128; without a vector unit its compares lower to byte loops, 1.9x
slower than scalar on wasm32 under V8 and 27 KB (wasm32) to 52 KB
(riscv32) larger. An earlier measurement, before Q39 removed the per-byte
tracker, had block ahead on comment-heavy and nested inputs and on every
bounded session; the tracker was most of that gap. The scalar scanner is
also the differential oracle: the equivalence tests in `src/dot/lexer/lexer.zig`
(fixtures, truncations, block shifts, random streams with 64- and 32-bit
draws, budget partitions) found two block-scanner bugs before release, and
the whole suite runs on wasm32 with and without simd128 under Node's WASI.
The execution contract accounts credits per backend. *(Embodied:
`src/dot/lexer/`; R-MOD-010, Q16, Q27.)*

**Configuration extension implemented (2026-09-20):** Q35 puts scanner selection
in `Policy.scanner` with compile-time/runtime parity. Fixed-only profiles can
exclude the other backend; runtime-selectable profiles retain both and select
at operation/session initialization. The root-file override is removed; direct
lexical callers use `lexer.For(backend)`. Scalar remains the default. The
measurements above predate this migration; the new policy-path performance
comparison still needs the standard benchmark machine.

**Q34 — How are subgraph edge endpoints retained without inflating ordinary edges?**
Use separate generalized owner/link pools and a uniform public `Endpoint`
(node reference or scope occurrence) / `EdgeView`. Node-only records retain their
sizes. Promote a node-only prefix by range, never by copying. Preserve one edge
statement owner, all endpoint scopes and their body statements, without expanding
node membership or edge products. Generalized links use indices so nested owners
can interleave; global edges/validation merge operators in lexical order.
Statement traversal is owner-first. Endpoint scopes have no extra statement entry.

Explicit frames preserve suspended outer-edge state (164 native bytes/level
with 32-bit positions; 272 before).
Scope records add a descendant-scope boundary (36 native bytes). Scope enter/exit
and standalone completion are separately charged; endpoint scopes count toward
nesting/pool capacity, not an extra `max_statements` item. No separate total-scope
policy is introduced: fixed pool capacity bounds retained occurrences, and work
budgets/cancellation bound execution. Allocator hints are not hard limits.
Semantic membership, repeated-name resolution and expansion remain deferred.
*(Embodied: `src/dot/parser.zig`, `src/dot/syntax.zig`, `src/dot/scratch.zig`,
`tests/subgraph_endpoints.zig`, `docs/READING_DOCUMENTS.md`.)*

**Q33 — How are standalone subgraphs represented, traversed and bounded?**
Use document-local occurrence `ScopeId`s (root 0), optional raw names and a
compact record with parent, body interval and source range (extended by Q34). Named/anonymous use
identical IDs; repeated names are not merged. Keep one global preorder statement
stream, including scope owners; borrowed scope views expose direct/recursive
statements, child scopes, pairwise edges and written node references. No repeated
ancestor membership lists, per-node scope tags, semantic defaults or clusters.
Parsing/traversal are iterative. Entry/exit events are separately charged; completed
statement progress is disambiguated after exit (Q34), while `max_statements`
reserves the potential owner at entry.
Temporary nesting frames are explicit, reused for siblings and separate from
retained output through `ParseMemory`; allocator callers may separate scratch
allocator lifetime. `max_nesting` counts depth below root; no separate max-subgraphs
policy is introduced; endpoint occurrences now rely on scope-pool capacity (Q34). Cycle detection is not a
syntax-parser responsibility. Endpoint syntax is implemented by Q34; resolved
membership remains deferred. *(Embodied: `src/dot/syntax.zig`, `src/dot/scratch.zig`, `src/dot/parser.zig`,
`tests/subgraphs.zig`, `docs/READING_DOCUMENTS.md`.)*

**Q32 — How are ports retained without inflating every node reference?**
Use an 8-byte inline-or-pooled `NodeReference`. Bare references hold a source
range; qualified occurrences index a 28-byte pool record containing the base ID
and raw first/optional second suffix IDs. A checked accessor returns that view.
No offset bits are stolen: zero raw length tags the pooled form, while even an
empty quoted ID has nonzero raw length. Pool entries are source occurrences,
not interned nodes, unique ports, declarations or resolved attachments. Chain
middles share their one occurrence through incoming/outgoing pairwise views.
All supported ID spellings work in suffixes; unknown compass-like IDs are
retained. No `a:n` ambiguity resolution, implicit ports, label parsing, defaults
or reverse indexes belong in this slice. Each completed suffix has one charged
private callback returning its pool handle; fixed/hinted capacities include the
new pool, with normal abort/reset ownership. The 50% qualification break-even
versus 12-byte references plus 20-byte suffix records concerns payloads only;
fixed metadata and reserved capacities still cost memory. *(Embodied:
`src/dot/syntax.zig`, `src/dot/parser.zig`, `tests/ports.zig`, `examples/ports.zig`.)*

**Q31 — How are identifier-only edge chains retained and budgeted?**
Keep ordinary edge records unchanged. A separate chain owner contains the first
edge and a compact range into continuation links. Each continuation retains its
written operator/range and right endpoint; no temporary chain list or eager
edge/node expansion is built. Whole-chain attributes are stored once. Each link
callback is a separately charged event; one accepted owner increments completed
statements once. The public allocation-free edge iterator offers a pairwise view
without changing retained syntax. Fixed capacities bound chain owners and
continuations independently; statement limits do not bound chain length.
Subgraph endpoints are covered by Q34; ports are covered by Q32. *(Embodied: `src/dot/syntax.zig`,
`src/dot/parser.zig`, `tests/edge_chains.zig`, `tests/sessions.zig`.)*

**Q30 — How does the first attribute slice retain groups and deliver pairs?**
Adjacent bracket groups are flattened into one ordered pair sequence, preserving
written duplicate keys but not group boundaries or empty-list presence. Node,
edge and attribute statements reference a shared pair pool; assignments have a
separate pool. The private event seam streams pairs before their owner statement;
abort discards staged data and no partial document escapes. Both storage paths
have explicit capacities for all attribute-slice pools (six at that slice;
eight after Q31's chain support; nine with Q32; ten with Q33). `max_attributes` counts all pairs,
including assignments, but does not bound lexical work. Defaults, effective-value
resolution and compile-time feature removal remain future work. *(Embodied:
`src/dot/parser.zig`, `src/dot/syntax_event.zig`, `src/dot/syntax.zig`, `tests/attributes.zig`.)*

**Q2 — Is the primary public result a syntax AST, an event stream, or equal
support for both?**
Both, layered: the borrowed `Document` is the public result; the syntax-event
stream is the internal seam between parser and builders, kept private until at
least two vertical slices exercise it. *(Embodied: `src/root.zig` façade,
`src/dot/syntax_event.zig`.)*

**Q3 — Must the AST preserve comments, exact quoting, whitespace, and
separators for lossless source reproduction?**
Not in version 1. Trivia and source preservation are the slice-7 tooling
representation; compact ranges keep the door open without paying for it now.
*(Embodied: `location.Range` design; non-goals §14.)*

**Q4 — Does validation reject a mismatched edge operator immediately, or may
a tolerant parsing mode retain it and report a diagnostic?**
Tolerant by design: the parser is kind-agnostic (both operators always parse,
the written operator is preserved), and the kind×operator legality rule lives
solely in validation, which reports independent mismatches in source order
under the selected error policy and operational limits. Sink filtering changes
reporting, not `document_valid`. Consumers may
parse without validation or select independent graph/operator validation and
interpretation policies through `Profile` (Q35). *(Embodied: `src/dot/parser.zig`,
`src/dot/validate.zig`, `src/dot/policy.zig`, corpus.)*

**Q5 — Is semantic resolution part of this package or a sibling package?**
This package, as a separate optional layer (`DotIR` + explicit lowering
passes) — never inside the parser core. *(Embodied: architecture layering;
roadmap slice 7.)*

**Q6 — Which input modes are required initially?**
A contiguous borrowed byte slice. Chunked and random-access sources remain
later policy axes per R-MOD-009. *(Embodied: `parseBorrowed`/`parseBorrowedIn`
signatures.)*

**Q8 — Which implementation language and minimum toolchain version?**
Zig, minimum 0.16.0. *(Embodied: `build.zig.zon`.)*

**Q9 — Is serialization required in version 1?**
No. *(Embodied: non-goals §14.)*

**Q10 — What compatibility baseline defines correct behavior?**
The written DOT specification is primary; Graphviz 16.0.0 is the pinned
differential reference (reconciled 2026-09-18 from 15.1.0: the 16.0.0
`lib/cgraph/grammar.y` and `scan.l` carry the same rules every compatibility
note relies on, and the identifier/attribute probes of 2026-09-12 already ran
on 16.0.0), not an instruction to reproduce every implementation quirk.
Intentional differences are listed in
[supported syntax](../SUPPORTED_SYNTAX.md), including standalone-CR comment
termination and whole-document consumption. Keywords, numeral IDs, quoted
IDs, non-ASCII bare IDs and basic attributes are implemented.
**Implemented compatibility exception:** Q40 accepts concatenation with
HTML-like operands to match the pinned Graphviz implementation, beyond the
written specification's double-quoted-string concatenation rule. This explicit
exception does not imply specialized Graphviz label validation or a general
preference for implementation quirks over the specification.
**Verification pending:** automate the differential harness against the
pinned reference and record exceptions explicitly; notes first verified by
running 15.1.0 keep that attribution until the harness re-runs them.
*(Embodied: `src/dot/lexer/`, compatibility notes, corpus; R-ROB-004.)*

**Q13 — What language-specific policy governs raw pointers, unchecked
blocks, integer casts, and dependency review?**
Use checked input-derived bounds and narrowing; isolate low-level operations
and document the invariants that make them safe. Callback context pointer casts
are permitted with explicit type, alignment, and lifetime contracts. Assertions
may enforce internal or documented caller preconditions, but malformed source
must produce a bounded failure rather than a trap. Disabling runtime safety
requires a local justification and direct tests. Dependencies require review
of safety, allocation/platform costs, and licensing before introduction; the
package currently has none. **Verification pending:** a dedicated audit of all
low-level sites; this policy is not a claim that such an audit has occurred.
*(Policy: R-SEC-004/R-SEC-006 and §17; existing seams: diagnostic sink context
casts and checked retained-range/index conversions.)*

**Q19 — Does version 1 support parsing independently supplied fragments?**
No — whole documents only. R-MEM-007's merge semantics remain the contract
for whenever fragments arrive. *(Embodied: façade surface.)*

**Q20 — Which WDP component, primary namespaces, sequence ranges, and catalog
conformance level will the project publish?**
Namespace `dot_parser` (WDP part 7, fully qualified compact IDs
`nshash-codehash`); components are logical domains (`Syntax`, `Validation`,
`Resource`, `Profile`) — revised 2026-09-18 from internal module names, which
had split one user-visible kind of problem across `Lexer`/`Parser` and tied
identities to the file layout; primaries name the failure domain (`Byte`,
`Operator`, `Numeral`, `Token`, `Concatenation`, `Grammar`, `Keyword`,
`Capacity`, `Memory`, `Feature`); sequences follow the part 6 conventions
(001 MISSING, 002 MISMATCH, 003 INVALID, 009 UNSUPPORTED, 026 EXHAUSTED,
031+ project-specific: 031 UNEXPECTED_END, 032 UNTERMINATED, 033 AMBIGUOUS). Sequence numbers and aliases are defined together in
`diagnostic.Sequence`; numbers may recur across diagnostic domains. Registry
uniqueness, format validity, and compact-ID collisions are test-enforced;
compact-ID generation is also checked against the official WDP test vectors.
*(Embodied: `src/dot/diagnostic.zig`; R-DIAG-001 as amended.)*

**Q21 — Are any analysis passes worth an optional parallel implementation?**
Not now. Concurrency stays external to the core (R-ARCH-008/R-CON-004);
revisit only after profiling demonstrates value. *(Embodied: no threading
anywhere; frozen documents are share-safe per R-CON-003.)*

**Q25 — What exact deterministic ordering is promised?**
For the current public API, statements and per-kind pools preserve source
order, and diagnostics follow deterministic phase/emission order. DOT validation
merges findings in source order; composed and markup source-validation phases
do not promise a global source sort (Q40). Repeated
runs with the same input and configuration promise semantic equality, not
literal byte identity of whole structs (padding is not part of the contract).
Existing tests and fuzz checks cover outcome classes, statement order and
pools including borrowed ranges, and diagnostic codes, positions, and feature
payloads. New public payloads must extend that coverage as they arrive.
Future merged-fragment, `DotIR`, and serialized-output APIs must define their
own ordering before publication; their absence does not leave the current
contract undecided. *(Embodied: `src/dot/syntax.zig`, `src/dot/validate.zig`,
validation/corpus/fuzz determinism tests; R-PORT-005/R-CON-005.)*

**Q29 — Which sinks require transactional staging, and is a standard staging
sink worth its memory and binary cost?**
A sink requiring atomic externally visible output owns staging or rollback.
The parser provides completion/abort lifecycle signals, not rollback of
arbitrary side effects. Header failures may emit no syntax events; after a
begin attempt, the documented cleanup/terminal rules apply. Completion means
complete syntax parsing, not semantic validity: consumers requiring validated
output must also stage through validation. No reusable staging helper will be
added until a concrete consumer demonstrates its need and cost; reconsider
that helper separately from the settled ownership boundary.
*(Embodied: `src/dot/syntax_event.zig`, builder abort paths; R-MOD-011.)*

**Q37 — How are fix suggestions carried on diagnostics for linters?**
**DOT implemented; reconciled 2026-09-22:** `Diagnostic.fix: ?Fix` carries an
original-source span, typed edit (`delete`, `replace`, `insert_before`,
`insert_after`, `wrap_in_quotes`), replacement identity and applicability.
`Replacement.text()` supplies the known replacement bytes; producers do not
allocate replacement strings or automatically apply edits. Source positions are
byte ranges; line and column are derived on demand (Q39).

The scanner/parser produce syntax repairs, and accepted lenient deviations
produce fixes under the selected interpretation (Q36). Operator-mismatch fixes
are `machine_applicable` under `.conform_to_kind` and `maybe` under
`.as_written`: a chosen deterministic repair is not proof of author intent.
Native Zig 0.16.0 measurements record an 80-byte `Diagnostic`, including the
optional fix; this is a layout observation, not an ABI promise. A future lean
diagnostics profile that omits fixes is a separate optional-cost decision,
not unfinished implementation of `Diagnostic.fix`.

**Markup/shared conventions implemented 2026-09-29:** both processors use
`reporting.Fix(Replacement)` and the same applicability/filtering semantics.
Markup keeps `Diagnostic.fix: ?Repair` compact and exposes `suggestedFix()` to
materialize the source edit on demand. The missing-reference-semicolon offer is
always `maybe` and only offered for terminable candidates: the scanner's existing
numeric value must satisfy the reference-character rule. `.diagnostics.fixes`
controls it at either binding time. Markup diagnostics remain 36 bytes.
Rich catalogs/presentation do not require matching
retained payload layouts or guessed tag/attribute repairs.
*(Embodied: [diagnostic types](../../src/dot/diagnostic.zig),
[operator checks](../../src/dot/validation_checks.zig),
[repair tests](../../tests/diagnostics.zig),
[policy tests](../../tests/policies.zig), [lenient tests](../../tests/lenient.zig);
R-DX-007, R-FUNC-005.)*

---

## Partially decided

**Q35 — Which validation policy does the library expose, and how are mixed
graphs represented?**
**Initial policy implementation complete; reconciled 2026-09-22.** The typed
policy core, graph/operator slice, existing-settings migration, Q36's initial
syntax rules and the additional configurable checks are implemented. Follow-up
designs and the standard-machine performance gate below remain open; this does
not mean every future validation or graph-building rule is implemented.

**Coverage reconciled 2026-09-27 (initial core at `3e1796b`, plus passthrough DOT slice):**

| Area | Implemented contract | Stage / evidence |
| --- | --- | --- |
| Typed configuration | `Profile`, one `Policy` schema, per-leaf inheritance, consumer baselines, default-off runtime overrides, `validatePolicy` | Configuration preflight; `src/dot/policy.zig`, `src/dot/profile.zig`, `tests/compile_fail/` |
| Graph meaning and operators | Separate `validation.graph` / `digraph`, all four graph treatments, mismatch severity, source-preserving effective conformance | Validation / interpretation; `tests/policies.zig` |
| Existing settings | Nesting/statement/attribute limits, recovery, scanner, independent metering/cancellation | Parse, measure and policy-bound sessions; `tests/policy_settings.zig` |
| Initial lenient syntax | Empty statements, exact `---`/`-->`, bare `-` from the written header; independent reject/warn/accept choices | Parsing; `tests/lenient.zig` |
| Numeral ambiguity | `validation.ambiguous_numeral`: error/warning/off, default warning; tokenization is unchanged | Parsing, not a later validation replay; `tests/validation_checks.zig` |
| Optional checks | Whole-source UTF-8, repeated attribute keys, effective graph-kind restrictions, qualified node references and subgraph occurrences | Post-parse validation; default off; `tests/validation_checks.zig` |
| Presets and factual results | Complete `standard` / `lenient` policies; deviations and warning counts survive suppression/failure; no hidden history | Q36 and the [public contract](../POLICIES.md) |
| Diagnostics and fixes | Typed policy-aware findings; `diagnostics.fixes = all / machine_applicable / off` filters all DOT offers at either binding time without changing validity or delivery | Q37; `tests/diagnostics.zig`, `tests/html_identifiers.zig` |
| HTML-like identifiers and processing selection | `markup = none / passthrough / process`; passthrough without a bound child, process with one; raw operands and explicit decoding | Parsing; `tests/html_identifiers.zig`, `tests/during_dot.zig` |

All implemented policy leaves have compile-time/runtime parity. The runtime
support switch is a compile-time capability, not an overridable leaf. Nesting
limits and active/recovery depth counters use `u32`, bounded by the source domain.
Statement/attribute limits remain `usize`; source spans/indices are u32.
Parse deviation/warning counters are u32; validation findings and composed
warning totals are u64 because independent rules can overlap on one source byte.
Sources, pools, allocators, scratch and callback contexts remain resources, not
a second settings system. The table identifies existing coverage, not a claim
that tests or benchmarks were rerun for this documentation reconciliation.

**Remaining work:** keyword-as-name acceptance, optional deviation history,
specialized Graphviz/extended rules, metered validation, DOT validation
cancellation, live auto-promotion events, graph-construction adapters and semantic
checks/conversion. Structural markup, markup validation cancellation and custom
content-processor binding are implemented (Q40). Required
attributes, value schemas, cycles, connectivity, degree limits, explicit-node
requirements and referenced-port resolution need separately designed optional
passes; the syntax restrictions above do not provide them. Mandatory safety,
resource enforcement and truthful completion/delivery never become optional.

**Configuration contract.** Use one typed policy model for behavioral settings,
not an all-boolean feature mask, string-keyed map or a second lenient parser.
The library supplies strict defaults, and consumers may define their own
compile-time baseline using supported rules. Ordinary built-in settings do not
require custom rule implementations or trait machinery.

- A separate compile-time switch enables runtime overrides and is **off by
  default**. With it disabled, override fields are absent from operation options
  and passing them is a compile error, not a silently ignored request.
- **Every supported policy field has the same allowed values and semantics at
  compile time and runtime.** This supersedes a selected runtime-overridable
  subset. The runtime-support switch itself is a compile-time build choice; a
  running binary cannot enable machinery that was not compiled in.
- Runtime overrides are partial per-operation patches. Omitted fields, including
  nested siblings, inherit the consumer's compiled baseline, not fresh library
  defaults. No override means the compiled baseline. Optional typed fields with
  `null` meaning inherit are implemented; the experimental API can still change.
- Resolve the effective policy once at operation/session initialization. Settings
  stay fixed across yields and may change on reset; no mutable global policy or
  leakage between operations. Each stage consumes the settings it needs.
- All behavioral settings, including syntax acceptance, validation, recovery,
  limits, execution and scanner selection, belong to this model. Source bytes,
  allocators, actual storage and callback contexts remain explicit resources.
  A configured limit does not supply memory or disable capacity checks.

| Decision | Typed representation | Example |
| --- | --- | --- |
| Include runtime-policy machinery | Compile-time boolean, default off | Runtime override support |
| Accept a syntax deviation | Enum | Reject, accept with warning, accept silently |
| Validation severity | Enum | Error, warning, off |
| Interpretation/strategy | Enum | Graph meaning, operator reading, recovery, scanner backend |
| Work/resource limit | Integer | Maximum nesting, statements or attributes |

Do not add redundant enable flags for a rule whose policy already selects its
behavior. Fixed policies should specialize code, not be copied into runtime
state. Full-runtime profiles must retain every implementation reachable through
their policy values (both scanner backends, for example). They cannot also claim
those alternatives were compiled out. Fixed-only profiles retain the exclusion
opportunity; no equivalent binary/state-size claim is made for runtime profiles.
This updates the older compile-time-only scanner choice and restricted-runtime
markup configuration direction (Q38/Q40).

**Efficiency and invariants.** No hidden allocations, generic policy interpreter,
per-token override merging, per-node/edge policy storage or repeated large policy
copies. Retain only stage-relevant effective values. Resolving once removes
repeated merging, not necessarily runtime branches. Measure binary size,
throughput, parser/session state, scratch and retained memory separately on the
standard benchmark machine, comparing fixed, runtime-without-override and
runtime-with-override paths under equivalent policies. Secondary-host numbers do
not replace that baseline. Architectural neatness does not excuse performance or
memory regressions. Bounds/overflow/storage safety, truthful completion and
exhaustion, and the distinction between validity and diagnostic delivery cannot
be disabled by policy.

**Graph policy shape and vocabulary (revised 2026-09-20).** Separate
`.validation.graph` and `.validation.digraph` settings are selected by the
**written DOT header**, not the effective kind. Both branches can be configured
in the same profile, independently. These outer keys deliberately match DOT;
the `graph` key does not itself mean generic treatment.

| Name | Meaning |
| --- | --- |
| `.validation.graph` | Settings for a source document declared with `graph` |
| `.validation.digraph` | Settings for a source document declared with `digraph` |
| `GraphKind` | Effective kind: `.undigraph`, `.digraph`, `.generic` |
| `GraphTreatment` | Selection for `graph.treated_as`: the three graph kinds, plus `.auto` behavior |
| `.directed`, `.undirected` | Edge/operator vocabulary, not graph-kind policy values |

The selected names and shape are:

```zig
pub const GraphKind = enum { undigraph, digraph, generic };
pub const GraphTreatment = enum { undigraph, digraph, generic, auto };

.validation = .{
    .graph = .{
        .treated_as = .undigraph,
        .operator_mismatch = .warning,
        .operator_reading = .as_written,
    },
    .digraph = .{
        .operator_mismatch = .warning,
        .operator_reading = .as_written,
    },
},
```

This shape is implemented by `Policy.Validation`. A treatment needs
its own type because `.auto` is **not** a `GraphKind`. `digraph` has no
`treated_as` setting: its effective kind is always `.digraph`. The default
`graph.treated_as` is `.undigraph`. For either concrete kind, mismatch severity
defaults to `.err` (`.warning` and `.off` are alternatives), and operator reading
defaults to `.as_written` (`.conform_to_kind` is the alternative). The example
opts into warnings; it does not change library defaults.

| Written header | Treatment | Effective kind | Operator policy |
| --- | --- | --- | --- |
| `graph` | `.undigraph` | Always `.undigraph` | Its `graph` settings govern `->` mismatches |
| `graph` | `.digraph` | Always `.digraph` | Its `graph` settings govern `--` mismatches; do not switch to the `digraph` settings |
| `graph` | `.generic` | Always `.generic`, even when empty | Both ordinary operators are preserved; no kind mismatch |
| `graph` | `.auto` | `.undigraph` until the first directed operator, then `.generic` | Both ordinary operators preserved; promotion is not a mismatch |
| `digraph` | No setting | Always `.digraph` | Its independent `digraph` settings govern `--` mismatches |

**Auto is treatment, not a fourth kind.** It starts as `.undigraph`; the first
accepted syntax operator `->` promotes the effective kind to `.generic`, never
back again and never to `.digraph`. Empty and `--`-only graphs stay `.undigraph`;
even a graph containing only `->` becomes `.generic`. Operators in chains,
nested subgraphs and endpoint scopes participate. Detection follows syntax
normalization, before effective operator interpretation: an accepted `-->`
supplies `->` and promotes; a bare dash interpreted `.from_keyword` in a written
`graph` supplies `--` and does not. Do not infer a majority or rewrite earlier
edges. For streaming consumers the kind is provisional until completion; the
source declaration never changes. In the first implementation, a document-bound
interpretation scans syntax edges once, stopping at the first directed edge;
subsequent queries are O(1). No fields are added to retained documents or edges.
Live-session provisional-kind/promotion notifications remain future work.
The policy itself remains `.auto` across yields; only the input-derived kind
changes. Each new document/reset starts again at `.undigraph`. Even a fixed
compile-time `.auto` policy must observe runtime input; this is graph-treatment
work, not runtime policy overriding or verification.

In `.generic` and `.auto`, neither `operator_reading` nor `operator_mismatch`
has an applicable role: ordinary operators are preserved and promotion accepts
`->`. These modes should not offer effective mismatch/conformance settings.
**Provisional implementation rule, awaiting confirmation:** explicitly supplying
either operator field when the resolved treatment is `.generic`/`.auto` is a
configuration error, including explicit default values. Inherited concrete
values remain dormant, and selecting a concrete treatment uses them again unless
replaced. A mode change never resets sibling leaves. The checker receives both
resolved settings and the input's explicit-field presence. This makes invalid
requests observable without making a treatment-only override invalid merely
because concrete defaults were inherited. This rule was surfaced during
implementation; it is not recorded as a user-approved final decision.
Changing a `graph` treatment must never change the independent `digraph` branch.

**Conformance targets the effective kind.** `.conform_to_kind` replaces the
earlier `.as_declared` name: a written `graph` can now be treated as `.digraph`,
so the source header is not necessarily the conformance target. `.as_written`
preserves the operator; `.conform_to_kind` supplies the operator required by the
effective `.undigraph` or `.digraph` without overwriting retained syntax/ranges.
Conforming `a -- b` to `.digraph` means `a -> b` in written left-to-right order,
not two opposing edges. Conforming `->` to `.undigraph` drops direction only in
the effective view. `.err` still invalidates a mismatched document even if a
conforming view is available; changing severity never silently converts an edge.
`.off` selects explicit silence. Source rewriting/materializing a converted
graph remains a separate transformation/lowering/export operation.

Bare-dash `.from_keyword` deliberately remains different: it follows the written
header (`graph` -> `--`, `digraph` -> `->`), regardless of `treated_as` (Q36).

Declaration, effective kind and observed usage remain distinct. **Generic is a
graph kind; mixed is an observation of both operator kinds.** Explicit generic
treatment stays generic regardless of usage; auto selects between `.undigraph`
and `.generic`. Ordinary acceptance under a concrete treatment does not reclassify
the graph. There is no new DOT source keyword, and no inferred `.auto` kind in
results. These treatments are library dialect behavior, not a claim of standard
Graphviz compatibility. Source fidelity and kind-agnostic parsing remain binding.

**Implementation status:** `src/dot/policy.zig` and `src/dot/profile.zig` implement the
optional typed inputs, per-leaf inheritance, default-off runtime gate, checker,
separate header branches, all four graph treatments, severity and interpretation.
Validation adds `warnings`, a warning diagnostic twin, policy-aware payloads and
fix applicability. Source facts stay immutable. Fixed concrete views have zero
instance storage; fixed auto stores one derived kind; runtime views store only
kind/reading. Native Zig 0.16.0 layouts are 0/1/2 bytes, respectively, and
`Diagnostic` remains 80 bytes. Consumed Wasm Debug IR has no `policy.check`,
`policy.resolve` or runtime preflight function in the fixed profile; runtime
profiles include them. This is not a throughput or final binary-size benchmark.

Tests cover fixed/runtime equivalence, nested/chain auto detection, branch
independence, source fidelity, sink failure, staged bounded/reset use and
configuration rejection before allocation/input access. Compile-fail fixtures
exercise forbidden overrides, runtime verification on fixed profiles, invalid
baselines and `digraph.treated_as`. Consumed profiles compile for Wasm32 and
RISC-V32. [Consumer API and costs](../POLICIES.md).

**Existing-settings slice implemented:** `limits.max_nesting`, `max_statements`
and `max_attributes`, `on_error`, `scanner`, and `execution.metering` /
`cancellation` now use the same baseline/patch model. The default ordinary parse
is scalar, fail-fast, unmetered and uncancellable, with nesting at `maxInt(u32)`
and statement/attribute limits at `maxInt(usize)`;
`BoundedSession` is the metered fixed-profile convenience. Allocators, pool hints,
actual memory and cancellation callbacks remain explicit resources.

`Profile.Session` resolves once at init/reset and latches parsing/validation
settings across yields. Runtime scanner/execution choices select a specialized
engine; one tagged union stores only the largest variant, not eight simultaneous
machines. Fixed profiles specialize the same grammar, without runtime settings
or the disabled recovery-depth field. Invalid reset leaves the current work and
views intact; successful reset uses the compiled baseline plus the new patch.
Validation/interpretation of a committed session document is separate and
unbudgeted. Enabled cancellation also applies to one-shot parse/measure calls,
which publish no document/capacities when cancelled.

The former parse-option limit/recovery fields, `FixedSession(ExecutionFeatures)`
and root-file scanner hook are removed rather than retained as a second
configuration path. Runtime parse/measure calls are now fallible. Tests cover
the full scanner/execution/recovery matrix, fixed/runtime parity, policy latching,
atomic rejected resets, early configuration failure, state shape and freestanding
consumers. `bench-policy` compares fixed, runtime-baseline and runtime-override
paths; its standard-machine timing/binary-size gate remains pending. Recorded
baselines and package version are unchanged.

**Statement-boundary performance fix (2026-09-20).** Factual counters enlarged
the internal optional parse result from 8 to 20 bytes on native arm64. Even
continuing/null returns incurred extra stack/return-buffer traffic in hot grammar
helpers; compile-time removal of acceptance branches did not remove that cost.
Force inline calls to `beginNext`, `finishPending` and `schedule` only for the
fixed-policy unmetered, uncancellable engine. Runtime-policy and metered/cancellable
engines retain ordinary method calls: forcing inlining had mixed costs there,
and even `@call(.auto)` changed bounded-session code generation in Zig 0.16.
There is still one grammar implementation;
no counters, checks, limits or source information are dropped, and no state or
storage fields are added. Local ReleaseFast checks against `eccc595` improved
geometric-mean throughput by 4.36% across the original 14 L workloads, with
identical measured allocation counts and bytes. This is a targeted recovery,
not a guarantee of improvements for every execution profile or complete parity
with pre-policy performance; the standard-machine gate above remains open.

The parser has one policy-specialized `Machine`, with `ParseSettings` and
borrowed scratch kept separate. The previous machine/validation wrappers,
duplicated options, scanner-selection aliases and retired-root-hook detection
are removed. Direct sink fixtures use a test-only driver over that same machine;
production adapters do not translate through an old options structure.

**Additional checks implemented (2026-09-20):** `validation.ambiguous_numeral`
selects error/warning/off during parsing (default warning); validation does not
retroactively re-run lexical checks. `invalid_utf8`, `repeated_attribute`, and
consumer restrictions on effective graph kinds, ports and subgraph occurrences
are independent optional post-parse checks, default off. Every leaf supports
fixed and runtime binding. Each check selects `.err`, `.warning` or `.off`;
error affects validity, warning reports without invalidating, and off skips the
check rather than merely suppressing its diagnostic. `restrictions.ports`
reports each written qualified node reference (including a compass-only suffix),
not a label's port declaration. `restrictions.subgraphs` reports each named or
anonymous subgraph occurrence, including edge endpoints. Neither resolves a
graph or a port. Repeated keys compare logical identifier bytes within
one owner's adjacent attribute lists; separate statements/defaults are not
resolved or merged. One 16-byte caller scratch entry per attribute enables
deterministic sorting and exact comparisons without decoded string allocation.
Insufficient scratch is a separate incomplete outcome, preflighted before any
check/write; it is not a failed policy check or a valid document. These optional
validation passes are currently unbudgeted and uncancellable even when parsing
uses metering/cancellation. Validation diagnostics merge in source order with
deterministic rule-order ties. Aggregate counts use u64 because multiple rules may report the
same byte. See [public policy contract](../POLICIES.md) for names, stages and costs.
Schema restrictions, required attributes, cycles/connectivity/degree checks and
port-reference resolution still belong to later optional graph-building passes.

**Still open:** confirmation of the provisional mode-switch/irrelevant-field
rule; observation and live promotion APIs; standard-machine performance gates.
Semantic resolution,
custom rules, trait-style adapters and marshal/unmarshal remain separate designs.
Q40's compile-time-replaceable HTML-content processors and processor-owned
schemas are implemented for delayed/one-shot integration. Recursive execution
and broader grammar extensions remain separate designs; a custom implementation
is distinct from supplying a preset of existing Q35 fields.

**Verification contract (2026-09-20):** one public name, `validatePolicy`, and
the same `Policy` input schema for baselines and overrides. Omitted fields inherit
library defaults when defining a baseline and that compiled baseline at runtime.
Verify the resolved policy with one pure, allocation-free checker independent of
DOT source and storage. Fixed profiles verify during compilation; their explicit
`validatePolicy` calls require comptime arguments and there is no runtime verifier
or override path. Runtime-enabled profiles support preflight and automatically
resolve/check once before a source/document operation or session init/reset.
Real configuration failures are distinct from DOT diagnostics and must precede
input consumption/events. Do not invent invalid
combinations: mismatch error plus conforming interpretation is valid for a
concrete graph kind. The provisional mode-specific constraints above produce two
typed issues, with mismatch reported first if both fields are inapplicable.
Runtime source/document operations that accept a policy, and session init/reset,
return `PolicyError!T`; fixed counterparts return `T` without a configuration-error
union. Latched session methods do not resolve policy again: `run`, `cancel` and
`result` have no configuration-error union, while runtime `advance` can return
`MeteringDisabled` without doing work. Validity of a policy does not guarantee valid
DOT or adequate storage. Delivery status is recorded separately.

**Q36 — Which syntax deviations may be accepted leniently, and how are they
reported?**
**Initial slice implemented; history and keyword extensions remain open.** Syntax acceptance is
policy with the same compile-time/runtime semantics as Q35. It runs during
parsing; validation of a completed document is a separate stage. Default to
rejection for the deviations below. Opt-in acceptance should warn with the
selected assumption; silent acceptance is a separate explicit choice. Accepting
a deviation precedes failure; a rejected one can enter existing recovery (Q22).

| Deviation | Accepted interpretation | Scope/status |
| --- | --- | --- |
| Empty statement | No retained statement | Implemented; reject/warn/accept |
| Exact long operators `---` and `-->` | `--` and `->`, respectively, by spelling | Implemented; independent of graph kind |
| Bare `-` in an edge-operator position | `.from_keyword`, as below | Implemented; acceptance/reporting separate |
| Reserved keyword as a name | A name only where grammar permits that reading | Deferred until exact name-only contexts are specified |

**Bare-dash decision.** Use the narrow rule `syntax.bare_dash`,
not a catch-all `malformed_operator` rule. Unlike a long operator,
a bare dash does not supply direction. The agreed opt-in action is
`.from_keyword`, explicitly based on the written header, not an ambiguous
`.conform` to the interpreted graph kind:

| Written header | Interpreted kind | Bare `-` with `.from_keyword` |
| --- | --- | --- |
| `digraph` | `.digraph` | `->` |
| `graph` | `.undigraph` | `--` |
| `graph` | `.digraph` via `treated_as` | `--` |
| `graph` | `.generic`, or either kind selected by `.auto` | `--` |

For example, under generic interpretation, `graph { a - b; b -> c; }` accepts
the first edge as `--` and keeps the second as `->`; the effective kind stays
generic. This is an explicit fallback for incomplete syntax, not a claim that
generic graphs are undirected. Never infer direction from neighboring edges or
their majority. Only the bare dash in an operator position is affected; negative
numeric IDs and dashes in strings/comments/other tokens remain unchanged.

Implemented policy input:

```zig
.syntax = .{
    .bare_dash = .{ .acceptance = .warn, .interpretation = .from_keyword },
    .long_operator = .warn,
},
```

The pipeline order is syntax interpretation/normalization, graph-treatment
resolution (including auto promotion), graph validation, then any requested
effective operator view. Thus `-->` first supplies `->` even under `.undigraph`
treatment; any mismatch and conformance are separate decisions. A bare `-` in a
written `graph` treated as `.digraph` first supplies `--`, after which the `graph`
branch may reject, warn or interpret it as conforming. Syntax and mismatch
warnings may describe separate facts.
Spaced operators, missing delimiters, unterminated constructs, guessed headers
and arbitrary trailing input are not made acceptable by these rules.

**Information-loss boundary.** Lenient structural data may normalize an operator
or omit an empty statement; it is not a lossless record of those decisions.
Borrowed source remains unchanged, and retained ranges cover the original
spelling (`-`, `---`, `-->`), not synthetic repaired text. No duplicate spelling
field is needed on each edge. Dropped constructs may require rescanning; changing
syntax policy can require reparsing. A policy states what was allowed, not what
actually occurred. Counters are not detailed history, and diagnostic suppression
must not masquerade as absence of deviations.

**Presets and reporting (implemented).** `dot.presets.standard` names the default
`Policy`; `dot.presets.lenient` changes only the three syntax acceptances
to `.warn`. There is no separate lenient flag or parser. `standard` avoids
confusion with DOT's unrelated `strict` modifier. Both presets leave `markup`
unset to inherit the binding default or compiled baseline. A full runtime preset
replaces the other baseline fields; a `.syntax` subtree patch preserves those too.
All leaves have compile-time/runtime parity and ordinary inheritance.

Both scanners retain their strict lexical contract. On the cold failure path,
the shared parser adapts only recognized operator shapes in eligible grammar
positions; no new token tags or per-byte policy checks are needed. Normalized
tokens keep the original range, and warnings/counters occur once at grammar
acceptance, including across port/chain replay and bounded yields.
`W.Syntax.Operator.003` records chosen operator and `.long_shape`/`.from_keyword`;
`W.Syntax.Grammar.034` records an omitted empty statement. Fixes replace with the
selected operator or delete that semicolon and are machine-applicable under the
selected interpretation, not a claim about the author's intent.

Parse/measure/session results expose `accepted_deviations: u32` and `warnings: u32`,
including prefix facts before failure. `CheckResult.warnings` totals syntax and
validation warnings. Silent acceptance still counts; lexical numeral warnings
are warnings but not deviations. Empty statements use no statement capacity or
statement-limit count, but consume work and count as deviations. Standard fixed
profiles compile out acceptance counters/logic in the grammar machine; public
result counters remain present. No optional deviation history is retained.

**Still open:** optional typed deviation events or caller-owned history, its
capacity/overflow/lifetime contract and costs; keyword contexts. Explicit `.directed` or
`.undirected` bare-dash interpretations are possible later additions, not an
agreed initial requirement. Recovery remains separate from successful lenient
acceptance. No always-on per-node/edge audit metadata or hidden history allocation
is authorized by these decisions.

**Q40 — How are HTML-like identifiers recognized, parsed and validated, and
which markup policies are offered?**

**Partially decided; delivery reconciled 2026-10-04.** Standalone structural
markup, DOT passthrough recognition, explicit delayed processing and one-shot
during-DOT composition are implemented. Specialized dialects and broader
composition remain unfinished. Details live in [markup delivery and design](MARKUP.md)
and the [processor contract](PROCESSOR_CONTRACT.md); public usage is in
[markup](../MARKUP.md), [labels](../LABELS.md) and
[custom processors](../CUSTOM_PROCESSORS.md).

**Settled boundaries**

- Recognize HTML-like spelling wherever DOT permits an ID. The outer scanner
  counts every `<` and `>`; quotes, comments, CDATA and references do not shelter
  brackets at this boundary. Recognition does not prove inner structure.
- DOT owns `none | passthrough | process`, default `passthrough` without a
  processor and `process` with one unless explicitly overridden. DOT presets
  inherit this choice. Unbound process fails policy verification
  at compile time or runtime preflight. Both scanner backends
  retain recognition even under `none`; rejection is a processing policy, not
  a scanner-size switch. Supported passthrough is different from silently
  reporting unsupported input. Unsafe boundaries remain terminal.
- A passthrough operation never invokes the markup engine. Other profiles or
  delayed entry points may still require it in the binary. Runtime selection
  cannot determine linking or install an implementation.
- Outer selection (`none`, `passthrough`, `process`) is independent of the
  processor's mode. Built-in markup exposes `mode = .structural` and an
  unreleased `.graphviz` vocabulary slice (element/per-element attribute checks,
  ASCII case-insensitive lookup and duplicate comparison). This is not complete
  Graphviz compatibility; content models, values, references and automatic
  label-context selection remain unfinished. `extended` remains future work,
  not a callable value or a compatibility ladder.
  Custom processors own their schema and need not expose this mode field.
- Standalone, delayed and during-DOT paths use the same selected implementation.
  Standalone markup depends only on shared support, not DOT records/grammar.
  Its structural grammar is XML-like, not full XML or browser HTML.
- Graphviz validation will check vocabulary, attributes and parent/child
  placement, only in label contexts. A `TABLE` containing a `TD` directly
  can be balanced yet fail the required row structure.
- `n:<p>` names port `p`; `label=<p>` is text `p`;
  `label=<<p>x</p>>` contains a `p` element. Port spelling is not meaningless.
  Resolving it against label declarations belongs to later graph semantics.
- Source stays immutable and unexpanded. Preserve complete concatenations and
  operand spelling. HTML/quoted concatenation is an implemented exception to
  Q10's specification-first rule, matching Graphviz 16.0.0. Explicit decoding
  may join values but never replaces the retained expression.
- `identifier.form` and `identifier.parts` are implemented. Form follows
  spelling, not content: quoted markup-looking bytes remain quoted. Each raw
  operand supplies its own inner range/origin. Decoded combined expressions
  need a source map, not one constant offset.
- Depth means element nesting, not the outer angle counter. The retained layout
  is settled: preorder subtree intervals and owner-indexed attributes, not the
  earlier parent/child/sibling proposal. Frames are 12 bytes on measured targets;
  the earlier 8-byte name-only estimate is not a capacity promise. Stack
  compression is not required; a summary index remains a separate proposal.
- Both markup scanners are implemented, independently selectable from DOT's.
  Share mechanisms only where contracts match; no speculative common scanner
  framework, guaranteed vector speedup or implicit parallel runtime is required.
  Caller-owned threads can process separate fragments with independent state.

**Processing and policy ownership**

Implementation identity is compile-time-only; its settings may have default-off
runtime overrides with full supported-leaf parity. Built-in and consumer
processors use the same contract. Each owns its schema, presets, resolved state,
diagnostics and verification. Shared `PolicyBinding` and nested `PolicySet`
prepare settings once, not execution. Buffers, allocators and callbacks remain
resources, not policies. Static binding does not sandbox custom code.

One-shot composition binds `Profile.processors.markup`, invokes one child
workspace per complete raw HTML operand and shares a diagnostic union/bag of
only the bound processors. It has no composed `Session`, fixed-memory facade or
retained child-tree array. Workspace results borrow until the next call/deinit;
DOT never deinitializes individual results. Ordinary DOT gains no mandatory
per-ID processor state.

None/passthrough skips child workspace initialization and execution, not policy
verification. Switching outer selection leaves the child policy unchanged.
`MarkupReport.requested` distinguishes disabled work from successful validation;
`allValid()` is false when not requested, while combined validity is relative to
the selected policy. Execution remains synchronous after a complete operand
boundary; no thread argument, queue or implicit concurrency is introduced.

Nested DOT → markup → string and sibling string settings already prepare
independently. Automatic deeper execution and a built-in string processor remain
future work. New token spellings need a separate lexical contract for boundaries,
escaping, collisions, recovery and work; new statements/operators are outside
the content contract. Replacing an inner parser cannot extend DOT grammar.
Numeral boundaries remain grammar-defined; ambiguity checking stays lexical,
not implicit numeric conversion or a promised `.string.non_ascii` API.

**Diagnostics, scheduling and independent outcomes**

Boundaries, local checks and enclosing structure have different prerequisites.
Reliable headers/values remain checkable after enclosing syntax failure through
the scope APIs; unavailable coverage is incomplete, not valid. No partial tree,
guessed delimiter or typo repair follows. Public scope metadata is checked in
all builds; incomplete coverage identifies the earliest gap, not a resume cursor.

Parent and child `on_error` choices are independent. The child returns under its
own choice; the parent then decides whether to visit the next fragment. Ordinary
child errors/unsupported input/policy limits are not unconditional batch stops.
Shared sink stops/failures, storage/allocation failures and cancellation are
operational stops. `diagnostics.unsupported` changes reporting and error
classification, never whether unprocessed input was checked. Silence constructs
no user-facing diagnostic; passthrough is separately supported preservation.
Completion, validity and delivery remain separate; terminal reporting failure
does not erase the original failure.

During-DOT child findings occur at operand recognition; outer validation follows
successful DOT parsing. Delayed calls follow caller selection/phase order.
Source validation performs encoding first, then local scopes. Determinism does
not promise global source sorting or hidden buffering. Shared rendering locates
mixed findings without changing emission order.

Rebase primary, related and fix spans exactly once from each raw fragment.
Tree spans stay fragment-local. Decoded/transcoded bytes need a map. Source
ownership, fixed-storage paths and explicit costs apply whether or not the
caller retains a tree. Requested incomplete work is not “not requested”.
Completed outer results survive later inner errors; stops during outer parsing
need not leave a document.

**Remaining decisions, not delivered APIs**

| Topic | Status / next decision |
| --- | --- |
| Graphviz validation | Agreed direction; context selection, rules, compatibility scope and costs |
| Extended vocabulary | Under discussion; concrete consumer, tags, attributes and placement |
| Dialect parsing | Under discussion; void names/case/context, explicit closers, unquoted/empty attributes and grammar policy |
| Custom name/reference catalogs | Further design; built-ins remain independent optional checks |
| Composed execution | Agreed direction; shared credits, cancellation, fixed scratch, reset/latching and validation scheduling |
| Deeper/string processing | Future design; nested policy preparation is implemented |
| Profile/API redesign | Deferred discussion; workspace reuse did not decide it |
| Summary index / caching / public events | Optional proposals; ownership, layout, budgets and event contract unresolved |
| Partial-tree publication | Deferred; current parse results remain complete-document-only |
| UTF-16/32 adapters | Provenance constraints agreed; conversion errors, mapping, metadata and storage APIs open |
| Packaging/versioning | Open; an independent module does not decide separate packages/version numbers |
| Cross-parser boundary survey | Optional follow-up, not a gate on delivered recognition |

Markup/integration are post-0.3.0 development work. No next release number,
browser compatibility or implementation schedule is established here.
Performance approval is separate from functional delivery; preserve the
[standard-machine gate](MARKUP.md#verification-and-performance-gates).

**Q1 — Is version 1 the complete documented DOT grammar or a named subset?**
Direction: the complete documented grammar, reached through vertical slices;
every interim release documents its exact supported subset. The end-state
compatibility statement is written when the slices land. *(Embodied: README
"First goal"; `tests/corpus/unsupported/` tracks the boundary.)*

**Q12 — What default security limits apply to convenience APIs?**
`max_statements` exists and is caller-visible, but defaults to unlimited;
whether convenience APIs should ship with non-trivial defaults is open.
*(Embodied: `Policy.limits.max_statements`.)*

**Q16 — What size thresholds establish that disabling a feature removed its
cost?**
Parser-state size is regression-guarded (≤ 512 B with the scalar scanner, currently 368 B native with offset-only positions; ≤ 640 B with the block scanner, 472 B measured) and baselines exist;
per-profile binary-size thresholds await the profile work. *(Embodied:
`docs/PERFORMANCE.md`; parser-size test.)*

**Q17 — What exact boundary separates the syntax tree from `DotIR`, and
which lowering passes are in version 1?**
The document side is now concrete: source-shaped, source-ordered, no
deduplication, no implicit nodes, no attribute semantics. The `DotIR` side
(passes, storage) is open until slice 7. *(Embodied: `src/dot/syntax.zig`.)*

**Q18 — Which index widths and pool sizes define the first embedded retained
representation?**
`u32` indices with checked overflow, declared once so profiles can narrow
them; 8-byte compact ranges and 32-bit positions sharing one 4 GiB domain,
enforced once at the scanner entry. u16/u24 variants
await the profile work. *(Embodied: `syntax.Index`, `location.Range`.)*

**Q23 — Does version 1 ship the optional UTF-8 validator, and what policy
applies to BOMs, NUL bytes, invalid sequences, and HTML-like IDs?**
**Decided:** the core is byte-oriented, with physical byte offsets and
LF/CRLF/standalone-CR tracking; encoding validation is a separate optional
policy/pass. Comment bodies are opaque bytes, including NUL and invalid UTF-8,
and preprocessor directives do not alter physical locations.
**Implemented boundary:** quoted IDs retain one raw-expression range and decode
only on explicit request into caller storage or a writer. Escaped LF/CRLF/CR
continuations are removed on decoding; raw line endings are preserved. Quoted
content accepts non-ASCII and non-NUL control bytes without validation of its
encoding; NUL is rejected. **Non-ASCII bare IDs (decided and implemented
2026-09-18):** bytes 0x80–0xFF may start or continue a bare identifier alongside
the existing ASCII identifier bytes. Preserve the whole run as one borrowed
range, with no normalization, transcoding, encoding validation or implicit
allocation. Invalid and partial UTF-8 sequences are accepted raw bytes;
keywords remain ASCII-only. The same rule applies in every ID position and
to both scanner backends, including bounded execution and explicit decoding.
Outside comments and quoted content, control bytes other
than supported whitespace are invalid when reached by the lexer. HTML-like
identifiers use the implemented angle-balancing boundary; passthrough does not
validate their bodies.
A leading UTF-8 BOM is skipped, matching Graphviz's scanner (decided
2026-09-18); elsewhere its bytes are identifier content, including when
decoding an extracted identifier starting with those bytes. Q40's recognition in
all DOT ID positions, independent structural markup and delayed/one-shot
integration are implemented; specialized label rules remain future work.
**Optional validator implemented (2026-09-20):** `validation.invalid_utf8` is
off by default, with error and warning choices. It checks all source bytes,
including comments and trivia, without mutation. A byte not consumed by a valid
UTF-8 sequence is one finding, then recovery advances one byte. Overlong forms,
surrogates and values beyond U+10FFFF are invalid. No policy weakens grammar NUL
rules. **Standalone markup implemented (2026-09-27, slice 4a):** the same optional
whole-source encoding check is available independently of parsing, including
comments/CDATA and with compile-time/runtime parity. Retained-document findings
merge with duplicates in source order, UTF-8 first on equal starts. The separate
source-scope path runs encoding before local checks; it is not globally sorted. Shared sequence checking
does not share processor-owned policies/diagnostics or imply XML name/character
conformance. Optional markup names and known-reference checks are implemented in
slice 4b with independent selection/severity; further catalogs remain open (Q40).
**Future UTF-16/32 adapters (requirement clarified 2026-09-27; not implemented):**
use UTF-8 working bytes while retaining original encoding, byte order and BOM
provenance once per source. Keep original bytes/a live source handle for exact
reproduction, and explicit offset mapping for original-file diagnostics/fixes.
Unknown provenance stays unknown; converted bytes alone cannot recover it. Do not
hide replacement or normalization as lossless conversion. Metadata/API shape,
malformed-input handling, mapping storage versus rescanning and all buffer/work
costs remain design decisions; current raw-byte behavior stays unchanged. See
[the encoding contract](MARKUP.md#encoding-adapters).
*(Embodied: `src/dot/lexer/`, `src/dot/validation_checks.zig`,
[supported syntax](../SUPPORTED_SYNTAX.md); R-PORT-006.)*

**Q24 — When will the first stable compatibility boundary be declared?**
`v0.1.0` shipped after slice 2 (directed documents). It is a useful experimental
release, not a source-API stability declaration. The stable boundary and its
criteria remain open. There is no compatibility guarantee for source APIs,
diagnostic identities, payload discriminants or retained layouts during this
experimental phase. Obsolete entries and compatibility-only scaffolding are
removed, including retired-API detection and compatibility-only tests. Internal
callers and correctness tests use the current implementation; they do not justify
retaining an old wrapper or settings schema. WDP conformance and current registry
consistency remain required. *(Embodied: `CHANGELOG.md`,
`build.zig.zon`, `src/root.zig`; R-ARCH-009/R-DIAG-005.)*

**Q26 — Which named profiles are public conveniences?**
**Implemented conveniences; reconciled 2026-09-22:** `dot.presets.standard`
and `dot.presets.lenient` are editable `Policy` values, not separate
parsers or boolean modes. Standard names the library defaults; lenient changes
only the three Q36 syntax acceptances to `.warn`, not validation, recovery,
limits, scanner or execution. Both presets leave `markup` unset to inherit the
binding default or compiled baseline; a runtime preset replaces the other leaves.
A `.syntax`-only patch preserves those other baseline choices too. `Profile`
supports consumer-defined compile-time baselines and default-off runtime
overrides, and `BoundedSession` is the fixed metered convenience. Earlier
named-profiles-first/custom-structs-later ordering is superseded. Markup also
provides an `untrusted` resource preset. A DOT equivalent and additional
footprint-oriented presets remain open; no broader set is promised.

**Q27 — Which progress budgets does the bounded driver support, and what
work unit is deterministic?**
**Agreed policy:** metering and cancellation are optional capabilities; bounded
execution uses deterministic work units, with source progress reported
separately. Yield preserves continuation/staged data without abort; cancellation
is terminal. Keep the stage-based architecture and expose factual progress, not
a whole-pipeline percentage.
**Implemented execution contract:** [contract](../EXECUTION.md)
defines charged scan/grammar/dispatch microsteps, zero/one-credit behavior,
callback exclusions and terminal cleanup, cancellation precedence, source
frontier semantics, and acceptance tests. `BoundedSession` now provides public
fixed-storage bounded parsing. `Profile.Session` independently selects metering
and cancellation through `Policy.execution`; the hook is a borrowed
context/non-failing predicate pair. Explicit
cancel/deinit cleans up abandoned work, and reset reuses pools after cleanup.
Partition, cancellation-boundary, failure-precedence, lifetime and freestanding
checks accompany the API. Ordinary-path and optional costs are recorded in
`docs/PERFORMANCE.md` for the pre-migration implementation; policy-path comparisons
remain pending on the standard machine. Public pull events, streaming input, total-operation work
limits and bounded validation remain outside this implemented slice.
*(R-MOD-010/R-MOD-013; `profile.Session`, `parser.Machine`, `lexer.scannerFor`.)*

**Q22 — Which grammar boundaries are safe recovery points, and what is the
measured binary-size cost of recovery support?**
**Implemented (2026-09-18):** statement boundaries are the sync points. With
the policy `on_error = .collect` (now the default, per
R-FUNC-007), a syntax error inside the body aborts the sink once, the parser
skips to the next `;` or `}` at the same brace depth (skipped `{` are matched
by counting), and every later syntax error is reported through the same bag.
No document is ever published; completed recovery reports `invalid_syntax`.
Later operational stops keep their own outcomes with `.incomplete` completion;
the u32 `syntax_errors` count retains every discovered rejection, including a
finding refused by the diagnostic sink. Fixed fail-fast excludes the running
counter and supplies its single terminal syntax-error count directly. Lexical
errors resume after the malformed bytes; unterminated quotes/comments, header
errors, end of input, trailing tokens and limits remain terminal. Excluded
HTML-like body identifiers now also recover, retaining `unsupported_feature`
unless a syntax error is reported (R-MOD-006). Measured: renderer-free ReleaseSmall
examples grew by 350–650 B and ordinary throughput did not change. These measurements predate Q35's unified
policy migration: fixed fail-fast profiles now exclude recovery handling and
skip-depth storage; runtime profiles support both values. Diagnostic bags now
signal stop at capacity and parsing honors that immediately. Explicit omission
mode limits retention only. **Still open:** a broader per-class abort/report/ignore
policy. Q36's three lenient
acceptances are implemented and can successfully commit; recovery after a
rejected construct remains separate and cannot publish a partial document.
*(Embodied: `Policy.on_error`,
`tests/diagnostics.zig`, `tests/policy_settings.zig`; R-FUNC-007, R-DX-002.)*

---

## Open

**Q7 — What are the target RAM, flash, maximum token, maximum nesting, and
document-size budgets for the first embedded profile?**
Gated on choosing the target board and build configuration (R-PORT-002).
Interim: `FixedDocumentStorage.byte_size`, `max_statements`, and
`max_attributes` give callers their own output budgeting. `FixedParseScratch.byte_size`
and `max_nesting` now expose temporary nesting capacity and depth policy; choosing
an actual board budget remains open.

**Q11 — Which observer events and verbosity levels are stable public API in
version 1?**
Policy-bound sessions, progress, metering and cancellation are implemented
(Q27/Q35). The stable public observer/pull-event interface and verbosity contract
remain open; implementation of the policy core does not settle them.

**Q14 — Which syntax features are compile-time selectable, and which remain
in every parser profile?**
Q35/Q36 implement fixed-policy specialization of supported syntax acceptance,
checks, recovery, scanner and execution settings. The broader grammar-feature
exclusion matrix remains open. In particular, port/subgraph restrictions are
post-parse checks, not switches that compile those grammar features out.
HTML recognition and optional structural-processor binding are implemented
(Q40); neither settles the broader grammar-exclusion matrix.

**Q15 — Does the smallest profile retain unsupported-feature detectors, or
prefer the absolute smallest binary?**
The current parser retains unsupported-feature detection (R-MOD-006). The
implemented policy core does not define a smallest embedded grammar profile.
Q40's implemented `none` still recognizes HTML-like boundaries before rejecting
them; broader minimal-profile choices remain open.

**Q28 — Does version 1 provide lazy semantic lowering only, or also a lazy
syntax index over retained source?**
Open; nothing currently forces the choice.

---

## Reconciliation log

Historical checkpoints below describe their dates, including features that were
pending then and are implemented now. Current status is given above under each
question; these entries are not a second task list.

- 2026-10-03 — Documentation consolidation: preserve Q1–Q40 and decision status,
  reconcile implemented custom bindings/integration, distinguish cancellable
  markup validation from unmetered validation, and keep outstanding dialect,
  scheduling, encoding, packaging and performance decisions. Completed slice
  diaries are removed from the active markup plan; preparation details are
  consolidated into the processor contract. No implementation or benchmark change.


- 2026-10-03 — Replace `recovery` / `Recovery` with `on_error` / `OnError`, no
  aliases. Apply fail-fast to validation and combined operations; separately
  requested source validation still synchronizes safe malformed headers. Add
  unsupported reporting without treating silence as passthrough. Delayed child
  results distinguish errors from operational stops and expose parent-controlled
  continuation. See [the processor contract](PROCESSOR_CONTRACT.md).

- 2026-10-02 — Harden the public scope boundary with all-build-mode metadata
  checks and `invalid_scope`; keep scanner-produced scopes on the trusted internal
  path. `incomplete: u32` now identifies the earliest coverage gap, not a resume
  cursor. Closing-name coverage and recovery selection are unchanged.

- 2026-10-02 — Separate markup local validation scopes from enclosing structure.
  Headers, names, attribute-value content and text can be checked without a tree
  through `validateScope[In]` and `validateSource[In]`. Recognized prefixes retain
  findings, missing coverage remains incomplete, and parse-only costs/contracts
  stay separate. Shared kernels preserve standalone document validation. No
  custom string processor or SIMD batching is added. See [local scopes](MARKUP.md#validation-and-coverage).

- 2026-10-02 — Standalone markup `.collect` now synchronizes selected rejected
  opening-header attribute errors at explicit quote-aware `>`/`/>` boundaries.
  Preserve written names and stack effects; uncertain boundaries remain terminal.
  No syntax acceptance, typo correction, partial tree or validation of skipped
  attributes is introduced. See [opening-header recovery](MARKUP.md#recovery-and-acceptance).

- 2026-09-30 — DOT defaults to statement recovery with terminal unterminated
  lexical constructs. Standalone markup gains default structural recovery,
  explicit fail-fast, source-bounded ancestor lookup, completion/error facts and
  no partial-tree publication. Sink stops end work; fixed fail-fast excludes
  continuation state. Both processors name the choices `.fail_fast` and `.collect`;
  recovery remains distinct from acceptance, validation and markup processing mode.

- 2026-09-29 — Shared WDP metadata/identity and console machinery now serve both
  DOT and markup, with processor-owned catalogs/typed adapters and unchanged
  identity strings. Added conservative markup repair offers with fixed/runtime
  filtering and no diagnostic layout increase. Integrated execution stays open.

- 2026-09-27 — Slice 4b implements optional name/reference validation with typed
  selections and severities, fixed/runtime parity, source-ordered diagnostics and
  no new retained pools. The parser stays generic/extensible with Graphviz its
  priority consumer. Recovery, void elements, custom catalogs and transcoding are
  not part of this implementation.
- 2026-09-27 — Clarified that an HTML-like void-element rule can be a swappable
  parsing rule in a shared engine, not just validation or recovery; the existing
  built-in baseline remains unchanged pending design. Recorded future UTF-16/32
  adapters' original-encoding provenance, mapping, lifetime and cost requirements.
- 2026-09-27 — Next validation slice selects optional name rules and reference
  catalogs independently, without imposing XML restrictions on other dialects.
  Recorded name-local decoding, independent overlapping encoding findings and
  explicit optional-cost targets. Structural recovery is deferred to a separate
  design discussion; no new parser behavior or public policy API is implemented.
- 2026-09-27 — Shared growable bags now default to 1,024 retained diagnostics;
  finite limits use `u16` and unlimited retention is explicit. Markup adds
  `presets.untrusted` with finite source/node/attribute/nesting budgets. Diagnostic
  payloads and finding counters are unchanged; UTF-8 findings remain one per bad
  byte. These bounds do not promise total heap, time or bounded validation.
- 2026-09-27 — Structural slice 4a adds optional whole-source UTF-8 checking with
  default-off error/warning policies and independent validation. Encoding and
  duplicate findings are source-ordered without a queue; names, known-reference
  checks, structural recovery and DOT integration remain subsequent work.
- 2026-09-27 — Structural slice 3 implements raw-preserving references, comments
  and CDATA, malformed-reference syntax policy, deviation/warning counters and
  diagnostic-stop handling. Node/attribute/frame sizes remain unchanged; reference
  continuation and public result state have explicit measured costs. DOT integration,
  further optional checks and defined recovery remain pending.

- 2026-09-27 — Structural slice 2 implements quoted attributes, ordered duplicate
  retention, explicit attribute capacity/limits and independent duplicate checks
  with fixed/runtime error/warning/off parity. Retained node layout stays 20 bytes;
  sparse attributes and per-element validation scratch are separate costs.
  Reference processing, bounded validation and DOT integration are still pending.

- 2026-09-27 — Standalone markup first (decided 2026-09-26): implement structural parsing in vertical
  slices before more processor composition. Recorded case-sensitive raw-byte
  grammar, explicit encoding boundary, duplicate retention/checking and the
  malformed-reference literal-ampersand policy. Slice 1 implements the independent
  module, elements/text, compact retained/count-only paths, policy limits and
  bounded/cancellable fixed sessions. Later constructs and DOT integration remain
  unsupported. The old passthrough-first delivery order is superseded, not its rules.

- 2026-09-26 — Q40 preparation: recorded agreed stages 1–4 and ownership/reset
  defaults; implemented shared typed reporting and compile-time policy preflight.
  DOT diagnostic stop/failure ends unfinished work, with original terminal causes
  and completed outer results preserved. Fixed bags stop by default; general
  examples use growable bags. This does not implement markup or composed scheduling.
  This deliberately reverses the 2026-09-23 decision to continue after diagnostic
  delivery failure: the later agreed sink-owned stop contract treats a rejected
  delivery as an operational stop, avoiding further work after the destination
  has signalled that it cannot accept output. Ordinary validation findings still
  permit independent checks; completed outer output and terminal failure causes
  remain intact.

- 2026-09-26 — Documentation placement corrected: processor design and preparation
  notes live under `docs/internal/`, not in the public usage guide. Durable
  documentation must not depend on disposable working files. Shared reporting
  remains public documentation because its fixed/growable/streaming destinations
  are implemented. Review suggestions about muting, bag defaults, stopped counts,
  schema diagnostics, PolicySet and span types remain proposals, not changes to
  the agreed behavior.

Entries describe the state at the time they were recorded; current delivery
status is in the question entries above, not an earlier log's pending-work list.

- 2026-09-23 — Q40: shared diagnostic infrastructure with processor-owned
  payloads, independent validation continuation, bounded diagnostic retention,
  standalone/delayed/composed validation and separate stage outcomes decided.
  The initial retained-document sequence is DOT validation followed by requested
  inner processing, without requiring outer validity. Dependent checks and
  operational failures remain explicit; aggregate ordering and concrete APIs
  remain open. Clarified that `none`/`passthrough` select behavior, not diagnostic
  severity. R-FUNC-008, R-MOD-014/015 and R-DIAG-007 record the contract; this
  does not implement processor composition or bounded validation.
- 2026-09-22 — Q40 content-processor vision decided: implementation identity
  is compile-time-only, each processor owns its typed policy and optional
  runtime overrides, and built-in inner parsers use the same contract as
  consumer replacements. Clarified `none`/`passthrough` versus processor invocation,
  ownership of nested configuration, numeral boundaries and illustrative string
  checks. Custom lexical forms remain a separate future design, not an automatic
  consequence of replacing an inner parser. Reconciled the earlier single-enum
  and exactly-two-schemas wording; shared policy generation and the concrete
  adapter remain provisional. R-MOD-015 records the intended contract. No new
  implementation or performance result is claimed.
- 2026-09-22 — Q40: the passthrough slice contract is decided (default
  `passthrough`; unterminated fix offered at depth one with a new
  policy-controlled `diagnostics.fixes` leaf; minimal `identifier.form`
  now; policy-free scanners with the mode applied by the parser;
  concatenation in scope; all ID positions; both backends). The owner
  proposed a policy ownership split — DOT knows `none | passthrough`, the markup
  subsystem owns its own policy and modes, the engine attaches as a
  resource — recorded with the reviewer's analysis, to confirm. Nothing
  implemented.
- 2026-09-22 — Reconciled Q35/Q36/Q26/Q22 with the implemented policy core,
  settings migration, lenient syntax, presets, factual counters and optional
  validation checks. Added a source/test coverage table and explicit deferred
  work; distinguished syntax restrictions from semantic graph checks. Moved
  implemented Q37 into Decided and corrected its layout/applicability wording.
  Clarified Q11/Q14/Q15 follow-ups now that policy profiles exist. Preserved the
  standard-machine performance gate and the targeted fixed-policy optimization
  record; no fresh performance result is claimed.

- 2026-09-22 — Clarified Q40 element depth versus delimiter depth, unknown
  structural summaries under passthrough recognition, and possible element-count
  limits. Corrected label validation, operation versus module inclusion,
  source-preserving concatenation versus explicit decoding, per-operand origins,
  the Q10 compatibility exception and port-ID meaning. Frame size remains an
  estimate and markup-backend delivery/performance requires measurement. Exact
  fragment grammar/APIs and markup implementation remain pending.

- 2026-09-20 — Q35 graph-policy refinement: outer `graph`/`digraph` keys match
  the written DOT header and configure independent branches. Settled
  `graph.treated_as`, `GraphKind` (`undigraph`, `digraph`, `generic`) and
  `GraphTreatment` (those selections plus `auto` behavior); no treatment setting
  on `digraph`. Auto starts as `undigraph` and promotes to `generic` on the first
  directed syntax operator. Renamed conformance to `conform_to_kind`, targeting
  the effective kind, while Q36 bare-dash `from_keyword` keeps its written-header
  meaning. Updated examples, behavior tables and §2 terminology. Irrelevant-field
  representation, mode-switch inheritance and auto metadata/notifications remain
  open. The interrupted implementation requires revision and verification.

- 2026-09-20 — Q35/Q36 now record the agreed typed policy model and full
  compile-time/runtime field/value parity, superseding a restricted override
  subset. Preserved default-off runtime support, partial baseline inheritance,
  session stability, explicit resources and efficiency/safety requirements.
  Recorded the three graph decisions, preservation versus effective conversion,
  left-to-right directed conversion, and generic meaning versus mixed usage.
  Settled bare-dash `.from_keyword` interpretation, including `--` in a generic
  `graph`, independently of long-operator normalization and warning selection.
  Added behavior tables and the information-loss boundary; moved Q35/Q36 into
  **Partially decided** without changing IDs. Q26/Q38/Q40 and R-MOD-005 now
  reconcile earlier configuration directions with full parity. API spelling,
  history/summary storage and implementation details remain open; no delivered
  policy implementation or new performance measurement is claimed.

- 2026-09-19 — Q35/Q36 policy configuration: settled a consumer-selectable
  compile-time baseline with separately enabled, default-off runtime overrides.
  Runtime patches inherit unspecified compiled defaults, apply per operation and
  stay fixed during a session. Public API names and rule details remain proposed;
  no policy implementation or measured cost improvement is claimed.

- 2026-09-19 — Added Q40 for the dedicated, optional staged markup subsystem
  and recognition in every DOT ID position. Distinguished passthrough preservation,
  XML-like structural checking and Graphviz label validation. Settled the mode
  names `none`, `passthrough`, `structural`, `extended`, and `graphviz`, with a
  comparison table of their processing stages and validation policies.
  Recorded standalone, during-DOT and delayed use of one markup engine, with
  a usage-path table and explicit source-lifetime, work-budget and validity
  boundaries.
  Q23 links the remaining markup policy to Q40. The fragment grammar,
  extended vocabulary, decoding/form API, configuration and delivery scope
  remain open; no implementation claimed.
- 2026-09-19 — Q40 review: nine clarification questions raised and, after
  discussion, resolved into recorded decisions (`none` as policy with
  recognition always compiled, the Graphviz delimiter rule verified against
  the 16.0.0 scanner, XML structure for every parsing mode, compile-time
  stage inclusion with runtime mode, the origin-mapping rule, explicit lazy
  decoding with form from spelling, no collapsing of concatenations, bounded
  nesting with small frames and no stack compression, both backends for both
  scanners independently selected, caller-side parallelism) plus a proposed
  retained-representation layering (summary index, structure, validation)
  left as direction. Concatenation with HTML operands, the parts API, the
  fragment grammar and the cross-parser boundary survey stay open.

- 2026-09-18 — Non-ASCII identifier slice: Q10/Q23 record acceptance of raw
  high bytes in every bare-ID position, byte-preserving decoding, ASCII-only
  keywords, and document-only BOM skipping. Encoding validation stays optional
  future work. Removed the implemented feature's diagnostic variant per
  R-DIAG-005; no retained-layout or memory-policy change.

- 2026-09-12 — Q10, Q13, Q25, and Q29 moved to **Decided**, with pending
  verification and future API scope stated separately. Corrected Q4's
  reporting/validity distinction, Q20's paired sequences/aliases, Q23's
  context-dependent byte handling, Q24's shipped release, and Q27's
  token-progress versus bounded-work distinction. No question IDs changed.
- 2026-09-12 — Identifier slice: Q10/Q23 now distinguish supported quoted and
  numeral IDs from deferred non-ASCII bare IDs, and record the explicit decoding,
  NUL, and line-continuation policies. The 16.0.0 manual probes do not replace
  the pinned 15.1.0 differential suite; BOM policy remains open.

- 2026-09-12 — Attribute slice: added Q30 for representation/event decisions;
  Q10 records supplemental Graphviz checks. Q7 still requires a concrete target;
  Q27's byte/work budgets are not satisfied by the new pair-count limit.

- 2026-09-18 — Diagnostics overhaul: Q20 components are logical domains and
  the registry names conditions (operator, numeral, keyword, ambiguous
  numeral warning); Q23 BOM policy decided (skipped); Q22 statement-boundary
  recovery implemented as an opt-in runtime policy with its cost measured;
  Q16 state-size guard raised to 896 B (872 B measured), then lowered to
  640 B once positions became 32-bit (544 B measured). R-DIAG-001 amended.
  Q10 baseline reconciled to Graphviz 16.0.0. Added Q35–Q37 (validation
  policy and mixed graphs, lenient syntax, fix suggestions) as open
  questions with their agreed direction.
- 2026-09-18 — Scanner backends: added Q38 (block scanner as an opt-in
  second implementation; the default was block on vector targets until
  Q39 removed the per-byte tracker and scalar pulled ahead everywhere but
  tiny budgets and long runs); Q16 gains the block-machine guard; Q27's
  contract now accounts lexical credits per backend.
- 2026-09-18 — Lazy positions: added Q39 (offsets only; line and column
  derived on demand); Q16 guards lowered to 512/640 B (368/472 measured);
  R-MEM-008 and R-DIAG-001 amended.

- 2026-09-12 — Q24: removed the premature diagnostic stability exception;
  experimental 0.x now has no backward-compatibility retention requirement.

- 2026-09-12 — Q27: recorded agreement on optional work budgeting, stop
  behavior and factual progress. Linked the execution-contract draft; exact
  operational rules remain a proposed specification, not delivered behavior.

- 2026-09-13 — Q32: ports use compact inline-or-pooled node references,
  raw suffix semantics, explicit occurrence-pool capacities and separately
  budgeted callbacks. Updated current state-size and coverage references.

- 2026-09-13 — Q33: standalone scope occurrence/tree views, explicit nesting
  scratch, depth policy, charged enter/exit events and deferred endpoint semantics.

- 2026-09-20 — Q35/Q38/Q27: unified existing limits, recovery, scanner and
  execution controls under `Policy`, with full runtime parity and policy-bound
  sessions. Fixed specializations keep disabled state/code exclusion; runtime
  sessions select one specialized variant and latch it across yields. Removed
  legacy configuration paths, added migration coverage and benchmark harness;
  standard-machine performance approval and lenient syntax remain pending.

- 2026-09-20 — Q36: implemented independent syntax acceptance, `standard` and
  `lenient` policy presets, source-preserving operator ranges, typed warning/fix
  payloads, factual u32 counters and fixed/runtime/session parity. The shared
  grammar reuses cold scanner failure recognition without new token tags.
  Deviation history, keyword-as-name rules and a warning-volume limit remain
  separate work; this does not resolve the standard-machine performance gate.
