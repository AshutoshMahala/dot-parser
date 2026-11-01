# Performance

How fast the parsers are and how much memory they use. Measurements use one
machine and made-up test files. Use the numbers as a rough guide: your files,
hardware and settings will give different results.

Where the numbers come from:

- **0.5.0 sections.** From [Parse and validate](#parse-and-validate) to
  [DOT with label checking](#dot-with-label-checking), the numbers were
  measured for 0.5.0 on 2026-10-12, at commit `2ea1311`, with Zig 0.16.0.
  They haven't been re-measured as a set on `main`.
- **Unreleased sections: development measurements.** Features added after
  0.5.0 were measured while they were being built, at the commit named at the
  top of each section, not at the current `main`. Later commits changed some of
  this code, including optimizations, so these are not benchmark results for
  the next release. Treat them as development measurements until they are
  re-run for a release, and compare numbers within one table, not across
  sections.
- **Compiler.** `main` builds with Zig 0.17.0. Numbers from Zig 0.16.0 builds
  are not claims about Zig 0.17.0. To compare two revisions yourself, build
  both with the same compiler; see [running the benchmarks](#running-the-benchmarks).

[How these were measured](#how-these-were-measured) has the details.

Reading the tables:

- **MB** means 1,000,000 bytes, and **MB/s** means MB per second. **KiB** means
  1,024 bytes.
- A timing cell like `7.85 / 348.2` means **7.85 ms, which is 348.2 MB/s**.
  Both numbers describe the same run.
- **Fast**, **Safe** and **Small** are optimized builds: `-Doptimize=fast`,
  `safe` and `small` with Zig 0.17.0, or `ReleaseFast`, `ReleaseSafe` and
  `ReleaseSmall` with Zig 0.16.0.
- Memory is the number of bytes the library asked its allocator for, unless a
  table says otherwise. It is not the program's total memory use (RSS).
- **Identical machine code** means the benchmark program compiled to
  byte-for-byte the same code with and without a feature. This is the best
  evidence here that a feature you don't use costs nothing. Two identical
  programs can still time a few percent apart; treat that as noise.

## At a glance

Measured for 0.5.0:

- **DOT:** parsing and validating a 2.7 MB file takes 7.9 ms (about 350 MB/s)
  in a Fast build, or 6.8 ms (about 400 MB/s) with size hints.
- **Memory:** the document takes about 34 bytes per statement, and your source
  is never copied. With an arena, size hints cut the memory for that file from
  37.6 MB to 8.4 MB.
- **Scanners:** the default scalar scanner is faster end to end. The block
  scanner wins on long runs of plain text.
- **Small steps:** with both metering and cancel checks on, parsing takes about
  1.6 times as long.
- **Markup:** about 300 to 430 MB/s for markup full of tags and attributes, and
  much faster for mostly plain text. These are structural-mode parsing numbers.
  Checking Graphviz tag and attribute names afterwards ran at about 1,700 MB/s
  on the test labels.
- **Labels in DOT:** a file with 1,000 small labels is parsed and checked at
  about 150 MB/s, with only 7 allocations (labels in structural mode).

Development measurements of unreleased features, at the commits named in each
section (see [where the numbers come from](#performance)):

- **Graph IR (unreleased):** building the IR for 10,000 connections took
  1.111 ms in a Fast build. `{a b} -> {c d}` stays one connection: a
  50,000 × 50,000 product keeps 7,848,888 bytes, not 2.5 billion edges. See
  [the graph IR](#the-graph-ir).
- **Strings (unreleased):** an exact check of a 19-byte UTF-8 value took
  14.4 ns, with no heap allocation. See [standalone strings](#standalone-strings).
- **Optional features (unreleased):** early outline events, token previews,
  attribute string checks and IR query indexes are off by default. With them
  off, the measured benchmark programs compiled to identical machine code.
  What they cost when on is in
  [cost of opt-in features](#cost-of-opt-in-features).

## Parse and validate

Measured for 0.5.0 (commit `2ea1311`, Zig 0.16.0).

The [DOT throughput benchmark](../bench/throughput.zig) uses a 2.733 MB file
with 200,000 statements: numbered nodes alternating with `--` edges. Settings
are the defaults. Times include `parseAndValidate` and its allocations into a
fresh arena, but not freeing the arena.

"Hinted" passes exact size hints, taken from the known contents of the file.
The time it would take `measure` to work them out is **not** included.

| Build | Scanner | Growing | Hinted |
| --- | --- | --- | --- |
| Fast | scalar | 7.85 / 348.2 | 6.82 / 400.8 |
| Fast | block | 8.04 / 340.0 | 7.04 / 388.3 |
| Safe | scalar | 8.91 / 306.8 | 7.36 / 371.4 |
| Safe | block | 10.06 / 271.7 | 8.42 / 324.6 |

## Memory

Measured for 0.5.0 (commit `2ea1311`, Zig 0.16.0).

For the same 200,000-statement file. The sizes were the same for both scanners
and both builds:

| What | Size |
| --- | ---: |
| Your source (borrowed, not copied) | 2.733 MB |
| The document | 6.800 MB (34 bytes per statement) |
| Arena memory, no size hints | 37.620 MB |
| Arena memory, exact size hints | 8.400 MB |

The document size doesn't include the source, because the source is never
copied. Arena memory also counts unused space and old copies left behind when
lists grow. It isn't the document's own size, and it isn't the program's total
memory use. See [arenas](MEMORY.md#option-2-an-arena).

Record sizes on this machine: node statement 16 bytes, edge statement 36 bytes,
subgraph 36 bytes, statement entry 8 bytes, nesting frame 116 bytes. Plan memory
for the source, diagnostics, sessions and nesting space separately.

## Type sizes

`@sizeOf` values on this machine (aarch64 macOS). They are the size of each
value itself, not memory used while parsing, and they can differ on other
targets or Zig versions. A [layout test](../tests/layouts.zig) checks the DOT
rows below in all four build modes, so they hold for both 0.5.0 and `main`.

| Type | Debug / Safe | Fast / Small |
| --- | ---: | ---: |
| `dot.Profile(.{}).Session` | 1,128 bytes | 1,120 bytes |
| DOT session with metering and cancellation | 1,192 bytes | 1,184 bytes |
| `dot.lexer.For(.scalar)` | 64 bytes | 56 bytes |
| `dot.lexer.For(.block)` | 152 bytes | 152 bytes |

The second row turns on `.execution = .{ .metering = true, .cancellation = true }`
and leaves every other setting at its default. Session sizes don't include the
source, document buffers, nesting space or diagnostics, which you supply
separately. Use `@sizeOf` on your own profile and target rather than copying
these numbers.

Keeping comments makes the document and storage types a little larger even
when it is off. With comment retention off, no comment records are allocated.
With it on, each comment takes 12 bytes, plus spare room in growing lists
unless you give exact sizes or fixed buffers. The comment text itself is never
copied.

More sizes, the same in Fast and Safe builds. The markup rows were measured for
0.5.0 with Zig 0.16.0:

| Type | Size (bytes) |
| --- | ---: |
| DOT session with run-time settings | 1,424 on `main` (1,408 in 0.5.0) |
| Markup node / attribute | 20 / 20 |
| Markup nesting frame / attribute-key scratch entry | 12 / 8 |
| Markup diagnostic / validation result | 36 / 32 |
| Markup session: default / bounded / run-time settings | 440 / 448 / 528 |
| Markup `Document` | 56 |
| Markup node / attribute view | 64 / 64 |
| Markup root/child iterator / attribute iterator | 64 / 64 |

**Zig 0.17.0 debug and safe builds.** Two list safety locks in the markup
builder add 16 bytes in `debug` and `safe`: default / bounded / run-time
sessions are **456 / 464 / 544 bytes**. With exact closing-tag recovery,
default / bounded are **448 / 456 bytes**. `fast` and `small` keep the sizes
above. These are fixed session costs, not per-node allocations; DOT's session
and scanner sizes are not affected. Other growable builders and workspaces
carry the same per-list locks in `debug` and `safe`. For example, DOT and
markup growable diagnostic bags are 56 bytes instead of 48, and
`markup.ParseResult` is 192 bytes instead of 176.

What adds to these sizes:

- **DOT completeness metadata** makes the default fixed DOT session 40 bytes
  bigger than in 0.4.0. Scanner sizes and per-statement records are unchanged.
- **Closing-tag typo recovery**, on by default, adds 8 bytes to markup sessions
  with fixed settings and 24 bytes to the run-time-settings session. With a
  fixed `closing_tag_recovery = .exact`, the default and bounded sessions are
  432 and 440 bytes; run-time settings keep room for every choice. No choice
  allocates or makes node or attribute records bigger.
- **Markup partial results** add 8 bytes to the run-time-settings session;
  other sessions are unchanged. They make the markup `Document` 56 bytes
  instead of 48, even with partial results off, so views and iterators that
  hold it are 8 bytes bigger too. Copying a view still copies no source or tree and doesn't
  allocate. Node and attribute records are still 20 bytes. Keeping the
  finished part after a failure reuses the same buffers, without allocating.
  Growing buffers keep their spare room after a failure: an owned result holds
  it until `deinit()`, and a workspace keeps it for the next call.
- **DOT partial results and kept label trees** have their own
  [memory costs](EDITORS.md#memory). They add 8 bytes to the default DOT
  session and 56 bytes to run-time-settings sessions, because those must be
  able to keep partial results too. Default node and edge allocations are
  unchanged, and no list of label results is allocated unless label trees are
  kept.

## Scanners

Measured for 0.5.0 (commit `2ea1311`, Zig 0.16.0).

The [lexer benchmark](../bench/lexer.zig) times the DOT scanner on its own, in
a Fast build. Each pattern is repeated 65,536 times. The `long HTML label` row
only measures how fast DOT finds where a `<...>` value ends, not checking what
is inside it.

| Pattern | Source (MB) | Scalar | Block |
| --- | ---: | --- | --- |
| short names and punctuation | 1.114 | 7.22 / 154.3 | 5.65 / 197.2 |
| short names, spaces and line breaks | 0.983 | 2.87 / 342.5 | 2.72 / 361.4 |
| keywords and numbers | 3.670 | 5.90 / 622.0 | 5.85 / 627.4 |
| quoted strings and comments | 2.228 | 2.78 / 801.5 | 4.55 / 489.7 |
| long HTML label | 80.806 | 40.98 / 1,971.8 | 8.62 / 9,374.2 |
| long name | 4.260 | 3.32 / 1,283.1 | 2.06 / 2,067.9 |

The block scanner wins on long runs, but scalar wins on quoted strings and
comments. A faster scanner alone doesn't mean a faster parse overall: end to
end, scalar is faster (see [parse and validate](#parse-and-validate)). Scalar
stays the default; see [two scanners](EXECUTION.md#two-scanners).

## Step-by-step sessions

Measured for 0.5.0 (commit `2ea1311`, Zig 0.16.0).

The [session benchmark](../bench/session.zig) parses 200,000 `a;` statements
(0.400 MB) in a fixed-buffer session with the scalar scanner, without
validation. Metered sessions spend 256 credits per `advance` call; the others
use `run()`.

| Metering | Cancellation | Fast | Safe | Cancel checks |
| --- | --- | --- | --- | ---: |
| off | off | 3.28 / 122.0 | 3.80 / 105.3 | 0 |
| on | off | 4.06 / 98.5 | 4.23 / 94.6 | 0 |
| off | on | 4.83 / 82.8 | 4.80 / 83.3 | 1,400,016 |
| on | on | 5.15 / 77.7 | 5.12 / 78.1 | 1,405,484 |

The cancel callback counts how often it is called but never asks to stop. So
these numbers show the cost of checking, not how quickly a cancel takes
effect. Your own callback's work adds to it. Setting up the session and its
memory isn't timed.

### Cancellation intervals

> **Unreleased.** Not in 0.5.0.

Measured with Zig 0.16.0 on 2026-10-17: markup at commit `ca71148`, DOT at
commit `2597811`.

The [interval benchmark](../bench/cancellation.zig) covers intervals 1, 4, 16,
64 and 256, both parsers and both scanners, fixed and run-time settings, and
metering on and off. It uses dense 30,000-statement inputs (DOT 0.210 MB,
markup 0.300 MB) and 1.350 MB of long quoted or text content. Markup uses
structural mode, and validation isn't timed. Buffers and session setup are
outside the timing. Each case warms up for at least 150 ms, then takes the
median of nine samples; the tables use the median of three interleaved runs.
Metered calls grant 4,096 credits. The callback counts checks and never asks
to stop.

**What a larger interval changes.** The work credits are the same at every
interval; only the number of cancel checks changes. For dense DOT, intervals 1
and 64 made 600,161 and 9,522 checks for the same **600,015 credits**. Dense
markup made 480,153 and 7,618 checks for **480,036 credits**. The extra checks
come from checking on entry to each call. The interval adds no heap allocation,
no per-record storage, and doesn't change session sizes.

Markup throughput against interval 1 in the same build (geometric mean across
both inputs, fixed and run-time settings, metering on and off; higher is
faster):

| Markup scanner | Build | 4 | 16 | 64 | 256 |
| --- | --- | ---: | ---: | ---: | ---: |
| scalar | Fast | +6.3% | +5.7% | +9.4% | +10.5% |
| scalar | Safe | +3.8% | +3.3% | +5.2% | +6.5% |
| block | Fast | +4.9% | +4.5% | +4.6% | +4.8% |
| block | Safe | +2.2% | +2.7% | +2.2% | +4.4% |

Markup timings, Fast build, scalar scanner, fixed settings, metered:

| Input | Interval 1 | Interval 64 |
| --- | --- | --- |
| Markup dense | 1.567 / 191.5 | 1.403 / 213.9 |
| Markup long text | 4.017 / 336.0 | 3.734 / 361.5 |

There are no current DOT figures for intervals above 1.

**What the default interval costs DOT.** Throughput at interval 1 against the
version before intervals existed (commit `702d4ea`). The geometric mean covers
metering on and off and six 30,000-statement inputs: dense, long text, nodes
(`a;`), subgraph ends (`{a;}->{b;};`), ports and attributes
(`a:p->b:q[x=1];`) and HTML-like labels passed through unchecked
(`a[label=<<b>x</b>>];`). Dense and long text use five alternating runs, the
others three. Higher is faster:

| DOT scanner | Fast, fixed | Fast, run-time | Safe, fixed | Safe, run-time |
| --- | ---: | ---: | ---: | ---: |
| Scalar | -0.6% | +10.9% | +1.5% | +5.4% |
| Block | +1.0% | -0.7% | -0.1% | -0.4% |

With cancellation turned off, the same comparison averages +1.9% (Fast) and
-0.5% (Safe). Credits, check counts and session sizes match the earlier
version exactly.

Some cases are still slower (negative numbers). In the benchmark program that
compiles all these settings together, dense run-time metered block parsing is
-6.6% (Fast) and -4.0% (Safe), and fixed unmetered scalar parsing reaches -4.5%
(Fast) on the ports input. Programs that each compile only one setting, same
comparison on the dense input, five alternating runs:

| One-setting program | Fast | Safe |
| --- | ---: | ---: |
| Fixed scalar, unmetered | -3.5% | +6.6% |
| Run-time scalar, unmetered | +8.0% | +2.2% |
| Run-time block, unmetered | -5.0% | +0.6% |
| Run-time block, metered | +0.1% | -1.7% |

Results depend on which other settings are compiled into the same program, so
measure your own application. The default fixed scalar loop has the same
structure as before intervals existed, apart from moved addresses and
error-code mapping. Run-time settings cost code: specializing their cancel
checks adds 29.0 KiB (Fast) and 32.9 KiB (Safe) to the all-settings
benchmark's `__TEXT`. A fixed scalar program is within 40 bytes (Fast) and 48
bytes (Safe) of the version before intervals existed.

Interval **1 stays the default**. Larger intervals trade responsiveness for
fewer checks; they neither increase work budgets nor guarantee faster parsing.
See the [interval contract](EXECUTION.md#cancellation-interval).

## Compile-time and run-time settings

Measured for 0.5.0 (commit `2ea1311`, Zig 0.16.0).

The [settings benchmark](../bench/policies.zig) parses three files into fixed
buffers, without validation:

- `nodes`: 50,000 lines of `a;` (0.150 MB)
- `edges`: 50,000 lines of `a -> b;` (0.400 MB)
- `subgraph ends`: 50,000 lines of `{a;} -> {b;};` (0.700 MB)

Each is parsed with four kinds of settings:

- `fixed` uses compile-time settings.
- `runtime_baseline` turns on run-time settings but changes nothing.
- `runtime_override` passes the same scanner choice as a run-time setting.
- `runtime_partial` also turns on [partial results](EDITORS.md#keep-the-finished-part-of-a-dot-file)
  at run time.

Fast build:

| Scanner | Settings | `nodes` | `edges` | `subgraph ends` |
| --- | --- | --- | --- | --- |
| scalar | fixed | 0.835 / 179.7 | 1.551 / 257.9 | 6.361 / 110.0 |
| scalar | runtime_baseline | 0.944 / 158.9 | 1.767 / 226.4 | 6.666 / 105.0 |
| scalar | runtime_override | 0.946 / 158.6 | 1.772 / 225.7 | 6.638 / 105.5 |
| scalar | runtime_partial | 0.952 / 157.6 | 1.771 / 225.9 | 6.740 / 103.9 |
| block | fixed | 0.858 / 174.8 | 1.687 / 237.1 | 6.309 / 111.0 |
| block | runtime_baseline | 1.345 / 111.5 | 2.779 / 143.9 | 9.150 / 76.5 |
| block | runtime_override | 1.333 / 112.5 | 2.777 / 144.0 | 9.154 / 76.5 |
| block | runtime_partial | 1.357 / 110.5 | 2.783 / 143.7 | 9.224 / 75.9 |

Safe build:

| Scanner | Settings | `nodes` | `edges` | `subgraph ends` |
| --- | --- | --- | --- | --- |
| scalar | fixed | 0.972 / 154.3 | 1.667 / 240.0 | 7.179 / 97.5 |
| scalar | runtime_baseline | 1.003 / 149.6 | 1.857 / 215.4 | 7.461 / 93.8 |
| scalar | runtime_override | 1.000 / 150.0 | 1.851 / 216.1 | 7.428 / 94.2 |
| scalar | runtime_partial | 1.016 / 147.6 | 1.871 / 213.8 | 7.419 / 94.4 |
| block | fixed | 1.183 / 126.8 | 2.003 / 199.7 | 7.765 / 90.1 |
| block | runtime_baseline | 1.223 / 122.7 | 2.384 / 167.8 | 8.368 / 83.7 |
| block | runtime_override | 1.222 / 122.8 | 2.387 / 167.6 | 8.314 / 84.2 |
| block | runtime_partial | 1.235 / 121.5 | 2.402 / 166.5 | 8.369 / 83.6 |

These time the whole parse, not just the cost of reading the settings. Each
row is compiled differently, so part of the difference is just different
machine code. The files are small, so this can't tell you the cost of run-time
settings in general. Measure the settings and files you actually use.

## Subgraphs

Measured for 0.5.0 (commit `2ea1311`, Zig 0.16.0).

The [subgraph benchmark](../bench/subgraphs.zig) parses empty subgraphs into
fixed buffers with the scalar scanner. Each `{}` is two bytes, plus eight bytes
for the surrounding graph. `siblings` puts them side by side; `nested` puts
each one inside the previous one.

| Shape | Count | Fast | Safe | Document (MB) | Nesting space (bytes) |
| --- | ---: | --- | --- | ---: | ---: |
| siblings | 1,000 | 0.029 / 69.2 | 0.028 / 71.7 | 0.044 | 116 |
| nested | 1,000 | 0.029 / 69.2 | 0.033 / 60.8 | 0.044 | 116,000 |
| siblings | 10,000 | 0.290 / 69.0 | 0.310 / 64.5 | 0.440 | 116 |
| nested | 10,000 | 0.307 / 65.2 | 0.341 / 58.7 | 0.440 | 1,160,000 |
| siblings | 100,000 | 2.930 / 68.3 | 3.169 / 63.1 | 4.400 | 116 |
| nested | 100,000 | 3.081 / 64.9 | 3.481 / 57.5 | 4.400 | 11,600,000 |

Deep nesting can't overflow the call stack, but it does need nesting space for
every open level. 100,000 nested subgraphs need **11.6 MB** of nesting space,
on top of the 4.4 MB document. Setting up that memory isn't timed, and an
allocator that grows as it goes may use more at its peak.

## Markup on its own

Measured for 0.5.0 (commit `2ea1311`, Zig 0.16.0).

The [markup benchmark](../bench/markup.zig) parses markup into fixed buffers of
exactly the right size, with compile-time settings in structural mode. Parsing
in Graphviz mode, the default since 0.5.0, hasn't been timed; its name checks
are timed under [Graphviz vocabulary checks](#graphviz-vocabulary-checks). Times
don't include sizing or setting up the buffers, or any validation.

| Fixture | Source (MB) | Fast, scalar | Fast, block | Safe, scalar | Safe, block |
| --- | ---: | --- | --- | --- | --- |
| flat | 0.200 | 0.575 / 347.8 | 0.601 / 332.5 | 0.638 / 313.3 | 0.668 / 299.5 |
| mixed | 0.750 | 2.344 / 319.9 | 2.568 / 292.0 | 2.553 / 293.8 | 2.672 / 280.6 |
| text | 1.000 | 0.567 / 1,764.5 | 0.080 / 12,466.8 | 0.725 / 1,380.0 | 0.079 / 12,717.8 |
| deep | 0.070 | 0.236 / 296.6 | 0.253 / 276.9 | 0.263 / 266.1 | 0.281 / 249.1 |
| attributes | 1.100 | 3.256 / 337.9 | 3.427 / 321.0 | 3.434 / 320.3 | 3.619 / 304.0 |
| duplicates | 1.100 | 3.232 / 340.4 | 3.447 / 319.1 | 3.445 / 319.3 | 3.657 / 300.8 |
| references | 1.700 | 3.926 / 433.0 | 4.090 / 415.7 | 4.170 / 407.6 | 4.241 / 400.8 |
| attribute_references | 1.800 | 4.149 / 433.8 | 4.167 / 432.0 | 4.178 / 430.9 | 4.281 / 420.5 |
| comments | 1.400 | 1.199 / 1,167.4 | 1.100 / 1,273.1 | 1.330 / 1,052.8 | 1.214 / 1,153.0 |
| cdata | 1.550 | 1.505 / 1,029.7 | 1.425 / 1,087.9 | 1.705 / 909.3 | 1.579 / 981.4 |
| prose | 1.835 | 0.996 / 1,843.2 | 0.284 / 6,470.4 | 1.378 / 1,331.2 | 0.317 / 5,795.5 |
| long_names | 0.655 | 0.247 / 2,647.9 | 0.095 / 6,919.1 | 0.334 / 1,960.6 | 0.115 / 5,706.3 |
| long_values | 1.965 | 1.109 / 1,771.4 | 0.304 / 6,457.9 | 1.528 / 1,285.8 | 0.332 / 5,914.6 |

The fixture names match the benchmark source:

- Most fixtures repeat an item 50,000 times. `prose`, `long_names` and
  `long_values` repeat theirs 5,000 times.
- `deep` is 10,000 nested elements, and `text` is one million bytes of plain
  text.
- `mixed` repeats `<a><b/>text</a>`.
- `attributes` and `duplicates` have three attributes per element. Parsing
  keeps both copies of a duplicate.
- References are checked for form only. They aren't expanded or looked up.

### Memory

The document and nesting space for each fixture. They were the same for both
scanners and both builds. They don't include the source, session state,
diagnostics, validation scratch or allocator overhead, and they aren't the peak
of a growing allocation.

| Fixture | Nodes | Attributes | Document (bytes) | Nesting space (bytes) |
| --- | ---: | ---: | ---: | ---: |
| flat | 50,000 | 0 | 1,000,000 | 12 |
| mixed | 150,000 | 0 | 3,000,000 | 24 |
| text | 1 | 0 | 20 | 0 |
| deep | 10,000 | 0 | 200,000 | 120,000 |
| attributes | 50,000 | 150,000 | 4,000,000 | 12 |
| duplicates | 50,000 | 150,000 | 4,000,000 | 12 |
| references | 100,000 | 0 | 2,000,000 | 12 |
| attribute_references | 50,000 | 50,000 | 2,000,000 | 12 |
| comments | 50,000 | 0 | 1,000,000 | 0 |
| cdata | 50,000 | 0 | 1,000,000 | 0 |
| prose | 10,000 | 0 | 200,000 | 12 |
| long_names | 5,000 | 0 | 100,000 | 12 |
| long_values | 5,000 | 5,000 | 200,000 | 12 |

### Execution options

Fast build, scalar scanner, on the `attributes` and `prose` fixtures:

| How it runs | `attributes` | `prose` |
| --- | --- | --- |
| fixed | 3.256 / 337.9 | 0.996 / 1,843.2 |
| runtime_baseline | 3.287 / 334.7 | 0.991 / 1,852.6 |
| runtime_override | 3.263 / 337.1 | 0.949 / 1,933.9 |
| count_only | 2.865 / 383.9 | 0.937 / 1,958.6 |
| cancellable | 6.070 / 181.2 | 6.091 / 301.2 |

- `runtime_baseline` and `runtime_override` use the same settings as `fixed`,
  passed at run time.
- `count_only` runs `measureIn`. It keeps no tree, but still needs nesting
  space.
- `cancellable` checks a cancel callback that never asks to stop. Metering
  stays off.
- The rows that keep a tree use the same memory as the table above.

### Validation on its own

Optional checks on a document that is already parsed, with compile-time
settings and scratch arrays set up in advance. Parsing, and storing or printing
diagnostics, are not timed. These fixtures are separate from the parsing ones.

| Check | Source (MB) | Fast | Safe | Scratch (bytes) |
| --- | ---: | --- | --- | ---: |
| Duplicate attributes | 1.100 | 0.922 / 1,193.1 | 1.431 / 768.7 | 24 |
| ASCII names | 1.400 | 1.514 / 924.7 | 1.876 / 746.1 | 0 |
| Unicode names | 1.100 | 1.020 / 1,078.9 | 1.395 / 788.6 | 0 |
| Reference list | 1.250 | 1.343 / 930.5 | 1.515 / 825.2 | 0 |
| Encoding, ASCII text in UTF-8 | 0.500 | 0.117 / 4,284.3 | 0.127 / 3,929.7 | 0 |
| Encoding, Unicode text in UTF-8 | 0.600 | 0.670 / 895.5 | 0.735 / 816.2 | 0 |
| Encoding, invalid UTF-8 | 0.350 | 0.366 / 956.7 | 0.513 / 682.4 | 0 |
| All checks together | 1.200 | 2.727 / 440.1 | 3.372 / 355.8 | 16 |

- The duplicate fixture has 50,000 repeated keys.
- Name checks use the XML 1.0 rules. The reference check uses the five XML
  names (`amp`, `lt`, `gt`, `quot`, `apos`).
- The encoding rows use `invalid_encoding` on UTF-8 input.
- "All checks together" turns on names, references, the encoding check and
  duplicate keys.
- Findings in the invalid inputs are counted and thrown away, not stored.

### Checking markup that failed to parse

[`validateSourceIn`](MARKUP.md#checking-a-fragment-that-failed-to-parse) checks
the parts it can recognise, without building a tree. This is the
`--scopes-only` run. Each fixture repeats an item 10,000 times and reports
20,000 validation errors.

| Fixture | Source (MB) | Fast, scalar | Safe, scalar | Scratch (bytes) |
| --- | ---: | --- | --- | ---: |
| complete | 0.260 | 1.093 / 237.9 | 1.301 / 199.8 | 72 |
| bad_closer | 0.300 | 1.118 / 268.2 | 1.307 / 229.6 | 72 |
| bad_header | 0.360 | 1.562 / 230.4 | 1.874 / 192.1 | 72 |

- `complete`: every tag is finished, though attributes and references still
  have errors.
- `bad_closer`: closing tags are wrong, but every tag can still be checked on
  its own. This says nothing about whether the tags nest correctly.
- `bad_header`: some tags are cut off, so checking skips ahead and reports that
  it couldn't check everything.

Don't compare these with full-document validation times; they do different
work.

### Graphviz vocabulary checks

This is the `--graphviz-only` run. It validates an already parsed document in
each mode, with duplicate checking on in both. Parsing and storing diagnostics
aren't timed.

- `tables`: 10,000 copies of a small valid Graphviz table, with `<TABLE>`,
  `<TR>`, `<TD>`, `<B>` and `<BR>` and their attributes.
- `invalid`: 10,000 copies of an unknown element and two disallowed
  attributes. Graphviz mode reports three errors per copy.

| Input | Mode | Settings | Source (MB) | Fast | Safe | Scratch (bytes) |
| --- | --- | --- | ---: | --- | --- | ---: |
| tables | structural | fixed | 0.980 | 0.142 / 6,898.6 | 0.228 / 4,303.6 | 16 |
| tables | structural | run-time | 0.980 | 0.143 / 6,854.8 | 0.230 / 4,259.0 | 16 |
| tables | graphviz | fixed | 0.980 | 0.575 / 1,705.3 | 0.772 / 1,270.1 | 16 |
| tables | graphviz | run-time | 0.980 | 0.658 / 1,489.0 | 0.913 / 1,073.0 | 16 |
| invalid | structural | fixed | 0.380 | 0.034 / 11,066.5 | 0.063 / 6,056.1 | 0 |
| invalid | structural | run-time | 0.380 | 0.035 / 10,728.7 | 0.068 / 5,625.3 | 0 |
| invalid | graphviz | fixed | 0.380 | 0.256 / 1,484.4 | 0.361 / 1,052.3 | 0 |
| invalid | graphviz | run-time | 0.380 | 0.340 / 1,119.2 | 0.469 / 809.8 | 0 |

- Each element and attribute is looked up with a few short comparisons. The
  checks keep nothing extra in the document and allocate nothing themselves.
- Validating a document still walks its elements and attributes once.
  Duplicate checking costs what it did before.
- `validateSource` needs no buffer for tags when duplicate checking is off.
- A profile fixed at compile time to structural mode leaves the Graphviz checks
  and case-insensitive matching out of the program. A profile with run-time
  settings includes both modes, which makes the program larger.
- Validation still can't run in small steps. Cancelling and stopping work as
  before.

## DOT with label checking

Measured for 0.5.0 (commit `2ea1311`, Zig 0.16.0).

The [composition benchmark](../bench/composition.zig) uses a DOT profile with
the markup parser bound as its
[label checker](LABELS.md#check-every-label-while-parsing), in structural mode,
and calls `parseAndValidate`. Times include parsing the DOT, checking the labels,
validating, and freeing the result. Both parsers use the scanner shown.
Diagnostics are thrown away.

The benchmark covers both fixed and run-time settings for both parsers, labelled
`fixed` and `runtime` in its output. The table below uses fixed settings.

- `plain`: 1,000 nodes and no labels. The label checker is bound but has
  nothing to do.
- `labels`: 1,000 labels of `<b x='1' y='2'>t</b>`.
- `invalid`: 1,000 labels, each with a repeated attribute and a wrong closing
  tag. The DOT itself is fine, but the file as a whole is invalid.
- `large_first`: one label with 10,000 elements, followed by 50,000 plain
  nodes.

| Fixture | Scanner | Source (bytes) | Fast | Safe | Peak (bytes) | Allocations / resizes / remaps |
| --- | --- | ---: | --- | --- | ---: | --- |
| plain | scalar | 2,010 | 0.024 / 84.2 | 0.024 / 82.7 | 27,064 | 2 / 0 / 19 |
| plain | block | 2,010 | 0.026 / 77.7 | 0.029 / 70.1 | 27,064 | 2 / 0 / 19 |
| labels | scalar | 32,010 | 0.216 / 148.2 | 0.228 / 140.1 | 44,260 | 7 / 0 / 29 |
| labels | block | 32,010 | 0.247 / 129.7 | 0.280 / 114.4 | 44,260 | 7 / 0 / 29 |
| invalid | scalar | 35,010 | 0.305 / 114.6 | 0.338 / 103.7 | 44,404 | 8 / 0 / 29 |
| invalid | block | 35,010 | 0.345 / 101.6 | 0.385 / 91.0 | 44,404 | 8 / 0 / 29 |
| large_first | scalar | 140,029 | 1.313 / 106.7 | 1.354 / 103.4 | 1,670,604 | 5 / 0 / 55 |
| large_first | block | 140,029 | 1.396 / 100.3 | 1.543 / 90.8 | 1,670,604 | 5 / 0 / 55 |

**Peak** is the most memory the library had asked for at any one moment
during a call, measured with a separate counting allocator. It doesn't include
the source, the allocator's own bookkeeping or the copies it makes while
resizing, or the program's total memory use. The last column counts calls to
the allocator, not requests to the operating system.

The label checker's buffers can stay allocated while DOT's own buffers grow;
`large_first` tests exactly that. After each call, the counting allocator
confirms that everything was freed.

## Standalone strings

> **Unreleased.** Not in 0.5.0.

The [string processor](STRINGS.md) checks one value at a time: its encoding,
and optionally rules such as equality. It never allocates, and it never copies
or decodes the value into a buffer.

### Equality checks

Measured with Zig 0.16.0 on 2026-10-18, at commit `608038f`, Fast build.

[`bench/string.zig`](../bench/string.zig) (`bench-string`): each cell is the
median of three runs; each run uses seven measured batches after two warm-ups.
Source allocation is outside timing. Each call checks the encoding, runs the
equality check and consumes the result with a discard sink. Profiles compile
UTF-8, UTF-16 and UTF-32 readers, with fixed settings. Case folding is on only
in the folding columns.

For the same logical value, `Straße 中文 😀`:

| Source encoding | Physical bytes | Exact, ns/value (MB/s) | Unicode folding, ns/value (MB/s) |
| --- | ---: | ---: | ---: |
| UTF-8 | 19 | 14.4 (1,319) | 119.3 (159) |
| UTF-16LE | 24 | 55.5 (432) | 116.8 (205) |
| UTF-32LE | 44 | 40.6 (1,084) | 102.5 (429) |

MB/s counts physical bytes, so wider encodings can't be compared by throughput
alone; compare ns/value too. For the seven-byte ASCII value `Seattle`, UTF-8
exact checking took about 7.2 ns/value and folding 40.5 ns/value. On a
4,200-byte ASCII value, exact checking took about 235 ns/value
(17,895 MB/s), using the standard validator's ASCII fast path and a byte
comparison. Folding took about 25 µs/value, with large run-to-run variation
(19–29 µs). These microbenchmarks are not guarantees for arbitrary text or for
work that produces many diagnostics.

The same equality check bound as a custom validator does the same work, but
its code and timing can differ: for the 19-byte UTF-8 value it took about
17.6 ns/value, against 14.4 ns for the built-in one. Membership checks, run-time
settings, callbacks and kept diagnostics depend on their configuration and
aren't covered by this table.

Later changes (commit `32ecc3d`) made the native comparison cases faster:
-4.0% (Fast), -6.1% (Safe) and -20.2% (Small) in time, as a geometric mean.
The table above wasn't re-recorded.

**Memory.** The processor and comparators make **no** heap allocations. The
source stays borrowed, and there is no tree or decoded or folded copy. On this
target `Result` is 24 bytes and the default diagnostic is 72 bytes; custom
details can make diagnostics larger. Growable diagnostic bags and your own
callbacks can allocate. Folding uses small fixed buffers (three Unicode scalars
per side) plus cursors, not scratch that grows with the input.

### Code size

Measured with Zig 0.16.0 at commit `32ecc3d`; the predicate probe at `608038f`.

Consumed, stripped Wasm32 `ReleaseSmall` probes, without console printing:

| Probe | Module bytes | Unicode folding table |
| --- | ---: | --- |
| Exact UTF-8 equality | 3,240 | absent |
| ASCII-insensitive equality | 3,370 | absent |
| Unicode-folded equality | 10,247 | present |
| Check other than comparison, with folding allowed but unused | 2,833 | absent |

Only the Unicode-folded probe keeps the folding table. `zig build check-wasm`
(needs Node; also part of `zig build check`) runs the probes' exports and
checks which probes keep the table; it doesn't check their size.
`zig build string-size-probes` installs the probes so you can measure them.

### Metering and cancellation

Measured with Zig 0.16.0 on 2026-10-18 at commit `16935f8`, except where noted.

**The default check** (encoding only; no rules, metering or cancellation) keeps
bulk encoding validation and has no session state or counters. Time per value:

| Input | Fast | Safe | Small |
| --- | ---: | ---: | ---: |
| 7-byte ASCII | 4.28 ns | 5.02 ns | — |
| 19-byte Unicode | 8.63 ns | 10.12 ns | — |
| 4,200-byte ASCII | 79.78 ns | 79.74 ns | 87.19 ns |

The 7- and 19-byte rows used 15 measured batches after four warm-ups. The
4,200-byte row was measured at commit `32ecc3d`: nine batches after two
warm-ups, one million calls per batch. With exact equality on but metering and
cancellation off, the 4,200-byte check took 251.31 ns (Fast) and 312.18 ns
(Safe).

**Sessions** ([metering and cancellation](STRINGS.md#metering-cancellation-and-sessions)) are opt-in. The
[session benchmark](../bench/string_sessions.zig) (`bench-string-sessions`)
uses the median of three runs, each with seven measured batches after two
warm-ups. Times include setting up the session, running it and consuming the
result. Inputs are allocated outside timing, diagnostics are thrown away, and
values use exact UTF-8 equality. 4,200-byte ASCII input, Fast build:

| Execution | µs | Session bytes |
| --- | ---: | ---: |
| Unmetered one-shot | 0.257 | none |
| Metered, budget 1 | 46.63 | 128 |
| Metered, budget 64 | 1.96 | 128 |
| Session run to completion | 2.03 | 128 |
| Budget 64, cancellation interval 1 | 46.74 | 152 |
| Budget 64, cancellation interval 64 | 2.33 | 152 |
| Budget 1, run-time settings | 51.11 | 256 |
| Budget 64, run-time settings | 2.55 | 256 |
| Budget 1, Equals bound as custom | 47.58 | 128 |
| Budget 64, Equals bound as custom | 1.95 | 128 |
| Budget 64, step-only custom equality | 33.84 | 128 |
| Budget 64, two-candidate membership | 2.28 | 136 |

In a Safe build the same input took 61.31 µs at budget 1, 68.09 µs at budget 1
with run-time settings, and 2.47 µs at budget 64. The seven-byte value at
budget 1 took 92.4 ns (Fast) and 128.0 ns (Safe).

Unicode input, µs:

| Contents | Fast, budget 1 | Fast, budget 64 | Safe, budget 64 |
| --- | ---: | ---: | ---: |
| 1,216-byte mixed Unicode | 11.27 | 11.44 | 12.67 |
| 384-byte Chinese | 2.87 | 2.92 | 3.27 |
| 256-byte emoji | 1.55 | 1.55 | 1.46 |
| 1,728-byte mostly ASCII with Chinese | 19.11 | 4.70 | 5.31 |

Why budget 64 is so much faster on ASCII: metered checking takes 16 ASCII
steps at a time and charges all 16 credits. It never goes past the
remaining budget or the next cancel check, so budget 1 and cancellation
interval 1 still go one step at a time. Dense Unicode and case folding always
go one step at a time, so metering stays much slower than unmetered checking
there. With both metering and cancellation off, no step counting happens at
all.

The seven-byte and 4,200-byte inputs cost 26 and 12,605 credits, whatever the
budget or cancellation interval. On the large value, interval 1 made 12,605
cancel checks and interval 64 made 197. Preparing run-time settings is
included in the timings but isn't charged as credits. Session size is a fixed
payload you own, not total stack use or RSS; custom states and folding can make
it larger. There are no processor heap allocations.

Later changes (commit `32ecc3d`) made these session cases faster: -9.4%
(Fast), -9.2% (Safe) and -13.9% (Small) in time, as a geometric mean over 84
cases. The tables above weren't re-recorded.

**Compiling many profiles together.** In a benchmark program that compiles many
string profiles at once, single cases can move by several percent between
builds even when the code they run is unchanged. One long Unicode-folded custom
check moved by +59.1% in such a program while an isolated program of the same
check had identical machine code. Measure the combination you ship.

### Scanning DOT quotes, then checking the contents

Measured with Zig 0.16.0 on 2026-10-18, at commit `16935f8`.

`zig build bench-string-passthrough -Doptimize=fast` uses the **actual DOT
lexer** to scan one quoted name up to the end of the input, then optionally
hands the borrowed contents to the string processor. Every timed variant calls
the same scanner. This simulates the hand-off; it isn't the real DOT
integration. There is no tree, escape decoding, concatenation or kept
diagnostics. The inputs have no escapes or concatenations, so the raw and
logical contents are the same without a copy.

Median of three runs; each run has nine measured batches after two warm-ups
and alternates the variant order. Compiling and allocating the input are
outside timing. The default scalar scanner, Fast build:

| UTF-8 contents | Scan only | Scan + encoding | Scan + encoding/equality | Scan + metered encoding/equality, budget 64 |
| --- | ---: | ---: | ---: | ---: |
| 7-byte ASCII | 10.13 ns | 14.89 ns | 18.47 ns | 89.06 ns |
| 19-byte Unicode | 13.40 ns | 23.32 ns | 29.43 ns | 182.25 ns |
| 4,200-byte ASCII | 1.409 µs | 1.515 µs | 1.671 µs | 3.501 µs |
| 1,216-byte Unicode | 0.560 µs | 0.997 µs | 1.379 µs | 10.228 µs |

The ASCII inputs are `Seattle` and repeated `The quick brown fox. `; the
Unicode inputs are `Straße 中文 😀` once or repeated 64 times. Exact comparisons
match the whole value, without case folding. All processor paths are
allocation-free and use fixed settings, with cancellation off.

For the 4,200-byte ASCII contents these are about
**2,980 / 2,773 / 2,513 / 1,200 MB/s** (content bytes, excluding the two
quotes, which are still scanned in the timed work). Unmetered encoding and
equality add about 19% over scanning; metered equality takes about 2.5 times
the scan time. Long-ASCII scan medians varied from 1.332 to 1.929 µs across
runs, so treat these as rough hot-buffer measurements, not whole-file
throughput.

The opt-in block scanner, same harness:

| Contents | Block scan only | Block scan + encoding/equality | Block scan + metered encoding/equality |
| --- | ---: | ---: | ---: |
| 7-byte ASCII | 31.26 ns | 38.11 ns | 109.48 ns |
| 19-byte Unicode | 32.48 ns | 46.16 ns | 201.73 ns |
| 4,200-byte ASCII | 1.664 µs | 1.951 µs | 3.828 µs |
| 1,216-byte Unicode | 0.506 µs | 1.375 µs | 10.190 µs |

Scanning does look at the bytes for quotes, escapes and DOT's own rules, but it
is **not encoding validation**: the harness checks that a quoted `0xff` passes
the scanner and fails the string processor's encoding check. If you already
have the bounded contents, keeping that span needs no second scan; don't scan
twice. These figures can't predict whole DOT parse times.

## Attribute string processing

> **Unreleased.** Not in 0.5.0.

Measured with Zig 0.16.0 on 2026-10-19 and 2026-10-20, at commits `b58db00`
and `75ce950`.

DOT and markup can [pass chosen attribute values to the string
processor](STRINGS.md#attribute-processing-in-dot-and-markup) while parsing.
[`bench/string_integration.zig`](../bench/string_integration.zig)
(`bench-string-integration`) times whole documents: parsing, validation,
allocation and freeing are included, building the source isn't, and
diagnostics are thrown away. Each process takes nine timed batches after three
warm-ups.

**With no string check selected,** including a bound string processor that only
passes values through, the profile is the same type as the plain DOT or markup
profile; tests check this. The `host-defaults` benchmark programs had identical
machine code and identical sizes with and without the feature: 353,872 bytes
(Fast), 386,784 (Safe) and 257,328 (Small). Their timing changed by +0.06%,
+0.95% and -2.74% (geometric mean, eight fixtures), within noise. A program
that compiles both checked and unchecked profiles has a different code layout,
so measure your own combination, especially in Small builds.

**With checks on,** each document has 2,000 selected `label` values and 2,000
attributes that are left alone. The selected check verifies the logical
encoding and exact equality; markup uses structural mode. For long ASCII
values (4,654,007 source bytes for DOT, 4,660,013 for markup), three
alternating runs:

| Build | DOT | Markup |
| --- | --- | --- |
| Fast | 8.226 / 565.76 | 6.548 / 711.68 |
| Safe | 9.597 / 484.93 | 7.932 / 587.49 |
| Small | 13.173 / 353.30 | 11.761 / 396.21 |

Checks are not free: each check can read the value again. Unchanged ASCII runs
are checked 16 steps at a time, with the same credits, without crossing a
budget or cancel check. References, escapes, case-folding expansions and short
values are checked one step at a time. Short-value timings haven't been
re-measured on the current implementation.

**Memory.** Routing and the built-in checks add no heap storage and no decoded
copy, only fixed-size state. Allocation probes gave the same number of
allocator requests and the same requested bytes with checks off,
pass-through only, and checks on: 3 allocations and 147,632 bytes for every
DOT fixture, 4 and 138,228 for every markup fixture (commit `b58db00`). Bound
equality sessions are 344 bytes for plain readers and 464 bytes for DOT and
markup readers. This isn't a peak-stack or RSS measurement; kept diagnostics
and your own callbacks have their own costs.

To compare revisions, use `zig build perf-string -- --suites host-defaults,integration`
(see [running the benchmarks](#one-command-string-comparison)).

## Names, outline events and previews

> **Unreleased.** Not in 0.5.0.

Event features for tools such as editors: binding names the parser has already
checked, and the opt-in early outline events and previews of unfinished
tokens. See [events](EVENTS.md).

### Parser-recognized names

Measured with Zig 0.16.0 on 2026-10-20, at commit `75ce950`.

`zig build bench-identifiers -Doptimize=fast` (and `safe` / `small`). Each
input has 10,000 node statements and 1,000 different names. An event consumer
builds a hash-based index of name references, without a syntax tree. Building
the source and reserving equal tables are outside timing. Numbers are medians
of nine alternating samples of four parses.

| Name spelling | Fast, checked → trusted | Safe, checked → trusted | Small, checked → trusted |
| --- | ---: | ---: | ---: |
| Quoted | 0.647 → 0.460 ms | 0.728 → 0.502 ms | 1.254 → 0.776 ms |
| Concatenated | 0.944 → 0.639 ms | 1.029 → 0.700 ms | 1.621 → 1.029 ms |
| Unicode quoted | 0.914 → 0.647 ms | 0.981 → 0.677 ms | 1.651 → 1.001 ms |
| Long quoted (10.36 MB input) | 23.818 → 14.421 ms | 23.689 → 14.442 ms | 37.271 → 17.417 ms |

"Checked" re-checks each name's spelling with the standalone helpers.
"Trusted" binds the name the parser delivered with
`identifier.fromName(source, name)`, which skips the repeated syntax check but
still hashes and compares the logical value. Across all six inputs (also bare
and escaped names), parsing plus indexing took 24–40% less time in Fast, 29–40%
in Safe and 33–53% in Small. This is an indexing result, **not** a speedup of
ordinary parsing. Both paths reserved 43,032 bytes in one allocation for the
index and allocated nothing while parsing. A `Name` handle is 8 bytes, the same
as a `Span`, and adds no parser, event or document storage.

Since commit `c936fd1`, the checked helpers' scanner is inlined. That made
checked hashing of long quoted names 14–20% slower per byte in Fast builds and
about 20% faster in Small builds, so the "checked" column above is optimistic
for long quoted names in Fast.

**Linking a checked helper.** Measured at commit `c936fd1` with Zig 0.17.0,
Fast build, 50,000-node and 50,000-edge inputs, three process runs. The helper
is linked into the program but runs outside the timed loop:

| Linked helper | Nodes, ms | Edges, ms |
| --- | ---: | ---: |
| None | 0.600 | 2.299 |
| `Document.hashIdentifier` | 0.604 | 2.399 |
| `identifier.check` + `fromName` | 0.604 | 2.287 |
| `Document.decodeIdentifier` | 0.605 | 2.408 |

So in Fast builds, linking a checked helper makes little difference to
ordinary parsing. Two linking costs remain, measured with a separate probe at
the same commit:

- **Small builds:** linking a checked helper such as `identifier.hash` or
  `Document.hashIdentifier` makes ordinary parsing 26–31% slower on edge-heavy
  input and 10–13% slower on node input. Two small parser helpers then have a
  second caller, and Small builds don't inline them.
- **Fast builds:** linking the public `dot.lexer.Lexer.next()` makes ordinary
  parsing 20–23% slower, because the parser's scanner then gets an out-of-line
  copy.

### Early outline events

Measured with Zig 0.16.0 on 2026-10-20, at commit `75ce950`.

**Off (the default):** the [settings](../bench/policies.zig) and
[metering](../bench/metering.zig) benchmarks compiled to identical machine
code with and without the feature, in Fast, Safe and Small. That covers both
scanners, fixed and run-time settings, ordinary parsing, one-credit and batched
metering, and cancellation intervals 1 and 64. Early events that are off add no
session storage or allocation.

**On** (declare `pub const observations = dot.events.Observations.early;` in
your event consumer), the parser does more work. These numbers come from a
one-off harness that isn't in the repository: an event consumer with fixed
scratch counts callbacks on 10,000 `a[x=1];` statements (80,010 bytes,
including a named header). Fast build, nine alternating timed batches of four
parses after three warm-up batches; building the source isn't timed.

| Execution | Scalar off → on | Block off → on |
| --- | ---: | ---: |
| Unmetered | 0.552 → 0.586 ms | 0.528 → 0.823 ms |
| One-credit resumes | 1.286 → 1.423 ms | 1.297 → 1.511 ms |
| 4,096-credit resumes | 0.568 → 0.623 ms | 0.708 → 0.711 ms |
| 4,096-credit resumes, cancellation interval 1 | 0.644 → 0.690 ms | 0.693 → 0.729 ms |

With early events on, this input delivered 50,003 callbacks instead of 30,002.
Metered work grew by exactly the 20,001 extra callbacks: 230,020 → 250,021
scalar credits and 191,263 → 211,264 block credits, whatever the resume budget.
Your callback's own work isn't charged as parser credits, and it adds to the
time.

Session sizes on this target are the same with early events on or off: scalar
448 / 488 / 512 bytes (plain / metered / metered and cancellable), block
544 / 584 / 608. One event-consumer nesting frame is 100 bytes and `Event` is
116 bytes. The parser stores no event list or partial tree; keeping outline
entries costs whatever your consumer stores.

### Unfinished-token previews

Measured with Zig 0.17.0 on 2026-10-20, at commit `8615e9f`. The "off" check
was repeated at commit `cb950e9`.

**Off (the default):** the settings, metering and string-integration benchmarks
compile to identical machine code with and without previews in `fast`, `safe`
and `small`. They cover both scanners, fixed and run-time settings, ordinary
and fixed-buffer parsing, small and large budgets, and cancellation. The
name-index benchmark also has identical Fast and Small code; Safe changes only
two constants for the two new event tags.

**On,** previews allocate nothing and copy no source. Fixed event sessions are
16 bytes larger in a Fast build: scalar 464 (plain) and 504 (metered), block
560 and 600, against 448 / 488 and 544 / 584 with previews off. Outline storage
in your consumer is separate.

`zig build bench-previews -Doptimize=fast` (or `safe` / `small`) prints one CSV
report: time with previews off and on, MB/s, callback counts, exact credits and
session sizes. Building the source isn't timed. The event consumer allocates
nothing; it counts callbacks and reads the preview spans. Each case is the
median of seven alternating samples after two warm-up rounds, eight parses per
sample. Selected Fast results, ms per parse:

| Input / execution | Scalar off → on | Block off → on |
| --- | ---: | ---: |
| 5,000 `a[x=1];` statements, unmetered (35,007 bytes) | 0.207 → 0.220 | 0.236 → 0.238 |
| Same dense input, 4,096-credit resumes | 0.238 → 0.325 | 0.294 → 0.336 |
| Long Unicode quoted value, 4,096-credit resumes (95,018 bytes) | 0.0396 → 0.0392 | 0.0387 → 0.0391 |
| Same Unicode value, one-credit resumes | 0.470 → 1.382 | 0.0422 → 0.0687 |
| Unterminated Unicode value, unmetered (95,015 bytes) | 0.0461 → 0.0456 | 0.0395 → 0.0396 |

Previews cost something even when a pause lands on a token boundary and no
preview is delivered, because the parser still checks for them.
Sub-microsecond differences are noise, not speedups.

Unlike early events, the number of previews **depends on the resume budget and
the scanner**. Every preview update or end is a callback charged one credit; the
benchmark checks that credits with previews equal ordinary credits plus preview
callbacks. A one-credit scalar session can deliver an update for each extra
byte, which adds a lot of time and callbacks. Larger budgets combine updates
without making credits coarser or weakening cancellation. Use the report to
pick a resume budget for your UI.

## The graph IR

> **Unreleased.** Not in 0.5.0.

The optional [graph IR](IR.md) (`dot.ir`) is built from a parsed Document.
Ordinary DOT parsing never runs IR code or allocates IR storage. The words used
in this section:

- **Lowering** builds the IR from a Document. The IR keeps nodes, scopes,
  attributes and connections as written: `{a b} -> {c d}` stays one connection
  rather than four edges (it is kept *symbolic*).
- **Streaming** visits the expanded edges one at a time, without keeping an
  array of them.
- **Materializing** expands the connections into an owned array of edges. With
  attributes, it also works out each edge's effective attributes once and keeps
  them (**folded** attributes). The alternative is **compact** reads: asking
  the IR for an edge's attributes each time.
- A **session** does the same work in steps: each call gets a work budget in
  credits and can check for cancellation, like the parser's
  [step-by-step sessions](#step-by-step-sessions). The ordinary calls without a
  session are called **direct**.

**How the IR was measured.** All IR numbers come from the same Apple M4 Pro
with Zig 0.17.0, between 2026-10-21 and 2026-11-01; each subsection names its
commit. The IR changed a lot in that time. Parsing and building the input are
outside every IR timing. Unless a table says otherwise, times are medians of
process medians over several alternating process runs. **Retained** bytes are
still held when the operation returns; **peak** bytes are the most held at
once, including temporary scratch and old copies while lists grow. Neither
includes the source or the Document, and neither is RSS. **Arena capacity** is
the total an `ArenaAllocator` reserved; it includes unused space, can be much
larger than the requested bytes, and doesn't move in step with them.

**Not using the IR costs nothing:** when the IR was added (commit `5c36bd3`),
the Fast machine code of `bench/identifiers.zig` (event-only parsing) and
`examples/quick_start.zig` (parsing and validating a document) was
byte-identical with and without it.

### Lowering a Document

Development measurement. Times measured at commit `d875891` (2026-10-24);
memory at commit `60cc57e` (2026-11-01). Lowering changed in later commits
(for example `778b958`, `7a5dfd7` and `772b6fe`), and the times haven't been
re-run since.

`bench-ir` ([`bench/ir.zig`](../bench/ir.zig)): two warm-ups and nine samples
per process, five alternating processes per build. The inputs:

- **10,000 connections:** `n0->n1; n1->n2; …`
- **10,000 small sets:** `n0->{a b c}; …`
- **1,000 reopened scopes:** `subgraph s{n0} -> x; subgraph s{n1} -> x; …`,
  reopening the same subgraph each time.
- **Strict reopened scopes:** the same in a `strict digraph`.
- **10,000 nested scopes:** 10,000 levels of `{` around one node, then one
  connection.
- **Symbolic product:** `{n0 … n49999} -> {n50000 … n99999}`.

| Input | Fast, ms | Safe, ms | Small, ms |
| --- | ---: | ---: | ---: |
| 10,000 connections | 1.111 | 1.352 | 1.786 |
| 10,000 small sets | 2.125 | 2.642 | 2.889 |
| 1,000 reopened scopes | 0.150 | 0.180 | 0.201 |
| Strict reopened scopes | 0.151 | 0.183 | 0.209 |
| 10,000 nested scopes | 0.293 | 0.461 | 0.340 |
| 50,000 × 50,000 symbolic product | 5.441 | 6.861 | 8.090 |

The product keeps 100,000 nodes and **one** connection, not 2.5 billion edges.
Nothing expands it unless you ask.

Memory, Fast build. "Without attributes" is a profile with
`.capabilities.attributes = false`, which keeps topology only:

| Lowering input | Retained | Retained, without attributes | Arena capacity | Arena capacity, without attributes |
| --- | ---: | ---: | ---: | ---: |
| 10,000 connections | 1,257,404 B | 1,177,404 B | 1,982,156 B | 3,603,728 B |
| 10,000 nodes with attribute updates | 2,734,680 B | 862,344 B | 7,565,040 B | 1,251,428 B |
| 50,000 × 50,000 symbolic product | 7,848,888 B | 5,848,880 B | 21,827,544 B | 16,359,814 B |

Turning attributes off lowers the retained bytes. Arena capacity can go either
way, because allocation order changes how the arena's chunks grow and
get reused.

**Attributes.** Lowering stores each attribute key once, records the defaults
in force when each node or edge is created, and folds node and graph updates
into shared, unchangeable maps. It doesn't expand edge products or copy source
strings. Measured at commit `57d3674` (2026-10-22), five alternating process
runs, nine samples after two warm-ups ([`bench/ir_attributes.zig`](../bench/ir_attributes.zig),
part of `bench-ir`):

| Attribute input | Fast, ms | Safe, ms |
| --- | ---: | ---: |
| 64 defaults shared by 10,000 nodes | 0.476 | 0.722 |
| 10,000 nodes, two keys then one update each | 1.696 | 2.329 |
| 1,000 reopened scopes with changing defaults | 0.254 | 0.346 |
| 10,000 nested scopes sharing defaults | 0.319 | 0.509 |
| 50,000 × 50,000 symbolic product with defaults | 5.228 | 6.512 |

Defaults are shared: at that commit, working out effective attributes added
only 472 retained bytes to the product with defaults, not 2.5 billion
attribute records. Repeated updates to the
same node are the expensive case: each update keeps a copy of the changed part
of that node's attribute map. Compare the update input's retained bytes with
and without attributes in the memory table above. The `max_attribute_states`,
work and allocation limits bound this.

### Attribute queries and value access

Measured at commits `57d3674` and `c41b28e` (2026-10-22), and `a302e58` and
`4201dba` (2026-10-24), in `bench-ir`.

**One lookup**, repeating the same key so its data is in the CPU cache, without
name lookup, edge expansion or formatting the value. Lookups allocate nothing:

| Lookup | Fast | Safe | Small | Commit |
| --- | ---: | ---: | ---: | --- |
| Node, through a view | 6.5–10.4 ns | 8.9–13.8 ns | — | `c41b28e` |
| Edge in a non-strict graph | 20–23 ns | 24–28 ns | — | `57d3674` |
| Strict edge with 1,000 strict updates | 5.097 µs | 4.811 µs | 9.734 µs | `a302e58` |
| Strict edge with reopened defaults | 7.558 µs | 8.002 µs | 18.916 µs | `a302e58` |

Strict-graph lookups scan the edge's contributions, so asking for every edge's
attributes one by one is slow on strict graphs. To read them all, materialize
with [folded attributes](#streaming-and-materializing-edges).

**All attributes of one node or edge.** Includes setting up the iterator,
reading every entry and cleaning up; doesn't include formatting or edge
expansion:

| Effective attributes read | Fast | Safe | Peak scratch |
| --- | ---: | ---: | ---: |
| Node with 64 defaults | 723.8 ns | 820.9 ns | 0 B |
| Node with two updated keys | 28 ns | 33 ns | 0 B |
| Non-strict edge with one written key | 30 ns | 32 ns | 0 B |
| Strict edge, 1,000 explicit updates, 33 effective keys | 11.73 µs | 12.88 µs | 396 B |
| One edge of the 50,000 × 50,000 product, two keys | 36 ns | 44 ns | 0 B |

The first row was measured at `4201dba`, the others at `57d3674`. Strict edges
use 12 bytes of scratch per distinct edge key, not per update or expanded pair.
The returned entries point into the IR, not into that scratch.

**Values.** Measured at commit `c41b28e` with
[`bench/ir_values.zig`](../bench/ir_values.zig) (part of `bench-ir`; three
warm-ups, nine samples). Writing a value's joined text, without the lookup or
output I/O:

| Joined value | Fast, ns | Safe, ns |
| --- | ---: | ---: |
| Bare string | 3.85 | 4.36 |
| Quoted Unicode | 8.67 | 8.87 |
| Mixed concatenation | 23.40 | 24.16 |
| Short markup | 10.87 | 10.63 |
| 4 KiB quoted value | 1,422 | 1,002 |

- **Kind of a value** (quoted, HTML-like and so on) is worked out when you ask:
  roughly 3–9 ns for small values in Fast, 1.38 µs when the first part is a
  4 KiB quoted string, and 2.75 µs for a 4 KiB HTML-like part. The IR keeps no
  kind cache. A cache tried in the benchmark made later lookups cost about
  0.2–0.5 ns, but needs the same work up front plus one byte per written value
  (10,000 bytes for 10,000 values) even if you never look. If you check long
  values repeatedly, check once and keep the kind.
- **`toString`** makes two bounded passes and one allocation of the exact size:
  about 2.98 µs for the 4 KiB quoted value in Fast, against about 1.00 µs to
  stream the same joined text to a writer. An empty value allocates nothing. The
  source bytes are never changed.
- Views of nodes, edges and attributes are returned by value and point into the
  IR; they add no heap allocation per node or attribute.
- The endpoint port readers (`tailPort()`, `headPort()` and the helpers that
  split a port at its first colon) read the value again from start to end,
  with fixed scratch and no allocation; their bounded `...With` forms keep the
  work limits and cancellation. They add no stored fields (commit `4e525ac`).

### Streaming and materializing edges

Measured on 2026-10-21 to 2026-10-23, at the commits shown.

**Topology only.** In `bench-ir`, `materialize(.{ .attributes = false })`
returns an owned edge array and `edgeIterator` streams the same edges:

| Operation | Edges | Fast, ms | Safe, ms | Peak bytes |
| --- | ---: | ---: | ---: | ---: |
| Materialize 10,000 connections | 10,000 | 0.075 | 0.141 | 323,072 |
| Materialize 1,000 reopened scopes | 500,500 | 2.502 ‡ | 4.178 ‡ | 18,672,020 |
| Stream 10,000 connections | 10,000 | 0.086 | 0.099 | 0 |
| Stream 10,000 small sets | 30,000 | 0.214 | 0.269 | 40,144 |
| Stream 1,000 reopened scopes | 500,500 | 3.557 † | 4.124 † | 11,036 |
| Stream strict reopened scopes | 1,000 | 2.857 ‡ | 2.792 ‡ | 33,564 |
| Stream the first 1,000 product edges | 1,000 | 0.383 | 0.362 | 1,096,892 |

Times are from commit `57d3674`, except † `c41b28e` and ‡ `9349221`. Peak bytes
are from commit `08537a9`.

- Streaming avoids the output array; it isn't automatically faster. Each pull
  and each per-pair limit check takes time.
- A strict stream still visits every candidate pair (500,500 for the strict
  reopened input) and keeps keys to remove duplicates for the 1,000 unique
  edges.
- The product row stops after 1,000 edges. It lists both endpoint sets but
  doesn't visit the other 2,499,999,000 pairs.
- A 2,500 × 2,500 product stays one connection until you expand it. Expanding
  it returns `PairLimit` under the default limit of four million pairs
  (`max_pairs`), without returning part of the array.
- Wrapping streamed edges in views made the benchmark's reopened stream
  slower: +4.5% (Fast) and +11.4% (Safe) for the 500,500 non-strict edges
  (commit `c41b28e`). A loop that only adds up endpoint IDs showed about +1.9%
  and +1.6%, so part of this depends on how the caller's loop is compiled, but
  the slowdown hasn't been shown to go away.

**Folded attributes versus compact reads.** Measured at commit `4e525ac`
(2026-10-23) with `bench-ir-materialized`
([`bench/ir_materialized_attributes.zig`](../bench/ir_materialized_attributes.zig)).
Five process runs per build; each case takes nine measured rounds after two
warm-ups, alternating the two routes in each round. Each total covers building
the result, reading every effective attribute once, and freeing the result; it
doesn't time formatting. "Compact" is topology materialization plus compact
attribute reads; "folded" is `materialize(.{})`.

| Input | Edges | Fast, compact / folded (ms) | Safe, compact / folded (ms) |
| --- | ---: | ---: | ---: |
| No attributes | 2,000 | 0.0329 / 0.0197 | 0.0468 / 0.0296 |
| 64 shared defaults | 2,000 | 0.7252 / 0.3585 | 1.1593 / 0.6109 |
| Eight explicit keys per edge | 2,000 | 0.1014 / 0.1771 | 0.1400 / 0.3380 |
| 32 overlapping strict products, eight keys | 1,024 | 0.8893 / 1.3273 | 1.2279 / 1.4052 |
| Reopened named subgraph, 31,375 pair contributions | 250 | 5.5093 / 0.2715 | 5.9959 / 0.3433 |
| Two endpoint ports per edge | 2,000 | 0.0569 / 0.0582 | 0.0860 / 0.1228 |
| 3,200 strict contributions with reversed ports and overrides | 100 | 2.3527 / 0.0696 | 2.4744 / 0.0913 |

Later runs (commit `e61761e`) made compact reads faster on the two port inputs:
0.0512 ms (Fast) and 0.0727 ms (Safe) for two ports per edge, and 0.6560 ms and
0.7196 ms for the strict port updates. Folded totals for those inputs weren't
re-measured.

Folding is **not always faster for one pass**. On input with many explicit
values it pays to build the winning values first, so compact reads can be
cheaper for a single read. Later reads skip that cost: reading the
explicit-heavy result again took 0.0169 ms in Fast (0.0840 ms through compact
reads), and the overlapping strict result 0.0094 ms (0.7592 ms). On the
reopened subgraph, folding was about 20 times faster in Fast and 17 times in
Safe. These are particular generated inputs, not a throughput guarantee.

Output memory, topology only against folded, in bytes:

| Input | Retained, topology / folded | Peak, topology / folded |
| --- | ---: | ---: |
| No attributes | 38,064 / 38,064 | 63,344 / 63,344 |
| 64 shared defaults | 38,064 / 38,396 | 63,344 / 63,344 |
| Eight explicit keys per edge | 38,064 / 484,796 | 63,344 / 759,476 |
| Overlapping strict products | 16,752 / 312,156 | 36,536 / 514,632 |
| Reopened subgraph | 4,752 / 13,236 | 11,956 / 21,988 |
| Two endpoint ports per edge | 38,064 / 177,308 | 63,344 / 263,192 |
| Strict port updates | 1,952 / 9,988 | 4,176 / 15,632 |

Peaks include pair and endpoint scratch and old copies while lists grow. Each
folded winning value takes a 24-byte cell, plus key indexes and spare list room.
Defaults stay shared with the IR; folding keeps only the winning values, not
all 3,200 updates. Arena capacity for lowering plus output, Fast: the
eight-key input used 1,443,728 bytes for topology and 3,079,880 for folded,
while the reopened input used 234,456 bytes on both routes. Folding doesn't
save arena memory in general.

**Choosing.** `materialize(.{})` folds attributes when the profile has them;
`materialize(.{ .attributes = false })` returns topology only and runs no
folding code (the topology-only benchmark's machine code was identical with and
without folding).

### Optional materialized adjacency

Measured at commits `9026753` and `60cc57e` (2026-11-01). Run
`zig build bench-ir-adjacency -Doptimize=fast` (also `safe` / `small`).

Adjacency rows let you walk the edges at a node. You choose them when you
materialize (`.adjacency = .forward`, `.backward` or `.all`); the default is
`.none`. Parsing and lowering never build rows, and ordinary queries never
build adjacency or expand sets. The benchmark reports building and walking
separately, along with retained and peak bytes, arena capacity and session
work. Each case has three warm-ups and nine measured samples. Parsing,
lowering and freeing the result are outside timing.

**Building rows**, including topology materialization
(`.attributes = false, .adjacency = .all`), without walking or freeing, ms.
Most inputs have 100,000 edge statements; the set product expands to 250,000
edges:

| Input | Fast | Safe | Small | Fast, no rows |
| --- | ---: | ---: | ---: | ---: |
| 100,000-edge directed chain | 1.441 | 1.848 | 2.593 | 1.199 |
| 100,000 edges mixing `->` and `--` | 1.639 | 1.987 | 2.815 | 0.879 |
| 500 × 500 set product | 2.826 | 2.924 | 3.621 | 0.853 |
| 100,000 isolated nodes plus one edge | 0.074 | 0.114 | 0.192 | <0.001 |

The row columns are from `60cc57e` (the average of two process medians per
build); the "no rows" column is from `9026753`. Forward-only rows haven't been re-measured
with the current row builder. The isolated input benefits from clearing rows
in bulk. The set product still pays for its 250,000 requested edges.

**Walking** every node and its incident edges in all directions took
0.124–1.236 ms in these Fast topology cases (commit `9026753`). A walk
allocates nothing and doesn't scan rejected edges. For partial input, counts
keep their uncertainty instead of implying an edge is absent.

**Memory.** Rows use allocations of the exact size. Extra retained bytes for
`.all`: 1,600,016 (directed chain), 2,000,024 (mixed), 2,008,008 (set product)
and 800,032 (isolated nodes). Rows add retained memory but don't always raise
the peak. Fast, excluding the IR and source:

| Output | Retained | Peak | Arena capacity |
| --- | ---: | ---: | ---: |
| Chain, no rows | 2,211,776 B | 3,686,192 B | 8,443,256 B |
| Chain, all rows | 3,811,792 B | 3,811,792 B | 8,443,256 B |
| Set product, all rows | 6,984,872 B | 8,304,192 B | 19,212,190 B |
| Isolated nodes, all rows | 800,176 B | 800,176 B | 1,200,724 B |

The set product's peak stays at 8,304,192 bytes while its retained output grows
from 4,976,864 to 6,984,872 bytes. In Fast, the chain's rows fit in space the
arena already had; in Safe, the set product's arena grew from 8,599,416 bytes
without rows to 19,212,190 bytes with all rows.

**Off cost.** With adjacency off, against the version before adjacency existed
(commit `11471fb`), three alternating pairs of runs, change in time as a
geometric mean over both attribute choices (the one-edge nesting input, below
0.01 ms, is left out):

| Adjacency off | Fast | Safe | Small |
| --- | ---: | ---: | ---: |
| Default growable materialization, attributes included | +1.4% | 0.0% | -6.4% |
| Fixed storage, observed sizes | +1.0% | +0.3% | +1.4% |
| Fixed storage, scanned bounds | +1.3% | -0.9% | +2.9% |
| Fixed session, budget 4096 | -1.8% | -3.3% | -4.1% |
| Fixed session, budget 1 | +3.8% | -8.9% | -3.7% |

Small fixed output (observed sizes and scanned bounds) and Fast one-credit
fixed sessions keep small slowdowns. Retained and peak bytes, edge counts and work totals match the
version without adjacency.

### Optional query indexes

Measured at commit `11471fb` (2026-10-31).

`.indexes.connections` and `.indexes.scope_memberships` both default to
`false`. They speed up the existing symbolic queries; neither expands endpoint
sets or edge pairs. See [query indexes](IR.md#optional-query-indexes).

```sh
zig build bench-ir-query-indexes -Doptimize=fast
# Also -Doptimize=safe or -Doptimize=small.
```

The report compares the default profile with both indexes on. It reports
lowering time, retained and peak bytes, arena capacity, repeated `hasEdge`,
single and all-attribute queries, final scope lookup, query credits and inline
sizes. Query batches mix early and late hits and misses on existing nodes;
attribute queries use valid edges, including repeated updates. Each process
warms up, makes each query sample last at least 1 ms, and reports medians; an
optimizer barrier before every lookup stops repeated reads being folded
together. Three serial runs per build; query times are averaged over warm
batches, not single-call latency.

Selected **Fast** results, indexes off → on:

| Input | Lowering, ms | `hasEdge`, µs/query | Extra retained arrays | Extra peak |
| --- | ---: | ---: | ---: | ---: |
| 8,000-link chain | 0.991 → 1.120 | 7.004 → 0.005 | 125.0 KiB | 92.7 KiB |
| 8,000-edge star | 0.905 → 1.063 | 7.860 → 0.005 | 125.0 KiB | 92.7 KiB |
| 2,000 one-sided sets | 0.490 → 0.513 | 1.746 → 0.013 | 23.5 KiB | 23.5 KiB |
| 8,000 connections, 5% sets | 0.851 → 1.052 | 7.878 → 1.483 | 128.2 KiB | 98.9 KiB |
| Reopened subgraph, 1,000 contributions | 0.190 → 0.202 | 129.469 → 42.298 | 7.8 KiB | 7.1 KiB |
| 50,000 × 50,000 symbolic product | 4.955 → 4.926 | 0.008 → 0.008 | 12 B | 0 B |

- The chain pays back its extra lowering time after roughly 19 queries in this
  mix. One query may not pay for the index, and inputs with long symbolic
  histories may gain nothing.
- On the mixed-set input, `hasEdge` goes from 6.942 to 1.735 µs in Safe and
  10.230 to 3.820 µs in Small. One attribute query goes from 24.283 to
  2.922 µs in Fast, and reading all effective attributes from 11.590 to
  2.364 µs.
- Final scope lookup across 4,001 scopes goes from 670.86 to 0.64 ns in Fast,
  for 16,004 retained bytes and about 1 µs more lowering time.
- **Indexes aren't always faster.** For 4,000 updates to the **same pair**, one
  attribute query still reads the whole history: 16.014 → 18.133 µs (Fast),
  17.397 → 19.763 µs (Safe) and 44.872 → 44.077 µs (Small). Leave indexes off
  when such histories dominate or queries are rare.
- The product stays one connection, with no connection-index arrays; its 12
  bytes are three cached scope handles.

**Memory.** Arena capacity didn't change on these inputs because the new arrays
fit in existing arena space, but their bytes are still real storage. With both
indexes on, inline state grows by 96 bytes per graph, 120 per lowering session
and 88 per has-edge or attribute session; nothing grows per node, connection or
query. None of this exists with the indexes off. Fixed sizing adds five `u32`
capacity fields; no bounds are reserved automatically.

**Off cost.** With the indexes off, the ordinary lowering, symbolic-query and
attribute-access benchmark programs (including their session routes) have
identical machine code in all three builds. Lowering sessions match in Fast
and Small; in Safe they measured -0.1%. Credits, cancel checks, retained bytes
and peaks match. **On cost in code:** a consumed `ReleaseSmall` Wasm
example (caller-buffer parsing and lowering, plus `hasEdge` and final scope
lookup) grows from 89,034 to 93,447 bytes with both indexes on: **4,413
bytes**. That is one program, not a library-size estimate.

### Partial IR

Measured at commits `b64a8ba`, `a302e58` and `4201dba` (2026-10-24); object
sizes rechecked at `60cc57e` (2026-11-01).

[Partial IR](IR.md#partial-graphs-for-editors) is built from a Document that
stopped at an error. It keeps the valid statements and records each gap, and
answers say whether they are known or unknown.

**Off cost.** Complete lowering doesn't do any partial-coverage work or
allocation. When partial support was added, complete retained, peak and arena
bytes were unchanged, and time changed by +0.2% (Fast), +0.2% (Safe) and -0.3%
(Small) as a geometric mean over six inputs.

**Lowering.** `zig build bench-ir-partial -Doptimize=fast` warms each path for
100 ms, then takes two more warm-ups and nine samples. Medians from five
processes, commit `b64a8ba`:

| Input | Complete lowering (ms) | Partial, complete input (ms) | Partial, with gaps (ms) |
| --- | ---: | ---: | ---: |
| 10,000 sparse nodes | 0.545 | 0.535 | 0.536 |
| 10,000 dense connections | 1.014 | 1.044 | 1.044 |
| Shared defaults and updates | 1.277 | 1.196 | 1.213 |
| Port-bearing edges | 1.160 | 1.196 | 1.213 |
| Reopened scopes | 0.160 | 0.166 | 0.165 |
| 10,000 nested scopes | 0.356 | 0.342 | 0.342 |
| 10,000 assignments / 10,000 gaps | 0.830 | 0.810 | 0.935 |
| 50,000 × 50,000 symbolic product | 6.149 | 6.010 | 6.048 |

The inputs with gaps add one gap after the valid statements, except the nested
input (a gap on the inside) and the many-gap input (one gap per node). Small
wins or losses don't mean partial lowering is faster.

**Memory.** On complete input, partial IR keeps exactly the same allocated
bytes as complete IR. The graph objects are 488 bytes (complete) and 520 bytes
(partial) in a Fast build, and 504 and 544 bytes in a Safe build, at commit
`60cc57e`. A partial attribute view is 48 bytes, and
`Knowledge(?AttributeView)` is 80 bytes. Each gap takes a 32-byte record, in an ordinary growing list (the first
allocation holds five records, 160 bytes). With 1,000 gaps, the IR keeps
267,796 bytes against 224,340 without them. Arena growth can add more: two gaps
added 160 retained bytes but 8,754 bytes of arena capacity on the strict
overlap input. Queries for candidates and mentions allocate nothing.

**Queries.** On the 10,000-gap input, an attribute lookup that reports known or
unknown took 23.9 ns, against 5.8 ns without coverage: it searches a gap index,
not the history. Other such lookups took 4.2–6.9 ns, and listing mentions
0.7–1.0 ns per kept record. A pair query on the product took about 10 ns;
pair searches that traversed 10,000 connections took about 10 µs. These are
input-specific costs, not constant-time guarantees.

**Edges.** `zig build bench-ir-partial-edges -Doptimize=fast` (also `safe` /
`small`) warms each path for 100 ms and takes nine samples; five serial
process runs, commit `a302e58`. The inputs with gaps have a gap at the start and
end of the root body. Each cell is **complete / partial on complete input /
partial with gaps**:

| Input | Edges | Folded materialization (ms) | Read all attributes (ms) |
| --- | ---: | ---: | ---: |
| Plain connections | 2,000 | 0.0205 / 0.0205 / 0.0205 | 0.0010 / 0.0010 / 0.0010 |
| 64 shared defaults | 2,000 | 0.0204 / 0.0192 / 0.0203 | 0.3740 / 0.4977 / 0.4975 |
| 8 explicit attributes | 2,000 | 0.1817 / 0.1828 / 0.1831 | 0.0223 / 0.0262 / 0.0258 |
| Strict overlapping sets | 1,024 | 1.4489 / 1.4349 / 1.4441 | 0.0113 / 0.0137 / 0.0212 |
| Reopened scopes | 250 | 0.3617 / 0.3612 / 0.3623 | 0.0004 / 0.0007 / 0.0009 |
| Endpoint ports | 2,000 | 0.0545 / 0.0547 / 0.0547 | 0.0040 / 0.0048 / 0.0055 |
| Strict port updates | 100 | 0.0689 / 0.0703 / 0.0696 | 0.0002 / 0.0003 / 0.0011 |

- Streaming plain connections took 0.0173 / 0.0172 / 0.0173 ms, and strict
  overlapping sets 0.1178 / 0.1180 / 0.1178 ms.
- **Partial attribute reads aren't free,** even on complete input: the
  shared-default case reads 128,000 values and adds about 0.124 ms (about
  1 ns per value). Strict winners also check the gap index.
- Retained output and peak bytes are the same on all three paths, for example
  484,796 retained and 759,476 peak for the explicit attributes. Streaming edge
  views are 24 bytes; folded partial edge views are 40 bytes against 32 for
  complete ones. Views are temporary and allocate nothing.
- A 2,500 × 2,500 product stays one connection. Every path streams a
  1,000-edge prefix with 60,040 bytes of iterator scratch; full materialization
  returns `PairLimit` without allocating the 6.25-million-edge output.

**Node and scope attributes**, commit `4201dba`, Fast, five serial processes.
Each cell is **complete / partial on complete input / partial with gaps**;
times include building the view and reading every entry:

| Input | Node values | Node attributes (ms) | Scope attributes (ms) |
| --- | ---: | ---: | ---: |
| 1,000 empty nodes and scopes | 0 | 0.0053 / 0.0059 / 0.0059 | 0.0053 / 0.0061 / 0.0060 |
| 64 shared defaults | 64,000 | 0.7759 / 0.8250 / 0.8173 | 0.7548 / 0.7833 / 0.7865 |
| 8 explicit node attributes | 8,000 | 0.0933 / 0.0970 / 0.1022 | 0.0284 / 0.0306 / 0.0316 |
| 1,000 reopened contributions | 2,000 | 0.0217 / 0.0241 / 0.0247 | too short to time |
| 1,000 nested scopes | 1,000 | 0.0142 / 0.0142 / 0.0148 | 0.0134 / 0.0147 / 0.0147 |
| 1,000 assignments / gaps | 1,000 | 0.0135 / 0.0144 / 0.0346 | too short to time |

Scope reads include the root: 64,064 values for defaults, 2,002 for explicit
attributes and 1,001 for nesting. Partial answers are larger (known or unknown)
and check the gap index for explicit winners. Reading allocates nothing, even
with an allocation limit of zero. The iterators are 176 bytes (complete) and
192 bytes (partial). These numbers come from the program's `--attributes-only`
mode: `zig build bench-ir-partial -Doptimize=fast -- --attributes-only`.

### Resumable sessions

Sessions are opt-in, and **not** as fast as direct calls: use them when you
need bounded steps or cancellation, and direct calls otherwise. With metering
and cancellation off, a direct call runs its own fast driver. With either one
on, the direct lowering calls (`lowerComplete`, `lowerPartial` and their
fixed-storage forms) run the session machine internally, so they cost about
what a session does.

Two things count differently when you split the work into smaller budgets:

- **Work credits:** the total is the same however you split the budget. With
  growable storage, copy credits can vary slightly with the allocator's resize
  behaviour.
- **Cancellation checks:** every `advance` checks once when it starts, so many
  small budgets mean more checks than one large one.

No work unit was made coarser to improve these numbers.

Timings **with a cancel hook** below were measured before commit `c936fd1`,
which added a second check per credit to hooked lowering, materialization,
attribute and query sessions. At `c936fd1` that cost +4–9% on hooked lowering
sessions and +12–21% on hooked one-credit materialization sessions. Sessions
without a hook are not affected.

#### Lowering sessions

Development measurement at commit `d875891` (2026-10-24). Lowering changed in
later commits, and these times haven't been re-run since.

`zig build bench-ir-lowering-sessions -Doptimize=fast` compares direct
lowering with a lowering session on smaller inputs. Each process rotates the
routes over four warm-ups and eleven measured rounds. Direct lowering frees its
own scratch before returning, so that is timed; freeing the session isn't. All
session routes compile cancellation support; only the hook column installs a
hook, at interval 1.

Fast, median ms:

| Input | Direct | Session `run()` | Budget 4096 | Budget 1 | Budget 4096 + hook |
| --- | ---: | ---: | ---: | ---: | ---: |
| 2,000 connections | 0.2544 | 0.4690 | 0.4452 | 0.8939 | 0.5373 |
| 2,000 nodes, three attributes each | 0.3067 | 0.8795 | 0.8771 | 1.7309 | 0.9712 |
| 400 reopened scopes | 0.1123 | 0.2146 | 0.2146 | 0.4275 | 0.2440 |
| 2,000 nested scopes | 0.0650 | 0.1003 | 0.0998 | 0.1860 | 0.1179 |
| Concatenated name with a 64 KiB comment between its parts | 0.0173 | 0.1626 | 0.1618 | 0.3221 | 0.1789 |
| 5,000 × 5,000 symbolic product | 0.5048 | 0.9046 | 0.9002 | 1.8391 | 1.0712 |

Safe and Small, median ms, without a hook:

| Input | Safe direct | Safe 4096 | Safe 1 | Small direct | Small 4096 | Small 1 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Connections | 0.2959 | 0.7359 | 1.0097 | 0.3859 | 0.7657 | 1.3949 |
| Attributes | 0.4877 | 1.3999 | 1.8973 | 0.5280 | 1.5048 | 2.5794 |
| Reopened | 0.1590 | 0.3608 | 0.4875 | 0.1713 | 0.3755 | 0.6641 |
| Nested | 0.0977 | 0.1710 | 0.2201 | 0.0813 | 0.1503 | 0.3239 |
| Long comment | 0.0167 | 0.2628 | 0.3550 | 0.0295 | 0.2621 | 0.5048 |
| Symbolic product | 0.7053 | 1.5851 | 2.0795 | 0.8943 | 1.4559 | 2.7600 |

Fast budget-4096 sessions take about 1.5–2.9 times as long as direct lowering
on ordinary inputs, and 9.4 times on the long-comment input (15.7 times in
Safe): the session counts every byte of the comment instead of skipping it in
one step that can't be interrupted. Budget 1 adds the cost of pausing and
resuming.

Heap bytes, direct → session, the same in every build and budget:

| Input | Retained | Peak |
| --- | ---: | ---: |
| Connections | 321,828 → 321,828 | 336,424 → 336,424 |
| Attributes | 766,560 → 678,000 | 1,012,972 → 846,136 |
| Reopened | 183,228 → 193,428 | 215,756 → 232,696 |
| Nested | 194,268 → 194,268 | 281,396 → 281,396 |
| Long comment | 536 → 536 | 1,076 → 1,076 |
| Symbolic product | 943,184 → 943,184 | 1,050,824 → 1,050,824 |

Sessions reserve room for one attribute-map update before doing it, which
changes how storage grows, so session memory can be lower **or higher**: the
reopened input's peak is 7.9% higher. The session object itself is 1,816 bytes
in Fast and Small, 1,880 in Safe. The symbolic product stays one connection and
10,000 nodes, not 25 million edges.

#### Materialization sessions

Measured at commit `ac473db` (2026-10-24).

`zig build bench-ir-sessions -Doptimize=fast` (also `safe` / `small`) compares
direct materialization with sessions. One untimed folding pass warms the
process, then each route gets 12 warm-ups and 15 samples, rotating the routes.
Five serial processes per build. Parsing, lowering, reading the output and
freeing the final output are outside timing; freeing scratch is inside.

Sessions with attributes, **budget 4096, no hook**, median ms:

| Input | Fast | Safe | Small |
| --- | ---: | ---: | ---: |
| 2,000 plain edges | 0.0310 | 0.0339 | 0.0355 |
| 64 shared defaults | 0.0315 | 0.0356 | 0.0355 |
| 8 explicit attributes | 0.2847 | 0.3624 | 0.4559 |
| Strict overlapping sets | 2.0265 | 2.5162 | 2.6166 |
| Reopened scopes | 0.4323 | 0.5162 | 0.9660 |
| Endpoint ports | 0.0816 | 0.1087 | 0.1132 |
| Reversed strict port updates | 0.0852 | 0.0895 | 0.1344 |

At commit `0b3c81f`, Fast budget-4096 sessions took 1.25–1.73 times the direct
time in this harness, and budget 1 took 3.0–4.4 times. Use direct `materialize`
when you don't need steps.

- **Memory:** heap bytes match direct materialization in every build and
  budget, retained / peak: plain 38,064 / 63,344; explicit attributes
  484,796 / 759,476; strict overlap 312,156 / 514,632; reopened 13,236 / 21,988;
  ports 177,308 / 263,192.
- The session object is 448 bytes for topology only and 896 bytes with
  attributes in a Fast build, and 472 and 944 bytes in a Safe build (commit
  `60cc57e`). Nothing per node or edge is added to the
  IR or the output.
- The 2,500 × 2,500 product returns `PairLimit` on every route, without
  expanding its 6.25 million pairs.

#### Edge streaming sessions

Measured at commits `2a72c90`, `24f8ba0` and `6bfa394` (2026-10-24 and
2026-10-25).

`zig build bench-ir-edge-sessions -Doptimize=fast` compares the ordinary edge
iterator with a pull session. Each input warms for at least 50 ms and four
rotated rounds, then records eleven rounds; medians of five process medians.
Parsing, lowering, attribute queries and freeing are outside timing; setting up
the iterator or session and reading every edge are inside. An `advance` returns
as soon as **one** edge is ready, even if credits remain.

Fast, median ms:

| Input | Direct | Budget 4096 | Budget 1 | Budget 4096 + hook |
| --- | ---: | ---: | ---: | ---: |
| 2,000 connections | 0.0138 | 0.0123 | 0.0655 | 0.0399 |
| 1,000 three-member sets, 3,000 edges ¶ | 0.0173 | 0.0194 | 0.0843 | 0.0511 |
| 400 overlapping strict products, 10 edges | 0.0241 | 0.0267 | 0.0938 | 0.0424 |
| 200 reopened scopes, 20,100 edges | 0.0975 | 0.1495 | 0.4777 | 0.3016 |
| 2,000 port-bearing edges | 0.0133 | 0.0122 | 0.0656 | 0.0368 |
| First 1,000 edges of a 5,000 × 5,000 product | 0.0449 | 0.0410 | 0.0905 | 0.0536 |

Safe and Small, median ms, without a hook:

| Input | Safe direct | Safe 4096 | Safe 1 | Small direct | Small 4096 | Small 1 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Connections | 0.0175 | 0.0126 | 0.0653 | 0.0210 | 0.0124 | 0.0625 |
| Three-member sets ¶ | — | 0.0213 | 0.0870 | — | 0.0195 | 0.0973 |
| Strict overlap | 0.0268 | 0.0309 | 0.0978 | 0.0785 | 0.0806 | 0.1525 |
| Reopened | 0.0886 | 0.1579 | 0.4669 | 0.1638 | 0.1548 | 0.4782 |
| Ports | 0.0173 | 0.0126 | 0.0652 | 0.0210 | 0.0123 | 0.0636 |
| Product prefix | 0.0306 | 0.0532 | 0.1004 | 0.0544 | 0.0325 | 0.0892 |

Direct and hook columns are from `2a72c90`, budget columns from `24f8ba0`, and
rows marked ¶ from `6bfa394`.

- Without a hook, the session takes a combined path for one-to-one connections,
  for edges between endpoints it has already prepared, and for small
  non-strict sets in a single body. It charges exactly the same credits. Budget 1, an active hook,
  strict duplicate removal and scratch growth use the step-by-step path.
- On the three-member sets, the Fast budget-4096 session takes 1.12 times the
  direct time. The two-edge nested input is too short to time.
- **Memory:** direct and session peaks match: 0 bytes for one-to-one and port
  edges, 4,144 for small sets, 608 for strict overlap, 144 for nested scopes and
  100,456 for the product prefix. Reopened scopes use 2,516 bytes in Fast and
  Small, 1,884 in Safe. The session object is 488 bytes in Fast and Small, 512
  in Safe. Non-strict streams keep no output array; strict streams keep node
  pairs and a hash table, so they aren't constant-memory.

#### Query sessions

Measured at commit `9cd30d2` (2026-10-25).

`IR.hasEdgeSession` and `IR.containsSession` answer edge-existence and
membership questions in steps. `zig build bench-ir-query-sessions -Doptimize=fast`
(also `safe` / `small`) compares direct calls, session `run()`, budgets 1, 64
and 4096, an active interval-1 hook and run-time settings. Each row is 32
queries that alternate a miss on an isolated node with a query on the input's
target, checked against the other routes. Medians of three processes per build; each warms for at
least four rotated rounds and 50 ms, then measures eleven rotated rounds.
Times are **ms per 32 queries**, direct → session at budget 4096, no hook:

| Query input | Fast | Safe | Small |
| --- | ---: | ---: | ---: |
| 2,000 directed one-to-one connections, existence | 0.0764 → 0.1068 | 0.0795 → 0.13113 | 0.1269 → 0.1275 |
| 2,000 small-set connections, existence | 0.0749 → 0.1000 | 0.0643 → 0.12575 | 0.1118 → 0.1281 |
| 2,000 undirected connections, existence | 0.1000 → 0.1709 | 0.1076 → 0.23404 | 0.1790 → 0.2223 |
| 1,000 reopened scopes, existence | 15.3969 → 30.4107 | 16.94883 → 25.29417 | 62.9452 → 51.2665 |
| Final reopened membership, contains | 0.0306 → 0.0562 | 0.0423 → 0.05471 | 0.1231 → 0.0887 |

Safe session times, and Safe direct time for reopened existence, come from a
separate run with the Safe build's batching driver.

- Fast budget-4096 sessions take about 1.3–2.0 times the direct time; Safe 1.49
  times on reopened existence and about 2.18 times on undirected connections;
  Small 0.7–1.2 times.
- Fast `run()` / budget 1, same rows: 0.1069 / 0.1929, 0.1060 / 0.1879,
  0.1898 / 0.2983, 30.9156 / 55.3299 and 0.0639 / 0.1034 ms.
- Safe reopened existence: `run()` 26.99279 ms, budget 64 26.98592 ms, budget 1
  54.66013 ms, active hook 49.22917 ms, run-time settings at budget 4096
  27.27629 ms. Reopened membership: budget 1 0.08467 ms, active hook
  0.08363 ms, run-time settings 0.05517 ms.
- One-to-one membership, deep membership and the single product query are too
  short to time. The product query checks 2.5 billion possible edges through
  membership indexes without visiting them.
- Without the [query indexes](#optional-query-indexes), a session repeats the
  direct search, so reopened scopes stay expensive. Sessions bound each call;
  they don't lower the total work.
- **Memory:** no heap scratch on any route. With fixed settings, metering and
  complete input, the session state is **72 bytes** for existence and **56
  bytes** for membership in all three builds. Partial, run-time or cancellable
  variants can be larger.

#### Attribute sessions

Measured at commit `bb3ae96` (2026-10-25), except the rows marked §, measured
at `60cc57e` (2026-11-01).

`zig build bench-ir-attribute-sessions -Doptimize=fast` (also `safe` / `small`)
compares direct calls, session `run()`, budgets 1, 64 and 4096, an active
interval-1 hook and run-time settings. Building the source, parsing, lowering,
materializing and finding the handle are outside timing; setting up the
session, scratch and cleanup are inside. Medians of three processes per build,
each with at least four rotated warm-ups and 50 ms, then eleven measured
rounds. Times are **ms per 32 completed operations**; "all" reads the whole
effective attribute list:

| Operation / input | Fast, direct → budget 4096 | Safe, direct → budget 4096 | Session scratch bytes |
| --- | ---: | ---: | ---: |
| All 129 indexed node attributes | 0.05554 → 0.10083 | 0.06342 → 0.11192 | 0 |
| One attribute, 2 KiB quoted key § | 0.02092 → 0.037 | 0.02175 → 0.033 | 0 |
| One attribute, 2,000 strict updates | 0.33204 → 0.87483 | 0.34783 → 0.88788 | 0 |
| All attributes, 2,000 strict updates § | 0.290 → 1.333 | 0.35625 → 1.34171 | 24 |
| All attributes, 1,000 reversed port updates | 0.17100 → 0.62617 | 0.21121 → 0.63713 | 12 |
| All attributes, 1,000 reopened subgraph contributions | 0.31754 → 1.28608 | 0.43221 → 1.39608 | 12 |
| All two already-folded attributes | 0.00025 → 0.00154 | 0.00025 → 0.00158 | 0 |

§: the long-key row's session values and the strict row's Fast values are from
`60cc57e`; everything else is from `bb3ae96`.

- With fixed settings and no hook, a session compares plain key bytes in
  batches; the 32 long-key lookups take 66,848 credits. Budget 1 can't batch:
  Fast stays at about 0.42 ms. With run-time settings it takes about 0.27 ms
  in Fast. In Small, the long-key session took 0.360 ms.
- Large edge inputs cost roughly 2.6–4.7 times the direct operations. Strict
  edges still walk their contributions.
- Strict-update reads at `bb3ae96`: `run()` 1.35267 / 1.33946 ms (Fast / Safe),
  budget 1 4.09900 / 4.27033 ms, active hook 1.52563 / 1.77183 ms, run-time
  settings at budget 4096 1.34883 / 1.44263 ms.
- Tiny indexed and folded calls are shown for context; their ratios aren't
  stable.
- **Memory:** with fixed settings and metering, session state is 624 bytes for
  one lookup and 696 for reading all attributes; partial versions are 680 and
  752. One-key lookups allocate nothing, and so does reading all attributes of
  a node, scope, non-strict edge or folded edge. Strict compact reads use 12
  bytes per distinct written edge key, as direct reads do. A
  50,001 × 50,001 symbolic product is queried without expanding it.
- Ordinary attribute access doesn't use these sessions.

### Fixed storage

Fixed storage lets you hand the IR caller-owned buffers instead of an
allocator. It is opt-in; ordinary calls do no sizing or reservation. See
[fixed buffers](IR.md#fixed-buffers-no-allocator).

#### Fixed lowering

Measured at commit `a5ab7f8` (2026-10-25).

`zig build bench-ir-fixed -Doptimize=fast` (or `safe` / `small`). Nine process
runs per build, each with four warm-ups and eleven samples per rotating route.
Building the source, parsing, sizing, allocating the caller's buffers and
cleanup are outside timing. Allocation counts come from a separate untimed run.

`fixed used` reserves exactly what a previous run of the same input used. It
shows what fixed storage can save when you know the sizes; it isn't a cheap
sizing pass or a promise for edited input. `fixed bounds` reserves the full
bounds worked out from counts instead. No route expands the 25-million-pair
product.

| Input | Direct Fast: growable → fixed used (ms) | Direct Safe: growable → fixed used (ms) | Fixed session `run`: Fast / Safe (ms) |
| --- | ---: | ---: | ---: |
| 2,000 one-to-one connections | 0.2343 → 0.2006 | 0.3202 → 0.2212 | 0.3634 / 0.5978 |
| 2,000 nodes with attributes | 0.3237 → 0.2418 | 0.5583 → 0.3229 | 0.7471 / 1.1880 |
| 400 reopened-scope statements | 0.1202 → 0.1001 | 0.1991 → 0.1244 | 0.1855 / 0.2924 |
| 2,000 nested scopes | 0.0735 → 0.0637 | 0.1605 → 0.0685 | 0.0716 / 0.1268 |
| 64 KiB comment inside a concatenated name | 0.0175 → 0.0173 | 0.0168 → 0.0166 | 0.1645 / 0.2675 |
| 5,000 × 5,000 symbolic product | 0.5357 → 0.3930 | 1.0112 → 0.4196 | 0.5832 / 0.9953 |

Fixed storage removes copying while lists grow, not name reading or other
semantic work.

Memory, in bytes. Growable peak is live requested memory; fixed peak is the
whole graph-plus-scratch reservation, used or not. Fixed routes make no
allocator calls while building. Inline objects and the borrowed source and
Document are excluded:

| Input | Fast allocator calls: growable → fixed | Retained: growable → fixed used | Peak: growable → fixed used | Full-bounds peak |
| --- | ---: | ---: | ---: | ---: |
| 2,000 one-to-one connections | 33 → 0 | 321828 → 312488 | 336424 → 312776 | 768936 |
| 2,000 nodes with attributes | 66 → 0 | 766560 → 640624 | 1012972 → 640720 | 5810120 |
| 400 reopened-scope statements | 58 → 0 | 183228 → 173960 | 215756 → 174272 | 116088008 |
| 2,000 nested scopes | 44 → 0 | 194268 → 192504 | 281396 → 265112 | 505336 |
| 64 KiB comment inside a concatenated name | 13 → 0 | 536 → 312 | 1076 → 600 | 600 |
| 5,000 × 5,000 symbolic product | 57 → 0 | 943184 → 811360 | 1050824 → 811688 | 811800 |

Observed sizes cut the peak by about **6–44%** on these inputs. Full bounds can
be far larger: the reopened input reserves about **116 MB** with bounds, against
**174 KB** with observed sizes. Most of that is the safe upper bound for
attribute history, not live records. That is why bounds are an explicit choice,
not automatic.

The fixed session object is **2,304 bytes in Fast and 2,368 in Safe** at commit
`60cc57e`, beside its buffers. Supporting borrowed storage makes the ordinary graph handle 8 bytes
larger; nothing is added per record.

#### Fixed scratch for streaming and queries

Measured at commit `a484fef` (2026-10-25), except the row marked §, measured
at `60cc57e`.

The `...In` operations run the existing streaming and query algorithms on
caller-owned scratch. Ordinary operations don't reserve bounds, track scratch
high-water marks or check which storage they use, and no graph or record fields
were added.

`zig build bench-ir-fixed-queries -Doptimize=fast` (also `safe` or `small`)
compares growable scratch, observed sizes, explicit bounds, and fixed sessions
at budgets 1 and 4096. Five processes per build; eleven warmed, rotating samples
per process. Parsing, lowering, sizing and allocating the buffers are untimed;
setting up, walking and cleanup are timed. `fixed used` reuses a previous run's
high-water counts, as above.

| Input | Direct Fast: growable → fixed used (ms) | Direct Safe: growable → fixed used (ms) |
| --- | ---: | ---: |
| 2,000 one-to-one connections | 0.01321 → 0.01521 | 0.01608 → 0.01733 |
| 1,000 three-member sets | 0.01717 → 0.01963 | 0.01875 → 0.02350 |
| 400 overlapping strict products | 0.02292 → 0.02229 | 0.02604 → 0.02521 |
| 200 reopened-scope connections § | 0.09208 → 0.112 | 0.08688 → 0.120 |
| First 1,000 edges of a 5,000 × 5,000 product | 0.04254 → 0.02408 | 0.03408 → 0.03925 |
| 32 reads of all attributes over 2,000 strict updates | 0.47063 → 0.43629 | 0.39963 → 0.38821 |

In the § row the growable values are from `a484fef` and the fixed values from
`60cc57e` (Small: 0.226 ms).

Fixed scratch is a guarantee about allocation and ownership, **not a speedup**:
the reopened input is slower with it. Fixed edge sessions at budget 4096 take
0.00800 / 0.00888 ms for one-to-one connections and 0.10758 / 0.11779 ms for
reopened scopes (Fast / Safe). Fixed attribute sessions take
1.26283 / 1.25738 ms at budget 4096 and 4.60138 / 4.86138 ms at budget 1 for the
32 reads.

Scratch memory, in bytes. Growable peak is live requested memory; fixed is the
whole reservation, including unused slots, marks and hash tables. Every `In`
operation makes no allocator calls:

| Input | Growable peak, Fast / Safe | Fixed, observed sizes | Fixed, full bounds |
| --- | ---: | ---: | ---: |
| One-to-one connections | 0 / 0 | 0 | 24,012 |
| Three-member sets | 4,144 / 4,144 | 4,024 | 12,036 |
| Strict overlap | 608 / 608 | 304 | 304 |
| Reopened scopes | 2,516 / 1,884 | 1,604 | 2,412 |
| Product prefix | 100,456 / 100,456 | 80,000 | 120,000 |
| Strict attribute reads | 192 / 192 | 192 | 192 |

The product stays symbolic: its query holds member lists, not 25 million
edges. Bounds can waste memory; they don't look for one-to-one-only streams or
leave out keys that no edge uses.

With metering on and cancellation compiled out, the complete edge iterator is
280 bytes (growable) or 328 (fixed) in Fast, 304 or 352 in Safe; the edge
session is 456 or 432 bytes in Fast, 480 or 456 in Safe. The attribute iterator
is 176 bytes and the attribute session 696 bytes.

#### Fixed materialization

Measured at commit `eda87c7` (2026-10-31).

Caller-owned output and scratch cover complete and partial materialization,
with and without attributes, direct and in sessions. The input IR stays
symbolic. Run one report with:

```sh
zig build bench-ir-fixed-materialization -Doptimize=fast
# Also -Doptimize=safe or -Doptimize=small.
```

The report warms each route for 150 ms, then takes three more warm-ups and the
median of nine samples. Parsing, lowering, allocating the caller's buffers and
sizing are outside the build timing; sizing time is reported separately.
Building includes checking the buffer description and setting up tables. The
output is read and checked against the growable output. Routes: growable,
observed sizes, scanned bounds, and fixed sessions at budgets 4096 and 1.

Selected Fast results with attributes, **observed sizes**:

| Input | Edges | Growable ms | Fixed ms | Growable peak KiB | Fixed output + scratch KiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| One-to-one connections | 2,000 | 0.02075 | 0.01413 | 61.9 | 31.3 |
| Eight explicit keys per edge | 2,000 | 0.16371 | 0.11396 | 741.7 | 414.1 |
| Repeated strict set products | 1,024 | 1.24442 | 1.13642 | 502.6 | 220.5 |
| Reopened strict subgraphs | 250 | 0.29079 | 0.28288 | 21.5 | 14.7 |
| Endpoint ports | 2,000 | 0.05517 | 0.03629 | 257.0 | 132.8 |

- Observed sizes cut peak bytes by 31–56% here. Fixed building never allocates
  or falls back to an allocator, even after running out of room or being
  cancelled. Defaults stay shared with the IR; the output stores only explicit
  and derived winning values and its key list.
- **Bounds aren't sizing advice.** Scanning doesn't remove strict duplicates:
  the reopened input reserves 1,644,656 bytes with scanned bounds, against
  15,060 with observed sizes and a 21,988-byte growable peak. Strict overlap
  reserves 901,664 bytes scanned against 225,824 observed. One-to-one inputs
  have much tighter bounds. The scan took 0.024 ms on the reopened input and
  roughly 0.0002–0.0043 ms on the others, with its own work and cancellation
  allowance. Pass your own upper bounds or previous counts when memory
  matters.
- **Off cost:** ordinary lowering's machine code is byte-identical with and
  without fixed materialization in all three builds, and allocation peaks,
  credits and graph and session sizes are unchanged. Materialized results keep
  their size: 56 bytes for topology and 176 bytes with attributes in Fast and
  Small (200 in Safe). Ordinary routes against the version before (commit
  `772b6fe`), five alternating runs, change in time as a geometric mean (the
  one-edge nesting input is left out):

| Build | Attribute materialization | Topology-only materialization | Materialization session `run()` | Edge streaming |
| --- | ---: | ---: | ---: | ---: |
| Fast | +0.7% | +2.3% | +0.4% | +0.8% |
| Safe | -0.5% | +0.6% | -0.1% | +0.9% |
| Small | -4.2% | +1.8% | +1.5% | -2.7% |

One reopened topology case was +6.6% in Fast in the mixed benchmark program,
but -3.6% in a separate topology-only program with unchanged loop code.

## Cost of opt-in features

**Partial DOT results** ([editors](EDITORS.md#keep-the-finished-part-of-a-dot-file)).
The compile-time-settings figures here were measured during 0.5.0 development,
on the same machine, and weren't re-run for the release:

- **Off:** with compile-time settings, no measurable change (−1.0% to +0.5%
  across scanners, storage and both builds). Profiles with run-time settings
  weren't compared with the version before this feature.
- **On:** parsing is a few percent slower. Scalar scanner, Fast build:

| Input | Fixed buffers | Growing buffers |
| --- | ---: | ---: |
| Nodes | −6.0% | −2.5% |
| Edges | −5.3% | −6.9% |
| Subgraph edge ends | −7.9% | −8.9% |

- **On, with run-time settings:** 0–2% slower than the same profile with it
  off (`runtime_partial` against `runtime_baseline` in the
  [settings tables](#compile-time-and-run-time-settings)).
- **Memory, on:** fixed buffers use nothing extra. Growing buffers use 104 bytes
  more at their peak, and keep 26–34% more memory afterwards, because the lists
  aren't trimmed when parsing ends. Exact size hints or fixed buffers avoid that.

**Keeping label trees** costs memory for every kept tree; how much depends on
the labels. It hasn't been timed yet.

**Other opt-in features**, in short:

| Feature | When off | When on | Details |
| --- | --- | --- | --- |
| Cancellation interval above 1 (unreleased) | Interval 1 is the default | Same credits, fewer cancel checks | [Cancellation intervals](#cancellation-intervals) |
| Attribute string checks (unreleased) | Same profile type; identical machine code | Each checked value can be read again; no extra allocation | [Attribute string processing](#attribute-string-processing) |
| Early outline events (unreleased) | Identical machine code; no storage | One credit per extra callback | [Early outline events](#early-outline-events) |
| Unfinished-token previews (unreleased) | Identical machine code | 16 bytes per event session; callbacks depend on the budget | [Unfinished-token previews](#unfinished-token-previews) |
| Graph IR (unreleased) | Identical machine code when unused | Lowering time and memory | [Lowering a Document](#lowering-a-document) |
| Partial IR (unreleased) | No work in complete lowering | 32 bytes per gap; slower known/unknown lookups | [Partial IR](#partial-ir) |
| Folded attributes (unreleased) | Topology-only output runs no folding code | Builds winning values once; faster repeated reads | [Streaming and materializing edges](#streaming-and-materializing-edges) |
| Materialized adjacency (unreleased) | Default `.none`; timing changes up to +3.8% | Rows take exact extra memory and build time | [Optional materialized adjacency](#optional-materialized-adjacency) |
| IR query indexes (unreleased) | Identical machine code | Extra arrays and lowering time; much faster `hasEdge` | [Optional query indexes](#optional-query-indexes) |
| IR sessions (unreleased) | Direct calls don't use them | Slower than direct; bounded steps and cancellation | [Resumable sessions](#resumable-sessions) |
| Fixed IR storage (unreleased) | Ordinary calls do no sizing | No allocator calls; reservation can exceed use | [Fixed storage](#fixed-storage) |

## How these were measured

- **Machine:** Apple M4 Pro, 14 CPU cores, 48 GiB RAM, native aarch64 macOS
  27.0 (26A428). The CPU was not pinned and its speed was not fixed. Every
  section was measured on this machine.
- **Builds:** the 0.5.0 sections used Zig 0.16.0, `ReleaseFast` and
  `ReleaseSafe`. Unreleased sections used Zig 0.16.0 or Zig 0.17.0 as each
  section says, and often `ReleaseSmall` or `small` too.
- **Running:** the [benchmark programs](../bench/) were built before timing and
  ran one at a time, with no builds, tests or other benchmarks running.
- **Repeats:** in the 0.5.0 sections, each time is the median of five runs, and
  each run reports the median of its own timed rounds. The order of scanners
  and builds alternated between repeats, and no runs were thrown away.
  Unreleased sections say how many process runs they used (from two to nine),
  usually alternating the compared versions.
- **Rounding:** numbers are rounded as the benchmark programs print them. DOT
  speeds in the 0.5.0 sections are worked out from the source size and the
  time, rather than copied from the programs' MiB/s output.

Warm-up and timed rounds per benchmark, as set in the benchmark sources. When a
round does several operations, the time shown is per operation:

| Benchmark (step) | Warm-up per case | Timed rounds | Operations per round |
| --- | --- | ---: | --- |
| `bench`, `bench-lexer`, `bench-session`, `bench-subgraphs` | 2 rounds | 9 | 1 |
| `bench-policy` | at least 150 ms | 9 | 4 |
| `bench-cancellation` | at least 150 ms | 9 | 1 |
| `bench-markup` | 5 rounds | 9 | 16 |
| `bench-composition` | 3 rounds | 9 | 10 |
| `bench-identifiers` | 3 rounds | 9 | 4 |
| `bench-metering` | 2 rounds | 7 | 4 |
| `bench-previews` | 2 rounds | 7 | 8 |
| `bench-string` | 2 batches | 7 | at least 1,000 calls |
| `bench-string-sessions` | 2 batches | 7 | at least 100 calls |
| `bench-logical-strings` | 2 batches | 5 | at least 100 calls |
| `bench-string-integration` | 3 rounds | 9 | 3 |
| `bench-string-passthrough` | 2 rounds | 9 | at least 128 calls |
| `bench-ir`: lowering, attributes, bulk attributes | 2 rounds | 9 | 1 |
| `bench-ir`: values | 3 rounds | 9 | 1 |
| `bench-ir-partial` | at least 100 ms, then 2 rounds | 9 | 1 |
| `bench-ir-partial-edges` | at least 100 ms | 9 | 1 |
| `bench-ir-sessions` | 12 rounds | 15 | 1 |
| `bench-ir-lowering-sessions`, `bench-ir-fixed` | 4 rounds | 11 | 1 |
| `bench-ir-edge-sessions`, `bench-ir-fixed-queries` | at least 4 rounds and 50 ms | 11 | 1 |
| `bench-ir-query-sessions`, `bench-ir-attribute-sessions` | at least 4 rounds and 50 ms | 11 | 32 |
| `bench-ir-query-indexes` | lowering: at least 100 ms; queries: at least 80 ms | lowering 11, queries 9 | queries: enough for at least 1 ms |
| `bench-ir-fixed-materialization` | at least 150 ms, then 3 rounds | 9 | 1 |
| `bench-ir-adjacency` | 3 rounds | 9 | 1 |

The string benchmarks repeat each call many times per batch (more for shorter
inputs) and report the time per call.

**What isn't timed:** building the test input, reading files, and storing or
printing diagnostics. Diagnostics are counted but thrown away. Fixed-buffer
benchmarks also leave out sizing and setting up the buffers.

**What isn't covered:** real-world files, `ReleaseSmall` speed in the 0.5.0
sections, step-by-step markup parsing, the peak memory of markup trees built
with an allocator, and comparisons with older releases.

**How much runs varied.** The five DOT parse-and-validate runs for 0.5.0 fell
within these ranges. They are just the lowest and highest results, not
confidence intervals:

| Build / scanner | Growing (ms) | Hinted (ms) |
| --- | ---: | ---: |
| Fast / scalar | 7.81–8.26 | 6.50–6.88 |
| Fast / block | 8.01–8.30 | 6.77–7.27 |
| Safe / scalar | 8.74–9.25 | 7.30–7.45 |
| Safe / block | 9.90–10.17 | 8.14–8.51 |

Short tests varied more. The `plain` label-checking case ranged from 0.024 to
0.065 ms in the Fast build, and 1,000 sibling subgraphs from 0.026 to 0.035 ms.
Some markup cases also moved between runs: plain `text` with the scalar scanner
in a Safe build ranged from 0.636 to 0.849 ms. Even identical machine code can
time differently from one process to the next, depending on where the code
lands in memory. Treat small differences between settings or builds as noise,
not as dependable speedups.

In the settings benchmark, run-time settings are read in a way the compiler
can't see in advance, so it can't optimize them away. That reading happens
outside the timer.

## Running the benchmarks

Run one benchmark at a time, with no builds or other heavy work running. Pick
the build with `-Doptimize=fast`, `safe` or `small`, run each one several times
(five for the 0.5.0 tables) and take the median.

```sh
zig build bench -Doptimize=fast -Dlexer=scalar
zig build bench-markup -Doptimize=fast -- --graphviz-only
zig build bench-ir -Doptimize=safe
zig build check-benches  # only checks that they compile
```

`-Dlexer=scalar`, `block` or `auto` (the default, which means scalar) picks the
scanner for `bench`, `bench-lexer`, `bench-session` and `bench-subgraphs`.
The other benchmarks cover both scanners where it matters.

### Every benchmark step

| Step | What it measures | Options after `--` |
| --- | --- | --- |
| `bench` | DOT parse and validate, growing and hinted ([throughput.zig](../bench/throughput.zig)) | |
| `bench-lexer` | The DOT scanner on its own | |
| `bench-session` | DOT sessions with metering and cancellation | |
| `bench-subgraphs` | Sibling and nested subgraphs | |
| `bench-policy` | Compile-time against run-time settings | |
| `bench-markup` | Markup parsing, memory, execution options and validation | `--rules-only`, `--validation-only`, `--scopes-only`, `--graphviz-only` |
| `bench-composition` | DOT with markup label checking: time, allocator calls, peak bytes | |
| `bench-cancellation` (unreleased) | Cancellation intervals for both parsers | |
| `bench-metering` (unreleased) | DOT and markup parsing: default, tiny and batched budgets, cancellation, run-time settings | |
| `bench-identifiers` (unreleased) | Checked against parser-recognized names in an event-only index | |
| `bench-previews` (unreleased) | Unfinished-token previews: time, callbacks, credits, session size | |
| `bench-string` (unreleased) | Standalone exact, ASCII-insensitive, Unicode and custom checks | `--csv` |
| `bench-string-sessions` (unreleased) | String metering and cancellation | `--csv` |
| `bench-logical-strings` (unreleased) | String checks through DOT, markup and plain readers | `--csv` |
| `bench-string-integration` (unreleased) | Attribute string checks in DOT and markup, with allocator totals | `--csv` |
| `bench-string-passthrough` (unreleased) | Real DOT quote scanning, then simulated string checks | |
| `bench-ir` (unreleased) | IR lowering, expansion, attributes, values and bulk attributes (four programs, one after another) | |
| `bench-ir-materialized` (unreleased) | Folded attributes against compact reads | |
| `bench-ir-partial` (unreleased) | Partial IR lowering, lookups, mentions and pair queries | |
| `bench-ir-partial-edges` (unreleased) | Complete against partial edge streaming, folding and memory | |
| `bench-ir-sessions` (unreleased) | Direct against resumable materialization | |
| `bench-ir-lowering-sessions` (unreleased) | Direct against resumable lowering | |
| `bench-ir-edge-sessions` (unreleased) | Direct against resumable edge streaming | |
| `bench-ir-query-sessions` (unreleased) | Direct against resumable `hasEdge` and membership queries | |
| `bench-ir-attribute-sessions` (unreleased) | Direct against resumable attribute lookups and reads | |
| `bench-ir-query-indexes` (unreleased) | Optional query indexes: lowering, memory, repeated queries | |
| `bench-ir-adjacency` (unreleased) | Optional adjacency: building, walking, memory | |
| `bench-ir-fixed` (unreleased) | Fixed-storage lowering: sizing, allocator calls, memory, time | |
| `bench-ir-fixed-queries` (unreleased) | Fixed scratch for streaming and queries | |
| `bench-ir-fixed-materialization` (unreleased) | Growable against fixed materialization | |
| `perf-string` (unreleased) | Compares string benchmarks against a Git revision; see below | see below |
| `string-size-probes` (unreleased) | Installs the Wasm size probes | |
| `check-wasm` (unreleased) | Runs the Wasm probes and checks which keep the folding table (needs Node) | |
| `check-benches` | Compiles the benchmarks without running them | |

Without an option, `bench-markup` runs the parsing, memory, execution-option
and validation measurements, but not the `--scopes-only` and `--graphviz-only`
runs, which need their option. `--rules-only` runs only the name and reference
checks; `--validation-only` runs those plus the encoding checks and validation
with cancel checks. `--csv` prints machine-readable rows.
`bench-ir-partial -- --attributes-only` runs only the attribute reads. Other
benchmark steps don't take options: `zig build` doesn't pass arguments to them.
`-Dstring-default-only=true` compiles only the default paths of
`bench-string-integration`.

`bench-policy` warms each case for at least 150 ms and averages four parses per
sample, because two short warm-up parses didn't reliably settle the first case.

### One-command string comparison

> **Unreleased.** Not in 0.5.0.

`perf-string` compares the working tree with a Git revision:

```sh
zig build perf-string -- --baseline HEAD
zig build perf-string -- --baseline HEAD --modes fast,safe,small --runs 5
zig build perf-string -- --baseline HEAD --suites sessions --modes fast
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--baseline REF` | `HEAD` | Git commit or ref to compare with |
| `--modes LIST` | `fast,safe` | Any of `fast`, `safe`, `small` (not the old `Release*` names) |
| `--suites LIST` | `native,sessions` | Any of `native`, `sessions`, `logical`, `integration`, `host-defaults` |
| `--runs N` | `3` | Process runs per side: an odd number from 3 to 31 |
| `--threshold PERCENT` | `5` | Flag median time increases above this |
| `--output DIRECTORY` | `zig-out/perf-string/<timestamp>/` | A new report directory; an existing one is refused |
| `--help` | | List the options |

The suites:

- `native`: UTF-8, UTF-16LE and UTF-32LE, the available comparison modes, and
  built-in and custom equality. Seven timed batches after two warm-ups.
- `sessions`: UTF-8 default encoding validation, exact equality, run-time
  settings, budgets 1 and 64, cancellation intervals 1 and 64, custom stepped
  and batched validators, and membership. Seven after two.
- `logical`: plain, DOT and markup readers on short, long, Unicode and
  glue- or reference-heavy values, including budgets 1 and 64 and exact
  credit and session-size accounting. Five after two.
- `integration` and `host-defaults`: DOT and markup attribute checks, and the
  default-only programs. Nine after three.

The reporter copies both source trees and the current benchmark harness,
builds everything with the **same compiler**, then runs one benchmark at a time,
alternating before and after. It reads Git objects without checking out or
changing a branch. Both revisions must build with that compiler: revisions that
still need Zig 0.16.0 can't be compared with Zig 0.17.0 without porting them
first. A baseline that lacks a required API fails the build; it isn't treated
as passing. Comparison modes that are new in the working tree are reported as
**new**, with no made-up baseline or percentage.

Each report includes:

- `summary.md`: group summaries, and timings and decimal MB/s for every case.
- `results.csv` and `raw/`: medians, observed ranges, per-run results, session
  sizes, credit totals and cancellation check counts.
- `metadata.txt`, source manifests and the captured harness and sources:
  compiler, architecture and OS, revision, dirty-tree status and the exact
  inputs needed to reproduce it.
- `binaries.csv`: sizes of the benchmark programs, **not the library size**.

A time increase above `--threshold` whose run ranges don't overlap is flagged
`slower`. An increase above the threshold with overlapping ranges is
`inconclusive`. Neither this rule nor a geometric mean replaces looking at
individual cases; `within_threshold` is not a promise of no slowdown. The
suites use hot buffers and throw diagnostics away. Zero processor heap
allocations in these inputs don't mean zero process memory, zero stack use, or
zero allocations with growable bags or your own callbacks. All builds finish
before timing; avoid other heavy work while the measurements run.

The reporter is tested by `zig build check-tools` and `zig build test`. It
doesn't run the DOT or markup parsing benchmarks, sample RSS or check Wasm
sizes.

## Examples

- [fixed_buffer.zig](../examples/fixed_buffer.zig): the whole pipeline with no
  allocator, printing the storage size
- [bounded.zig](../examples/bounded.zig): a work-budget loop, then cancelling a
  session
- [policies.zig](../examples/policies.zig): compile-time settings, run-time
  overrides and sessions bound to settings
- [resumable_graph.zig](../examples/resumable_graph.zig): lowering a Document
  into the IR in bounded steps
- [fixed_graph.zig](../examples/fixed_graph.zig): IR storage you own
- [fixed_edge_stream.zig](../examples/fixed_edge_stream.zig): streaming edges
  with scratch you own
- [graph_adjacency.zig](../examples/graph_adjacency.zig): building adjacency
  only when you ask for it

Run them with `zig build examples`. The programs that produced the numbers on
this page are in [bench/](../bench/).
