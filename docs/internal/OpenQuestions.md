# Open design decisions

Split out of `REQUIREMENTS.md` §16 (2026-07-18). Question numbers (Q1–Q29)
are stable: they are never renumbered, deleted, or reused, and new questions
append with fresh numbers. Answered questions are not removed — the
**Decided** section doubles as the project's decision log, each entry naming
where the decision is embodied.

Status meanings:

- **Decided** — settled; changing it is a deliberate reversal, not drift.
- **Partially decided** — a direction or first slice exists; the rest stays open.
- **Open** — genuinely undecided; usually gated on a future slice.

---

## Decided

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
order. Consumers may filter the diagnostic class at their sink for dialect
tolerance. *(Embodied: `src/parser.zig`, `src/validate.zig`, corpus.)*

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

**Q19 — Does version 1 support parsing independently supplied fragments?**
No — whole documents only. R-MEM-007's merge semantics remain the contract
for whenever fragments arrive. *(Embodied: façade surface.)*

**Q20 — Which WDP component, primary namespaces, sequence ranges, and catalog
conformance level will the project publish?**
Namespace `dot_parser` (WDP part 7, fully qualified compact IDs
`nshash-codehash`); components are internal modules (`Lexer`, `Parser`,
`Validation`, `Resource`, `Profile`); sequences follow the part 6 conventions
(001 MISSING, 002 MISMATCH, 003 INVALID, 009 UNSUPPORTED, 026 EXHAUSTED,
031+ project-specific); registry uniqueness, format validity, and compact-ID
collisions are test-enforced against the official WDP test vectors.
*(Embodied: `src/diagnostic.zig`; R-DIAG-001 as amended.)*

**Q21 — Are any analysis passes worth an optional parallel implementation?**
Not now. Concurrency stays external to the core (R-ARCH-008/R-CON-004);
revisit only after profiling demonstrates value. *(Embodied: no threading
anywhere; frozen documents are share-safe per R-CON-003.)*

---

## Partially decided

**Q1 — Is version 1 the complete documented DOT grammar or a named subset?**
Direction: the complete documented grammar, reached through vertical slices;
every interim release documents its exact supported subset. The end-state
compatibility statement is written when the slices land. *(Embodied: README
"First goal"; `tests/corpus/unsupported/` tracks the boundary.)*

**Q10 — What compatibility baseline defines correct behavior?**
The written DOT specification is primary (case-independent keywords,
`\200–\377` identifier bytes, and the numeral grammar are implemented from
it). Differential testing against a pinned Graphviz release is still to be
chosen. *(Embodied: lexer follows the spec; R-ROB-004 differential tests
pending.)*

**Q12 — What default security limits apply to convenience APIs?**
`max_statements` exists and is caller-visible, but defaults to unlimited;
whether convenience APIs should ship with non-trivial defaults is open.
*(Embodied: `ParseOptions.max_statements`.)*

**Q13 — What language-specific policy governs raw pointers, unchecked
blocks, integer casts, and dependency review?**
Practice is established — no unsafe patterns, checked narrowing with
justifying comments, asserts as documented traps in safe builds, zero
dependencies — but it is not yet written down as a policy document.

**Q16 — What size thresholds establish that disabling a feature removed its
cost?**
Parser-state size is regression-guarded (≤ 320 B) and baselines exist;
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
Version 1 stays byte-oriented: bytes 0x80–0xFF are reported as the deferred
non-ASCII identifier feature with full-run spans; NUL and other control
bytes are invalid input. The validator and BOM policy land with slice 3
(lexical completeness). *(Embodied: `lexer.nonAsciiIdentifier`.)*

**Q24 — When will the first stable compatibility boundary be declared?**
Plan: tag `v0.1.0` after slice 2 (directed documents) — not a stability
declaration, but the first version claiming general usefulness. The stable
boundary itself remains future. *(Embodied: versioning discussion,
2026-07-18.)*

**Q25 — What exact deterministic ordering is promised?**
Statements and diagnostics are in source order; repeated runs are
semantically identical over an enumerated set of stable properties, each
test- and fuzz-verified: outcome class, statement order/node/edge pools
(including borrowed ranges), and diagnostic codes, positions, and feature
payloads. Literal byte identity of whole structs is deliberately not
claimed — it would drag padding and other representation details into the
contract. Ordering for merged fragments and serialized output is not
applicable yet. *(Embodied: validation/corpus/fuzz determinism tests.)*

**Q26 — Which named profiles are public conveniences?**
Decision in principle: named profiles first (`micro`/`core`/`full`),
custom feature structs later, and common consumer types stay non-generic.
Implementation awaits the profile slice. *(Embodied: DX design discussion,
2026-07-17.)*

**Q27 — Which progress budgets does the bounded driver support, and what
work unit is deterministic?**
The work unit is decided and implemented: one `step` = one token, with
terminal-idempotent stepping and all continuation state in the machine.
The budget vocabulary (`max_tokens`, byte budgets) is open. *(Embodied:
`parser.Machine.step`.)*

---

## Open

**Q7 — What are the target RAM, flash, maximum token, maximum nesting, and
document-size budgets for the first embedded profile?**
Gated on choosing the target board and build configuration (R-PORT-002).
Interim: `FixedDocumentStorage.byte_size` and `max_statements` give callers
their own budgeting.

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

**Q29 — Which sinks require transactional staging, and is a standard staging
sink worth its memory and binary cost?**
Open. The event contract documents that staging is the sink's own
responsibility (R-MOD-011); no standard staging sink is planned yet.
