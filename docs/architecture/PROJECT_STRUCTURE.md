# Proposed Project Structure

Status: discussion draft 0.1  
Date: 2026-07-15

This structure assumes the implementation language is Zig. The package remains
a standalone DOT-language library and must not depend on Zigraph.

## Design rule

Start with a small physical layout and split modules only when responsibilities
actually grow. Architectural boundaries are important from the first commit;
having one file per hypothetical future feature is not.

## Initial vertical-slice layout

Create only these implementation files for the first anonymous-undigraph slice:

```text
dot-parser/
├── build.zig
├── build.zig.zon
├── LICENSE-APACHE
├── LICENSE-MIT
├── README.md
├── src/
│   ├── root.zig
│   ├── location.zig
│   ├── diagnostic.zig
│   ├── console.zig
│   ├── lexer.zig
│   ├── syntax_event.zig
│   ├── parser.zig
│   ├── syntax.zig
│   └── validate.zig
├── tests/
│   ├── integration.zig
│   └── corpus/
│       ├── valid/
│       └── invalid/
├── examples/
│   ├── parse_undigraph.zig
│   └── fixed_buffer.zig
└── docs/
    └── architecture/
        └── PROJECT_STRUCTURE.md
```

Unit tests should live beside the code they exercise. `tests/integration.zig`
tests the public API, and `tests/corpus` holds reusable DOT inputs once inline
test strings become unwieldy.

## Initial file responsibilities

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

- Diagnostic severity and code.
- Source location/span.
- Parse/validation outcome categories.
- Fixed-capacity and streaming diagnostic sink helpers.

Human-readable catalogs, localization, JSON, and runtime hashing do not belong
in the initial core.

### `src/lexer.zig`

The raw-byte lexer and token cursor. For milestone 1 it recognizes:

- `graph`.
- Bare ASCII identifiers.
- `{`, `}`, `;`, `--`, and `->`.
- Whitespace and physical line endings.
- End of input and invalid bytes/tokens.

It borrows source spans, performs no hidden allocation, and owns no AST types.

### `src/parser.zig`

The parser state machine and a private, provisional syntax-event contract. It
parses one document and emits source-shaped events. It does not allocate AST
nodes directly and does not know about graph engines.

The first implementation may expose only a run-to-completion wrapper, but its
state must remain instance-owned so `next`/`pump` drivers can be added without
rewriting the grammar.

### `src/syntax.zig`

The borrowed, index-based syntax tree and its builder. The builder is the first
consumer of the private syntax-event contract.

Milestone 1 syntax data includes:

- Document kind (`undigraph`).
- Ordered statement IDs.
- Node statements.
- Edge statements with the written operator and endpoint spans.

The syntax tree preserves written statements. It does not synthesize implicit
nodes from an edge statement.

### `src/validate.zig`

Validation over syntax data. It completes after independent validation errors
and writes them to a caller-supplied diagnostic sink or bag. In milestone 1 it
validates that an undigraph uses `--`; multiple written `->` edges yield multiple
diagnostics.

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
3. **Corpus tests:** valid and invalid DOT files with expected diagnostics.
4. **Property/fuzz tests:** added after the first deterministic vertical slice;
   every discovered regression becomes a permanent small test.

Every module that accepts memory must be tested with a deliberately undersized
fixed buffer. Every parser boundary should be tested with input truncated at
each byte position.

