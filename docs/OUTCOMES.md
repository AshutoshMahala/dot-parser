# Outcomes and diagnostics

Phases report problems through the same interface: functions
return a **small outcome value** describing what happened, and the
**explanation travels through your diagnostic sink** — structured,
typed, and never printed by the library. There is no error-code soup to
`catch` and no string parsing; outcomes are for control flow, diagnostics
are for humans and tooling. Runtime-enabled [policy profiles](POLICIES.md)
add a separate configuration error union: an invalid policy is rejected before
DOT processing and does not produce a source diagnostic.

## Parse outcomes

`parseBorrowed`, `parseBorrowedIn`, and `parseAndValidate` report a
`ParseOutcome`. Fixed sessions use the same type and additionally support cancellation:

| Outcome | Meaning | Document? |
| --- | --- | --- |
| `.success` | The document parsed completely | Yes |
| `.cancelled` | A session was cancelled, or an enabled cancellation hook stopped a one-shot operation | No |
| `.invalid_syntax` | The input is not accepted by the selected syntax policy | No |
| `.unsupported_feature` | The parse stopped at a recognized-but-deferred DOT construct | No |
| `.resource_exhausted` | A caller-configured limit (e.g. `max_statements` or `max_attributes`) was reached; the input may still be valid | No |
| `.storage_failure` | Document storage could not hold the document | No |

`storage_failure` carries its own cause: `.out_of_memory` (allocator),
`.pool_exhausted` (a fixed pool filled — the diagnostic names the pool and
its capacity), `.statement_index_overflow`, `.attribute_index_overflow`,
`.edge_link_index_overflow`, `.ported_reference_index_overflow`, or
`.internal` (never expected; a bug report is welcome). A source longer than
4 GiB is refused before a byte is read: positions are 32-bit, so the parse
reports `.resource_exhausted` with capacity resource `.source_range`. `.internal` currently has no corresponding
diagnostic; inspect the outcome even when the diagnostic bag is empty.

Chain storage failures use the existing WDP capacity diagnostic, with typed
resources `edge_chain_pool`, `edge_link_pool`, or `edge_link_index`.
A missing chain endpoint remains a syntax error, not a capacity failure.
The shipped chain feature no longer appears in `diagnostic.Feature`.

Ports likewise no longer have an unsupported-feature entry. Fixed-pool/index
failures use `ported_reference_pool` / `ported_reference_index` capacity
resources. Missing suffix IDs use the existing expected-set syntax diagnostics
with context `port_component`; EOF after a colon has a `suffix_started_here`
secondary span. This adds no new WDP code or raw message-string payload.

## Sessions: yield and cancellation

A yielded session has no terminal outcome (`SessionProgress.outcome == null`)
and `result()` is null. Yield is resumable, not a resource failure. Cancellation
is terminal and emits no failure diagnostic. A previously obtained failure or
successful commit is never replaced by later cancellation. See
[bounded execution](EXECUTION.md).

## Unsupported is not invalid

The distinction the taxonomy is built around:

- **`invalid_syntax`** means *the selected syntax policy does not accept this input*.
- **`unsupported_feature`** means *this is recognized DOT syntax that this
  library does not process yet*. The parse stopped at the construct's
  introducer, and the diagnostic names the exact feature as a typed enum
  (`Feature.html_identifier`) that tooling can
  aggregate or test against.

An unsupported outcome is a **boundary, not a validity claim**: nothing at
or beyond the stopping point has been checked. And the classification is
grammar-aware — a deferred keyword in a position where it is not legal DOT
(`subgraph` as the document root) is plain `invalid_syntax`.

Basic attributes produce syntax errors for malformed supported forms.
`Feature` contains only currently deferred constructs; implemented features
have no unsupported-feature entry. Attribute failures reuse
`E.Syntax.Grammar.003` / `031` with typed key/value/list contexts, expected
`=` / `]` vocabulary and a related opener whenever the list was left open. Capacity diagnostics identify
the attribute, assignment or attribute-statement pool, or the total
`max_attributes` limit.

## Parsing succeeds, validation judges

The parser is kind-agnostic: `digraph { a -- b; }` **parses** with
`.success`. Whether `--` is legal in a directed document is a *policy*
question, answered by `validate` (or the `parseAndValidate` one-shot):

```zig
var checked = dot.parseAndValidate(allocator, source, bag.sink(), .{});
// checked.outcome == .success        — structure was fine
// checked.documentValid() == false   — validation found violations
```

`ValidationResult.outcome` is `.completed { document_valid, violations, warnings }`.
`violations` counts errors, while `warnings` counts warning-severity mismatches;
only errors invalidate the document. Both count occurrences independently of sink
retention/delivery. [Profiles](POLICIES.md) configure severity, graph treatment
and effective operator reading. Bounded/cancellable validation is future work; outcomes for those
behaviors will be added when implemented. Validation reports **every** violation, in source order — it never
stops at the first.

## The diagnostic bag

Parse, fixed-parse, measure and session-progress results contain factual
`accepted_deviations: u32` and `warnings: u32`. The first counts syntax-policy
acceptances, including silent `.accept`; the second counts produced syntax
warnings, including numeral warnings. Neither depends on bag retention,
filtering or successful delivery. Counts remain available when later work fails
or is cancelled; they are not a complete deviation history.
`CheckResult.warnings` totals syntax and validation warnings;
`CheckResult.accepted_deviations` retains the parse count. Separate validation
reports only its own warnings. See [syntax policies](POLICIES.md).

By default parsing is fail-fast: at most one failure diagnostic. With
`Policy.recovery = .statements` a syntax error inside the body does not end the parse: the
document is aborted once, the parser skips to the next `;` or `}` at the
same brace depth, and every further syntax error is reported too. The
outcome is still `invalid_syntax`, no document is published, and validation
never runs — later diagnostics can be consequences of an earlier one, so
read them in order. Header errors, end of input, trailing tokens, limits,
deferred features, and unterminated quotes or comments still stop the parse.

Warnings (`W.Syntax.Numeral.033`, `W.Syntax.Operator.003`,
`W.Syntax.Grammar.034`) can accompany a successful parse; they never
change the outcome. Retention depends on the sink: a full bag, discard
sink, or rejected delivery can leave no retained entry, and `.internal`
emits no diagnostic. Validation attempts one diagnostic per violation. A
`FixedDiagnosticBag(N)` keeps the first `N` and counts the rest in
`omitted` — diagnostics are never silently dropped.

Each diagnostic carries a WDP identity, a source span, and **optional
typed details** (`Details.none` means no additional context). The span is a
byte offset and length; line and byte column are derived from the source
when they are shown (`span.locate(source)`, or a `location.PositionCursor`
for many spans), which the renderers do when given `RenderOptions.source`
and otherwise print the offset. Details are never pre-rendered strings. Wording belongs to renderers; the
out-of-the-box console renderer is one consumer of these payloads, and
your logger, LSP, or JSON emitter can be another via `DiagnosticSink`.

Current registry. The component is the logical domain of the problem
(`Syntax`, `Validation`, `Resource`, `Profile`), never the source module
that noticed it: filter on `E.Syntax.*` for every malformed-input problem.
A code names one condition; where in the grammar it occurred travels in the
payload (`Unexpected.context`, `ReservedKeyword.context`).

| Code | When | Details emitted by the library |
| --- | --- | --- |
| `E.Syntax.Byte.003` | A byte that cannot start any DOT token, or NUL inside quotes | `.invalid_byte` |
| `E.Syntax.Operator.003` | `-` that does not form `--`/`->` (`a - b`, `a - > b`), or `-->`/`---` | `.invalid_operator` (the byte that broke it, or null at EOF) |
| `W.Syntax.Operator.003` | Exact long operator or bare dash accepted with `.warn` | `.accepted_operator`: chosen operator and `.long_shape` or `.from_keyword` reason |
| `W.Syntax.Grammar.034` | Empty statement accepted with `.warn` | `.none`; the span marks the omitted `;` |
| `E.Syntax.Numeral.001` | `.` or `-.` without the required digit | `.incomplete_numeral` (the byte found, or null at EOF) |
| `E.Syntax.Token.032` | Input ended inside an unclosed quote or block comment; span marks its opener | `.unterminated` (`.block_comment` or `.quoted_identifier`) |
| `E.Syntax.Concatenation.003` | `+` is not followed by a quoted identifier | `.expected_quote` (next byte, or null at EOF) |
| `E.Syntax.Grammar.003` | Unexpected token | `.unexpected` (expected set, found, context, related opener, suspect brace) |
| `E.Syntax.Grammar.031` | Input ended before the document was complete | `.unexpected` |
| `E.Syntax.Keyword.003` | Reserved keyword where a name was needed, or `node`/`edge`/`graph` without its `[` list | `.reserved_keyword` (keyword, context) |
| `W.Syntax.Numeral.033` | A numeral runs into a letter or a second dot (`1e3`, `1.2.3`); the parse continues with two tokens, as Graphviz does | `.ambiguous_numeral` (the byte it runs into) |
| `E.Validation.Operator.002` | Edge operator does not match the graph kind | `.operator_mismatch` |
| `W.Validation.Operator.002` | Mismatch tolerated by the selected policy | `.operator_mismatch` (including reading and original-header relation) |
| `E.Profile.Feature.009` | Recognized-but-deferred DOT construct | `.unsupported_feature` |
| `E.Resource.Capacity.026` | A configured capacity was exhausted | `.capacity` when available, otherwise `.none` |
| `E.Resource.Memory.026` | Document memory was exhausted | `.none` |

`Unexpected.related` is the still-open `[` or `{` (or the port colon) the
failure traces back to; `Unexpected.suspect` is set when the input ends
inside a scope and an earlier `}` sat at a smaller indentation than the
line that opened the scope it closed — the brace that is probably missing
belongs above that `}`. The console renderer turns the payload into a
rule statement and a hint per context; consumers rendering their own text
have the same fields.

## Fix suggestions

When the producer knows the one edit that repairs a problem, the diagnostic
carries it as `fix: ?Fix`: a span, a typed edit, and an applicability.
Nothing in it is a string — a replacement is a `Replacement` enum whose
`text()` gives the bytes — so it costs no allocation and a linter can act on
it without parsing wording.

| Edit | Meaning |
| --- | --- |
| `.delete` | remove the span |
| `.replace = r` | replace the span with `r.text()` |
| `.insert_before = r` / `.insert_after = r` | insert `r.text()` at the span's start / end (a zero-length span is a position, such as end of input) |
| `.wrap_in_quotes` | put the span in double quotes |

`applicability` is the contract for tools: `.machine_applicable` means the
edit is the single correct repair and may be applied unattended (`-->` to
`->`, quoting a keyword used as a name, deleting a stray `;`, closing an
open `[` at end of input); `.maybe` means it is one plausible repair among
several or its position is a guess (a `,` between statements, a missing
`=`, closing a quote at end of input, an operator mismatch where changing
the keyword would do as well). Apply fixes from the highest offset down so
earlier spans stay valid, then re-parse; the library never applies fixes
itself.

Which diagnostics carry a fix, and how confident it is:

| Diagnostic | Situation | Fix |
| --- | --- | --- |
| `E.Syntax.Operator.003` | `-->`, `---`, `- >`, `- -` | replace with the operator the last byte names, machine-applicable |
| `E.Syntax.Operator.003` | lone `-` | replace with the declared kind's operator, machine-applicable (none before the kind keyword) |
| `W.Syntax.Operator.003` | accepted `---`, `-->`, or `-` | replace with the policy-selected syntax operator, machine-applicable |
| `W.Syntax.Grammar.034` | accepted empty statement | delete the marked `;`, machine-applicable |
| `E.Syntax.Byte.003` | `=>` | replace with the declared kind's operator, maybe |
| `E.Syntax.Keyword.003` | keyword as a name | wrap in quotes, machine-applicable; none for `node;`, which has two readings |
| `E.Syntax.Grammar.003` | stray `;`, extra `}`, doubled operator, doubled or leading `,`/`;` in a list | delete, machine-applicable |
| `E.Syntax.Grammar.003` | `,` between statements | replace with `;`, maybe |
| `E.Syntax.Grammar.003` | missing `=` after a key; `]` missing before a token; `{` missing after the header | insert, maybe |
| `E.Syntax.Grammar.003` | header typo | replace with the nearest header keyword, maybe |
| `E.Syntax.Grammar.031` | input ends inside `[` / `{` | insert `]` / `}` at end of input, machine-applicable unless a misindented `}` was found |
| `E.Syntax.Token.032` | unterminated quote or comment | insert the closer at end of input, maybe |
| `E.Validation.Operator.002` / `W.Validation.Operator.002` | operator mismatch | replace with the effective kind's operator; machine-applicable under `.conform_to_kind`, otherwise maybe |

`W.Syntax.Numeral.033` carries no fix: the repair would quote the whole run
(`"1e3"`), and the scanner has not seen where the following token ends.

The console renderer prints the fix under the hint (`Fix: replace '-->'
with '->'`, with `(one possible repair)` appended for `maybe`); the compact
renderer adds a `fix:` line. Diagnostic and bag sizes are target-dependent;
inspect `@sizeOf` for the selected build instead of assuming a portable size.

This table describes library-produced diagnostics. `Diagnostic` is publicly
constructible: its separate `code` and `details` fields do not enforce these
pairings in the type system. Consumers must not assume every diagnostic has
non-empty details. Diagnostic enums describe this library version, not a
cross-version serialization format.

Sequence numbers and aliases are defined together in `diagnostic.Sequence`.
Registry entries select one definition; `Code.Info.sequence` and `.alias`
are derived from that pair. Neither field is retained in each diagnostic.

During experimental `0.x`, backward compatibility is not promised for diagnostic
codes, payload enums, source APIs or retained layouts. Obsolete entries are
removed rather than kept for replay. WDP conformance and unique, coherent
identities within the current registry are still tested. Identities follow
the Waddling Diagnostic Protocol version
0.1.0-draft at conformance Level 2 (Namespaced: structured codes, compact
IDs, and namespaces), with the part 6 sequence conventions and part 10
presentation palette as informative guidance.

## Delivery is never masked

If *your sink* fails while a diagnostic is being reported, the outcome
still describes the parse; the loss is surfaced separately as
`diagnostic_delivery == .failed`. One channel never hides the other.

## Byte-safe excerpts

Console source excerpts escape non-ASCII and non-printable bytes as `\xNN`
(tabs retain their existing presentation). Underlines account for those byte
escapes; diagnostic offsets and byte columns still refer to original input.
This avoids emitting input-supplied terminal control sequences and does not
require Unicode display-width tables. Each excerpt window contains at most
60 source bytes, which can expand to 240 cells before framing/tab expansion.
This presentation policy is separate from identifier decoding, which preserves
the actual value bytes.

### Subgraph limits and storage failures

`max_nesting` reports `.resource_exhausted` with capacity resource
`.nesting_depth`; the root is depth zero. Insufficient fixed scratch reports
`.storage_failure: .pool_exhausted` with `.nesting_frames`. Insufficient retained
scope slots uses the same storage outcome with `.subgraph_pool`. Allocator-backed
scratch allocation failure reports `.out_of_memory`. These use the existing WDP
capacity/memory codes and emit one diagnostic, not a second facade diagnostic.

Malformed subgraph headers and missing/malformed edge endpoints are syntax errors.
Subgraph endpoints are supported; the old unsupported-feature variant is removed.
Fixed generalized-edge storage failures identify `.scoped_edge_pool` or
`.scoped_edge_link_pool`. Every failure exposes no document.
