# Reading a parsed graph

A successful parse gives you a `dot.Document`. It is a faithful record of what
the file says, in the order it says it. This page shows how to read each part.

All the reading functions are cheap and allocate nothing. They return small
values that point into your source text.

## Partial results for editors

> **Unreleased.** Default parsing still returns no document on failure.

To keep a safe prefix of an unfinished DOT file:

```zig
const Editor = dot.Profile(.{ .policy = .{
    .retention = .{ .partial = true },
} });
var result = Editor.parseAndValidate(allocator, source, bag.sink(), .{});
defer result.deinit(allocator);
if (result.document) |*document| {
    _ = document.state;             // .complete or .partial
    _ = document.scopeComplete();   // DOT representation only, not validity
    _ = document.unrepresented();   // remaining raw source range, or null
    var scopes = document.subgraphs();
    while (scopes.next()) |scope| {
        _ = scope.state();
        _ = scope.sourceRange();
    }
}
```

The same `Document` type and traversal functions work for both states. Completed
statements and opened subgraphs remain available; unfinished subgraphs are
marked partial. A pending ordinary statement is not published until its event
is complete. Raw pools can contain already-read attributes, references or links
whose unfinished owner is not yet a statement; use statement and scope views
for an outline. An unfinished raw subgraph has `subtree_end == 0`; views supply
safe prefix bounds without walking the stack at failure time.

Retention freezes at the first failure. `.collect` may continue diagnostics,
but later recovered statements are not added. Unterminated quotes/comments leave
the ambiguous tail raw; no closing delimiter or name is guessed. The returned
tail is not a safe restart point, and can be empty at EOF when a closer is
missing. A failure before a supported graph header has begun returns no document.

This works with fixed/growing storage, both scanners, sessions, cancellation,
limits and runtime policy. Results become readable only when the operation is
terminal, not while a session is paused. Runtime overrides use the same
`retention.partial` leaf. `measure` still returns counts only on success.

Completeness does not imply validity. A fully represented graph can fail
validation; a partial graph is never `documentValid()`. Direct validation checks
retained facts and returns `coverage = .{ .incomplete = first_unrepresented_byte }`.
Automatic validation does that after a `.collect` syntax failure, but never
after an operational stop or `.fail_fast` rejection. It does not validate later
unretained DOT statements. See [memory costs](MEMORY.md#partial-result-storage)
and [retaining composed label trees](LABELS.md#retaining-label-trees-for-editors).

## The document header

| Field | Meaning |
| --- | --- |
| `document.kind` | `.digraph` for `digraph`, `.undigraph` for `graph` |
| `document.strict` | `true` if the file starts with `strict` |
| `document.name` | The graph's name as a range, or `null` if it has none |
| `document.statementCount()` | Number of statements, including those inside subgraphs |

Why `undigraph`? In this library "graph" means any graph, directed or not. So
the undirected kind needs its own name.

## Names: spelling versus value

Every name and value in the document is a *range*: a start offset and a length
in your source. There are two ways to turn a range into text:

- `document.text(range)` returns the exact spelling, including quotes.
- `document.decodeIdentifier(range, &buffer)` returns the actual value.
  `document.writeIdentifier(range, writer)` writes the value without a buffer.

| Written | `text` | Decoded value |
| --- | --- | --- |
| `sensor` | `sensor` | `sensor` |
| `"two words"` | `"two words"` | `two words` |
| `"sen" + "sor"` | `"sen" + "sor"` | `sensor` |
| `"say \"hi\""` | `"say \"hi\""` | `say "hi"` |
| `-01.50` | `-01.50` | `-01.50` (numbers stay text) |
| `<<b>bold</b>>` | `<<b>bold</b>>` | `<b>bold</b>` (outer brackets removed) |
| `東京` | `東京` | `東京` (bytes kept as they are) |

Decoding only undoes DOT's quoting. It does not turn `\n` into a newline,
expand HTML entities, or convert numbers. It also doesn't check that text is
valid UTF-8. That is an optional check in [settings](POLICIES.md#optional-checks).

If you need the decoded size first,
`try dot.identifier.decodedLen(document.text(range))` gives it.

## Statements

`document.statements()` visits every statement in the order it was written.
Each one is a tagged union. You switch on its kind:

| You wrote | Kind | What it holds |
| --- | --- | --- |
| `a;` or `a [color=red];` | `.node` | `reference` (the node) and `attributes` |
| `a -> b;` | `.edge` | `left`, `operator`, `right`, `attributes` |
| `a -> b -> c;` | `.edge_chain` | `first` (the first edge) and the rest of the chain |
| `subgraph s { ... }` or `{ ... }` | `.subgraph` | the subgraph's id |
| `rankdir = LR;` | `.assignment` | `key` and `value` |
| `node [shape=box];` | `.attribute_statement` | `target` (`.graph`, `.node` or `.edge`) and `attributes` |

Statements inside a subgraph are in the same list. They come right after the
subgraph's own statement, so a simple loop never misses nested content. To
know which subgraph a statement is in, see [Subgraphs](#subgraphs).

## Nodes and ports

A node is stored as a small `NodeReference`. Ask the document for its parts:

```zig
const view = document.nodeReference(node.reference).?;
const name = document.text(view.identifier);
if (view.port) |port| {
    // `a:out` has port.first = "out"; `a:out:n` also has port.second = "n".
    _ = port.first;
    _ = port.second;
}
```

The parser records the port text only. It doesn't decide whether `n` is a
named port or a compass direction, because that depends on how the node is
defined elsewhere.

## Edges

`document.edgeIterator()` visits every edge in the file, in source order. A
chain `a -> b -> c` gives two edges: `a -> b`, then `b -> c`.

Each edge end is an `Endpoint`, which is either a node or a subgraph:

```zig
var edges = document.edgeIterator();
while (edges.next()) |edge| {
    switch (edge.right) {
        .node => |reference| {
            const node = document.nodeReference(reference).?;
            _ = node.identifier;
        },
        .subgraph => |id| {
            // `a -> { b c }`: the right end is a whole subgraph.
            const scope = document.scope(id).?;
            _ = scope;
        },
    }
    _ = edge.operator; // .directed (->) or .undirected (--)
    _ = edge.attributes; // shared by every edge of a chain
}
```

`a -> { b c }` is kept as one edge to a subgraph. It is **not** expanded into
`a -> b` and `a -> c`. You can expand it yourself by visiting the subgraph's
nodes (see below).

If you are walking statements and meet an `.edge_chain`, use
`document.edgeLinkCount(chain)` to count the edges after the first, and
`document.edgeLinks(chain)` to visit them.

## Attributes

Nodes, edges and attribute statements carry an `AttributeRange`. Turn it into
a list of key/value pairs with `attributeSlice`:

```zig
for (document.attributeSlice(node.attributes).?) |attribute| {
    const key = document.text(attribute.key);
    _ = key;
    try document.writeIdentifier(attribute.value, writer);
}
```

- Pairs keep their written order.
- Duplicates are kept. `[color=red, color=blue]` gives two pairs. Deciding
  which one wins is up to you.
- Several lists on one statement, like `a [x=1][y=2]`, become one list.
- Defaults are **not** applied. `node [shape=box]` is an
  `.attribute_statement`; nodes after it do not get a `shape` pair.

The [attributes example](../examples/attributes.zig) prints every pair in a
file.

## Subgraphs

Each subgraph written in the file gets its own id, a `ScopeId`. The whole
document is the *root* scope, `ScopeId.root`.

```zig
var scopes = document.subgraphs(); // every subgraph, in source order
while (scopes.next()) |scope| {
    const name = if (scope.name()) |range| document.text(range) else "(no name)";
    const parent = scope.parent().?; // the root has no parent
    _ = name;
    _ = parent;

    var edges = scope.edges(.direct); // edges written directly inside it
    while (edges.next()) |edge| _ = edge;
}
```

A scope can list four things, either `.direct` (only what is written directly
inside it) or `.recursive` (also what is inside nested subgraphs):

| Method | Lists |
| --- | --- |
| `scope.statements(mode)` | statements |
| `scope.subgraphs(mode)` | child subgraphs |
| `scope.edges(mode)` | edges |
| `scope.nodeReferences(mode)` | every place a node is mentioned |

Use `document.scope(id)` to look up a scope by id, and
`document.scope(.root).?` for the whole document.

To know which scope each statement is in while walking the full list, call
`nextScoped()` instead of `next()`:

```zig
var statements = document.statements();
while (statements.nextScoped()) |item| {
    // item.statement is the statement; item.scope is the scope it is in.
    _ = item;
}
```

Keep in mind:

- Two subgraphs with the same name get two different ids. They are not merged.
- `nodeReferences` lists every mention, so `{ a -> b; a }` mentions `a`
  twice. It is not a list of unique nodes.
- `cluster_` names have no special meaning to the parser.

See the [subgraphs example](../examples/subgraphs.zig) and the
[subgraph endpoints example](../examples/subgraph_endpoints.zig).

## What you work out yourself

The document records the file. These questions need decisions that depend on
your program, so they are left to you:

- **Which nodes exist?** Decode node names and remove duplicates.
- **What are a node's final attributes?** Apply `node [...]` defaults and
  subgraph scoping in the order you need.
- **Which node pairs does `a -> { b c }` connect?** Walk the subgraph's
  `nodeReferences(.recursive)`.
- **What does a port mean?** Look at the node's shape or label.

## Comments

> **Unreleased.** Not in 0.4.0.

Comments are skipped by default. To keep them, turn on comment retention. The
parser then records where each comment is; it doesn't interpret or check them.

```zig
const Parser = dot.Profile(.{ .policy = .{
    .retention = .{ .comments = true },
    .limits = .{ .max_comments = 1000 }, // optional cap on kept comments
} });
var parsed = Parser.parseBorrowed(allocator, source, bag.sink(), .{});
defer parsed.deinit(allocator);
if (parsed.document) |document| {
    for (document.comments.?) |comment| {
        _ = comment.kind; // .slash_line, .block, or .hash_line
        _ = comment.span; // byte start and length in document.source
        _ = comment.raw(document.source); // with `//`, `/* */` or `#`
        _ = comment.body(document.source); // without them, otherwise unchanged
        _ = comment.span.locate(document.source); // line and byte column
    }
}
```

- `document.comments` is `null` when retention is off, and an empty list when
  it is on but the file has no comments.
- Comments are listed in source order, separately from statements. They aren't
  attached to the statement next to them.
- Every comment is kept, wherever it is: before or after the graph, inside a
  header or attribute list, or between the parts of a joined name like
  `"a" /* note */ + "b"`.
- Nothing is copied, decoded or trimmed. A line comment's span stops before the
  line break; a block comment's span includes `/*` and `*/`. A `#` line is just
  a comment; it doesn't change line numbers.
- Text that only looks like a comment, inside quotes or an HTML-like value, is
  not a DOT comment. `<!-- ... -->` inside a label belongs to the markup parser.

**Settings.** With run-time settings, pass the same `.retention` in a call's
`.policy`, or in `.dot.policy` when checking labels. The `standard` and
`lenient` presets turn retention off. `parseAndValidate` keeps comments when
asked, but doesn't check them.

**When parsing fails**, there is no document by default. With `retention.partial`
also enabled, complete comments in the retained prefix remain available.
An unclosed `/*` is still a syntax error.

[Comment storage](MEMORY.md#comment-storage) covers sizing.

### Comments from the lexer

If you work with tokens directly, `dot.lexer.WithComments(.scalar)` (or
`(.block)`) also returns comments, as `comment_slash_line`, `comment_block` and
`comment_hash_line` tokens. `token.comment()` gives a `dot.Comment` for those,
and `null` for any other token. The ordinary `Lexer` and `For` still skip
comments.

- Each complete comment comes out exactly once, even while the lexer recovers
  from an error. An unclosed comment is reported as an error, not a token.
- A comment inside a joined name, like `"a" /* note */ + "b"`, comes out
  before the name's token. So the full token list **isn't sorted by position,
  and spans can overlap**. The comments on their own are in order, and
  skipping the comment tokens gives exactly the ordinary token list.
- This doesn't return whitespace or separators, so you can't rebuild the file
  exactly from the tokens.

## Lifetimes

- Keep the source text alive and unchanged while you use the document or any
  view from it.
- If you reuse the document's storage for another parse, earlier documents and
  views from that storage become invalid.
- A finished document is read-only. Several threads may read it at once.

[Memory](MEMORY.md) covers ownership in detail.

## Examples

- [identifiers.zig](../examples/identifiers.zig): spelling versus decoded value,
  joined strings, numbers and non-ASCII names
- [attributes.zig](../examples/attributes.zig): attribute lists, defaults and
  assignments
- [edge_chains.zig](../examples/edge_chains.zig): chains and the edge iterator
- [ports.zig](../examples/ports.zig): reading ports
- [subgraphs.zig](../examples/subgraphs.zig): scopes, direct and recursive views,
  and `nextScoped()`
- [subgraph_endpoints.zig](../examples/subgraph_endpoints.zig): edges whose end
  is a subgraph

Run them with `zig build examples`. Each program is also installed in
`zig-out/bin/`.
