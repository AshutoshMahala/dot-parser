# Open design decisions

Last reconciled: 2026-09-12 (comments, identifiers, and basic attributes).

Split out of `REQUIREMENTS.md` §16 (2026-07-18). Question numbers (Q1–Q30)
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

**Q30 — How does the first attribute slice retain groups and deliver pairs?**
Adjacent bracket groups are flattened into one ordered pair sequence, preserving
written duplicate keys but not group boundaries or empty-list presence. Node,
edge and attribute statements reference a shared pair pool; assignments have a
separate pool. The private event seam streams pairs before their owner statement;
abort discards staged data and no partial document escapes. Both storage paths
have explicit capacities for all six pools. `max_attributes` counts all pairs,
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
The written DOT specification is primary; Graphviz 15.1.0 is the current
differential reference, not an instruction to reproduce every implementation
quirk. Intentional differences are listed in
[supported syntax](../SUPPORTED_SYNTAX.md), including standalone-CR comment
termination and whole-document consumption. Keywords, numeral IDs, and quoted
IDs and basic attributes are implemented; non-ASCII bare IDs remain deferred.
Additional identifier and attribute probes used the locally available Graphviz 16.0.0, separately labeled in the
compatibility notes. **Verification pending:** automate the differential
harness against the pinned reference and record exceptions explicitly.
*(Embodied: `src/lexer.zig`, compatibility notes, corpus; R-ROB-004.)*

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
`nshash-codehash`); components are internal modules (`Lexer`, `Parser`,
`Validation`, `Resource`, `Profile`); sequences follow the part 6 conventions
(001 MISSING, 002 MISMATCH, 003 INVALID, 009 UNSUPPORTED, 026 EXHAUSTED,
031+ project-specific). Sequence numbers and aliases are defined together in
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
Parser-state size is regression-guarded (≤ 416 B; currently 400 B native) and baselines exist;
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
them; 8-byte compact ranges with a checked 4 GiB domain. u16/u24 variants
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
encoding; NUL is rejected. Non-ASCII bare identifier runs (bytes 0x80–0xFF plus
identifier continuation bytes) are reported as deferred, not decoded or
accepted identifiers. Outside comments and quoted content, control bytes other
than supported whitespace are invalid when reached by the lexer. HTML-like
constructs stop at a deferred boundary; their bodies have not been validated.
**Still open:** timing and exact policy for non-ASCII identifier support, BOM
handling, whether version 1 ships a UTF-8 validator and its invalid-sequence
policy, and HTML-like ID validation. Resolve these as lexical support grows;
they are not all promised
deliverables of the next slice. *(Embodied: `src/lexer.zig`,
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
**Implemented groundwork:** a nonterminal `step` asks the lexer for one token
and advances the parser; terminal calls are idempotent. Grammar continuation
state lives in the machine. **Not a bounded-work guarantee:** that lexer call
can scan a long identifier, whitespace region, or comment before returning.
A token count therefore does not bound bytes examined or cancellation latency.
**Still open:** budget vocabulary, deterministic byte/work accounting, and
cancellation safe points. Strict bounded pumping requires resumable lexical
scanning as well as parser stepping; yield must remain distinct from terminal
cancellation. No public bounded/cancellation driver ships yet.
*(Embodied: `parser.Machine.step`, `lexer.skipTrivia`; R-MOD-010/R-MOD-013.)*

---

## Open

**Q7 — What are the target RAM, flash, maximum token, maximum nesting, and
document-size budgets for the first embedded profile?**
Gated on choosing the target board and build configuration (R-PORT-002).
Interim: `FixedDocumentStorage.byte_size`, `max_statements`, and
`max_attributes` give callers their own output budgeting.

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

**Q22 — Which grammar boundaries are safe recovery points, and what is the
measured binary-size cost of recovery support?**
Direction sketched — statement boundaries (`;`, `}`) are the natural sync
points, and recovery reuses the same reporting surface (bag gains entries) —
but design and measurement belong to a dedicated recovery slice.

**Q28 — Does version 1 provide lazy semantic lowering only, or also a lazy
syntax index over retained source?**
Open; nothing currently forces the choice.

---

## Reconciliation log

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

- 2026-09-12 — Q24: removed the premature diagnostic stability exception;
  experimental 0.x now has no backward-compatibility retention requirement.
