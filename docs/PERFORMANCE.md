# Performance

How fast the parsers are and how much memory they use. Throughput and allocation
tables were measured on the development version (commit `fd36194`, 2026-10-05);
[type sizes](#type-sizes) were checked separately on 2026-10-07. Measurements use
one machine and made-up test files. Use the numbers as a rough guide: your files,
hardware and settings will give different results.
[How these were measured](#how-these-were-measured) has the details.

Reading the tables:

- **MB** means 1,000,000 bytes, and **MB/s** means MB per second.
- A timing cell like `7.60 / 359.7` means **7.60 ms, which is 359.7 MB/s**.
  Both numbers describe the same run.
- **Fast** and **Safe** mean `ReleaseFast` and `ReleaseSafe` builds.

## At a glance

- **DOT:** parsing and validating a 2.7 MB file takes 7.6 ms (about 360 MB/s)
  in a Fast build, or 6.6 ms (about 410 MB/s) with size hints.
- **Memory:** the document takes about 34 bytes per statement, and your source
  is never copied. With an arena, size hints cut the memory for that file from
  37.6 MB to 8.4 MB.
- **Scanners:** the default scalar scanner is faster end to end. The block
  scanner wins on long runs of plain text.
- **Small steps:** with both metering and cancel checks on, parsing takes about
  1.6 times as long.
- **Markup:** about 290 to 440 MB/s for markup full of tags and attributes, and
  much faster for mostly plain text.
- **Labels in DOT:** a file with 1,000 small labels is parsed and checked at
  about 140 MB/s, with only 7 allocations.

## Parse and validate

The [DOT throughput benchmark](../bench/throughput.zig) uses a 2.733 MB file
with 200,000 statements: numbered nodes alternating with `--` edges. Settings
are the defaults. Times include `parseAndValidate` and its allocations into a
fresh arena, but not freeing the arena.

"Hinted" passes exact size hints, taken from the known contents of the file.
The time it would take `measure` to work them out is **not** included.

| Build | Scanner | Growing | Hinted |
| --- | --- | --- | --- |
| Fast | scalar | 7.60 / 359.7 | 6.63 / 412.3 |
| Fast | block | 8.63 / 316.7 | 7.64 / 357.8 |
| Safe | scalar | 9.12 / 299.7 | 7.67 / 356.4 |
| Safe | block | 12.26 / 222.9 | 10.74 / 254.5 |

## Memory

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

`@sizeOf` values for the development version on this machine (aarch64 macOS,
Zig 0.16.0), checked 2026-10-07. They are the size of each value itself, not
memory used while parsing, and they can differ on other targets or Zig
versions. A [layout test](../tests/layouts.zig) checks this table in all four
build modes.

| Type | Debug / Safe | Fast / ReleaseSmall |
| --- | ---: | ---: |
| `dot.Profile(.{}).Session` | 1,120 bytes | 1,112 bytes |
| DOT session with metering and cancellation | 1,184 bytes | 1,176 bytes |
| `dot.lexer.For(.scalar)` | 64 bytes | 56 bytes |
| `dot.lexer.For(.block)` | 152 bytes | 152 bytes |

The second row turns on `.execution = .{ .metering = true, .cancellation = true }`
and leaves every other setting at its default. Session sizes don't include the
source, document buffers, nesting space or diagnostics, which you supply
separately. Use `@sizeOf` on your own profile and target rather than copying
these numbers.

Keeping comments (unreleased) makes the document and storage types a little
larger even when it is off, so the default fixed session is 32 bytes bigger
than in 0.4.0. Scanner sizes and per-statement records are unchanged. With
comment retention off, no comment records are allocated. With it on, each
comment takes 12 bytes, plus spare room in growing lists unless you give exact
sizes or fixed buffers. The comment text itself is never copied.

The benchmark programs also print these sizes, the same in Fast and Safe
builds:

| Type | Size (bytes) |
| --- | ---: |
| DOT session with run-time settings | 1,352 |
| Markup node / attribute | 20 / 20 |
| Markup nesting frame / attribute-key scratch entry | 12 / 8 |
| Markup diagnostic / validation result | 36 / 32 |
| Markup session: default / bounded / run-time settings | 432 / 440 / 504 |

Partial markup retention (unreleased) adds 8 bytes to a run-time-policy session;
default fixed-policy and bounded session sizes are unchanged. Node and attribute
records remain 20 bytes. Retaining a failed prefix reuses those pools without a
new allocation; an owned failed result keeps the pools alive until `deinit()`.

## Scanners

The [lexer benchmark](../bench/lexer.zig) times the DOT scanner on its own, in
a Fast build. Each pattern is repeated 65,536 times. The `long HTML label` row
only measures how fast DOT finds where a `<...>` value ends, not checking what
is inside it.

| Pattern | Source (MB) | Scalar | Block |
| --- | ---: | --- | --- |
| short names and punctuation | 1.114 | 7.21 / 154.5 | 5.67 / 196.5 |
| short names, spaces and line breaks | 0.983 | 2.97 / 331.0 | 2.75 / 357.5 |
| keywords and numbers | 3.670 | 5.98 / 613.7 | 5.84 / 628.4 |
| quoted strings and comments | 2.228 | 2.93 / 760.5 | 4.49 / 496.3 |
| long HTML label | 80.806 | 40.53 / 1,993.7 | 8.60 / 9,396.0 |
| long name | 4.260 | 3.31 / 1,287.0 | 2.13 / 1,999.9 |

The block scanner wins on long runs, but scalar wins on quoted strings and
comments. A faster scanner alone doesn't mean a faster parse overall: end to
end, scalar is faster (see [parse and validate](#parse-and-validate)). Scalar
stays the default; see [two scanners](EXECUTION.md#two-scanners).

## Step-by-step sessions

The [session benchmark](../bench/session.zig) parses 200,000 `a;` statements
(0.400 MB) in a fixed-buffer session with the scalar scanner, without
validation. Metered sessions spend 256 credits per `advance` call; the others
use `run()`.

| Metering | Cancellation | Fast | Safe | Cancel checks |
| --- | --- | --- | --- | ---: |
| off | off | 3.33 / 120.1 | 3.79 / 105.5 | 0 |
| on | off | 4.15 / 96.4 | 4.33 / 92.4 | 0 |
| off | on | 4.67 / 85.7 | 4.92 / 81.3 | 1,400,016 |
| on | on | 5.48 / 73.0 | 5.31 / 75.3 | 1,405,484 |

The cancel callback counts how often it is called but never asks to stop. So
these numbers show the cost of checking, not how quickly a cancel takes
effect. Your own callback's work adds to it. Setting up the session and its
memory isn't timed.

## Compile-time and run-time settings

The [settings benchmark](../bench/policies.zig) parses 50,000 `a;` statements
(0.100 MB) into fixed buffers, without validation:

- `fixed` uses compile-time settings.
- `runtime_baseline` turns on run-time settings but changes nothing.
- `runtime_override` passes the same scanner choice as a run-time setting.

| Scanner | Settings | Fast | Safe |
| --- | --- | --- | --- |
| scalar | fixed | 0.814 / 122.9 | 0.924 / 108.2 |
| scalar | runtime_baseline | 0.885 / 113.0 | 0.954 / 104.8 |
| scalar | runtime_override | 0.885 / 113.0 | 0.955 / 104.7 |
| block | fixed | 0.839 / 119.2 | 1.163 / 86.0 |
| block | runtime_baseline | 1.338 / 74.7 | 1.210 / 82.7 |
| block | runtime_override | 1.309 / 76.4 | 1.207 / 82.9 |

These time the whole parse, not just the cost of reading the settings. Each
row is compiled differently, so part of the difference is just different
machine code. The file is small, so this can't tell you the cost of run-time
settings in general. Measure the settings and files you actually use.

## Subgraphs

The [subgraph benchmark](../bench/subgraphs.zig) parses empty subgraphs into
fixed buffers with the scalar scanner. Each `{}` is two bytes, plus eight bytes
for the surrounding graph. `siblings` puts them side by side; `nested` puts
each one inside the previous one.

| Shape | Count | Fast | Safe | Document (MB) | Nesting space (bytes) |
| --- | ---: | --- | --- | ---: | ---: |
| siblings | 1,000 | 0.025 / 80.3 | 0.032 / 62.8 | 0.044 | 116 |
| nested | 1,000 | 0.029 / 69.2 | 0.033 / 60.8 | 0.044 | 116,000 |
| siblings | 10,000 | 0.278 / 72.0 | 0.315 / 63.5 | 0.440 | 116 |
| nested | 10,000 | 0.300 / 66.7 | 0.341 / 58.7 | 0.440 | 1,160,000 |
| siblings | 100,000 | 2.811 / 71.2 | 3.167 / 63.2 | 4.400 | 116 |
| nested | 100,000 | 3.080 / 64.9 | 3.377 / 59.2 | 4.400 | 11,600,000 |

Deep nesting can't overflow the call stack, but it does need nesting space for
every open level. 100,000 nested subgraphs need **11.6 MB** of nesting space,
on top of the 4.4 MB document. Setting up that memory isn't timed, and an
allocator that grows as it goes may use more at its peak.

## Markup on its own

The [markup benchmark](../bench/markup.zig) parses markup into fixed buffers of
exactly the right size, with compile-time settings. Times don't include sizing
or setting up the buffers, or any validation.

| Fixture | Source (MB) | Fast, scalar | Fast, block | Safe, scalar | Safe, block |
| --- | ---: | --- | --- | --- | --- |
| flat | 0.200 | 0.584 / 342.5 | 0.609 / 328.6 | 0.638 / 313.5 | 0.664 / 301.1 |
| mixed | 0.750 | 2.379 / 315.2 | 2.504 / 299.5 | 2.600 / 288.5 | 2.630 / 285.2 |
| text | 1.000 | 0.465 / 2,151.3 | 0.079 / 12,631.7 | 0.633 / 1,578.9 | 0.080 / 12,534.8 |
| deep | 0.070 | 0.241 / 290.2 | 0.256 / 273.8 | 0.265 / 263.7 | 0.277 / 253.1 |
| attributes | 1.100 | 3.391 / 324.4 | 3.567 / 308.4 | 3.431 / 320.6 | 3.633 / 302.8 |
| duplicates | 1.100 | 3.386 / 324.9 | 3.572 / 308.0 | 3.432 / 320.5 | 3.609 / 304.8 |
| references | 1.700 | 3.987 / 426.4 | 4.094 / 415.2 | 4.188 / 405.9 | 4.238 / 401.1 |
| attribute_references | 1.800 | 4.122 / 436.7 | 4.090 / 440.1 | 4.237 / 424.8 | 4.296 / 419.0 |
| comments | 1.400 | 1.238 / 1,131.1 | 1.102 / 1,270.0 | 1.316 / 1,063.7 | 1.207 / 1,160.3 |
| cdata | 1.550 | 1.552 / 998.5 | 1.429 / 1,084.5 | 1.745 / 888.5 | 1.571 / 986.4 |
| prose | 1.835 | 0.982 / 1,867.8 | 0.282 / 6,500.1 | 1.231 / 1,490.3 | 0.316 / 5,801.9 |
| long_names | 0.655 | 0.248 / 2,646.2 | 0.096 / 6,834.2 | 0.323 / 2,025.7 | 0.114 / 5,749.2 |
| long_values | 1.965 | 1.110 / 1,770.1 | 0.310 / 6,345.2 | 1.425 / 1,378.7 | 0.329 / 5,969.1 |

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
| fixed | 3.391 / 324.4 | 0.982 / 1,867.8 |
| runtime_baseline | 3.412 / 322.4 | 0.979 / 1,874.7 |
| runtime_override | 3.370 / 326.4 | 0.987 / 1,858.5 |
| count_only | 2.953 / 372.5 | 0.951 / 1,929.0 |
| cancellable | 5.632 / 195.3 | 5.614 / 326.9 |

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
| Duplicate attributes | 1.100 | 0.942 / 1,168.1 | 1.376 / 799.3 | 24 |
| ASCII names | 1.400 | 1.507 / 929.1 | 1.809 / 773.7 | 0 |
| Unicode names | 1.100 | 0.984 / 1,118.0 | 1.319 / 834.0 | 0 |
| Reference list | 1.250 | 1.323 / 944.8 | 1.491 / 838.1 | 0 |
| UTF-8, ASCII text | 0.500 | 0.116 / 4,328.4 | 0.139 / 3,609.4 | 0 |
| UTF-8, Unicode text | 0.600 | 0.666 / 900.6 | 0.740 / 810.7 | 0 |
| UTF-8, invalid bytes | 0.350 | 0.363 / 963.8 | 0.518 / 676.0 | 0 |
| All checks together | 1.200 | 2.807 / 427.4 | 3.288 / 365.0 | 16 |

- The duplicate fixture has 50,000 repeated keys.
- Name checks use the XML 1.0 rules. The reference check uses the five XML
  names (`amp`, `lt`, `gt`, `quot`, `apos`).
- "All checks together" turns on names, references, UTF-8 and duplicate keys.
- Findings in the invalid inputs are counted and thrown away, not stored.

### Checking markup that failed to parse

[`validateSourceIn`](MARKUP.md#checking-a-fragment-that-failed-to-parse) checks
the parts it can recognise, without building a tree. This is the
`--scopes-only` run. Each fixture repeats an item 10,000 times and reports
20,000 validation errors.

| Fixture | Source (MB) | Fast, scalar | Safe, scalar | Scratch (bytes) |
| --- | ---: | --- | --- | ---: |
| complete | 0.260 | 1.092 / 238.1 | 1.254 / 207.3 | 72 |
| bad_closer | 0.300 | 1.107 / 271.0 | 1.255 / 239.1 | 72 |
| bad_header | 0.360 | 1.656 / 217.4 | 1.852 / 194.4 | 72 |

- `complete`: every tag is finished, though attributes and references still
  have errors.
- `bad_closer`: closing tags are wrong, but every tag can still be checked on
  its own. This says nothing about whether the tags nest correctly.
- `bad_header`: some tags are cut off, so checking skips ahead and reports that
  it couldn't check everything.

Don't compare these with full-document validation times; they do different
work.

### Graphviz vocabulary checks

> **Unreleased.** No numbers are recorded yet.

- Each element and attribute is looked up with a few short comparisons. The
  checks keep nothing extra in the document and allocate nothing themselves.
- Validating a document still walks its elements and attributes once.
  Duplicate checking costs what it did before.
- `validateSource` needs no buffer for tags when duplicate checking is off.
- A profile fixed at compile time to structural mode leaves the Graphviz checks
  and case-insensitive matching out of the program. A profile with run-time
  settings includes both modes, which makes the program larger, so benchmark
  it separately.
- Validation still can't run in small steps. Cancelling and stopping work as
  before.

Measure them with
`zig build bench-markup -Doptimize=ReleaseFast -- --graphviz-only`. It times the
checks after parsing, with fixed and run-time settings and with valid and
invalid input. Parsing and storing diagnostics aren't included.

## DOT with label checking

The [composition benchmark](../bench/composition.zig) uses a DOT profile with
the markup parser bound as its
[label checker](LABELS.md#check-every-label-while-parsing), and calls
`parseAndValidate`. Times include parsing the DOT, checking the labels,
validating, and freeing the result. Both parsers use the scanner shown.
Diagnostics are thrown away.

- `plain`: 1,000 nodes and no labels. The label checker is bound but has
  nothing to do.
- `labels`: 1,000 labels of `<b x='1' y='2'>t</b>`.
- `invalid`: 1,000 labels, each with a repeated attribute and a wrong closing
  tag. The DOT itself is fine, but the file as a whole is invalid.
- `large_first`: one label with 10,000 elements, followed by 50,000 plain
  nodes.

| Fixture | Scanner | Source (bytes) | Fast | Safe | Peak (bytes) | Allocations / resizes / remaps |
| --- | --- | ---: | --- | --- | ---: | --- |
| plain | scalar | 2,010 | 0.024 / 85.0 | 0.025 / 80.4 | 27,064 | 2 / 0 / 19 |
| plain | block | 2,010 | 0.026 / 77.3 | 0.029 / 68.8 | 27,064 | 2 / 0 / 19 |
| labels | scalar | 32,010 | 0.222 / 144.2 | 0.226 / 141.6 | 44,260 | 7 / 0 / 29 |
| labels | block | 32,010 | 0.245 / 130.7 | 0.271 / 118.2 | 44,260 | 7 / 0 / 29 |
| invalid | scalar | 35,010 | 0.319 / 109.6 | 0.342 / 102.4 | 44,404 | 8 / 0 / 29 |
| invalid | block | 35,010 | 0.352 / 99.5 | 0.393 / 89.1 | 44,404 | 8 / 0 / 29 |
| large_first | scalar | 140,029 | 1.298 / 107.9 | 1.365 / 102.6 | 1,670,604 | 5 / 0 / 55 |
| large_first | block | 140,029 | 1.392 / 100.6 | 1.548 / 90.5 | 1,670,604 | 5 / 0 / 55 |

**Peak** is the most memory the library had asked for at any one moment
during a call, measured with a separate counting allocator. It doesn't include
the source, the allocator's own bookkeeping or the copies it makes while
resizing, or the program's total memory use. The last column counts calls to the allocator, not requests to the
operating system.

The label checker's buffers can stay allocated while DOT's own buffers grow;
`large_first` tests exactly that. After each call, the counting allocator
confirms that everything was freed.

## How these were measured

- **Machine:** Apple M4 Pro, 14 CPU cores, 48 GiB RAM, native aarch64 macOS
  27.0 (26A428). The CPU was not pinned and its speed was not fixed.
- **Builds:** Zig 0.16.0, `ReleaseFast` and `ReleaseSafe`.
- **Running:** the [benchmark programs](../bench/) were built before timing and
  ran one at a time, with no builds or other benchmarks running.
- **Repeats:** each time is the median of five runs, and each run reports the
  median of its own timed rounds. The order of scanners and builds alternated
  between repeats, and no runs were thrown away.
- **Rounding:** numbers are rounded as the benchmark programs print them. DOT
  speeds are worked out from the source size and the time, rather than copied
  from the programs' MiB/s output.

| Benchmark | Warm-up rounds per run | Timed rounds | Operations per round |
| --- | ---: | ---: | ---: |
| DOT parse and validate, lexer, sessions, subgraphs, settings | 2 | 9 | 1 |
| Markup parsing and validation | 5 | 9 | 16 |
| DOT with label checking | 3 | 9 | 10 |

When a round does several operations, the time shown is per operation.

**What isn't timed:** building the test input, reading files, and storing or
printing diagnostics. Diagnostics are counted but thrown away. Fixed-buffer
benchmarks also leave out sizing and setting up the buffers.

**What isn't covered:** real-world files, `ReleaseSmall` speed, step-by-step
markup parsing, the peak memory of markup trees built with an allocator, and
comparisons with older versions.

**How much runs varied.** The five DOT parse-and-validate runs fell within
these ranges. They are just the lowest and highest results, not confidence
intervals:

| Build / scanner | Growing (ms) | Hinted (ms) |
| --- | ---: | ---: |
| Fast / scalar | 7.55–7.80 | 6.62–6.81 |
| Fast / block | 8.57–8.68 | 7.57–7.74 |
| Safe / scalar | 8.59–9.31 | 7.06–7.78 |
| Safe / block | 9.87–12.39 | 8.14–10.94 |

Short tests varied even more: the scalar, Fast, compile-time `fixed` settings
case ranged from 0.803 to 1.280 ms. Treat small differences between settings or
builds as noise, not as dependable speedups.

In the settings benchmark, run-time settings are read in a way the compiler
can't see in advance, so it can't optimize them away. That reading happens
outside the timer.

## Running the benchmarks

Run one benchmark at a time, with no builds or other heavy work running:

```sh
zig build bench -Doptimize=ReleaseFast -Dlexer=scalar
zig build bench-lexer -Doptimize=ReleaseFast -Dlexer=scalar
zig build bench-session -Doptimize=ReleaseFast -Dlexer=scalar
zig build bench-subgraphs -Doptimize=ReleaseFast -Dlexer=scalar
zig build bench-policy -Doptimize=ReleaseFast
zig build bench-markup -Doptimize=ReleaseFast
zig build bench-markup -Doptimize=ReleaseFast -- --scopes-only
zig build bench-composition -Doptimize=ReleaseFast
zig build check-benches  # only checks that they compile
```

Repeat everything with `-Doptimize=ReleaseSafe`. Repeat the first four with
`-Dlexer=block` too; the others already cover both scanners where it matters.
Run each one five times and take the median. `bench-markup` also accepts
`-- --rules-only`, `-- --validation-only` and `-- --graphviz-only` for shorter
runs.
