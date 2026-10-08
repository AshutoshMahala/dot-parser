# Why it works this way

This page records the main design decisions and the reasons for them. It is
for anyone who wonders "why does it do that?", and for contributors deciding
whether a change fits.

Some sections end with tags such as `R-MEM-004`. Comments in the source code
use these tags to point back here. Plans that aren't built yet are in the
[roadmap](ROADMAP.md).

## What the library is for

### A parser, not a graph library

The library hands back DOT's own structure. It doesn't lay out graphs, doesn't
depend on any graph library, and doesn't convert into a node-and-edge model.

**Why:** people want very different things from a DOT file: a layout engine, a
linter, a formatter, a converter into their own types. A parser built around
one graph model makes everyone else convert twice. Building a graph is a
separate layer that can sit on top.

Tags: R-FUNC-003

### Record what was written; don't interpret it

Defaults are not applied. `a -> { b c }` is not expanded into edges. Repeated
subgraphs are not merged. Numbers stay text. Duplicate attributes are kept.
Ports are not resolved.

**Why:** three reasons.

- **Safety.** `{ a b c } -> { d e f }` is one statement but nine edges.
  Expanding eagerly lets a small hostile file use huge amounts of memory.
- **Correctness.** In DOT every value is a string, and Graphviz interprets it
  differently per attribute. Guessing here would be wrong for some users.
- **Tools.** Linters and formatters need what the author wrote, not a
  processed version.

### Parsing and validation are separate steps

Parsing checks the grammar and builds the document. Validation checks rules
about the finished document, such as "a `digraph` uses `->`". You can validate
later, or validate again with different settings.

**Why:** a tool often wants to keep a document that breaks a rule, so it can
show or fix it. Each check also costs time, and different users want
different checks. "Validation finished" and "the document is valid" are kept as
separate facts.

Tags: R-FUNC-008

### Both edge operators always parse

`digraph { a -- b }` parses successfully. Validation then reports the wrong
operator, as an error by default.

**Why:** a wrong operator is a common, local mistake. Rejecting it while
parsing would throw away the whole document and the chance to suggest the
one-character fix. Settings can downgrade it to a warning, or read the operator
as the correct one.

### Bytes in, nothing else

The core takes a byte slice. It doesn't open files or use the OS, threads,
environment variables, global setup, standard output or floating point. Nothing
in the input is ever run or fetched.

**Why:** the same code has to run on a microcontroller, in WebAssembly and on a
server. How to read files, which paths are allowed and how big files may be are
decisions for the application. It also keeps the attack surface small.

Tags: R-MOD-003, R-PORT-001

### Text is bytes, not checked Unicode

Names can contain any byte from 0x80 to 0xFF and are kept exactly. UTF-8
checking is optional and off by default. Nothing is normalised or converted.
Columns count bytes.

**Why:** real DOT files aren't always valid UTF-8, and Graphviz accepts them.
Checking would cost every user, even those who don't need it. Keeping bytes
exact also keeps every error position exact.

Tags: R-PORT-006

## Memory

### You provide all memory

Every operation that needs memory is given an allocator or buffers. There is no
global allocator. A fixed-buffer mode works with no allocation at all, and
fails clearly when a buffer is too small. The design supports three lifetimes:
temporary scratch, one document, and longer-lived data.

**Why:** embedded targets may have no heap, servers want arenas, and only the
caller knows how long things must live. Most other DOT parsers (pydot,
graphlib-dot, Gonum's) build their language's usual objects for convenience.
This one is meant to sit underneath other code, so it stays out of the way.

Tags: R-MEM-001, R-MEM-002, R-MEM-003

### Results point into your source

Names are ranges into your source text, not copies. Every piece of text is
either borrowed from your input or stored in memory you supplied.

**Why:** no copying means no allocation and less work. The cost is that your
source must outlive the document. Because a finished document is never
changed, several threads can read it at once.

Tags: R-MEM-004, R-CON-003

### Flat lists instead of pointer trees

The document is a set of flat arrays indexed by integers. Rarer features
(ports, chains, subgraph edge ends) live in their own arrays.

**Why:** freeing a document is a handful of frees, or one arena reset, never a
walk over every node. A 32-bit index is half the size of a pointer and stays
valid when the data is copied. Keeping rare features separate means a plain
node reference stays 8 bytes, so simple files don't pay for features they don't
use.

Tags: R-MEM-005, R-MEM-006

### Store offsets; work out lines and columns only when needed

A position is a byte offset and a length: 8 bytes. Line and column are
calculated only when something is displayed. Offsets are 32-bit, which limits
input to 4 GiB.

**Why:** tracking line and column for every byte took about a fifth of the
scanning time and made every record bigger. Most positions are never shown.
Removing it made parsing roughly 3 to 33% faster. 32-bit offsets halve the size
of every position, and 4 GiB is far beyond any realistic DOT file.

Tags: R-MEM-008

## Safety and predictability

### No recursion, one pass when parsing

The parser is a loop with its own bounded stack. It never backtracks, rescans
input, or expands anything.

**Why:** deeply nested input can't overflow the call stack, and hostile input
can't make *parsing* do slow, quadratic work. Parsing cost grows roughly in step
with the size of the input.

This is a property of parsing, not of everything. Optional validation checks
have their own costs: the UTF-8 check is another pass over the input, and the
repeated-attribute check sorts each statement's keys. Limits are also off by
default. So the library *supports* safe handling of untrusted input, but you
still choose the budgets. See [untrusted input](POLICIES.md#untrusted-input).

Tags: R-PERF-001, R-PERF-002, R-SEC-003

### Running out of room is not a syntax error

Every limit is visible and tested. Hitting one gives `resource_exhausted` or
`storage_failure`, naming what filled up. It never gives `invalid_syntax` and
never crashes.

**Why:** "your file is wrong" and "my buffer is too small" need completely
different fixes. The caller must be able to tell them apart.

Tags: R-ROB-002

### Same input, same result

There is no global mutable state; each parser owns its own state. The document
keeps source order. Diagnostics come in a fixed, repeatable order, but they are
**not** sorted by position across the whole run:

- Each step reports in its own order. Validation, for example, reports in
  source order.
- Steps run one after another. `parseAndValidate` reports parse findings first,
  then validation findings.
- With label checking during parsing, each label's findings appear when the
  parser reaches that label, before any DOT validation findings. So a DOT
  finding early in the file can appear after a label finding later in the file.

Nothing depends on hash order, locale or timing.

**Why:** reproducible output and tests, and many parsers can safely run in
parallel. Sorting everything by position would mean holding back findings until
the end, which costs memory and delays reporting. Callers who want a sorted list
can sort the bag by `span`.

Tags: R-ROB-003, R-PORT-005

## Errors

### Errors are data

Each operation returns a small outcome value for your control flow. The
details go to a diagnostic destination you own. Whether delivery worked is a
third, separate fact. The library never prints, never exits, and doesn't use
Zig errors for bad input.

**Why:** Zig error values can't carry details like where the problem is and
what was expected. A library that prints takes control of output away from you.
Keeping the three facts separate means a broken log destination can't hide a
syntax error, and an empty bag can't be mistaken for success.

Tags: R-FUNC-005, R-DIAG-003

### Collect errors by default; no partial document unless you ask

After a syntax error the parser skips to the next `;` or `}` and keeps looking.
It stops where there is no safe place to continue, such as an unclosed quote
or comment. By default a failed parse returns no document at all. DOT never
returns a half-built document; markup can keep the part it recognised, but
only when you ask (see [partial markup documents for editors](#partial-markup-documents-for-editors)).
`.fail_fast` is available, and removes the recovery code when chosen at compile
time.

**Why:** seeing every problem at once is much more useful in an editor or CI.
A partial document could look valid to code that doesn't check carefully, so
it is never the default. An unclosed quote has already swallowed the rest of
the file, so there is nowhere safe to resume.

Tags: R-FUNC-007

### Unsupported is not invalid

Input that uses a feature you turned off gets its own outcome,
`unsupported_feature`, never `invalid_syntax`.

**Why:** telling a user their valid file is "invalid" sends them to fix the
wrong thing. How it is reported can be changed, but it is never treated as
success.

Tags: R-MOD-006

### Structured error codes

Codes like `E.Syntax.Grammar.003` follow the Waddling Diagnostic Protocol
(WDP), pinned to version 0.1.0-draft. They are grouped by the kind of problem
(`Syntax`, `Validation`, `Resource`, `Profile`), not by source file. One code
means one condition; where it happened goes in the details. Message text and
the console renderer are optional. Tests check that codes are unique and
consistent.

**Why:** grouping by problem lets users filter, say, every syntax error at
once, and moving code between files doesn't change any code. An early version
grouped by module, which split one user-visible problem between "lexer" and
"parser" codes. Small devices can leave out message text entirely.

Tags: R-DIAG-001, R-DIAG-004, R-DIAG-005, R-DIAG-006

### Fixes are suggestions

A diagnostic can carry a typed edit marked `machine_applicable` or `maybe`. The
library never applies it.

**Why:** a likely repair is not proof of what the author meant. The tool or the
user decides.

## Configuration

### One typed policy, fixed at compile time by default

All behaviour lives in one typed `Policy`. It is compiled in by default.
Runtime changes are opt-in per profile, and accept the same fields and values.
Presets are ordinary policy values. Combinations that make no sense fail the
build. Every mode uses the same single grammar engine.

**Why:** a compile-time policy lets the compiler drop features you don't use:
the other scanner, the recovery code, the cancel checks. That makes "you don't
pay for what you don't use" real, and each such claim must name what
disappears (code, branches, state or memory). Rejected alternatives: boolean
flags, string-keyed options, and a separate lenient parser, since two grammars
drift apart.

Tags: R-ARCH-001, R-MOD-007, R-PERF-005

### Leniency is opt-in, counted and warned

Three mistakes that Graphviz rejects (`a;;`, `-->`, a lone `-`) can be
accepted. They are rejected by default; the lenient preset accepts them with
warnings. Every accepted mistake is counted, even when accepted quietly. The
default preset is called `standard`, because `strict` is already a DOT keyword.

**Why:** these are common in hand-written files, but accepting them silently
would hide real mistakes. A lone `-` takes its direction from the written
`graph`/`digraph` keyword, never from a guess.

### "undigraph", not "graph"

The undirected kind is called `undigraph`. A third kind, `generic`, allows both
operators.

**Why:** in this library "graph" means any graph. The written keyword is kept
as written; settings can choose a different *effective* kind without changing
the document.

## Execution

### Work is measured in credits, not time

Step-by-step sessions are optional. One credit is one tiny step: one byte
looked at, one grammar step, or one item added. A session pauses when its
budget runs out and resumes exactly where it stopped. Cancelling is a callback
you provide, checked between steps. Sessions only use fixed buffers. The same
state machine runs both one-call parsing and sessions.

**Why:** a clock isn't available on bare metal and isn't repeatable. Credits
are predictable and testable: the result is the same however the budget is
split. Allocation and your callbacks are outside the parser's control, so they
aren't metered. Fixed buffers are required because growing a list could copy a
lot of data in what should be one small step.

Tags: R-MOD-010

### The scalar scanner is the default

There are two scanners with identical results. Scalar reads one byte at a
time. Block reads 64-byte blocks with vector instructions.

**Why:** once per-byte line tracking was removed, scalar was faster on every
ordinary input, both run to completion and at normal budgets. It also has
smaller state and less code, and it doesn't slow down on
targets without vector instructions, where block was about 1.9 times slower on
wasm32. Block still wins at tiny budgets (2 to 4 times faster at one credit per
call) and on very long names (about 2 times faster), so it stays as an option.
Scalar is also the reference that block is tested against; that comparison
found two block bugs before release.

Those timings are historical evidence for the default, not a new benchmark.
Current, target-qualified state sizes are in
[Performance](PERFORMANCE.md#type-sizes).

### The document is built from internal events

The grammar emits events to an internal consumer, which builds the document.
Consumers see *begin*, *commit* and *abort*. This event interface is private for
now; the `Document` is the public result.

**Why:** one grammar can then feed every builder: allocator-backed, fixed
buffers, and the counting pass behind `measure`. A consumer might act before a
later error is found, so it needs an abort signal to throw away staged work.
That is how a partial document is never published. The interface stays private
until its shape settles.

Tags: R-MOD-011

## HTML-like labels

### A separate, extensible markup parser

DOT always finds where a `<...>` value ends with Graphviz's own rule (count `<`
and `>`). Unless a label checker is bound, it keeps the value as written and
doesn't look inside. Checking the inside is the job of a separate module,
`markup_parser`. Its built-in grammar is XML-like: closing tags must match,
attributes must be quoted, and entities aren't expanded.

**Why:** DOT users who never check labels pay nothing, and markup users don't
need DOT. The parser is meant to be a general base that several HTML-like
dialects can build on: Graphviz labels first, and also HTML subsets, SVG, or
custom ones like XAML. So it doesn't copy any one dialect's rules. In
particular, it is not a browser HTML parser. Keeping text unexpanded keeps error
positions exact.

### Optional rules never leak between dialects

Checks such as UTF-8, XML 1.0 names and the list of known references are
separate choices. Each is off by default, except duplicate attributes and, in
Graphviz mode, the Graphviz vocabulary checks. Turning one on never turns on
another. A whole processor can be
[replaced with your own](CUSTOM_PROCESSORS.md) at compile time.

**Why:** a dialect that reuses the parser must not inherit restrictions from a
different dialect just because they share code. A dialect that needs different
*parsing*, such as HTML's `<br>` with no closing tag, needs an explicit,
compile-time dialect rule. Switching a check off can never make rejected input
parse. Such dialect rules are proposed, not built. See
the [roadmap](ROADMAP.md#markup).

### Graphviz is the default dialect

> **Unreleased.** In 0.4.0 the default is `.structural`.

The built-in markup parser has two modes. `.graphviz`, the default, checks
Graphviz's tags and attributes and matches tag names ignoring ASCII case.
`.structural` checks only the grammar and matches tag names exactly.

**Why:**

- Graphviz labels are the parser's first and most important use, so the default
  should catch the mistakes people actually make in them, such as an unknown
  tag or `COLOR` on `<B>`.
- Graphviz itself treats element and attribute names as case-insensitive, so
  Graphviz mode does the same. Structural mode stays exact, because other
  dialects, like XML, are case-sensitive.
- Other dialects choose `.structural`, and get none of Graphviz's rules. That
  keeps the previous decision intact: only the default changed, and no dialect
  inherits another's rules by accident.
- The vocabulary is a first step. Passing it doesn't mean Graphviz will accept
  the label, and the docs never present it that way. Checking which tags may
  contain which, attribute values and references is
  [planned](ROADMAP.md#markup).

### Markup recovery never guesses a tree

After an error the markup parser keeps looking for more problems, but it never
invents closing tags and never returns a repaired tree. Searching back for a
matching open tag is capped by the input length.

**Why:** a guessed tree could quietly differ from what the author meant, and
code downstream might trust it. The cap stops hostile input from causing
quadratic work.

### Partial markup documents for editors

> **Unreleased.** Not in 0.4.0.

With `retention.partial = true`, a markup parse that fails still returns the
part it recognised before the first error. The document and every node say
whether they are complete or partial, and `unrepresented()` gives the text the
tree doesn't cover. It is off by default, and DOT doesn't offer it.

**Why:**

- Editors need it. While someone is typing, the markup is unfinished most of
  the time, and an outline or highlighting still needs the part that is done.
- Only the part before the first error is kept. After an error, the parser's
  idea of the structure is a guess, and a guessed tree is what the previous
  decision rules out.
- It is opt-in and clearly marked, because a partial tree could pass for a
  complete one. The parse outcome still reports the failure, and
  `documentValid()` is always false for a partial document.
- Keeping it needs no extra scanning or allocation: the parser hands back what
  it had already built.

### Two ways to check labels, both reporting in DOT positions

Labels can be checked automatically during the DOT parse (one call, one bag),
or afterwards on values you choose. Either way, errors point at the line and
column in the DOT file. The DOT settings and the label settings stay
independent: a label finishes under its own error setting, and only then does
the DOT side decide whether to continue.

**Why:** "is this whole file OK?" and "check just these labels, keep their
trees" are both common needs. Labels are passed as raw slices with their
starting offset, so moving positions back into the DOT file is a simple, exact
addition. Keeping the two error settings independent means each one means
exactly what it says.

### Label checkers are wired in at compile time

There is no plugin registry and no swapping at run time. Settings for every
processor are checked once, before any work starts. During the one-call check,
the label checker reuses one set of buffers for all labels.

**Why:** compile-time wiring lets the compiler type-check the connection and
remove anything unused. Reusing buffers cut one test from 4,003 allocations to
7. The trade-off is that the largest label's buffers stay alive until the
parse ends, so peak memory can be higher.

### DOT decides *whether* labels are checked; the checker decides *how*

DOT's `markup` setting only chooses whether labels are checked: `.process`,
`.passthrough` or `.none`. How they are checked belongs to the label checker's
own settings, such as the built-in parser's `mode`. Binding a checker turns
checking on by default, and DOT's presets don't touch `markup`.

**Why:**

- A caller can turn checking off for one call without knowing anything about
  the checker's settings, and turning it off never changes them.
- Checkers you write yourself aren't forced to share the built-in parser's idea
  of a `mode`.
- Adding a preset such as `lenient` for its syntax rules can't silently switch
  label checking off. When an earlier version tied the two together, it did
  exactly that.

## How the project is run

### Small public API, no compatibility promise during 0.x

Convenience functions sit on top of public building blocks; they never replace
them. Internal machinery stays private until it is ready. During 0.x, old names
are removed rather than kept as aliases, and no stable binary layout is
promised.

**Why:** a small surface is easier to learn and to change. While the design is
still settling, compatibility shims would add confusion and freeze mistakes.

Tags: R-ARCH-006, R-ARCH-009

### Every layer can be tested alone

The lexer, parser, document builder and validator can each be tested on their
own, with recording sinks, failing allocators and undersized buffers.

**Why:** bugs in failure paths are only found by forcing those failures.

Tags: R-ARCH-005

### Performance is measured, not assumed

Throughput and memory have reproducible benchmarks, and results are recorded
in [Performance](PERFORMANCE.md).

**Why:** without numbers, "fast" and "small" are just claims.

Tags: R-PERF-004

## Deliberately left out

- Layout, rendering, and giving meaning to attribute values
- Full whitespace/separator retention and exact reformatting (comment retention is opt-in)
- Threads inside the library
- Running, including or fetching anything named in the input
- Re-parsing only the changed part of a file

## Not built yet

See the [roadmap](ROADMAP.md).
