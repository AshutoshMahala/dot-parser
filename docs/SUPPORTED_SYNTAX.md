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
| Graph names | **Supported** | Bare ASCII identifiers only (`Document.name`); quoted/numeral/HTML names are deferred with those identifier forms |
| Node statements (`a;`) | **Supported** | |
| Edge statements (`a -- b;`, `a -> b;`) | **Supported** | Both operators always *parse*; kind×operator legality is a validation rule, not a parse error |
| Optional semicolons | **Supported** | As in Graphviz: `digraph G { a -> b b -> c }` |
| Bare ASCII identifiers | **Supported** | `[A-Za-z_][A-Za-z0-9_]*`; keywords are case-independent and reserved in every position |
| Whitespace / line endings | **Supported** | Space, tab; LF, CRLF, and standalone CR each end a line |
| Subgraphs (`{ … }`, `subgraph s { … }`) | Deferred | Feature `subgraph`, including subgraphs as edge endpoints |
| Edge chains (`a -- b -- c`) | Deferred | Feature `edge_chain` |
| Attribute lists (`[color=red]`) | Deferred | Feature `attribute_list` |
| Attribute statements (`graph`/`node`/`edge` + `[…]`) | Deferred | Features `graph_attribute_statement`, `node_attribute_statement`, `edge_attribute_statement` |
| ID assignments (`rankdir = LR`) | Deferred | Feature `attribute_assignment` |
| Quoted identifiers (`"a b"`) | Deferred | Feature `quoted_identifier` |
| HTML identifiers (`<…>`) | Deferred | Feature `html_identifier` |
| Numeral identifiers (`3`, `-.5`) | Deferred | Feature `numeral_identifier` |
| Non-ASCII identifiers (bytes `0x80`–`0xFF`) | Deferred | Feature `non_ascii_identifier`; the whole run is one span |
| Comments (`//`, `/* */`, `#`) | Deferred | Feature `comment` |
| Ports and compass points (`a:n`) | Deferred | Feature `port_or_compass` |

## Compatibility notes

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

## How this page stays honest

Every supported row is exercised by corpus fixtures and/or focused unit
tests (grammar constructs live in `tests/corpus/valid/`; properties like
case-independent keywords and CR line endings live in lexer and renderer
unit tests). Every deferred row's feature is asserted by parser or corpus
tests. When a slice promotes a construct, its fixture moves from
`tests/corpus/unsupported/` to `valid/` and its row moves up in this
table — the two change in the same commit.
