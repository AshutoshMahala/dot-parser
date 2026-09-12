# Supported DOT syntax

The authoritative compatibility page. The grammar grows one vertical slice
at a time; a construct is listed as supported only when it parses end to
end today. Deferred constructs are *recognized*: the parse stops at their
introducer with a typed `unsupported_feature` diagnostic naming the
construct, never a generic syntax error (see
[OUTCOMES.md](OUTCOMES.md) for that distinction).

## Terminology

In this library **`graph` always means "either kind"**. The undirected
kind is called `undigraph`, the directed kind `digraph`. Only at reading
time does the DOT source keyword `graph` map to the kind `undigraph`.

## Constructs

| Construct | Status | Notes |
| --- | --- | --- |
| `graph { … }` documents | **Supported** | Exposed as kind `.undigraph` |
| `digraph { … }` documents | **Supported** | Exposed as kind `.digraph` |
| `strict` modifier | **Supported** | Parsed and retained (`Document.strict`); strictness semantics (duplicate-edge rules) are not enforced |
| Graph names | **Supported** | Bare ASCII, numeral, or quoted identifier expressions (`Document.name`); HTML/non-ASCII bare names remain deferred |
| Node statements (`a;`) | **Supported** | |
| Edge statements (`a -- b;`, `a -> b;`) | **Supported** | Both operators always *parse*; kind×operator legality is a validation rule, not a parse error |
| Optional semicolons | **Supported** | As in Graphviz: `digraph G { a -> b b -> c }` |
| Bare ASCII identifiers | **Supported** | `[A-Za-z_][A-Za-z0-9_]*`; keywords are case-independent and reserved in every position |
| Numeral identifiers | **Supported** | `-?(.[0-9]+ \| [0-9]+(.[0-9]*)?)`; exact text, no numeric conversion |
| Quoted identifiers and `+` concatenation | **Supported** | Exact raw range; explicit value decoding, including escaped quotes and physical line continuations |
| Whitespace / line endings | **Supported** | Space, tab; LF, CRLF, and standalone CR each end a line |
| Comments (`//`, `/* */`, `#`) | **Supported** | Skipped without retention; see compatibility notes below |
| Subgraphs (`{ … }`, `subgraph s { … }`) | Deferred | Feature `subgraph`, including subgraphs as edge endpoints |
| Edge chains (`a -- b -- c`) | Deferred | Feature `edge_chain` |
| Attribute lists (`[color=red]`) | Deferred | Feature `attribute_list` |
| Attribute statements (`graph`/`node`/`edge` + `[…]`) | Deferred | Features `graph_attribute_statement`, `node_attribute_statement`, `edge_attribute_statement` |
| ID assignments (`rankdir = LR`) | Deferred | Feature `attribute_assignment` |
| HTML identifiers (`<…>`) | Deferred | Feature `html_identifier` |
| Non-ASCII identifiers (bytes `0x80`–`0xFF`) | Deferred | Feature `non_ascii_identifier`; the whole run is one span |
| Ports and compass points (`a:n`) | Deferred | Feature `port_or_compass` |

## Compatibility notes

- **Comment handling**: `#` starts a line comment at any token boundary,
  including after indentation or another token (matching Graphviz 15.1.0).
  Block comments do not nest and end at the first `*/`. Line comments end at
  LF, CRLF, standalone CR, or EOF. Standalone CR termination is an intentional
  difference: Graphviz 15.1.0 rejects `graph { a // c\r b }` and its `#`
  equivalent, while this library treats CR as a physical newline and accepts
  both (here `\r` denotes one CR byte).
  Preprocessor line numbers and file names are discarded; diagnostics always
  use physical positions in the supplied bytes. Comment bodies are opaque
  bytes, with no encoding validation. An unterminated block comment is
  `invalid_syntax`, diagnosed at its opening `/*` as `E.Lexer.Syntax.031`
  with `.unterminated = .block_comment`.
  Comments separate tokens; they cannot splice a keyword or edge operator.
  Comment markers inside quoted identifiers are content. HTML-like identifiers
  remain deferred and their bodies are not scanned.
- **Whole-document consumption**: after the root closing `}`, only whitespace,
  complete comments, and end of input are accepted. Malformed trailing comments
  and additional tokens are errors. Graphviz 15.1.0 accepts the specific inputs
  `graph {} /* unfinished` and `graph { a; } x`; this library rejects both.
- **Keywords are reserved words everywhere**, matching Graphviz: an
  unquoted keyword is never an identifier. `graph graph {}` and
  `graph { a -- node; }` are syntax errors (verified against Graphviz
  15.1.0), not deferred features.
- **Kind-agnostic parsing**: `digraph { a -- b; }` parses successfully;
  the operator/kind mismatch is reported by validation as
  `E.Validation.Operator.002`. Consumers with dialect-tolerant needs can
  skip or ignore validation.
- **Limits**: retained positions address at most 4 GiB of source
  (`storage_failure: .source_offset_overflow` beyond that);
  `ParseOptions.max_statements` optionally bounds output size.

## Identifier lexical rules

All supported forms work as document names, node IDs, and edge endpoints.
Quoted keywords such as `"graph"` are identifiers, never keyword tokens. An
empty quoted identifier is accepted. Adjacent quoted strings without `+` are
separate tokens; only quoted strings may be joined by `+`. Whitespace and
comments may occur on either side of it.

The lexer retains one raw-expression range. Explicit decoding removes the
quotes and concatenation glue, converts `\"` to `"`, and removes a backslash
followed by LF, CRLF, or standalone CR. All other escapes remain unchanged:
`\n` is two bytes, and `\\` remains two backslashes. Unescaped physical line
endings within quotes are preserved as written. This is DOT lexical decoding,
not a C/JSON unescaper or Graphviz label/attribute interpretation.

Non-ASCII bytes and non-NUL control bytes inside quotes are preserved without
UTF-8 validation. NUL inside quotes is rejected as `E.Lexer.Byte.003` at the
offending byte, not silently truncated. Non-ASCII bare IDs and a leading UTF-8
BOM remain on the existing deferred-feature path; BOM stripping, transcoding,
and encoding validation are not implemented.

An unterminated quoted segment reports `E.Lexer.Syntax.031` with
`.unterminated = .quoted_identifier` at that segment's opening quote, including
when it is a later part of a concatenation. A missing quoted operand after `+`
reports `E.Lexer.Syntax.003` with `.expected_quote` containing the next raw byte,
or null at EOF. Neither failure returns a partial document.

Numerals have no leading `+`, exponent, or numeric normalization. Maximal
matching means `1e3` is tokens `1` and `e3`, and `1.2.3` is `1.2` and `.3`;
in a statement list these can be separate nodes because separators are optional.
This parser emits no ambiguity warning for those cases. Bare `.` and `-.`
remain invalid.

**Verification:** the written [DOT grammar](https://graphviz.org/doc/info/lang.html)
is primary and Graphviz 15.1.0 remains the pinned differential baseline.
Additional manual identifier probes used the locally installed Graphviz 16.0.0
on 2026-09-12; they do not replace a pinned automated suite. The checked forms
include numeral boundaries, quoted concatenation, raw multiline content,
escaped quotes/backslashes, and control bytes. A deliberate difference in the
checked 16.0.0 behavior: it removes escaped LF but preserves escaped CRLF/CR;
this library removes all three, consistently with its physical-line policy.

Token-length/work budgets remain future work. Fixed output pools limit retained
statements, not the length of an individual lexical scan or the source retained
by a borrowed document.

## How this page stays honest

Every supported row is exercised by corpus fixtures and/or focused unit
tests (grammar constructs live in `tests/corpus/valid/`; properties like
case-independent keywords and CR line endings live in lexer and renderer
unit tests). Every deferred row's feature is asserted by parser or corpus
tests. When a slice promotes a construct, its fixture moves from
`tests/corpus/unsupported/` to `valid/` and its row moves up in this
table — the two change in the same commit.
