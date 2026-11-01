# Supported DOT syntax

This page lists exactly which DOT input the parser accepts. It follows the
written [DOT grammar](https://graphviz.org/doc/info/lang.html) first, and uses
Graphviz 16 as the reference where the grammar leaves something open. Every
known place where it reads input differently from Graphviz is listed
[below](#differences-from-graphviz).

## At a glance

| Construct | Example | Status |
| --- | --- | --- |
| Undirected graph | `graph { ... }` | Supported. `document.kind` is `.undigraph`. |
| Directed graph | `digraph { ... }` | Supported. `document.kind` is `.digraph`. |
| `strict` | `strict digraph { ... }` | Recorded in `document.strict`. Duplicate edges are not checked or merged. |
| Graph name | `digraph G { ... }` | Supported, in any name form |
| Node | `a;` | Supported |
| Edge | `a -> b;` `a -- b;` | Supported. Both operators parse in both graph kinds; a mismatch is reported by validation. |
| Edge chain | `a -> b -> c;` | Supported, stored as one statement |
| Attribute list | `a [color=red, shape=box];` | Supported, on nodes, edges and chains |
| Default attributes | `node [shape=box];` | Supported. Recorded, not applied. |
| Assignment | `rankdir = LR;` | Supported |
| Subgraph | `subgraph s { ... }`, `{ ... }` | Supported, named or not, nested |
| Subgraph as edge end | `a -> { b c };` | Supported. Not expanded into separate edges. |
| Port | `a:out`, `a:out:n` | Supported on nodes |
| Optional semicolons | `a -> b b -> c` | Supported, as in Graphviz |
| Comments | `//`, `/* */`, `#` | Supported, skipped |
| HTML-like value | `label=<<b>hi</b>>` | Supported, kept as written. See [checking HTML-like labels](LABELS.md). |
| Leading byte order mark | UTF-8; UTF-16 and UTF-32 when turned on | Skipped, but left in your source buffer. See [source encodings](ENCODINGS.md). |
| Empty statement | `a;;` | Rejected by default. [Lenient](POLICIES.md#lenient-syntax) accepts it. |
| Long operator | `a --> b`, `a --- b` | Rejected by default. Lenient reads it as `->` / `--`. |
| `--` before a negative number | `a---1`, `a---.5` | (unreleased) Supported, as in Graphviz: the edge `a -- -1`. Not a long operator. |
| Lone dash | `a - b` | Rejected by default. Lenient reads it as `--` after `graph` and `->` after `digraph`. |

## Names

This page describes UTF-8 input, the default. UTF-16 and UTF-32 input
follows the same grammar, and positions still count bytes of the
original file; see [source encodings](ENCODINGS.md).

DOT calls names *IDs*. Every form below works anywhere a name can go: graph
and subgraph names, nodes, both parts of a port, and attribute keys and values.

- **Plain words**: letters, digits and `_`, not starting with a digit. Any byte
  from 0x80 to 0xFF counts as a letter, so `café` and `東京` work. Bytes are
  kept exactly. They are not checked as UTF-8 unless you turn on that
  [check](POLICIES.md#optional-checks).
- **Numbers**: `42`, `-1.5`, `.5`. They stay text; `01.50` is not changed to
  `1.5`. There is no `+` sign or exponent. `1e3` is read as the number `1`
  followed by the name `e3`, with a warning, exactly as Graphviz does.
- **Quoted strings**: `"any text"`. Inside, `\"` is a quote and a backslash at
  the end of a line joins the lines. Every other backslash is kept as it is:
  `\n` stays two characters. An empty string `""` is allowed.
- **Joined strings**: `"sen" + "sor"` is one name, `sensor`. HTML-like parts
  can be joined too.
- **HTML-like values**: `<...>`, ending where the `<` and `>` balance.

**Keywords** (`graph`, `digraph`, `subgraph`, `node`, `edge`, `strict`, in any
letter case) can't be used as names unless quoted: `"node"`. A word that
merely starts with a keyword, like `graphs`, is fine.

[Reading a parsed graph](READING_DOCUMENTS.md#names-spelling-versus-value)
shows how to get the value of each form.

## Statements

- **Attribute lists** go in `[ ]`. Pairs can be separated by `,`, `;` or
  nothing, with one optional trailing separator. Several lists in a row,
  `a [x=1][y=2]`, are combined. Empty lists `[]` are allowed.
- **Edge attributes** follow the whole chain: `a -> b -> c [color=red]`. A list
  in the middle, `a -> b [x=1] -> c`, is an error.
- **`graph`, `node` and `edge` default statements** need at least one list.
- **Ports** are `node:port` or `node:port:compass`. A colon inside quotes is
  part of the name. The parser doesn't decide what a port means. Subgraphs
  can't have ports.
- **Subgraphs** can contain any statement, including other subgraphs. Each
  one written is kept separately, even if two share a name.

## Comments, whitespace and bytes

- `//` and `#` comments run to the end of the line. `#` works at the start of
  any token, not only at the start of a line.
- `/* */` comments don't nest. They end at the first `*/`.
- Comments separate tokens. They can't split a keyword or an operator.
- Comments are skipped by default. You can [keep them](READING_DOCUMENTS.md#comments);
  the parser records their kind and position without interpreting them.
- Lines can end with LF, CRLF or a lone CR.
- Control bytes (other than tab and line endings) are errors outside comments,
  quotes and HTML-like values. A NUL byte inside quotes is also an error.
- A UTF-8 byte order mark (BOM) at the very start is skipped. Positions still
  count its three bytes. A BOM anywhere else is not skipped: its bytes are read
  like any other byte from 0x80 to 0xFF, so they become part of a name. See
  the [differences](#differences-from-graphviz).

## Differences from Graphviz

These are known and kept on purpose. Each was confirmed with Graphviz 16
(16.0.0 or 16.1.0).

| Input | Graphviz 16 | This library | Why |
| --- | --- | --- | --- |
| `graph { a // c` + CR + `b }` | Error | Accepted | A lone CR ends a line everywhere here, including in comments. |
| `graph { a; } x` | Accepted | Error | The whole input must be one graph. Trailing text is likely a mistake. |
| `graph {} /* unfinished` | Accepted | Error | Same reason. |
| A backslash before CRLF or CR inside quotes | Only removes a backslash before LF | Removes all three forms | Line endings are treated the same everywhere. |
| `# 10 "file.dot"` | Read as a line-number directive | A comment | Positions always refer to the bytes you passed in. |
| `strict` | Merges duplicate edges | Only recorded | Merging is graph building, not parsing. The optional [semantic graph](IR.md) merges them. |
| Comma node lists: `a, b [color=red]`, `a -> b, c` | Accepted: the list or edge applies to every node named | Error at the `,` | The written grammar has no node lists. |
| An attribute list after a standalone subgraph: `{ a } [color=red]` | Accepted, but the list isn't applied to anything | Error at the `[` | The written grammar doesn't allow it. |
| Attribute macros: `node m = [color=red]` | Accepted with a warning that macros aren't implemented; the list still applies | Error | The written grammar has no macros. |
| A BOM between tokens, not touching a name: `a ->` BOM ` b` | Skipped like a space | Read as a name made of the BOM's bytes. Here that is the edge `a ->` BOM, and `b` is a separate node. In other places, such as inside `[ ]`, it is a syntax error. | Only a BOM at the very start of the input is skipped. |
| A BOM at the very start, directly followed by `digraph` | Error: the BOM is read as part of the keyword | Accepted | Same reason. |

A BOM that touches a name, as in `a` BOM `b`, is part of that name in both.

The comma error comes with a suggested fix that replaces `,` with `;`. It is
marked as one possible repair, because it changes the meaning: `a; b [color=red]`
colors only `b`. To keep Graphviz's meaning, write `a [color=red]; b [color=red]`.

One case goes the other way. The written grammar only joins quoted strings
with `+`, but Graphviz 16 also joins HTML-like parts. This library follows
Graphviz there.

This page is about reading the text. For differences in the graph built from
it, such as edge `key` and HTML-like names, see the
[semantic graph](IR.md#default-and-update-rules).

## Size limits

- Input can be up to 4 GiB. Positions are stored as 32-bit numbers, and a
  larger input is refused before parsing starts.
- You can set lower limits on statements, attributes and nesting in the
  [settings](POLICIES.md#limits-and-other-settings).

## How this page stays accurate

The [test corpus](../tests/corpus/) has example files for the main
constructs: [valid](../tests/corpus/valid/) input,
[invalid](../tests/corpus/invalid/) variants, and input reported as
[unsupported](../tests/corpus/unsupported/) when a feature is turned off. The
tests check each file's expected result. Other cases, such as ports and
HTML-like values, have their own tests in [tests](../tests/). See
[tests/corpus/README.md](../tests/corpus/README.md) for the rules.

## Examples

- [identifiers.zig](../examples/identifiers.zig): joined quoted strings,
  numbers and non-ASCII names, with their spelling and their value
- [attributes.zig](../examples/attributes.zig): attribute lists, default
  statements and assignments
- [edge_chains.zig](../examples/edge_chains.zig): edge chains
- [ports.zig](../examples/ports.zig): ports, including a compass point
- [subgraphs.zig](../examples/subgraphs.zig) and
  [subgraph_endpoints.zig](../examples/subgraph_endpoints.zig): nested
  subgraphs, and subgraphs as edge ends
- [comments.zig](../examples/comments.zig): keeping comments
- [policies.zig](../examples/policies.zig): the lenient preset accepting
  `;;`, `-->` and a lone `-`

Run them with `zig build examples`. Each program is also installed in
`zig-out/bin/`.
