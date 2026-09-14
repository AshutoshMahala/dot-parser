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
        // .subgraph carries the child's ScopeId; other variants are unchanged.
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
| `scope.statements(mode)` | Immediate statements, including child scope owners | Every descendant statement, including scope owners |
| `scope.subgraphs(mode)` | Immediate child scopes | All descendant scopes |
| `scope.edges(mode)` | Edges written directly in this scope | Also edges written in descendants |
| `scope.nodeReferences(mode)` | References written directly in this scope | Also references written in descendants |

None includes the scope's own owner statement. Edge views yield ordinary edges
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

Direct statement traversal skips a child body in O(1), so a complete traversal
is O(immediate statements). Recursive traversal is O(descendant statements).
Subgraph/reference/edge filters scan the selected statements, plus any yielded
chain links: their cost is not just the number of returned results.
Enumerating all scopes with `document.subgraphs()` is O(number of scopes).
Global `nextScoped()` uses parent links with amortized O(statements + scopes)
work and constant iterator storage. A single call may close several ancestors;
these consumer traversals are **unbudgeted**. “Recursive” describes inclusion,
not recursive implementation. Repeatedly scanning overlapping recursive views
can repeat work; use one global pass when indexing a whole document.

See [memory and scratch sizing](OWNERSHIP.md#subgraphs-and-nesting-scratch),
[execution/cancellation](EXECUTION.md), and [the runnable example](../examples/subgraphs.zig).
Subgraphs used as edge endpoints remain the next separate syntax slice.
