# Outcomes and diagnostics

Phases report problems through the same interface: functions
return a **small outcome value** describing what happened, and the
**explanation travels through your diagnostic sink** — structured,
typed, and never printed by the library. There is no error-code soup to
`catch` and no string parsing; outcomes are for control flow, diagnostics
are for humans and tooling.

## Parse outcomes

`parseBorrowed`, `parseBorrowedIn`, and `parseAndValidate` report a
`ParseOutcome`:

| Outcome | Meaning | Document? |
| --- | --- | --- |
| `.success` | The document parsed completely | Yes |
| `.invalid_syntax` | The input is malformed in any DOT dialect | No |
| `.unsupported_feature` | The parse stopped at a recognized-but-deferred DOT construct | No |
| `.resource_exhausted` | A caller-configured limit (e.g. `max_statements`) was reached; the input may still be valid | No |
| `.storage_failure` | Document storage could not hold the document | No |

`storage_failure` carries its own cause: `.out_of_memory` (allocator),
`.pool_exhausted` (a fixed pool filled — the diagnostic names the pool and
its capacity), `.statement_index_overflow`, `.source_offset_overflow`
(source beyond the 4 GiB retained-range limit), or `.internal` (never
expected; a bug report is welcome). `.internal` currently has no corresponding
diagnostic; inspect the outcome even when the diagnostic bag is empty.

## Unsupported is not invalid

The distinction the taxonomy is built around:

- **`invalid_syntax`** means *no DOT dialect accepts this input*.
- **`unsupported_feature`** means *this is recognized DOT syntax that this
  library does not process yet*. The parse stopped at the construct's
  introducer, and the diagnostic names the exact feature as a typed enum
  (`Feature.subgraph`, `Feature.attribute_list`, …) that tooling can
  aggregate or test against.

An unsupported outcome is a **boundary, not a validity claim**: nothing at
or beyond the stopping point has been checked. And the classification is
grammar-aware — a deferred keyword in a position where it is not legal DOT
(`subgraph` as the document root) is plain `invalid_syntax`.

## Parsing succeeds, validation judges

The parser is kind-agnostic: `digraph { a -- b; }` **parses** with
`.success`. Whether `--` is legal in a directed document is a *policy*
question, answered by `validate` (or the `parseAndValidate` one-shot):

```zig
var checked = dot.parseAndValidate(allocator, source, bag.sink(), .{});
// checked.outcome == .success        — structure was fine
// checked.documentValid() == false   — validation found violations
```

`ValidationResult.outcome` is `.completed { document_valid, violations }`
today; `.budget_exhausted` and `.cancelled` are declared for future
bounded/cancellable passes so consumer `switch`es will not break when they
arrive. Validation reports **every** violation, in source order — it never
stops at the first.

## The diagnostic bag

Parsing is fail-fast and attempts at most one failure diagnostic. Retention
depends on the sink: a full bag, discard sink, or rejected delivery can leave
no retained entry, and `.internal` emits no diagnostic. Validation attempts
one diagnostic per violation. A
`FixedDiagnosticBag(N)` keeps the first `N` and counts the rest in
`omitted` — diagnostics are never silently dropped.

Each diagnostic carries a stable WDP identity, a source span, and **optional
typed details** (`Details.none` means no additional context). Details are
never pre-rendered strings. Wording belongs to renderers; the
out-of-the-box console renderer is one consumer of these payloads, and
your logger, LSP, or JSON emitter can be another via `DiagnosticSink`.

Current registry:

| Code | When | Details emitted by the library |
| --- | --- | --- |
| `E.Lexer.Byte.003` | A byte no DOT token can begin with | `.invalid_byte` |
| `E.Lexer.Syntax.031` | Input ended inside an unclosed lexical construct; span marks its opener | `.unterminated` (currently `.block_comment`) |
| `E.Parser.Syntax.001` | A required syntax element is missing | Reserved; not currently emitted |
| `E.Parser.Syntax.003` | Unexpected token | `.unexpected` |
| `E.Parser.Syntax.031` | Input ended before the document was complete | `.unexpected` |
| `E.Validation.Operator.002` | Edge operator does not match the graph kind | `.operator_mismatch` |
| `E.Profile.Feature.009` | Recognized-but-deferred DOT construct | `.unsupported_feature` |
| `E.Resource.Capacity.026` | A configured capacity was exhausted | `.capacity` when available, otherwise `.none` |
| `E.Resource.Memory.026` | Document memory was exhausted | `.none` |

This table describes library-produced diagnostics. `Diagnostic` is publicly
constructible: its separate `code` and `details` fields do not enforce these
pairings in the type system. Consumers must not assume every diagnostic has
non-empty details. `UnterminatedConstruct` is non-exhaustive; handle unknown
values when consuming recorded diagnostics from newer versions.

Sequence numbers and aliases are defined together in `diagnostic.Sequence`.
Registry entries select one definition; `Code.Info.sequence` and `.alias`
are derived from that pair. Neither field is retained in each diagnostic.

Codes and payload enums are append-only: published discriminants are never
reused or renumbered, so recorded diagnostics stay meaningful across
versions. Identities follow the Waddling Diagnostic Protocol version
0.1.0-draft at conformance Level 2 (Namespaced: structured codes, compact
IDs, and namespaces), with the part 6 sequence conventions and part 10
presentation palette as informative guidance.

## Delivery is never masked

If *your sink* fails while a diagnostic is being reported, the outcome
still describes the parse; the loss is surfaced separately as
`diagnostic_delivery == .failed`. One channel never hides the other.
