# Changelog

Notable changes to dot-parser. During `0.x`, minor versions may break
compatibility, including diagnostic codes and enum values. Breaking changes
are marked; no compatibility shims are kept.

## Unreleased

### Added

- Fixed-storage Document-to-IR lowering via `lowerCompleteIn`, `lowerPartialIn`,
  `loweringSessionIn` and `partialLoweringSessionIn`. Caller-owned retained pools
  and reusable scratch use the same semantics and metered/cancellable sessions,
  with no construction allocations or heap fallback. Adds explicit capacity
  bounds, observed capacities/scratch peaks, checked byte-region binding and
  structured shortfalls; failed lowering publishes no graph. Returned graphs
  borrow retained storage/source, with optional storage for later queries.
  No automatic reservation is added to ordinary lowering. Includes `fixed_graph`
  and `bench-ir-fixed`; fixed query/output storage remains separate work.
- Policy-bound resumable attribute access via `IR.attributeSession(view, key, options)`
  and `IR.attributesSession(view, options)`, for complete/partial node, scope,
  compact-edge and materialized-edge views. Reuses existing execution policies
  and shared session options; bounded steps include keys, contribution/membership
  searches, port introductions, winner scratch and coverage qualification.
  Single lookup allocates no scratch; materialized views read existing maps.
  Streams deliver one final effective attribute at a time, preserving direct
  order/provenance and partial uncertainty. No expansion or implicit key copy.
  Includes a runnable example and `bench-ir-attribute-sessions`. Direct APIs
  and retained layouts are unchanged. Unreleased symbolic-query session members
  `QueryOutcome` are renamed `Outcome` to match the other query/stream types.
- Policy-bound resumable symbolic queries via `IR.hasEdgeSession` and
  `IR.containsSession`, for complete and partial IRs. Reuses metering,
  cancellation intervals and opt-in runtime policies; bounded steps cover
  connections, membership intervals and posting probes. No expansion or heap
  scratch, and no implicit negative answer on pause/stop. Partial successes
  retain existing known/unknown semantics. Direct queries remain unchanged.
  Includes `resumable_query` and `bench-ir-query-sessions`.
- Policy-bound resumable edge streaming via `IR.edgeSession` for complete and
  partial IR. Each `advance` delivers at most one existing edge view or a
  budget pause/terminal outcome; `run` stops at the next edge. Shares bounded
  expansion with materialization, without its output array or attribute folding.
  Strict streams retain pair keys; non-strict streams retain no emitted edges.
  Execution policy/runtime overrides match lowering sessions; limits remain
  cumulative and partial qualifications survive. Adds a runnable example and
  `bench-ir-edge-sessions`; ordinary pull iteration remains unchanged.
- Policy-bound resumable Document-to-IR lowering via `loweringSession` and
  `partialLoweringSession`. Reuses `.execution.metering`, cancellation and its
  interval, with default-off runtime overrides and `validatePolicy`. Budgeted
  steps include logical-name hashing/equality, collision probes/rehashing,
  persistent attribute updates, scope-default overlays, coverage/posting indexes
  and growth copies. No eager edge expansion or hidden preparation pass; only
  successful output transfers ownership. Existing direct calls remain unchanged.
  Includes native/partial/partition/stop tests, `resumable_graph` and the
  `bench-ir-lowering-sessions` report command.
- Opt-in `ir.materializationSession(options)` for complete and partial IRs,
  with `advance(u32)`, `run`, `cancel`, `deinit` and one-time `takeResult`.
  Per-call credits cover endpoint traversal, strict deduplication/rehashing,
  attribute-map updates, port-key reading and bounded growth copies. Existing
  `materialize` and its output types stay unchanged. Partial-source coverage
  survives successful materialization; pauses/failures never publish half-built
  output. Includes allocation/cancellation/partition tests, a runnable example
  and `bench-ir-sessions`. Allocator callbacks are not wall-time bounded.
- Partial IR node and graph/subgraph attribute iteration via
  `node.attributes(options)` and `scope.attributes(options)`. Retained keys
  yield qualified values with provenance and implicit-empty candidates;
  enumeration uses the existing catalogs/maps without allocating scratch and
  shares one cumulative lookup/coverage work allowance and cancellation token.
  Complete-input APIs and retained layouts are unchanged.
- Partial IR edge iteration and materialization reuse the existing expansion,
  strict deduplication and attribute folding engines. Retained edge views expose
  qualified attributes, ports, orientation and first contributions; folded
  lookups remain infallible. Complete-input APIs are unchanged. Includes native,
  compatible-gap-filling, cancellation/allocation-failure tests and
  `bench-ir-partial-edges`; incomplete sources never become complete merely
  because materialization finished.
- Opt-in `dot.ir.parsePartial` / `Lowering.lowerPartial`: retained node/scope
  views, mention iteration, symbolic existence/membership queries and indexed
  attribute candidates. `Knowledge(T)` separates known facts from source gaps;
  coverage never disguises syntax rejection or an execution stop. Complete IR
  entry points remain unchanged. Includes an editor example, native-encoding/
  failure/compatible-filling tests and `bench-ir-partial`.
- Partial DOT Documents retain factual `root_closed` delimiter coverage, so an
  unfinished root is distinguishable from internal recovery gaps even at EOF.
- Borrowed IR `tailPort()` / `headPort()` views share effective attribute
  precedence and provenance. `syntax()` preserves written endpoint components;
  explicit `graphvizParts()` provides the first-colon interpretation without
  losing ambiguous names, unknown compass text or empties. Helpers allocate
  nothing, add no retained storage, and offer bounded/cancellable variants.
  **Breaking:** port-specific access moved off general value/operand views;
  endpoint origins are `.written_left_port` / `.written_right_port` to distinguish
  written sides from stored edge orientation. No legacy aliases.
- IR attribute views format directly as their logical value with `{f}`;
  optional views use `{?f}` without forced unwrapping. The materialized-edges
  example prints explicit label updates alongside creation-time defaults.
- IR endpoint suffixes now resolve to effective `headport`/`tailport` across
  compact queries, enumeration and folded materialization. Explicit attributes
  override suffixes; strict updates respect first-edge orientation, including
  reversed undirected edges. Derived values retain component spans and format
  without a decoded allocation. Label-port existence/layout remain separate.
  **Breaking:** `ResolvedAttribute.attribute` is now optional (null for derived origins).
- `ir.materialize(.{})` now folds effective edge attributes during
  forward expansion, including strict duplicate contributions and creation-time
  defaults. Materialized views provide infallible indexed lookup/enumeration,
  with bounded variants. Values/defaults/provenance borrow the IR; mutable maps
  retain only winning explicit assignments. Output, scratch, growth, pair visits
  and updates share enforced limits/cancellation. `.attributes = false` is the compile-time topology-only option;
  limits/cancellation remain runtime values. Includes a printable example and
  `bench-ir-materialized`.
- Optional `console.printDiagnostics(io, items, options)` for DOT, markup,
  string and composed profiles: numbered boxes to stderr using shared rendering,
  a fixed stack buffer and caller IO. No heap allocation; write/flush failures
  propagate. The three introductory IR examples use this helper.
- Optional `dot.ir.Lowering(...).lowerComplete` topology layer from accepted
  complete Documents: logical node identity, shared scope-membership snapshots,
  symbolic connections, allocation-free existence queries and explicit bounded
  materialization or streaming edge iteration. Streaming reuses endpoint
  scratch, preserves non-strict parallel occurrences and deduplicates strict
  pairs, with cumulative limits/cancellation and explicit early cleanup.
  Effective node/graph/edge attribute queries resolve creation defaults and
  source-ordered updates, distinguish absent/implicit-empty values, and retain
  source origins. Immutable maps share default states; strict edge queries
  inspect symbolic contributions without expanding pairs. Attribute maps have
  explicit work/memory/state limits; no state is allocated for attribute-free
  input. Endpoint-derived port values require no additional lowering pools.
  Borrowed node/scope/edge views offer `.attribute(key)` and bounded
  `.attributes(options)` iteration with logical formatters and provenance.
  Strict-edge iteration merges contributions once using key-sized scratch;
  other attribute iterators allocate nothing. Retained record layouts are unchanged.
  Node/edge iterators yield borrowed component views directly. Name access and
  indexed node/scope attribute lookup are infallible on valid views, with bounded
  variants for explicit limits. Value views expose string/markup/concatenation
  kinds, original spelling/encoding/spans, allocation-free operand iteration,
  markup fragments and joined output. `toString` uses one exact allocation;
  bounded traversal and output preserve cancellation/work failures. No operand
  cache, automatic markup parsing or loss of concatenation boundaries.
  Includes one-call `dot.ir.parse`,
  allocation-free node iteration/name formatting, `test-ir`, `bench-ir` and a
  short graph example with diagnostics; its checks live outside the example.
  Ordinary parsing is unchanged.
- DOT `Consumer.observations = events.Observations.previews` exposes raw
  unfinished name-expression spans at EOF and metered pauses, through the same
  events interface. Updates carry known context and original encoding/offsets;
  explicit completion/rejection events retire previews. Callbacks consume their
  own credits, including queued delivery after a budget is exhausted. No repair,
  trusted-name promotion, source copy or parser allocation; default off.
  `zig build bench-previews` reports enabled/disabled timing, credits and sizes.
- Opt-in early DOT event observations with `Consumer.observations = events.Observations.early`:
  complete identifiers, recognized statement heads and document/subgraph names
  can feed an outline before their enclosing syntax finishes. The same event
  interface retains commit/abort, original byte spans and separate callback
  work credits. No event queue or partial-token guessing; default off.
- **Breaking (Unreleased):** one typed `events.Observations` selection replaces
  the separate early-event/preview flags; `.all`, `.none` and individual fields
  are also supported. Internal names, heads and previews share one dispatch
  continuation and cleanup flag, with unchanged metering/cancellation contracts.
- `identifier.fromName(source, name)` (also under `ForEncoding`) provides a borrowed
  name view with logical hash/equality that skips redundant DOT syntax checks.
  Complete identifier event fields now use a distinct eight-byte `Name`, while
  previews/general locations remain `Span`. Retained views expose typed names
  too. Arbitrary spans use `identifier.check`; the unchecked raw constructor is
  removed without aliases. Only complete recognized identifiers qualify; the source must stay
  unchanged. Checked helpers remain checked, and native decoding retains its
  encoding checks. No event/document fields, copies or allocations are added.
  `zig build bench-identifiers` compares both paths in an event-only name index.
- Opt-in attribute string processing for DOT and markup, including nested
  DOT → markup → string and delayed retained-document checks. Explicit attribute
  rules override the host default; omission stays passthrough. Child-owned
  delegated policies and enabled runtime patches use the existing validators,
  logical readers and original-source diagnostics. Shared bags/renderers retain
  all processor payloads. Default/pass-only profiles keep the original host
  type; routing adds no processor-owned heap allocation. Shared-budget
  composition and host-aware logical fixes remain deferred.
- `perf-string --suites host-defaults,integration` compares isolated host
  defaults, bound passthrough and active attribute processing with one
  alternating before/after report.
- Shared, opt-in logical readers for plain string contents, DOT identifiers and
  markup text/attribute contents. Fixed-state, bounded steps decode native
  encodings, DOT lexical quoting/concatenation and markup references while
  preserving original-byte locations and operand provenance. No decoded copy,
  automatic processing, validator API change or metering-policy change.
- String `.ascii_case_insensitive` comparison, independent of optional full
  Unicode folding. Case-sensitive remains the default; ASCII-only comparisons
  do not pull in Unicode tables.
- `zig build perf-string` creates alternating before/after reports from one
  command, using the same current harness and compiler for both snapshots.
- Optional outward scalar-boundary rounding for `location.textPosition` so
  byte-oriented diagnostic ranges can be converted to editor positions.

- Standalone `string_processor`: borrowed contents, native encoding validation,
  `equals`/`one_of` and compile-time custom validators through one contract,
  fixed/default-off runtime policies, common diagnostic bags/rendering, and
  resumable metering and cooperative cancellation. Built-ins and custom validators
  share `State`/`step`, with optional unmetered fast checks; active synchronous-only
  validators are rejected under metering. Execution settings live under
  `policy.execution`, with positive cancellation intervals and default-off features.
  Unicode 17.0.0 full default case folding is an
  optional compiled capability; exact-only builds exclude its tables. No tree
  or processor-owned allocations. Optional host integration is described above.

- Graphviz label content grammar, local attribute values/required attributes,
  and HTML4 named-reference checks. Each has independent fixed/runtime
  severity. Structural mode stays unaffected; local scope validation does not
  claim whole-label content coverage. No new tree/scratch allocations.
- Optional DOT Graphviz attribute-name checking via
  `validation.graphviz.unknown_attribute` (default off), plus
  `attribute_catalog.lookup`/`entries` metadata for 177 documented attributes.
  DOT value validation and target enforcement are not part of the catalog yet.

- Compile-time-bound DOT event consumers via `Profile.Events(Sink)`, with
  event-only one-shot/fixed-scratch parsing and UTF-8 sessions. Statement
  commit/abort, nested scopes and skipped ranges allow consumer-defined output
  without allocating the library's document pools.
  Builders and the sizing sink consume the same public event contract; storage
  bookkeeping remains private, with no event translation adapter.
- Opt-in DOT partial retention now keeps later completed statements after safe
  recovery. `skippedRanges()` exposes gaps; `unrepresented()` remains the
  unfinished suffix. No guessed lexical boundaries or repaired source.
- Allocation-free logical identifier hash/equality helpers, including checked
  document ranges and native encodings.
- `Document.capacities()` for reusing retained DOT pool counts as growth hints.
- Optional `location.textPosition` conversion to zero-based UTF-8, UTF-16 or
  code-point columns without changing stored byte spans.
- `inspectSource` on standalone and composed profiles, reporting encoding
  admission reasons, detected encoding and offending byte spans. `check_file`
  uses it to explain unsupported BOMs before parsing.

### Changed

- Reduce Safe symbolic-query session overhead by reusing posting slices within
  bounded search loops. One-credit resumes keep an inlined single-step path;
  Fast, Small and fixed interval-one cancellation profiles retain the compact
  driver. Credit counts, pause states, polling checkpoints, inline state sizes
  and ordinary direct queries are unchanged.
- Reduce resumable edge-streaming overhead with allocation-free non-strict
  transition fusion and inlined one-credit dispatch. Credit totals, pause/stop
  boundaries, cancellation checkpoints, partial views and scratch sizes are
  unchanged; active cancellation hooks retain the original stepped path.
  `bench-ir-edge-sessions` now warms each fixture for at least 50 ms before
  measuring, in addition to its four rotated warmup rounds.
- Reduce opt-in IR materialization-session dispatch/accounting overhead without
  changing credits, cancellation checkpoints, storage or the direct driver.
  Share exhausted-grant exits and cache endpoint cardinality in existing scratch
  space to reduce code size and plain-edge overhead.
  The session benchmark now covers topology/attributes, enabled cancellation
  and budgets 1/64/4096 as well as run-to-completion.
- **Breaking:** require Zig 0.17.0. Build steps, compile-time reflection and
  development tools use the new compiler APIs; optimization modes are
  `debug`, `safe`, `fast` and `small`. Parser policies and execution guarantees
  are unchanged. On the measured 64-bit target, standard-library safety metadata
  increases Debug/Safe markup sessions by 16 bytes, DOT/markup growable diagnostic
  bags from 48 to 56 bytes, and `markup.ParseResult` from 176 to 192 bytes.
  Other ArrayList-owning builders/workspaces can also grow. Fast/Small sizes are
  unchanged. Earlier performance tables retain their original toolchain.
- **Breaking (Unreleased API):** `events.Event` adds four early-observation tags
  and two token-preview tags.
  Exhaustive switches must handle them or use `else`; callback delivery stays
  unchanged unless the consumer opts in.
- Recovery resumes after certified boundaries, reporting independent errors
  previously missed while avoiding cascades when resuming an enclosing edge.
  For example, `digraph { a -> { b -> } -> c; }` now reports the one local error,
  not two. Partial retention does not make invalid input valid.
- **Breaking (Unreleased API):** string `Value.span()` now returns an error union,
  rejecting oversized consumer-constructed views rather than trapping/truncating.
- **Breaking (Unreleased API):** reader-bound string sessions now invoke optional
  custom `batch` methods with logical values. Like `step`, a portable `batch`
  must use reader-compatible helpers or return zero for logical input. Direct
  `value.bytes` access remains supported only for standalone values. No change
  to credit costs, cancellation polling or the scalar fallback contract.

- **Breaking:** Graphviz mode now rejects previously unchecked label content
  and values under its default policies. The new rules can be individually
  disabled; parsing alone still retains structurally valid input unchanged.

- Add `execution.cancellation_interval` to DOT and markup policies, default 1,
  with fixed/runtime selection and unchanged work-credit metering. Larger
  intervals trade cancellation responsiveness for fewer callback checks.
- **Breaking:** runtime markup policy entry points now return configuration
  errors, including `prepare`, parsing/validation and session init/reset.
  Interval 0 is rejected; fixed-policy entry points remain compile-time checked.
- Specialize DOT's interval-1 runtime driver at initialization/reset and keep
  its single-credit scanner path separate from batched execution. No change to
  polling frequency, work credits, cancellation precedence or session storage.
- Reduce DOT scalar-scanner dispatch and cancellable-session overhead without
  changing event, recovery or work-budget contracts, or increasing storage.
- **Breaking:** partial DOT `order` storage can contain paired `skipped_start`
  and `skipped_end` metadata. Normal statement views hide them; use
  `skippedRanges()` for recovery gaps. `unrepresented()` describes only an
  unfinished suffix and can be null even when the document is partial.

### Fixed

- Token previews report the next statement's context/absent owner during
  separator-free lookahead, retain owners for preview-only consumers, and
  recognize separator-free attribute keys. Trailing trivia after `+` no longer
  creates whitespace-only updates. A queued preview cannot hide an already-found
  scanner failure behind later cancellation. Aborted consumers no longer incur
  extra early-observation dispatch work.
- Replace deprecated Zig reflection/`std.builtin` aliases, share ASCII batch
  width with logical readers, and correct observation lifecycle, trusted-name
  guidance and historical benchmark reproduction instructions.
- Reduced endpoint-port IR overhead in edge expansion, streaming and attribute
  iteration/folding: cache immutable connection/graph facts, isolate port
  preparation and avoid redundant AVL height work. Follow-up repairs keep
  singleton membership checks inline, avoid copying full connections during
  attribute iteration and specialize folded reads for port-free graphs.
  APIs, retained storage,
  work accounting and cancellation boundaries are unchanged. See the focused
  performance report for measurements and remaining pre-port gaps.
- Long reader-bound string checks batch unchanged ASCII runs without changing
  credits, pause boundaries, cancellation polls or session size. Short values
  and decoding boundaries retain scalar execution.
- DOT string routing no longer re-tokenizes already parsed attribute values.
  This also avoids a shared-scanner optimization regression in mixed-profile
  ReleaseSmall builds. Public identifier helpers retain their input checks.
- Partial DOT validation excludes unattached attributes, discarded port
  occurrences and uncertified edge operators; delayed markup selection rejects
  identifiers outside retained syntax while allowing retained nested scopes.
- DOT event aborts pair with delivered begins and exclude an enclosing closing
  brace. Native events preserve encoding provenance and admission cancellation.
- Graphviz malformed-reference coverage, attribute reference catalogs, signed
  CELLSPACING and literal whitespace handling; catalog metadata is decoded.
- Explicit UTF-8 markup selection no longer probes a different encoding again.
- Oversized string patterns are rejected consistently before scanning, and
  performance reporting handles subdirectory repositories and invalid flags/paths.

## 0.5.0 — 2026-10-12

Changes since 0.4.0. This is an experimental, breaking minor release.
Both `dot_parser` and `markup_parser` share this package version.

This release adds results for editors, UTF-16 and UTF-32 input, and checks
for Graphviz's tag and attribute names, which markup now uses by default. It
still keeps your source as written and never builds a repaired tree. Full
Graphviz label rules and step-by-step parsing of UTF-16 and UTF-32 are future
work.

### Added

- **Other source encodings.** `source_encodings` on `dot.Profile` and
  `markup.Profile` chooses which readers are built in: UTF-8 (the default),
  ASCII only, UTF-16 and UTF-32. A byte order mark or the `.encoding` call
  option picks the reader for each file. Files are read without converting
  them, and positions stay in the original bytes. Step-by-step sessions for
  UTF-16 and UTF-32 aren't available yet. See
  [Source encodings](docs/ENCODINGS.md).
- **Results for editors**, all off by default. See
  [Using it in an editor](docs/EDITORS.md).
  - DOT and markup `retention.partial` keep the finished part of a file after
    an error.
  - DOT `retention.markup` keeps the tree of each checked label.
    `requestMarkup` and `processPendingMarkup` check chosen labels later, in
    the same result.
  - DOT `retention.comments` keeps comments, with an optional
    `limits.max_comments`. `lexer.WithComments` returns them as tokens.
  - Documents, subgraphs, elements and labels say whether they are complete,
    separately from whether they are valid.
- **Graphviz markup mode**, `.mode = .graphviz`. It checks tag and attribute
  names against Graphviz's list and matches tags ignoring ASCII case. Where
  tags may appear and attribute values aren't checked yet.
- **Closing-tag typo recovery**, `closing_tag_recovery`. A closing tag with a
  small typo, like `</TABEL>` for `<TABLE>`, still closes its element, so one
  typo doesn't cause more errors later. The mismatch is still reported, and
  nothing is rewritten.
- `dot.requiredValidationScratch(&document)` gives the exact scratch space
  validation needs for a document.

### Changed

- **Breaking:** `validation.invalid_utf8` is now `validation.invalid_encoding`
  in both parsers, still off by default. It checks the text in the file's
  encoding: ASCII, UTF-8, UTF-16 or UTF-32. Diagnostic codes, markup's
  `checks.invalid_utf8` and `NameProblem.invalid_utf8` are renamed to match,
  and the diagnostic detail now holds the encoding and the bad code unit
  instead of a byte.
- **Breaking:** DOT's encoding check no longer looks inside HTML-like labels.
  The label checker's own `invalid_encoding` covers them; when labels aren't
  checked, nothing does.
- **Breaking:** markup now defaults to `.mode = .graphviz`, including the
  presets and labels checked from DOT. Set `.mode = .structural` for the 0.4.0
  behaviour.
- **Breaking:** markup now defaults to `closing_tag_recovery = .one_edit`, so
  diagnostics after a mistyped closing tag can change. `.exact` gives the 0.4.0
  behaviour.
- **Breaking:** `effectiveKind` returns `?GraphKind`. It is `null` only for an
  unfinished document whose kind can't be known yet.
- **Breaking:** DOT validation can return `.unsupported_encoding`, and markup
  validation `completion.unsupported_encoding`. Exhaustive switches must
  handle them.
- **Breaking:** `insufficient_scratch.required_attribute_keys` now gives the
  exact amount needed, which is usually less than the attribute count it
  reported before.
- **Breaking:** for custom processors, `console.Adapter.headline` takes the
  source positions: `headline(diagnostic, positions, writer)`.

## 0.4.0 — 2026-10-05

Changes since 0.3.0. This is an experimental, breaking minor release.
Both `dot_parser` and `markup_parser` share this package version.

### Added

- **`markup_parser`**, a second, independent module for HTML-like markup:
  elements, quoted attributes, references, comments and CDATA. It has optional
  validation (duplicate attributes, UTF-8, XML 1.0 names, known references),
  error recovery that never returns a partial tree, fixed buffers, step-by-step
  sessions, and a `presets.untrusted` policy. It works on its own or with DOT.
- **Checking HTML-like labels in DOT.** Bind a label checker with
  `Profile(.{ .processors = .{ .markup = ... } })` to check every `<...>` value
  while parsing, with one diagnostic bag for both. Or check chosen values
  afterwards with `dot.identifier.parts`. You can also bind your own processor.
  The `markup` setting (`.none`, `.passthrough`, `.process`) chooses whether
  labels are checked.
- **Settings.** `dot.Profile(...)` with one typed `Policy`, fixed at compile
  time by default, with opt-in run-time changes and `standard`/`lenient`
  presets. It covers limits, error handling, scanner choice, step-by-step
  execution, lenient syntax, optional checks (UTF-8, repeated attributes,
  restrictions) and graph-kind rules (`graph.treated_as`, `.conform_to_kind`).
- **Diagnostics.** `GrowableDiagnosticBag` (stops at 1,024 entries by default),
  `console.renderList`, Unicode-aware console output, the `diagnostics.fixes`
  and `diagnostics.unsupported` settings, and codes for the new checks and
  lenient syntax.
- Results report `completion`, `syntax_errors`, `accepted_deviations`,
  `warnings` and `diagnostic_stop`.
- The `quick_start` and `custom_processor` examples, and rewritten,
  task-based documentation.

### Changed

- **Breaking:** recovering from syntax errors is now the default. The
  `recovery` option and `Recovery` type are replaced by `Policy.on_error` and
  `OnError`: `.collect` (default) or `.fail_fast`.
- **Breaking:** limits and error handling move from parse options into
  `Policy`. `max_nesting` is now a `u32`.
- **Breaking:** `FixedSession(ExecutionFeatures)` is replaced by
  `Profile(...).Session`. `BoundedSession` stays.
- **Breaking:** the root-file `dot_parser_options.lexer_backend` option is
  replaced by `Policy.scanner`; use `lexer.For(backend)` for direct lexer use.
  The `lexer.Backend`, `lexer.backend` and `lexer.default_backend` names are
  removed.
- **Breaking:** `GraphKind` now means the effective kind and includes
  `.generic`. `Document.kind` uses the new `DeclaredGraphKind`.
- **Breaking:** `ParseOutcome` gains `.diagnostic_stopped` and
  `.processor_stopped`. One-shot calls can now return `.cancelled` when
  cancellation is enabled.
- **Breaking:** a full `FixedDiagnosticBag` now stops the run instead of
  dropping later findings. For the old behaviour, use
  `reporting.FixedBag(Diagnostic, N, .omit)`.
- **Breaking:** `console.renderBoxedList` takes a caller-owned location array
  before the writer. `locationCapacity(items)` gives its size.
- **Breaking:** HTML-like identifiers are now accepted and kept as written,
  instead of being reported as unsupported. Set `markup = .none` for the old
  behaviour. A bad `+` join now reports an `expected_string_part` payload.
- Sources moved to `src/dot/`, `src/markup/` and `src/common/`. Module names
  are unchanged, but builds that wire source files directly must also provide
  the `parser_support` module.

### Fixed

- After recovering inside an attribute list, end-of-input errors point at the
  open scope and suggest `}` instead of `]`.
- The console escapes file names and keeps excerpt searches bounded on very
  long lines.

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
  offset-only spans; see [baselines](https://github.com/AshutoshMahala/dot-parser/blob/v0.3.0/docs/BASELINES.md).
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

The [0.3.0 baseline](https://github.com/AshutoshMahala/dot-parser/blob/v0.3.0/docs/BASELINES.md#030-baseline-2026-09-19) compares the
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
cooperative cancellation. This is an experimental, breaking minor release;
see the [0.2.0 release and migration notes](https://github.com/AshutoshMahala/dot-parser/blob/v0.2.0/docs/RELEASE_0.2.0.md).

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
