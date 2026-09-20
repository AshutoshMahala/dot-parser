# Supported DOT syntax

The authoritative compatibility page. The grammar grows one vertical slice
at a time; a construct is listed as supported only when it parses end to
end today. Deferred constructs are *recognized*: the parse stops at their
introducer with a typed `unsupported_feature` diagnostic naming the
construct, never a generic syntax error (see
[OUTCOMES.md](OUTCOMES.md) for that distinction).

## Terminology

In general library prose, **graph** means any graph; concrete kinds are called
`undigraph`, `digraph`, and `generic`. The written DOT keyword `graph` is retained
as declared kind `.undigraph`, and `digraph` as `.digraph`. [Policy treatment](POLICIES.md)
can select a different effective kind without changing the source declaration;
`generic` is not a new DOT keyword, and `.auto` is behavior rather than a kind.

## Constructs

| Construct | Status | Notes |
| --- | --- | --- |
| `graph { … }` documents | **Supported** | Exposed as kind `.undigraph` |
| `digraph { … }` documents | **Supported** | Exposed as kind `.digraph` |
| `strict` modifier | **Supported** | Parsed and retained (`Document.strict`); strictness semantics (duplicate-edge rules) are not enforced |
| Graph names | **Supported** | Bare (including non-ASCII), numeral, or quoted identifier expressions (`Document.name`); HTML names remain deferred |
| Node statements (`a;`) | **Supported** | |
| Edge statements (`a -- b;`, `a -> b;`) | **Supported** | Both operators always *parse*; kind×operator legality is a validation rule, not a parse error |
| Optional semicolons | **Supported** | As in Graphviz: `digraph G { a -> b b -> c }` |
| Bare ASCII identifiers | **Supported** | `[A-Za-z_][A-Za-z0-9_]*`; keywords are case-independent and reserved in every position |
| Non-ASCII bare identifiers (bytes `0x80`–`0xFF`) | **Supported** | High bytes may start or continue an identifier; exact bytes retained without encoding validation or normalization |
| Numeral identifiers | **Supported** | `-?(.[0-9]+ \| [0-9]+(.[0-9]*)?)`; exact text, no numeric conversion |
| Quoted identifiers and `+` concatenation | **Supported** | Exact raw range; explicit value decoding, including escaped quotes and physical line continuations |
| Whitespace / line endings | **Supported** | Space, tab; LF, CRLF, and standalone CR each end a line |
| Comments (`//`, `/* */`, `#`) | **Supported** | Skipped without retention; see compatibility notes below |
| Standalone subgraphs (`{ … }`, `subgraph { … }`, `subgraph s { … }`) | **Supported** | Named/anonymous/nested scope occurrences; no semantic merging |
| Subgraphs as edge endpoints | **Supported** | Named/anonymous/nested endpoints and mixed chains; no edge-product expansion |
| Edge chains (`a -- b -- c`) | **Supported** | Node or subgraph endpoints; one source statement with ordered continuation links |
| Attribute lists (`[color=red]`) | **Supported** | Attached to nodes, edges or whole chains; adjacent groups flattened, duplicates retained |
| Attribute statements (`graph`/`node`/`edge` + `[…]`) | **Supported** | Target and ordered pairs retained; defaults are not applied |
| ID assignments (`rankdir = LR`) | **Supported** | Separate assignment statements, retained as written |
| HTML identifiers (`<…>`) | Deferred | Feature `html_identifier` |
| Port suffixes (`a:n`, `a:out:e`) | **Supported** | Raw first/optional second identifier; no attachment resolution |
| Leading UTF-8 byte order mark | **Supported** | Skipped at the start of the input, as Graphviz does; byte columns on line 1 still count its three bytes |

## Compatibility notes

- **Comment handling**: `#` starts a line comment at any token boundary,
  including after indentation or another token (matching Graphviz 16.0.0,
  whose scanner treats `#` as a comment introducer at any position).
  Block comments do not nest and end at the first `*/`. Line comments end at
  LF, CRLF, standalone CR, or EOF. Standalone CR termination is an intentional
  difference: Graphviz 16.0.0 rejects `graph { a // c\r b }` and its `#`
  equivalent, while this library treats CR as a physical newline and accepts
  both (here `\r` denotes one CR byte).
  Preprocessor line numbers and file names are discarded; diagnostics always
  use physical positions in the supplied bytes. Comment bodies are opaque
  bytes, with no encoding validation. An unterminated block comment is
  `invalid_syntax`, diagnosed at its opening `/*` as `E.Syntax.Token.032`
  with `.unterminated = .block_comment`.
  Comments separate tokens; they cannot splice a keyword or edge operator.
  Comment markers inside quoted identifiers are content. HTML-like identifiers
  remain deferred and their bodies are not scanned.
- **Whole-document consumption**: after the root closing `}`, only whitespace,
  complete comments, and end of input are accepted. Malformed trailing comments
  and additional tokens are errors. Graphviz accepts the specific inputs
  `graph {} /* unfinished` and `graph { a; } x` (verified by running 15.1.0;
  the 16.0.0 grammar reads one graph the same way); this library rejects both.
- **Keywords are reserved words everywhere**, matching Graphviz: an
  unquoted keyword is never an identifier. `graph graph {}` and
  `graph { a -- node; }` are syntax errors (verified against Graphviz
  16.0.0, whose grammar never accepts a keyword token as an ID), not
  deferred features.
- **Kind-agnostic parsing**: `digraph { a -- b; }` parses successfully;
  the operator/kind mismatch is reported by validation as
  `E.Validation.Operator.002` under the strict defaults. [Graph policies](POLICIES.md)
  provide warning/off severity, generic/auto treatment and conforming interpretation
  without weakening syntax parsing or mutating the stored operators.
- **Limits**: positions are 32-bit, so a source is at most 4 GiB; a longer
  one is refused before scanning (`resource_exhausted`, capacity resource
  `source_range`);
  `max_statements` bounds statement count and `max_attributes` bounds total
  key/value pairs, including standalone assignments. Standalone subgraphs count as
  statements; endpoint subgraphs do not add a statement beyond their owning edge.
  Statements inside either kind of body still count; the root does not. `max_nesting` bounds active subgraph depth (root 0).
  These limits do not bound lexical work.

## Identifier lexical rules

All supported forms work as document/subgraph names, node IDs, node-reference
edge endpoints, port components, attribute keys/values and assignment keys/values.
Quoted keywords such as `"graph"` are identifiers, never keyword tokens. An
empty quoted identifier is accepted. Adjacent quoted strings without `+` are
separate tokens; only quoted strings may be joined by `+`. Whitespace and
comments may occur on either side of it.

Bare identifiers follow `[A-Za-z_\x80-\xFF][A-Za-z0-9_\x80-\xFF]*`, measured
in bytes. `café`, `東京`, Latin-1 bytes and byte sequences that are invalid UTF-8
are all accepted and preserved exactly. There is no transcoding, normalization
or Unicode case folding. Keywords match only complete ASCII words, so `graphé`
is one identifier, not a keyword plus a suffix. ASCII digits cannot start a
bare identifier; existing numeral tokenization and ambiguity warnings still
apply (for example, `1é` is a numeral followed by a bare identifier).

The lexer retains one raw-expression range. Explicit decoding removes the
quotes and concatenation glue, converts `\"` to `"`, and removes a backslash
followed by LF, CRLF, or standalone CR. All other escapes remain unchanged:
`\n` is two bytes, and `\\` remains two backslashes. Unescaped physical line
endings within quotes are preserved as written. This is DOT lexical decoding,
not a C/JSON unescaper or Graphviz label/attribute interpretation.

Non-ASCII bytes and non-NUL control bytes inside quotes are preserved without
UTF-8 validation. NUL inside quotes is rejected as `E.Syntax.Byte.003` at the
offending byte, not silently truncated. Outside comments and quotes, NUL and
other ASCII control bytes except supported whitespace are invalid.
A UTF-8 byte order mark at the very start of the document is skipped
(Graphviz's scanner ignores it too); elsewhere those bytes are ordinary
identifier content. Explicit identifier decoding preserves all bare bytes,
including a BOM at the start of an extracted identifier. A partial UTF-8
sequence is valid identifier content too: truncating a multibyte character
does not by itself make that identifier malformed. Transcoding and encoding
validation are not implemented.

An unterminated quoted segment reports `E.Syntax.Token.032` with
`.unterminated = .quoted_identifier` at that segment's opening quote, including
when it is a later part of a concatenation. A missing quoted operand after `+`
reports `E.Syntax.Concatenation.003` with `.expected_quote` containing the next
raw byte, or null at EOF. Neither failure returns a partial document.

Numerals have no leading `+`, exponent, or numeric normalization. Maximal
matching means `1e3` is tokens `1` and `e3`, and `1.2.3` is `1.2` and `.3`;
in a statement list these can be separate nodes because separators are optional.
Exactly as Graphviz warns ("syntax ambiguity - badly delimited number"), the
parser emits `W.Syntax.Numeral.033` on the numeral and continues. Bare `.` and
`-.` are `E.Syntax.Numeral.001`. A lone `-`, a spaced `- >`, or an over-long
`-->` is `E.Syntax.Operator.003`, never an invalid byte: those bytes are legal
DOT in the wrong shape.

**Verification:** the written [DOT grammar](https://graphviz.org/doc/info/lang.html)
is primary and Graphviz 16.0.0 is the pinned differential baseline
(reconciled from 15.1.0 on 2026-09-18 against the 16.0.0 `grammar.y` and
`scan.l` sources; the BOM, stray-semicolon and numeral-ambiguity notes above
come from those sources). The manual identifier probes ran on the locally
installed Graphviz 16.0.0 on 2026-09-12; they do not replace a pinned
automated suite. The checked forms
include numeral boundaries, quoted concatenation, raw multiline content,
escaped quotes/backslashes, and control bytes. A deliberate difference in the
checked 16.0.0 behavior: it removes escaped LF but preserves escaped CRLF/CR;
this library removes all three, consistently with its physical-line policy.

Optional fixed-session work budgets cover lexical steps (byte examinations, or
64-byte block classifications with the block scanner), grammar transitions,
and event attempts; see [bounded execution](EXECUTION.md). Token-length limits
remain future work. Output pools bound retained records, not source length.

## Basic attribute rules

The supported forms follow the [DOT attribute grammar](https://graphviz.org/doc/info/lang.html).
A pair is `ID = ID`; every currently supported identifier form works as either
key or value. Keywords need quoting. Inside a bracket group, pairs may be
separated by one comma or semicolon, or have no separator. One trailing
separator is accepted. Leading or repeated separators and missing keys,
equals signs, or values are invalid syntax.

Empty lists and adjacent groups are accepted: `a[][x=1][x=2]` retains two
ordered pairs. Group boundaries, empty-group presence and separator spelling
are not separately retained. They remain in the caller's source, but this is
not a lossless CST or formatting API. `graph`, `node` and `edge` attribute
statements require at least one bracket group. A standalone assignment cannot
take a following list; an edge operator cannot follow a node's attribute list.

No default propagation, last-value selection, layout-attribute validation,
external resource loading or engine-specific interpretation occurs. Subgraph-local
assignments and graph/node/edge attribute statements are retained in their scope;
there is no bracket-list attachment after a standalone closing subgraph brace.
HTML-like values retain their deferred boundary.

Incomplete lists use the existing parser syntax diagnostics. EOF inside a list
carries the current group's opening `[` as its related location; after that
group closes, EOF refers back to the innermost still-open scope's `{`.

Eighteen manual acceptance/rejection probes against local Graphviz 16.0.0 on
2026-09-12 agreed for checked empty/adjacent groups, separators, assignments,
quoted keys, malformed pairs and attachment boundaries. These are supplemental
checks, not the pending pinned differential harness or a semantic comparison.
See [ownership](OWNERSHIP.md#attributes-and-memory) for pool layout and limits.

## Edge chains

`a -> b -> c [color=red]` is one `.edge_chain` statement. All supported
identifier forms and port suffixes work at node endpoints. Subgraphs can occupy
either endpoint and mix with nodes inside a chain; comments work between tokens. The written
operators are retained independently; validation reports every mismatched
operator in source order. Missing endpoints are syntax errors. Subgraphs are retained as scope occurrences,
not eagerly expanded edge products.

Attributes follow the entire chain; `a -> b [x=1] -> c` is invalid. Adjacent
attribute groups retain the existing flattening policy. A chain does not
synthesize nodes, resolve defaults, or enforce `strict` duplicate-edge semantics.

`max_statements` counts a chain once. It does not cap its number of links.
Fixed storage exposes `edge_chains` and `edge_links` capacities; links count
only continuations after the first edge. Allocator-backed callers can provide
the same fields as reservation hints, not hard limits. Work budgets bound each
advance, not the total parse; the caller may stop via cancellation.

See [chain ownership and traversal](OWNERSHIP.md#edge-chains-and-memory) and
[the runnable example](../examples/edge_chains.zig).

## Port suffixes

A node reference is `ID`, `ID:ID`, or `ID:ID:ID`. All supported identifier
spellings and intervening trivia work in each component. Quoted colons are
identifier content: `"a:b"` is a bare reference, not a suffix. Reserved keywords
still need quoting. Missing components or a third colon are syntax errors;
EOF after a colon points back to that colon using a typed secondary location.
Suffixes are allowed on node statements and node endpoints in ordinary/mixed chains,
not on subgraph endpoints, document names, assignments, or attribute keys/values.

The syntax tree preserves `first` and optional `second` raw ranges. It does not
decide whether `a:n` means a named port or a compass direction; Graphviz's
[port-position semantics](https://graphviz.org/docs/attr-types/portPos/) depend
on node definitions. Unknown compass-like identifiers are accepted, consistent
with the [DOT grammar's parser note](https://graphviz.org/doc/info/lang.html).
Decoding either component uses the existing identifier helpers.

The parser does not discover record/HTML port declarations, synthesize implicit
ports, validate compass names, resolve `headport`/`tailport`, or build reverse
indexes. Those attributes remain ordinary pairs. The occurrence pool answers
what suffixes were explicitly written, not which ports exist or are effective.
Grouping by decoded node identity or indexing incoming/outgoing uses is consumer
work. For an undigraph the iterator's left/right remain written order, not
an assigned arrival/departure direction.

See [port ownership](OWNERSHIP.md#node-references-and-ports) and the
[runnable example](../examples/ports.zig).

## Subgraphs

The grammar is `("subgraph" ID?)? "{" statement* "}"`, with an optional
statement semicolon. A scope may contain every supported statement, including
another standalone scope. All supported ID spellings work for names; ports do
not attach to scope names. Empty scopes and repeated names are preserved.

Each written scope has its own document-local `ScopeId`; names do not merge
occurrences. `cluster_*` names carry no special parser semantics. Attributes,
assignments, repeated node references and order remain syntax, not effective
defaults or resolved membership. No cycle detection or implicit node creation
occurs. Parsing and traversal are iterative, not recursive.

A subgraph followed by an edge operator becomes the left endpoint of that edge
statement. Right endpoints and chain continuations can also be subgraphs:
`a -> {b; c} -> subgraph s {d}`. Empty endpoints remain explicit scopes,
even though later semantic expansion may produce no node-to-node edges.
Only the edge statement owns trailing attributes. A standalone scope cannot take
a bracket suffix, and a subgraph endpoint cannot take a port suffix.
Malformed headers/endpoints are syntax errors, not unsupported-feature boundaries.

See [scope APIs](SUBGRAPHS.md), [memory](OWNERSHIP.md#subgraphs-and-nesting-scratch)
and [the runnable example](../examples/subgraphs.zig).

## How this page stays honest

Every supported row is exercised by corpus fixtures and/or focused unit
tests (grammar constructs live in `tests/corpus/valid/`; properties like
case-independent keywords and CR line endings live in lexer and renderer
unit tests). Every deferred row's feature is asserted by parser or corpus
tests. When a slice promotes a construct, its fixture moves from
`tests/corpus/unsupported/` to `valid/` and its row moves up in this
table — the two change in the same commit.
