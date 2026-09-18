# Changelog

Notable changes to dot-parser. During `0.x`, minor versions may break
compatibility, including diagnostic identities and enum values. Breaking changes
are called out here; compatibility shims are not retained.

## Unreleased

Diagnostics overhaul, driven by an external probe of 79 malformed inputs.
Breaking (0.x): every structured code changes, `Details` gains variants, and
`DocumentStorage` pools are all optional.

### Changed

- WDP components are now logical domains, not source modules: `Syntax`,
  `Validation`, `Resource`, `Profile`. `E.Lexer.*` and `E.Parser.*` are gone;
  filter on `E.Syntax.*` for every malformed-input problem. New primaries name
  the failure domain: `E.Syntax.Byte.003`, `Operator.003`, `Numeral.001`,
  `Token.032`, `Concatenation.003`, `Grammar.003`/`031`, `Keyword.003`.
  Compact IDs change accordingly.
- Malformed operators (`a - b`, `a - > b`, `-->`) and incomplete numerals
  (`.`, `-.`) are their own conditions with their own payloads, no longer
  "invalid byte"; the payload names the shape (lone, over-long, spaced) and
  a spaced operator is one diagnostic over the whole `- >`. A stray `>`
  says to write `->`.
- A reserved keyword where a name was needed, or `node`/`edge`/`graph` without
  its `[` list, is `E.Syntax.Keyword.003` with the keyword and context; the
  hint says to quote it.
- Every console hint is derived from the payload: the grammar rule that was
  broken per parse context and token found (attribute list before the operator,
  ports on subgraphs, a second graph, `strict` after the kind, a comma between
  statements, …), "did you mean 'digraph'" for header typos, byte-specific
  advice for stray bytes. The stale milestone-grammar hint is gone.
- Expected sets collapse statement starters and the two edge operators into
  "a statement" and "an edge operator".
- An open `[` list is annotated whenever a token that cannot belong to a list
  is found, not only at end of input.
- End of input inside a scope points at a suspect `}` when one closed a scope
  at a smaller indentation than the line that opened it
  (`Unexpected.suspect`, role `misindented_close`).
- The compact renderer says "byte column".
- The differential compatibility baseline is Graphviz 16.0.0 (was 15.1.0);
  the BOM, stray-semicolon and numeral-ambiguity behaviours were checked
  against its `grammar.y` and `scan.l`.
- Several annotations on one excerpt line share a single mark row: the
  rightmost label stays inline, the others hang below from a `┬` junction
  and `└────` connector, leftmost lowest so connectors never cross labels.
  Overlapping spans keep one row each.
- A leading UTF-8 byte order mark is skipped, as Graphviz does.

### Added

- `Diagnostic.fix`: a typed, allocation-free repair (span, edit, replacement
  enum, applicability) on every diagnostic whose producer knows the one
  edit that fixes it — operators, keyword quoting, stray tokens, missing
  closers, header typos, `=>`, unterminated constructs and operator
  mismatches. `machine_applicable` fixes may be applied
  unattended; `maybe` fixes are offers. Both renderers print them.
  `Diagnostic` grows from 152 to 200 bytes.
- `W.Syntax.Numeral.033`: numerals running into a letter or second dot
  (`1e3`, `1.2.3`) warn, matching Graphviz, and the parse continues. First
  use of the warning severity.
- `ParseOptions.recovery = .statements` (also fixed and session options):
  after a body syntax error, resynchronize at `;`/`}` and keep reporting
  syntax errors. Still no document, one abort, `invalid_syntax`.
- `measure` / `measureIn`: count-only dry run returning the exact
  `DocumentCapacities` for a source, for arena hints and fixed-pool sizing.
- `Document.rootStatementCount()`; `statementCount()` is documented as
  counting every scope.
- `examples/check_file.zig`: command-line checker with recovery and the
  console renderer.
- Diagnostics regression table (`tests/diagnostics.zig`) and measure
  verification (`tests/measure.zig`).

### Fixed

- `DocumentStorage` no longer requires three pools while defaulting the rest:
  every pool defaults to empty.

## 0.2.0 — 2026-09-14

Expand the borrowed syntax parser with comments, quoted/numeral identifiers,
basic attributes, edge chains, ports and nested subgraphs, including subgraph
endpoints. Add fixed-storage resumable parsing with optional work metering and
cooperative cancellation. This is an experimental, breaking minor release;
see the [0.2.0 release and migration notes](docs/RELEASE_0.2.0.md).

### Added and changed

- Support named/anonymous subgraphs as either edge endpoint and in mixed chains,
  including nested endpoint edges. Retain syntax, never eager node-set expansion.
  Breaking API: statement/iterator edges use `EdgeView` with `Endpoint` values;
  chain views use `edgeLinks(chain)` / `edgeLinkCount(chain)`. Node-only raw pools
  retain their record sizes. New `scoped_edges` / `scoped_edge_links` capacities
  isolate generalized storage; node-only prefixes are promoted without copying.
  Endpoint scopes do not add standalone statement entries. Scope records gain a
  subtree boundary; explicit scratch frames now retain suspended outer-edge state.
  Remove `Feature.subgraph_endpoint`; malformed endpoints are syntax errors.
  Preserve operator-order validation, bounded work, cancellation and commit-only
  publication. Add endpoint guide/example, prefix and failure-path tests.

- Support named, anonymous and nested standalone subgraphs using compact scope
  records and iterative parsing/traversal. Preserve all global statements; expose
  direct/recursive scope statements, edges and written node references, plus
  `statements().nextScoped()` for containing-scope context. No semantic name
  merging, defaults, membership indexes or edge-product expansion.
  Breaking API: statement unions gain `.subgraph`; fixed parse/session calls take
  `ParseMemory { document, scratch }`. Reserve `.subgraphs` and explicit
  `FixedParseScratch` nesting frames; no legacy overload is retained.
  Allocator callers may supply a separate `scratch_allocator`. Add `max_nesting`
  and typed depth/scratch/scope-pool capacities; remove the deferred-feature
  boundary for standalone subgraphs. Entry/exit obey work budgets,
  cancellation and commit-only output. Add scope guide, example and benchmark.

- Support raw port suffixes on node statements and all edge/chain endpoints.
  Use compact inline-or-pooled references: 8-byte handles and a separate
  28-byte qualified-occurrence pool, with checked `Document.nodeReference` views.
  Breaking API: `NodeStatement.identifier` becomes `reference`; edge/link
  endpoints are `NodeReference`, not direct ranges. Use the view's `identifier`
  with text/decoding helpers. Fixed callers reserve `ported_references`; allocator
  callers can hint it. No compatibility aliases or attachment resolution.
  Remove `Feature.port_or_compass`; add typed port capacity resources, colon
  expectations, port-component context and related suffix-start locations.
  Suffix scans, grammar transitions and callback dispatch obey existing work
  budgets and cancellation. Update examples, ownership and execution docs.

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
