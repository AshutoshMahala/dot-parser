# Open design decisions

Last reconciled: 2026-09-18 (non-ASCII bare identifiers).

Split out of `REQUIREMENTS.md` §16 (2026-07-18). Question numbers (Q1–Q39)
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
the intended contract, while [supported syntax](../SUPPORTED_SYNTAX.md) is
authoritative for what the current release actually processes.

---

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
No numeric accounting changes. *(Embodied: `src/location.zig`,
`src/lexer/`, `src/console.zig` `Positions`; R-MEM-008 and R-DIAG-001
amended.)*

**Q38 — Which scanner backend is the default, and how is a backend chosen?**
**Decided (2026-09-18):** two implementations behind one interface, selected
at compile time: the scalar byte-at-a-time scanner on every target, with
the block scanner (64-byte vector classification into bit masks, tokens
extracted from the masks, backslash parity carried across blocks) opt-in
through a root file's `dot_parser_options.lexer_backend`. Evidence at the
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
also the differential oracle: the equivalence tests in `src/lexer/lexer.zig`
(fixtures, truncations, block shifts, random streams with 64- and 32-bit
draws, budget partitions) found two block-scanner bugs before release, and
the whole suite runs on wasm32 with and without simd128 under Node's WASI.
The execution contract accounts credits per backend. *(Embodied:
`src/lexer/`; R-MOD-010, Q16, Q27.)*

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
*(Embodied: `src/parser.zig`, `src/syntax.zig`, `src/scratch.zig`,
`tests/subgraph_endpoints.zig`, `docs/SUBGRAPHS.md`.)*

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
membership remains deferred. *(Embodied: `src/syntax.zig`, `src/scratch.zig`, `src/parser.zig`,
`tests/subgraphs.zig`, `docs/SUBGRAPHS.md`.)*

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
`src/syntax.zig`, `src/parser.zig`, `tests/ports.zig`, `examples/ports.zig`.)*

**Q31 — How are identifier-only edge chains retained and budgeted?**
Keep ordinary edge records unchanged. A separate chain owner contains the first
edge and a compact range into continuation links. Each continuation retains its
written operator/range and right endpoint; no temporary chain list or eager
edge/node expansion is built. Whole-chain attributes are stored once. Each link
callback is a separately charged event; one accepted owner increments completed
statements once. The public allocation-free edge iterator offers a pairwise view
without changing retained syntax. Fixed capacities bound chain owners and
continuations independently; statement limits do not bound chain length.
Subgraph endpoints are covered by Q34; ports are covered by Q32. *(Embodied: `src/syntax.zig`,
`src/parser.zig`, `tests/edge_chains.zig`, `tests/sessions.zig`.)*

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
`src/parser.zig`, `src/syntax_event.zig`, `src/syntax.zig`, `tests/attributes.zig`.)*

**Q2 — Is the primary public result a syntax AST, an event stream, or equal
support for both?**
Both, layered: the borrowed `Document` is the public result; the syntax-event
stream is the internal seam between parser and builders, kept private until at
least two vertical slices exercise it. *(Embodied: `src/root.zig` façade,
`src/syntax_event.zig`.)*

**Q3 — Must the AST preserve comments, exact quoting, whitespace, and
separators for lossless source reproduction?**
Not in version 1. Trivia and source preservation are the slice-7 tooling
representation; compact ranges keep the door open without paying for it now.
*(Embodied: `location.Range` design; non-goals §14.)*

**Q4 — Does validation reject a mismatched edge operator immediately, or may
a tolerant parsing mode retain it and report a diagnostic?**
Tolerant by design: the parser is kind-agnostic (both operators always parse,
the written operator is preserved), and the kind×operator legality rule lives
solely in validation, which reports every independent mismatch in source
order. Sink filtering changes reporting, not `document_valid`. Consumers may
parse without validation or apply their own acceptance policy; configurable
validation-rule policy is not implemented yet. *(Embodied: `src/parser.zig`,
`src/validate.zig`, corpus.)*

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
**Verification pending:** automate the differential harness against the
pinned reference and record exceptions explicitly; notes first verified by
running 15.1.0 keep that attribution until the harness re-runs them.
*(Embodied: `src/lexer/`, compatibility notes, corpus; R-ROB-004.)*

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
*(Embodied: `src/diagnostic.zig`; R-DIAG-001 as amended.)*

**Q21 — Are any analysis passes worth an optional parallel implementation?**
Not now. Concurrency stays external to the core (R-ARCH-008/R-CON-004);
revisit only after profiling demonstrates value. *(Embodied: no threading
anywhere; frozen documents are share-safe per R-CON-003.)*

**Q25 — What exact deterministic ordering is promised?**
For the current public API, statements and per-kind pools preserve source
order, and diagnostics follow deterministic source/emission order. Repeated
runs with the same input and configuration promise semantic equality, not
literal byte identity of whole structs (padding is not part of the contract).
Existing tests and fuzz checks cover outcome classes, statement order and
pools including borrowed ranges, and diagnostic codes, positions, and feature
payloads. New public payloads must extend that coverage as they arrive.
Future merged-fragment, `DotIR`, and serialized-output APIs must define their
own ordering before publication; their absence does not leave the current
contract undecided. *(Embodied: `src/syntax.zig`, `src/validate.zig`,
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
*(Embodied: `src/syntax_event.zig`, builder abort paths; R-MOD-011.)*

---

## Partially decided

**Q1 — Is version 1 the complete documented DOT grammar or a named subset?**
Direction: the complete documented grammar, reached through vertical slices;
every interim release documents its exact supported subset. The end-state
compatibility statement is written when the slices land. *(Embodied: README
"First goal"; `tests/corpus/unsupported/` tracks the boundary.)*

**Q12 — What default security limits apply to convenience APIs?**
`max_statements` exists and is caller-visible, but defaults to unlimited;
whether convenience APIs should ship with non-trivial defaults is open.
*(Embodied: `ParseOptions.max_statements`.)*

**Q16 — What size thresholds establish that disabling a feature removed its
cost?**
Parser-state size is regression-guarded (≤ 512 B with the scalar scanner, currently 368 B native with offset-only positions; ≤ 640 B with the block scanner, 472 B measured) and baselines exist;
per-profile binary-size thresholds await the profile work. *(Embodied:
`docs/BASELINES.md`; parser-size test.)*

**Q17 — What exact boundary separates the syntax tree from `DotIR`, and
which lowering passes are in version 1?**
The document side is now concrete: source-shaped, source-ordered, no
deduplication, no implicit nodes, no attribute semantics. The `DotIR` side
(passes, storage) is open until slice 7. *(Embodied: `src/syntax.zig`.)*

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
constructs stop at a deferred boundary; their bodies have not been validated.
A leading UTF-8 BOM is skipped, matching Graphviz's scanner (decided
2026-09-18); elsewhere its bytes are identifier content, including when
decoding an extracted identifier starting with those bytes. **Still open:**
whether version 1 ships a UTF-8 validator and its invalid-sequence policy,
and HTML-like ID validation. Resolve these as lexical support grows;
they are not all promised
deliverables of the next slice. *(Embodied: `src/lexer/`,
[supported syntax](../SUPPORTED_SYNTAX.md); R-PORT-006.)*

**Q24 — When will the first stable compatibility boundary be declared?**
`v0.1.0` shipped after slice 2 (directed documents). It is a useful experimental
release, not a source-API stability declaration. The stable boundary and its
criteria remain open. There is no compatibility guarantee for source APIs,
diagnostic identities, payload discriminants or retained layouts during this
experimental phase. Obsolete entries and compatibility-only scaffolding are
removed; WDP conformance and current registry consistency remain required. *(Embodied: `CHANGELOG.md`,
`build.zig.zon`, `src/root.zig`; R-ARCH-009/R-DIAG-005.)*

**Q26 — Which named profiles are public conveniences?**
Decision in principle: named profiles first (`micro`/`core`/`full`),
custom feature structs later, and common consumer types stay non-generic.
Implementation awaits the profile slice. *(Embodied: DX design discussion,
2026-07-17.)*

**Q27 — Which progress budgets does the bounded driver support, and what
work unit is deterministic?**
**Agreed policy:** metering and cancellation are optional capabilities; bounded
execution uses deterministic work units, with source progress reported
separately. Yield preserves continuation/staged data without abort; cancellation
is terminal. Keep the stage-based architecture and expose factual progress, not
a whole-pipeline percentage.
**Implemented execution contract:** [contract](../architecture/EXECUTION_CONTRACT.md)
defines charged scan/grammar/dispatch microsteps, zero/one-credit behavior,
callback exclusions and terminal cleanup, cancellation precedence, source
frontier semantics, and acceptance tests. `BoundedSession` now provides public
fixed-storage bounded parsing. `FixedSession` independently selects metering and
cancellation; the hook is a borrowed context/non-failing predicate pair. Explicit
cancel/deinit cleans up abandoned work, and reset reuses pools after cleanup.
Partition, cancellation-boundary, failure-precedence, lifetime and freestanding
checks accompany the API. Ordinary-path and optional costs are recorded in
`docs/BASELINES.md`. Public pull events, streaming input, total-operation work
limits and bounded validation remain outside this implemented slice.
*(R-MOD-010/R-MOD-013; `root.FixedSession`, `parser.Machine`, `lexer.Scanner`.)*

**Q22 — Which grammar boundaries are safe recovery points, and what is the
measured binary-size cost of recovery support?**
**Implemented (2026-09-18):** statement boundaries are the sync points. With
the runtime policy `recovery = .statements` (default `.fail_fast`, per
R-FUNC-007), a syntax error inside the body aborts the sink once, the parser
skips to the next `;` or `}` at the same brace depth (skipped `{` are matched
by counting), and every later syntax error is reported through the same bag.
No document is ever published; the outcome stays `invalid_syntax`. Lexical
errors resume after the malformed bytes; unterminated quotes/comments, header
errors, end of input, trailing tokens, limits and deferred features remain
terminal. Measured: renderer-free ReleaseSmall examples grew by 350–650 B and
ordinary throughput did not change, so compile-time exclusion is not yet
warranted (R-FUNC-007's "material" threshold). **Still open:** a caller-
provided diagnostic limit that ends recovery early (R-FUNC-007, R-SEC-002),
the per-class abort/report/ignore policy, and lenient acceptance of
unambiguous deviations as warnings. *(Embodied: `parser.Recovery`,
`ParseOptions.recovery`, `tests/diagnostics.zig`; R-FUNC-007, R-DX-002.)*

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
Gated on slice 9 (execution profiles: observers, cancellation, drivers).

**Q14 — Which syntax features are compile-time selectable, and which remain
in every parser profile?**
Gated on the profile slice.

**Q15 — Does the smallest profile retain unsupported-feature detectors, or
prefer the absolute smallest binary?**
Gated on the profile slice; the current default keeps the detectors
(R-MOD-006).

**Q28 — Does version 1 provide lazy semantic lowering only, or also a lazy
syntax index over retained source?**
Open; nothing currently forces the choice.

**Q35 — Which validation policy does the library expose, and how are mixed
graphs represented?**
Open. Direction: the document records the declared kind and the observed
operator usage as facts; a runtime validation policy reads the `graph`
keyword as undirected or generic, sets the mismatch rule's severity, and
chooses how a mismatched operator is read; no third declared kind. Defaults
stay strict. Design and the end-user policy guide follow implementation.

**Q36 — Which syntax deviations may be accepted leniently, and how are they
reported?**
Open. Direction: only deviations with one reading (empty statement, over-long
operator, bare dash, keyword as a name), each configurable as reject, warn or
accept per R-FUNC-007 and reported with `W.Syntax.*` codes. Everything
ambiguous stays an error or a recovery point.

**Q37 — How are fix suggestions carried on diagnostics for linters?**
**Implemented (2026-09-18):** `Diagnostic.fix: ?Fix` — a span, a typed edit
(`delete`, `replace`, `insert_before`, `insert_after`, `wrap_in_quotes`), a
`Replacement` enum whose `text()` is the only source of replacement bytes,
and an `Applicability` of `machine_applicable` (the one correct repair) or
`maybe` (a plausible repair, or a guessed position). Producers: the scanner
(over-long and spaced operators), the parser (a lone
`-` coerced to the declared kind, quoting a keyword, stray `;`, `}` or
operator, separators, missing `=`, `]`, `}` and `{`, header typos, `=>`,
unterminated constructs) and validation (operator mismatch, `maybe` because
changing the keyword is equally plausible). `Diagnostic` is 112 B with the
field (32-bit positions); a 32-slot bag is 3.6 KB. The lean-diagnostics profile that would compile the
field out stays with the profile slice. *(Embodied: `diagnostic.Fix`,
`tests/diagnostics.zig` round trip; R-DX-007, R-FUNC-005.)*

---

## Reconciliation log

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
