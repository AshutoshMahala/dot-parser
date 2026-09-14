# Working with subgraphs

A subgraph is a written scope, not a separate resolved graph. The parser keeps
one document-wide statement stream and compact records describing scopes within
it. No engine, node-membership index, or layout behavior is required.

## Find scopes and their contents

```zig
var scopes = document.subgraphs(); // All occurrences, in opening/source order.
while (scopes.next()) |scope| {
    const parent = scope.parent().?; // Root has ScopeId.root (zero).
    const raw_name = scope.name();   // Null for anonymous, not for quoted "".
    _ = parent;
    _ = raw_name;

    var children = scope.statements(.direct);
    while (children.next()) |statement| {
        // .subgraph is a standalone child owner; edge endpoints may also name scopes.
        _ = statement;
    }
}
```

`document.scope(id)` is a checked O(1) lookup returning an optional borrowed
`ScopeView`. `document.scope(.root).?` provides the same traversal interface
for the root document. Root's name is the document name, and its parent is null.
`scope.sourceRange()` describes the exact subgraph header/body through its closing
brace (excluding an optional following semicolon). Root's range covers the whole
source; it is null only if that length cannot fit the compact range format.

A `ScopeId` identifies a source occurrence in this document, not a name, interned
node, stable cross-parse handle, or hash. Named, anonymous, and repeated-name
scopes all receive distinct IDs. For raw pool access, scope N uses
`document.subgraph_records[N - 1]`; the root has no pool record.
`StatementId.subgraph` is a zero-based pool index, whereas
`Statement.subgraph` is the public one-based `ScopeId`. Prefer the checked views
instead of manually converting them.

## Choose traversal depth

| View | Direct | Recursive |
| --- | --- | --- |
| `scope.statements(mode)` | Immediate statements, including standalone child scope owners | Every descendant statement, including scope owners |
| `scope.subgraphs(mode)` | Immediate child scopes | All descendant scopes |
| `scope.edges(mode)` | Edges written directly in this scope | Also edges written in descendants |
| `scope.nodeReferences(mode)` | References written directly in this scope | Also references written in descendants |

None includes the scope's own owner statement. Endpoint scopes are not extra
statements; enumerate `scope.subgraphs(mode)` to see all child scopes. Edge views yield ordinary edges
and chain pairs in written order, sharing chain attributes. Node-reference views
include node statements and edge-only endpoints; repeated references remain,
but a chain middle is visited once as written. Resolve each with
`document.nodeReference(reference)`.

`document.statements()` still includes **all** statements. Scope owners occur
before their bodies, so flat consumers do not silently miss nested content.
Use `nextScoped()` instead of `next()` when containing scope matters:

```zig
var statements = document.statements();
while (statements.nextScoped()) |item| {
    // item.scope is the containing scope, not the child scope itself.
    // item.id is the StatementId; item.statement is the normal Statement.
    if (item.statement == .subgraph) {
        const child = document.scope(item.statement.subgraph).?;
        _ = child;
    }
}
```

Both methods advance the same iterator. `document.edgeIterator()` also remains
document-wide. Use root's `.edges(.direct)` when only root-level edges are wanted.

## What membership means here

These APIs answer “what was written inside this scope?” They do not claim a
resolved set of unique graph nodes. For example, `{ a->b->c }` has three written
node references but no explicit node statements. A consumer can decode and
compare identifiers or construct its own membership/reverse index.

Repeated named subgraphs are not merged. Nested scopes are syntactic parents,
not a restriction that nodes belong to only one group. The parser does not
apply graph/node/edge defaults, interpret `rank=same` or `cluster_*`, detect
graph cycles, or expand subgraph edge products. Attributes/assignments are normal
statements in the scope where written. A later semantic pass can interpret them.

## Complexity and ownership

Parsing is O(input bytes + emitted syntax), with no input-dependent recursion.
Fixed parsing uses O(maximum active depth) explicit temporary frames; output is
O(statements + attributes + links + qualified references + scopes). Repeated
ancestor membership lists are not retained.

All scope views/iterators allocate nothing and borrow the document/source pools.
Keep the referenced `Document` value alive at a stable address while using a view
or iterator. Copying a document does not rebind existing views. Pool reuse invalidates
them; scope views have no deinit.

Direct statement traversal skips each child body in O(1), for
O(immediate statements + immediate child scopes) total work. Recursive statement
traversal is O(descendant statements). Child-scope traversal uses subtree intervals:
O(returned scopes) for either mode. Node-reference traversal scans selected
statements and their chain links, skipping subgraph-valued endpoints themselves.
Its order is statement preorder then chain order, not a lexical token stream.
Scope edge traversal seeks into four ordered pools in logarithmic time, then scans
operators within the scope source range. Direct filtering also scans descendant
scope headers; it can inspect descendant operators it does not return.
Enumerating all scopes with `document.subgraphs()` is O(number of scopes).
Global `nextScoped()` uses parent links with amortized O(statements + scopes)
work and constant iterator storage. A single call may close several ancestors;
these consumer traversals are **unbudgeted**. “Recursive” describes inclusion,
not recursive implementation. Repeatedly scanning overlapping recursive views
can repeat work; use one global pass when indexing a whole document.

See [memory and scratch sizing](OWNERSHIP.md#subgraphs-and-nesting-scratch),
[execution/cancellation](EXECUTION.md), and [the runnable example](../examples/subgraphs.zig).
## Subgraphs as edge endpoints

For `a -> {b; c} -> d`, the document retains one outer chain, two body node
statements and one anonymous scope. It does **not** create four node-to-node edges.
`document.edgeIterator()` yields two syntactic edges, with endpoints typed as:

```zig
switch (edge.right) {
    .node => |reference| {
        const node = document.nodeReference(reference).?;
        _ = node;
    },
    .subgraph => |id| {
        const scope = document.scope(id).?;
        _ = scope;
    },
}
```

The same `EdgeView` is used for ordinary edges and mixed chains.
`document.edgeLinks(chain)` walks one chain's continuations in chain order;
`document.edgeLinkCount(chain)` counts them without walking. Use `edgeIterator()`
for global operator order: in `a -> {b -> c} -> d`, it yields the outer first
operator, inner operator, then outer continuation. Statement traversal remains
owner-first: outer chain then inner edge. Scope endpoints have their own source
ranges/IDs but do not add fake standalone statements. Left-position scopes are
classified as standalone versus edge endpoints after their closing brace.

Repeated names are separate occurrences; resolving/merging names, deduplicating
node membership, applying defaults and expanding edge products are still separate
semantic work. Empty endpoint scopes remain visible. See the
[runnable endpoint example](../examples/subgraph_endpoints.zig).
