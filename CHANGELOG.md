# Changelog

Notable changes to dot-parser. During `0.x`, minor versions may break
compatibility, including diagnostic identities and enum values. Breaking changes
are called out here; compatibility shims are not retained.

## Unreleased

- Recover statement-heavy fixed-policy parsing throughput by inlining synchronous
  grammar boundaries, eliminating intermediate result copies. Runtime policies
  and metered/cancellable execution retain ordinary calls; checks, factual counters,
  diagnostics and storage layouts are unchanged.
- Add `presets.standard` and `presets.lenient` as ordinary, complete policy values.
  Lenient changes only syntax acceptance; defaults stay unchanged. Each empty
  statement, exact long operator (`---`/`-->`), and bare dash has independent
  reject/warn/accept policy with full compile-time/runtime and session parity.
  Bare dashes use the written graph keyword; normalization retains source ranges.
- Add factual u32 `accepted_deviations` and `warnings` to parse, measure and
  session results/progress; composed checks total syntax and validation warnings.
  Counts survive suppression and later failures. New syntax warnings carry
  typed assumptions and machine-applicable fixes, without per-edge history.
  `invalid_syntax` now explicitly means rejected by the selected syntax policy,
  rather than claiming rejection by every possible DOT dialect.

- Add experimental graph policy profiles: independent `graph`/`digraph` rules,
  `graph.treated_as` (`undigraph`, `digraph`, `generic`, `auto`), error/warning/off
  severity, and source-preserving `.conform_to_kind` interpretation. Runtime
  overrides are opt-in; fixed profiles validate configuration at compile time.
- Add `validatePolicy`, typed configuration failures before DOT processing,
  `W.Validation.Operator.002`, validation warning counts and policy-aware fixes.
- Unify nesting/statement/attribute limits, recovery, scanner selection, metering
  and cancellation in the same typed policy, with full compile-time/runtime
  parity. Fixed profiles specialize the shared engine; runtime profiles resolve
  once per operation/session initialization without per-token policy merging.
- Add policy-bound `Profile.Session`: settings stay latched across yields,
  invalid resets leave existing work intact, and completed results can be
  validated/interpreted under the bound policy. `BoundedSession` remains a
  metered fixed-profile convenience. Cancellation-enabled one-shot parsing and
  measurement may now return `.cancelled`, with no document/capacity publication.
- **Breaking:** move parse-option limits/recovery into `Policy`; replace
  `FixedSession(ExecutionFeatures)` with `Profile(...).Session`; replace the
  root-file `dot_parser_options.lexer_backend` hook with `Policy.scanner`
  (`lexer.For` for direct lexical use). Storage, allocator hints and cancellation
  callbacks remain explicit resources. Runtime-profile parse/measure methods
  now return a policy error union instead of aliasing infallible default methods.
- Remove retired parser/validator wrappers, duplicated parser options, root-hook
  detection and compatibility-only tests. Scanner types use `ScannerBackend`;
  inspect `Profile.baseline.scanner` for the resolved choice. The old
  `lexer.Backend`, `lexer.backend` and `lexer.default_backend` aliases are removed.
- **Breaking:** public `GraphKind` now describes effective kinds, including
  `.generic`. Use `DeclaredGraphKind` for the original two-valued `Document.kind`.
  Syntax leniency is not yet implemented. See [Parsing and graph policies](docs/POLICIES.md).

## 0.3.0 — 2026-09-19

Improve diagnostics and tooling, support non-ASCII bare identifiers, and reduce
position-tracking overhead. Add opt-in statement recovery, typed fix suggestions,
exact pool measurement and a block scanner alongside the scalar default.
This is an experimental, breaking minor release. HTML-like identifiers
and the planned markup subsystem are deferred until after this release.

### Changed

- Removed `diagnostic.Feature.non_ascii_identifier` now that the feature is
  supported, following the experimental `0.x` policy. HTML identifiers remain
  the only deferred lexical feature.
- Positions are byte offsets only. `Span` is `{ start: u32, len: u32 }`,
  eight bytes, and `Range` is the same type; `Diagnostic.span.start`,
  `Fix.span`, `Related.span`, token and event spans no longer carry a line
  or column. Derive them from the source when showing a position:
  `span.locate(source)` for one, `location.PositionCursor.locate` for many
  (any order; one shared scan when ascending). `Range.fromSpan`, `toSpan`
  and `PositionCursor.spanFor` are gone. `console.render` takes
  `RenderOptions`; with `source` set, every renderer prints line and byte
  column exactly as before, and without it prints the offset.
- Sources are limited to `2^32 - 1` bytes and refused before scanning when
  oversized (`resource_exhausted` / `source_range`). Remove the former
  `StorageFailure.source_offset_overflow` switch branch. The lexer result no
  longer carries a diagnostic by value: use `Lexer.failureDiagnostic()` to
  obtain it and `Lexer.takeWarning()` to consume warnings when lexing directly.
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
- The lexer lives in `src/lexer/` (`lexer.zig`, `token.zig`, `scalar.zig`,
  `block.zig`), the first subsystem to take a directory of its own.
- The differential compatibility baseline is Graphviz 16.0.0 (was 15.1.0);
  the BOM, stray-semicolon and numeral-ambiguity behaviours were checked
  against its `grammar.y` and `scan.l`.
- Several annotations on one excerpt line share a single mark row: the
  rightmost label stays inline, the others hang below from a `┬` junction
  and `└────` connector, leftmost lowest so connectors never cross labels.
  Overlapping spans keep one row each.
- A leading UTF-8 byte order mark is skipped, as Graphviz does.

### Added

- Non-ASCII bare identifiers in all ID positions: bytes 0x80–0xFF may start
  or continue an identifier, with exact spelling preserved by both scanners,
  bounded sessions and explicit decoding. No UTF-8 validation, normalization,
  allocation or retained-layout changes. A document's leading BOM is still
  skipped; BOM bytes inside an identifier are preserved. `Lexer.initRaw`
  provides token scanning without document-level BOM handling for decoding.
- `Diagnostic.fix`: a typed, allocation-free repair (span, edit, replacement
  enum, applicability) on every diagnostic whose producer knows the one
  edit that fixes it — operators, keyword quoting, stray tokens, missing
  closers, header typos, `=>`, unterminated constructs and operator
  mismatches. `machine_applicable` fixes may be applied
  unattended; `maybe` fixes are offers. Both renderers print them.
  `Diagnostic` is 80 bytes on the measured native target with the field and
  offset-only spans; see [baselines](docs/BASELINES.md).
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
- A second scanner, `src/lexer/block.zig`: it classifies 64-byte blocks into
  bit masks with vector compares (byte classes, newlines, quotes with
  backslash parity carried across blocks, comment delimiters) and extracts
  tokens from the masks, behind the same resumable interface as the
  byte-at-a-time scanner (now `src/lexer/scalar.zig`). `src/lexer/lexer.zig`
  selects the backend at compile time: the scalar scanner unless a root
  file's `pub const dot_parser_options = .{ .lexer_backend = .block };`
  says otherwise; `dot.lexer.backend` reports the choice, and every bench
  takes `-Dlexer=scalar|block`. Differential tests hold both backends to
  identical tokens, spans, diagnostics, fixes, warnings and resume positions
  on fixtures, every truncation and block shift, random streams and budget
  partitions. The execution contract defines a lexical credit per backend:
  one byte or EOF examination for the scalar scanner; one block
  classification or one bounded advance inside the block for the block
  scanner, whose `source_frontier` moves a block at a time.

### Performance

The [0.3.0 baseline](docs/BASELINES.md#030-baseline-2026-09-19) compares the
unchanged release implementation with 0.2.0 on the project's standard benchmark
machine: five invocations per revision/backend/fixture, each with two warm-ups
and nine measured rounds. These results replace the intermediate development
figures previously listed here; no timings from the secondary release-preparation
machine are used.

- On the 200,000-statement parse-and-validate fixture, the scalar default takes
  **17.6% less time with growing pools** and **20.6% less with capacity hints**
  than 0.2.0 (12.260 / 10.680 ms, approximately 213 / 244 MiB/s).
- The ordinary scalar fixed session takes about **22% less time** than 0.2.0.
  Empty sibling and nested subgraph fixtures at 100,000 scopes take about
  **31% less time**. These are fixture-specific elapsed-time improvements.
- The native nesting frame falls from **272 to 116 B**; the ordinary scalar
  fixed session from **1,560 to 1,080 B**. The flat fixture still retains
  **34 B/statement**, with unchanged arena backing capacities; these are not
  process-RSS measurements.
- Block scanning remains a workload-dependent choice. Its parse-and-validate
  medians overlap scalar's ranges; its long-identifier lexer fixture takes
  **28% less time** than scalar, while the mixed short-quotes/comments fixture
  takes **59% more time**. It adds **96 B** to native fixed session/driver state.
  Cancellation-enabled session profiles favor block in this run; unmetered,
  non-cancellable and metered-only profiles favor scalar.
- Lexer comparisons normalize the checksum across revisions. Lazy source
  positions move line/column derivation out of parsing; that later work is not
  timed. Non-ASCII-heavy input, recovery, one-credit calls, code size and MCU
  runtime performance are outside this measurement.

### Fixed

- `DocumentStorage` no longer requires three pools while defaulting the rest:
  every pool defaults to empty.

## 0.2.0 — 2026-09-14

Expand the borrowed syntax parser with comments, quoted/numeral identifiers,
basic attributes, edge chains, ports and nested subgraphs, including subgraph
endpoints. Add fixed-storage resumable parsing with optional work metering and
cooperative cancellation. This is an experimental, breaking minor release.

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
