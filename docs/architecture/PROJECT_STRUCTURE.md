# Project Structure

Status: living document — updated as slices land  
Last updated: 2026-09-18 (diagnostics overhaul)

The package is a standalone Zig DOT-language library and must not depend on
Zigraph.

## Design rule

Start with a small physical layout and split modules only when responsibilities
actually grow. Architectural boundaries are important from the first commit;
having one file per hypothetical future feature is not.

The [optional execution contract](EXECUTION_CONTRACT.md) defines implemented
bounded parsing and cancellation, now available for caller-owned fixed storage.

## Current layout

```text
dot-parser/
├── build.zig
├── build.zig.zon
├── CHANGELOG.md
├── LICENSE-APACHE
├── LICENSE-MIT
├── README.md
├── src/
│   ├── root.zig
│   ├── location.zig
│   ├── diagnostic.zig
│   ├── console.zig
│   ├── lexer.zig
│   ├── execution.zig          (feature flags and borrowed cancellation hook)
│   ├── identifier.zig
│   ├── syntax_event.zig
│   ├── parser.zig
│   ├── scratch.zig            (explicit reusable nesting frames)
│   ├── syntax.zig
│   └── validate.zig
├── tests/
│   ├── integration.zig
│   ├── attributes.zig
│   ├── edge_chains.zig
│   ├── ports.zig
│   ├── subgraphs.zig
│   ├── subgraph_endpoints.zig
│   ├── sessions.zig
│   ├── freestanding_session.zig
│   ├── diagnostics.zig        (probe table: identity, location, wording)
│   ├── measure.zig            (count-only dry run equals retained pools)
│   └── corpus/
│       ├── README.md          (corpus governance)
│       ├── valid/
│       ├── invalid/
│       └── unsupported/       (recognized-but-deferred constructs)
├── examples/
│   ├── parse_undigraph.zig
│   ├── fixed_buffer.zig
│   ├── diagnostics_demo.zig
│   ├── identifiers.zig
│   ├── attributes.zig
│   ├── bounded.zig
│   ├── edge_chains.zig
│   ├── ports.zig
│   ├── subgraphs.zig
│   ├── subgraph_endpoints.zig
│   └── check_file.zig         (command-line checker: recovery + renderer)
├── bench/
│   ├── throughput.zig         (parse + validate, retained memory)
│   ├── lexer.zig              (lexical fixtures, no timed allocation)
│   ├── session.zig            (independent execution-policy costs)
│   └── subgraphs.zig          (sibling/deep scope costs)
└── docs/
    ├── SUPPORTED_SYNTAX.md
    ├── SUBGRAPHS.md
    ├── OWNERSHIP.md
    ├── OUTCOMES.md
    ├── EXECUTION.md
    ├── BASELINES.md
    ├── architecture/
    │   ├── PROJECT_STRUCTURE.md
    │   └── EXECUTION_CONTRACT.md
    └── internal/              (contributor-facing requirements and questions)
```

Unit tests live beside the code they exercise. `tests/integration.zig`
tests the public API exactly as an external consumer, and `tests/corpus`
holds reusable DOT inputs grouped by expected outcome class (see its
README for the governance rules).

## File responsibilities

### `src/root.zig`

The public package surface. It re-exports intentionally public types and
convenience entry points. It must not expose internal storage layouts merely
because they are convenient during development.

### `src/location.zig`

Small source primitives:

- `Location`: byte offset, physical line, and byte column.
- `Span`: start and byte length, with optional starting location.
- Newline tracking for LF, CRLF, and CR.

This module performs no allocation and does not interpret Unicode display
width.

### `src/diagnostic.zig`

WDP diagnostic identities and typed diagnostic fields:

- Diagnostic severity and code. Components are logical domains (`Syntax`,
  `Validation`, `Resource`, `Profile`), never source modules; a code names
  one condition and the grammar position travels in the payload.
- Source location/span, plus typed related locations (the open delimiter,
  the suspect misindented brace).
- Parse/validation outcome categories.
- Fixed-capacity and streaming diagnostic sink helpers.

Human-readable catalogs, localization, JSON, and runtime hashing do not belong
in the initial core; `console.zig` is the optional renderer that turns the
payloads into wording and is dropped by the linker when unused.

### `src/lexer.zig`

The shared raw-byte scanner implementation. `root.zig` selects `Token`, `Result`,
and ordinary `Lexer` for the public namespace; internal factories and scan
drivers are not re-exported. It recognizes:

- Every DOT keyword (`graph`, `digraph`, `strict`, `node`, `edge`, and
  `subgraph`), case-independently. Keywords always tokenize;
  whether one is legal in its position is the parser's decision.
- Bare ASCII, numeral, and quoted identifiers (including `+` concatenation).
- `{`, `}`, `;`, `:`, `[`, `]`, `=`, `,`, `--`, and `->`.
- Whitespace and physical line endings (LF, CRLF, standalone CR); a leading
  UTF-8 byte order mark is skipped.
- Comments, skipped without retaining trivia (see [supported syntax](../SUPPORTED_SYNTAX.md)).
- End of input, invalid bytes, malformed operators (`-`, `-->`) and
  incomplete numerals (`.`, `-.`), each its own typed failure; a numeral
  running into a letter or second dot raises a warning the parser forwards.
- Introducers of deferred *lexical* constructs (HTML/non-ASCII bare
  identifiers), reported
  as typed unsupported-feature failures.
- Resumption after a failure, so the parser's statement-boundary recovery
  can continue past malformed bytes.

It borrows source spans, performs no hidden allocation, and owns no AST types.
Ordinary lexing and the private metered parser share one resumable scanner.
Metered scanning can yield within every supported lexical form; public parsing
can run to completion or through fixed-storage sessions. Budget/frontier counters compile out of
ordinary lexing; shared continuation-state and throughput costs are recorded
in [baselines](../BASELINES.md).

### `src/identifier.zig`

Explicit logical-value decoding over one raw identifier expression. Uses the
lexer to validate spelling, then emits decoded chunks into caller memory or a
writer. It performs no allocation, caching, Unicode normalization, layout
escape interpretation, or numeric conversion. The document offers convenience
methods over this module without adding fields to retained records.

### `src/parser.zig`

The parser state machine and a private, provisional syntax-event contract. It
parses one document and emits source-shaped events. It does not allocate AST
nodes directly and does not know about graph engines.

Under the opt-in `recovery = .statements` policy a body syntax error aborts
the sink once and the grammar keeps running for diagnostics only,
resynchronizing at `;`/`}`; the default remains fail-fast.

Public facades offer run-to-completion and fixed-storage sessions. The metered specialization
separately charges scanning, grammar transitions, and event attempts, retaining
one token and pending action across yields. The ordinary specialization uses
the same grammar with immediate callbacks and no pending-work/progress fields.
Cancellation adds a borrowed hook and polls before each microstep. It can be
selected independently of metering; disabled features compile out. `root.zig`
owns the fixed-session API, lifetime rules, and public storage-failure mapping.

### `src/syntax.zig`

The borrowed, index-based syntax document (`Document`) and its two builders
(allocator-backed and fixed-storage). The builders are the first consumers
of the private syntax-event contract.

Document data includes:

- Document kind (`undigraph` or `digraph`), the `strict` marker, and the
  optional graph name.
- Ordered statement IDs, including standalone subgraph owners in preorder.
- Compact scope occurrence records with parent IDs, source ranges and body
  intervals; allocation-free direct/recursive views and scope-aware traversal.
- Node statements.
- Edge statements with the written operator and compact node references.
- Inline bare identifier ranges or pooled qualified occurrences, exposed through
  checked reference views. Port suffixes remain raw first/optional second IDs.
- Chain statements with a first edge and compact continuation-link range;
  no eager pairwise expansion. The edge iterator provides an allocation-free view.
- Standalone assignments and graph/node/edge attribute statements.
- Ordered key/value pairs in an attribute pool, referenced by compact ranges;
  adjacent groups are flattened and duplicate keys are preserved.

The document preserves written statements. It does not synthesize implicit
nodes from an edge statement.

### `src/validate.zig`

Validation over syntax data. It completes after independent validation errors
and writes them to a caller-supplied diagnostic sink or bag. The current rule
is kind-agnostic: an `undigraph` requires `--` and a `digraph` requires `->`;
every mismatched edge yields its own diagnostic.

## Target layout after responsibilities grow

The initial flat files may evolve into this structure. These directories should
be created only when their modules are implemented:

```text
src/
├── root.zig
├── core/
│   ├── location.zig
│   ├── limits.zig
│   ├── outcome.zig
│   └── diagnostic.zig
├── source/
│   ├── bytes.zig
│   ├── chunks.zig
│   └── decoding_adapter.zig
├── lexer/
│   ├── token.zig
│   └── lexer.zig
├── parser/
│   ├── parser.zig
│   ├── syntax_sink.zig
│   └── drivers.zig
├── syntax/
│   ├── tree.zig
│   ├── storage.zig
│   └── builder.zig
├── validation/
│   ├── validator.zig
│   └── rules/
├── ir/
│   ├── dot_ir.zig
│   ├── storage.zig
│   └── lower.zig
├── diagnostics/
│   ├── codes.zig
│   ├── fixed_bag.zig
│   └── catalog.zig
├── observability/
│   └── observer.zig
├── encoding/
│   └── utf8.zig
└── tooling/
    ├── serialize.zig
    └── source_index.zig
```

Engine-specific adapters should normally live in their own packages or
repositories. This repository may contain generic adapter contracts and example
targets, but not a Zigraph dependency.

## Dependency direction

Dependencies flow inward to outward:

```text
core
  ↑
source and lexer
  ↑
parser and private syntax-event contract
  ├──→ syntax builder and syntax tree
  ├──→ direct event consumers
  └──→ drivers

syntax tree
  ├──→ validation
  ├──→ DotIR lowering
  └──→ optional tooling

DotIR
  ├──→ semantic validation
  ├──→ documentation and analysis
  └──→ generic engine-target adapters
```

Forbidden dependencies:

- Core must not depend on lexer, parser, AST, IR, logging, or an engine.
- Lexer must not depend on parser, AST, or IR.
- Parser must not depend on an AST builder or engine.
- Syntax-tree storage must not depend on validation or `DotIR`.
- `DotIR` and adapters must not leak back into parser types.
- Observability must not become a required logging dependency.

## Ownership and memory boundaries

```text
Source bytes        caller-owned; borrowed for as long as spans are used
Parser state        temporary; fixed-size plus explicit scratch memory
Syntax tree         mid-term; caller allocator/arena/fixed buffer
Validation bag      caller-selected: streamed, fixed, or arena-backed
DotIR               optional mid/long-term caller-owned storage
Engine data         owned entirely by the engine adapter/consumer
```

No module may silently promote borrowed data into long-term ownership. Copying
must be requested explicitly and supplied with explicit memory.

## Public versus provisional contracts

During the experimental `0.x` phase:

- `root.zig` convenience functions are public but unstable.
- The syntax-event sink remains private/provisional.
- Syntax-tree types may change while the first slices teach us their real shape.
- `GraphTarget` is deferred until `DotIR` exists.
- No stable ABI or serialized tree format is promised.

## Test organization

Use four complementary levels:

1. **Unit tests:** colocated with location, lexer, parser, storage, and validation
   code.
2. **Public integration tests:** exercise only imports from `root.zig`.
3. **Corpus tests:** DOT files grouped by outcome class (valid, invalid,
   unsupported) with expected statements, diagnostics, or features.
4. **Property/fuzz tests:** `std.testing.fuzz` harness with determinism
   checks; every discovered regression becomes a permanent small test.

Every module that accepts memory must be tested with a deliberately undersized
fixed buffer. Every parser boundary should be tested with input truncated at
each byte position.

## Standalone scope storage

Subgraphs are records plus intervals into the single global statement order, not
separately allocated child trees. Root is scope zero; subgraph IDs identify source
occurrences. Scope views add no retained membership index. Iterators skip body
intervals for direct traversal or scan descendants iteratively for recursive views.
Global scope-aware traversal ascends parent links amortized linearly.

`scratch.zig` owns only the nesting-frame representation/stack mechanics.
The facade owns its lifetime; the parser borrows it and pushes/pops in constant
fixed-storage work. Builders retain parent IDs independently, closing body/source
ranges on exit. Allocator-backed scratch can use a separate temporary allocator;
fixed parsing receives a document/scratch memory bundle. Neither parser nor
builder uses input-dependent recursion or integrates graph-engine semantics.

Endpoint edges use separate generalized owner/link pools while public edge views
share a node-or-scope endpoint union. The prefix before promotion remains in its
original node-only link range. Indexed links tolerate nested owners without
copying, recursion or eager expansion. Endpoint scopes have no standalone order
entry; global statement traversal remains owner-first. A subtree scope boundary
supports direct-child traversal independently of statement kinds.

See `examples/subgraph_endpoints.zig` for the public endpoint switch and
`tests/subgraph_endpoints.zig` for nested ordering, storage failures, work
partitioning and cancellation coverage.
