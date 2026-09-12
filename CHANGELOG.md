# Changelog

Notable changes to dot-parser. During `0.x`, minor versions may break
compatibility; deprecations and breaks are called out here.

## Unreleased

- Parse `//`, `/* ... */`, and `#` comments without allocation or retained
  trivia. Behavior and Graphviz differences are documented in
  [Supported DOT syntax](docs/SUPPORTED_SYNTAX.md).
- Add `E.Lexer.Syntax.031` with typed `.unterminated` details for block comments
  and quoted identifiers, and construct-specific rendering at the opener.
- Define sequence numbers and aliases together in `diagnostic.Sequence`;
  existing `Code.Info` fields and published diagnostic identities are unchanged.
- Parse numeral and quoted identifiers, including `+` concatenation, into the
  existing compact ranges. Add allocation-free decoding into caller buffers
  or writers; preserve raw spelling and perform no numeric conversion.
- Report malformed quoted concatenation as `E.Lexer.Syntax.003`; retain legacy
  quoted/numeral feature discriminants for diagnostic compatibility.
- Escape non-ASCII/control bytes in console source excerpts and align their
  underlines without Unicode tables. See supported syntax for newline and
  byte-handling policies and the scope of Graphviz verification.

## 0.1.0 — 2026-07-18

First tagged release: an end-to-end DOT subset from bytes to a validated,
borrowed syntax document.

### Language

- Root documents of both kinds: `graph` (exposed as `undigraph`) and
  `digraph`, with optional `strict` and optional bare-ASCII graph names.
- Node statements and single-edge statements with `--`/`->`; statement
  semicolons optional, as in Graphviz.
- Keywords are case-independent and reserved in every position (verified
  against Graphviz 15.1.0).
- Every deferred DOT construct (subgraphs, attributes, edge chains,
  quoted/numeral/HTML/non-ASCII identifiers, comments, ports) is
  recognized and reported as a typed unsupported-feature diagnostic, not a
  generic syntax error. The full table: `docs/SUPPORTED_SYNTAX.md`.

### API

- `parseBorrowed` / `validate` / `parseAndValidate` façade returning
  result structs; documents are borrowed views over caller-owned source.
- Kind-agnostic parsing with validation as a separate policy pass (edge
  operator vs. document kind).
- Fixed-memory path: `parseBorrowedIn` with caller-owned pools and
  compile-time-sized `FixedDocumentStorage`; no allocator, no `deinit`.
- Uniform reporting surface: small outcome values plus caller-owned
  diagnostic sinks (`FixedDiagnosticBag` or bring-your-own); WDP
  structured codes with typed payloads (`docs/OUTCOMES.md`).
- Out-of-the-box console renderer: message-first boxes with annotated
  source excerpts, opt-in ANSI severity colors and verbose WDP identity;
  ASCII style for plain terminals.

### Quality

- Portable static library by default; builds for freestanding targets
  (riscv32, Cortex-M0+) with no OS, filesystem, or network dependency.
- Corpus test suite with per-fixture expectations, fuzz harness with
  determinism checks, runnable examples, and recorded performance
  baselines (`docs/BASELINES.md`).
