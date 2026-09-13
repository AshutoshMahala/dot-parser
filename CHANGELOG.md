# Changelog

Notable changes to dot-parser. During `0.x`, minor versions may break
compatibility, including diagnostic identities and enum values. Breaking changes
are called out here; compatibility shims are not retained.

## Unreleased

- Support identifier-only edge chains with whole-chain attributes, preserving
  one source statement and every written operator. Add `.edge_chain` traversal,
  separate chain/link pools, checked link slices and an allocation-free pairwise
  edge iterator. Single-edge records remain unchanged; validation merges both
  forms in source order. Continuation events obey work budgets and cancellation.
  Remove the shipped `Feature.edge_chain` detector; fixed callers reserve
  `edge_chains`/`edge_links` capacity. Exhaustive statement switches must handle
  the new variant; no compatibility shim is retained.

- Add `BoundedSession` and compile-time-configurable `FixedSession`: fixed-pool
  parsing with progress snapshots, commit-only documents, zero-credit yielding,
  idempotent results, and explicit cancel/deinit/reset cleanup. No allocation or
  source copy is introduced; sessions may move between non-overlapping calls.
- Add optional cancellation independently of metering, polled before each scan,
  grammar and dispatch step. Cancellation emits no diagnostic and cannot replace
  an obtained failure or successful commit. `ParseOutcome` gains `.cancelled`
  for session results; one-shot APIs never produce it.
- Consolidate the scanner implementation/tests in `lexer.zig`, selecting its
  public Token/Result/Lexer namespace in `root.zig`; remove the facade-only file
  split. Add the execution guide, bounded example, profile benchmark, and consumed
  freestanding checks for all four execution combinations.

- Specialize ordinary lexer entry to its known trivia state, avoiding the
  initial saved-state dispatch on short tokens. Metered scanners still resume
  their saved state, including when switching from bounded calls to `next()`.
  Add entry-invariant/resumption tests and a `bench-lexer` target covering
  punctuation, trivia, keywords/numerals, quotes/comments and longer IDs.
  This is a targeted speedup; mixed-workload tradeoffs are recorded in baselines.

- Extend private compile-time work metering through grammar transitions and
  normal syntax-event attempts, including begin and commit. Retain lookahead
  across owner dispatch without rescanning; count accepted statements/pairs
  separately from capacity reservations. Preserve terminal cleanup and ordinary
  run-to-completion behavior. Add partition, failure, progress and long-input
  tests; pending-work/audit storage compiles out of the ordinary parser.

- Centralize lexer result construction and use an explicit transient completion
  tag for internal transitions. Reduce generated driver stack usage and improve
  ordinary throughput without changing work-credit accounting or public APIs.

- Replace whole-token lexical loops with shared resumable scanning and a
  private compile-time-metered fixture. Preserve existing tokens, spans and
  diagnostics; latch EOF/failures without rescanning. Add boundary-partition,
  source-examination and long-input tests. Public parsing remains
  run-to-completion; this lexical groundwork did not include grammar/event
  metering or cancellation (grammar/event metering is recorded above).
  Shared-state and ordinary-throughput costs are recorded in the baselines.

- Remove obsolete unsupported-feature entries, the unused missing-element
  diagnostic, forward-compatibility-only enum fallbacks, and unimplemented
  validation outcome placeholders. Diagnostic enums now describe current behavior.
- Remove the diagnostic stability exception during experimental `0.x`; WDP
  conformance and current registry consistency remain tested.

- Parse basic attributes: standalone assignments, graph/node/edge attribute
  statements, and node/single-edge lists. Preserve pair order and duplicates;
  flatten adjacent groups without applying defaults or interpreting values.
- Add attribute/assignment/attribute-statement pools and capacity hints, plus
  `max_attributes` for total key/value pairs. Both storage paths share the
  streaming private event contract and abort without exposing partial documents.
- Reuse existing WDP syntax/capacity identities with appended typed contexts
  and resources.
- Add attribute examples, corpus coverage, truncation/failure tests and fuzzing.
  Record the larger retained records and measured smoke-run performance cost.

- Parse `//`, `/* ... */`, and `#` comments without allocation or retained
  trivia. Behavior and Graphviz differences are documented in
  [Supported DOT syntax](docs/SUPPORTED_SYNTAX.md).
- Add `E.Lexer.Syntax.031` with typed `.unterminated` details for block comments
  and quoted identifiers, and construct-specific rendering at the opener.
- Define sequence numbers and aliases together in `diagnostic.Sequence`;
  registry metadata is derived from those pairs.
- Parse numeral and quoted identifiers, including `+` concatenation, into the
  existing compact ranges. Add allocation-free decoding into caller buffers
  or writers; preserve raw spelling and perform no numeric conversion.
- Report malformed quoted concatenation as `E.Lexer.Syntax.003`.
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
