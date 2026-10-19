# Performance

How fast the parsers are and how much memory they use. Everything here was
measured for 0.5.0 on 2026-10-12, at commit `2ea1311`, except where a section
says otherwise. Measurements use one machine and made-up test files. Use the
numbers as a rough guide: your files, hardware and settings will give different
results.
[How these were measured](#how-these-were-measured) has the details.

Reading the tables:

- **MB** means 1,000,000 bytes, and **MB/s** means MB per second.
- A timing cell like `7.85 / 348.2` means **7.85 ms, which is 348.2 MB/s**.
  Both numbers describe the same run.
- **Fast** and **Safe** mean `ReleaseFast` and `ReleaseSafe` builds.

## At a glance

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

## Standalone strings (Unreleased)

Measured on 2026-10-18, Apple M4 Pro, Zig 0.16.0, ReleaseFast, using
[`bench/string.zig`](../bench/string.zig). These are new-module baselines, not
DOT/markup before-and-after numbers. Each cell is the median of three runs;
each run uses seven measured batches after two warmups. Source allocation is
outside timing. Each call verifies encoding, runs equality and consumes the
result with a discard sink. Profiles compile UTF-8/16/32 readers, with fixed
policies. Case folding is enabled only in the folding variants.

For the same logical value, `Straße 中文 😀`:

| Source encoding | Physical bytes | Exact, ns/value (MB/s) | Unicode folding, ns/value (MB/s) |
| --- | ---: | ---: | ---: |
| UTF-8 | 19 | 14.4 (1,319) | 119.3 (159) |
| UTF-16LE | 24 | 55.5 (432) | 116.8 (205) |
| UTF-32LE | 44 | 40.6 (1,084) | 102.5 (429) |

MB/s counts physical bytes, so wider encodings are not directly comparable by
throughput alone; compare ns/value too. For seven-byte ASCII `Seattle`, UTF-8
exact checking took about 7.2 ns/value and folding 40.5 ns/value. On a 4,200-byte
ASCII value, exact checking took about 235 ns/value (17,895 MB/s), using the
standard validator's ASCII fast path and validated byte equality. Folding took
about 25 µs/value, with appreciable run variation (19–29 µs): these microbenchmarks
are not guarantees for arbitrary text or diagnostics-heavy work.

The harness also binds the supplied Equals validator through the custom slot.
It uses the same verification/comparison/reporting contract; code generation
and timings are not promised identical. For the 19-byte UTF-8 value, exact custom
checking took about 17.6 ns/value versus 14.4 ns for the named built-in. Membership,
runtime-policy preparation, callbacks and retained diagnostic costs depend on
their configuration; they are not represented by the equality table.

Processor/comparator heap allocations: **zero**. Source stays borrowed, with no
tree or decoded/folded string buffer. On this target `Result` is 24 bytes and
the default diagnostic is 72 bytes; custom details can enlarge diagnostics.
Growable bags and consumer callbacks can allocate independently. Folding uses
bounded three-scalar buffers per comparison side plus cursors, not input-sized
scratch. These are library payload/cost facts, not process RSS measurements.

Consumed, stripped Wasm32 ReleaseSmall probes, without console rendering:

| Probe | Module bytes | Folding table |
| --- | ---: | --- |
| Exact UTF-8 equality | 3,136 | absent |
| Unicode-folded equality | 10,091 | present |
| Non-comparison predicate, folding capability enabled but unused | 2,833 | absent |

Reproduce with `zig build string-size-probes` followed by
`node tools/check_string_sizes.mjs`. The script executes the exports and checks
table retention, not just file size. This change does not modify DOT, markup or
shared parsing/validation code. Their existing throughput tables below are
unchanged; no new DOT/markup regression measurement is claimed here.

## Parse and validate

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

`@sizeOf` values for 0.5.0 on this machine (aarch64 macOS,
Zig 0.16.0), checked 2026-10-12. They are the size of each value itself, not
memory used while parsing, and they can differ on other targets or Zig
versions. A [layout test](../tests/layouts.zig) checks this table in all four
build modes.

| Type | Debug / Safe | Fast / ReleaseSmall |
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

Keeping comments makes the document and storage types a little
larger even when it is off. With the additional DOT completeness metadata, the
default fixed session is now 40 bytes bigger than in 0.4.0. Scanner sizes and per-statement records are unchanged. With
comment retention off, no comment records are allocated. With it on, each
comment takes 12 bytes, plus spare room in growing lists unless you give exact
sizes or fixed buffers. The comment text itself is never copied.

Additional type sizes, the same in Fast and Safe builds:

| Type | Size (bytes) |
| --- | ---: |
| DOT session with run-time settings (Unreleased) | 1,424 |
| Markup node / attribute | 20 / 20 |
| Markup nesting frame / attribute-key scratch entry | 12 / 8 |
| Markup diagnostic / validation result | 36 / 32 |
| Markup session: default / bounded / run-time settings | 440 / 448 / 528 |
| Markup `Document` | 56 |
| Markup node / attribute view | 64 / 64 |
| Markup root/child iterator / attribute iterator | 64 / 64 |

Changes since 0.4.0 to these sizes:

- **Closing-tag typo recovery**, on by default, adds 8 bytes to sessions with
  fixed settings and 24 bytes to the run-time-settings session. With a fixed
  `closing_tag_recovery = .exact`, the default and bounded sessions are 432 and
  440 bytes again; run-time settings keep room for every choice. No choice
  allocates or makes node or attribute records bigger.
- **Markup partial results** add 8 bytes to the run-time-settings session; other
  sessions are unchanged. The markup `Document` grew from 48 to 56 bytes, even
  with partial results off, so views and iterators that hold it grew by 8 bytes
  too. Copying a view still copies no source or tree and doesn't allocate.
  Node and attribute records are still 20 bytes. Keeping the finished part after
  a failure reuses the same buffers, without allocating. Growing buffers keep
  their spare room after a failure: an owned result holds it until `deinit()`,
  and a workspace keeps it for the next call.
- **DOT partial results and kept label trees** have their own
  [memory costs](EDITORS.md#memory). The default DOT session grew by 8 bytes,
  and run-time-settings sessions by 56 bytes, because they must be able to keep
  partial results too. Default node and edge allocations are unchanged, and no
  list of label results is allocated unless label trees are kept.

## Cost of opt-in features

> The compile-time numbers in this section were measured during 0.5.0
> development, on the same machine, and weren't re-run for the release.

**Partial DOT results** ([editors](EDITORS.md#keep-the-finished-part-of-a-dot-file)):

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

## Scanners

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

### Cancellation intervals (unreleased)

Measured on 2026-10-17 with Zig 0.16.0 on Apple M4 Pro, 48 GiB RAM.
The interval-relative tables below are the initial `ca71148` snapshot, before
the interval-1 follow-up described below; they are not updated-build speedups.
The [interval benchmark](../bench/cancellation.zig) covers intervals 1, 4, 16,
64 and 256, both parsers/scanners, fixed/runtime policies, and metering on/off.
It uses dense 30,000-statement inputs (DOT 0.210 MB, markup 0.300 MB) and
1.350 MB of long quoted/text content. Markup uses structural mode; validation
is not timed. Pools and session initialization are outside timing. Each case
warms for at least 150 ms, then takes the median of nine samples. The numbers
below take the median across three interleaved runs. Metered calls grant 4,096
credits; the callback counts polls and never requests cancellation.

Throughput change relative to **interval 1 in the same build**, geometric mean
across both inputs, fixed/runtime policies and metering on/off:

| Parser / scanner | Build | 4 | 16 | 64 | 256 |
| --- | --- | ---: | ---: | ---: | ---: |
| DOT scalar | Fast | +45.4% | +76.3% | +82.2% | +87.9% |
| DOT scalar | Safe | +40.3% | +65.6% | +83.2% | +85.6% |
| DOT block | Fast | +0.4% | +3.3% | +6.2% | +6.2% |
| DOT block | Safe | -0.7% | -0.3% | +2.8% | +4.2% |
| Markup scalar | Fast | +6.3% | +5.7% | +9.4% | +10.5% |
| Markup scalar | Safe | +3.8% | +3.3% | +5.2% | +6.5% |
| Markup block | Fast | +4.9% | +4.5% | +4.6% | +4.8% |
| Markup block | Safe | +2.2% | +2.7% | +2.2% | +4.4% |

Long text drives much of DOT's gain; this is not a representative-file average.
For context, these are actual **Fast, scalar, fixed-policy, metered** timings:

| Input | Interval 1: ms / MB/s | Interval 64: ms / MB/s |
| --- | --- | --- |
| DOT dense | 1.763 / 119.1 | 1.346 / 156.1 |
| DOT long text | 3.021 / 446.9 | 0.766 / 1,762.4 |
| Markup dense | 1.567 / 191.5 | 1.403 / 213.9 |
| Markup long text | 4.017 / 336.0 | 3.734 / 361.5 |

Credits were identical at every interval. For dense DOT, interval 1/64 used
600,161/9,522 polls but **600,015 credits** in both cases. Dense markup used
480,153/7,618 polls and **480,036 credits**. Entry checks account for extra polls
at resume boundaries. Measured session sizes were unchanged against the previous
commit; the countdown is local to a drive call, with no new heap allocations or
per-record storage. This is not a process peak-RAM measurement.

**DOT interval-1 follow-up.** The initial implementation changed LLVM's inlining:
sharing grammar helpers between one-credit and batched loops introduced calls
on the runtime default's hot path. DOT now selects the polling class once at
operation start/session init/reset. The interval-1 machine has no countdown work;
its runtime scalar scanner executes the same single lexical microstep directly.
Document, event-only and proactive-composition entry points share this approach.
No work unit, polling boundary, pause budget or terminal precedence changed.

Matched interval-1-only builds compare `702d4ea` (pre-interval), `ca71148` and
the follow-up. Dense and long-text inputs use five alternating runs; four extra
30,000-statement inputs use three: nodes (`a;`), subgraph endpoints
(`{a;}->{b;};`), ports/attributes (`a:p->b:q[x=1];`) and passthrough HTML-like
identifiers (`a[label=<<b>x</b>>];`). The latter does not process markup.
Warmup, sampling and budget rules are as above. Geometric mean throughput changes
against **pre-interval `702d4ea`**, across six inputs and metering on/off:

| DOT scanner | Fast fixed | Fast runtime | Safe fixed | Safe runtime |
| --- | ---: | ---: | ---: | ---: |
| Scalar | -0.6% | +10.9% | +1.5% | +5.4% |
| Block | +1.0% | -0.7% | -0.1% | -0.4% |

Against the regressed `ca71148`, runtime scalar improves **20.7% Fast / 16.2%
Safe**, and runtime block improves **5.2% / 10.0%**. Cancellation-disabled
controls average +1.9% / -0.5% against pre-interval. Exact poll counts, metered
credit totals and session sizes match all three versions, with no new heap
allocation or retained-record storage.

**Residual variation is not a blanket performance sign-off.** The mixed-profile
binary still has individual slower cases: dense runtime-metered block is -6.6%
Fast / -4.0% Safe, and fixed unmetered scalar reaches -4.5% Fast on ports.
Separate single-profile binaries also use five alternating runs. Their dense
input comparisons against pre-interval are:

| Isolated profile | Fast | Safe |
| --- | ---: | ---: |
| Fixed scalar, unmetered | -3.5% | +6.6% |
| Runtime scalar, unmetered | +8.0% | +2.2% |
| Runtime block, unmetered | -5.0% | +0.6% |
| Runtime block, metered | +0.1% | -1.7% |

This sensitivity to the surrounding compiled profiles matters: compare the
actual application, not just an aggregate. Assembly inspection also finds the
same fixed scalar default hot loop structure as pre-interval, apart from
relocated addresses and error-code mapping. We have removed the added
default-path work, not demonstrated zero regression for every configuration.

The mixed-profile benchmark's `__TEXT` grows by 29.0 KiB Fast / 32.9 KiB Safe
against `ca71148`, from specializing runtime polling classes. This is not a
fixed-policy-only cost: the isolated fixed scalar binary differs from
pre-interval by only 40 bytes Fast / 48 bytes Safe of `__TEXT`. Markup is unchanged
by this follow-up; its initial interval-1 comparisons ranged from +0.4% to -2.3%
by configuration.

Interval **1 remains the default**. Larger intervals trade responsiveness for
fewer polls; they neither increase work budgets nor guarantee faster parsing.
See the [interval contract](EXECUTION.md#cancellation-interval).

## Compile-time and run-time settings

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

The [composition benchmark](../bench/composition.zig) uses a DOT profile with
the markup parser bound as its
[label checker](LABELS.md#check-every-label-while-parsing), in structural mode,
and calls `parseAndValidate`. Times include parsing the DOT, checking the labels,
validating, and freeing the result. Both parsers use the scanner shown.
Diagnostics are thrown away.

The benchmark covers both fixed and runtime policies for both parsers, labelled
`fixed` and `runtime` in its output. The recorded table below uses fixed policies.

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
| DOT parse and validate, lexer, sessions, subgraphs | 2 | 9 | 1 |
| Settings | at least 150 ms | 9 | 4 |
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
| Fast / scalar | 7.81–8.26 | 6.50–6.88 |
| Fast / block | 8.01–8.30 | 6.77–7.27 |
| Safe / scalar | 8.74–9.25 | 7.30–7.45 |
| Safe / block | 9.90–10.17 | 8.14–8.51 |

Short tests varied more. The `plain` label-checking case ranged from 0.024 to
0.065 ms in the Fast build, and 1,000 sibling subgraphs from 0.026 to 0.035 ms.
Some markup cases also moved between runs: plain `text` with the scalar scanner
in a Safe build ranged from 0.636 to 0.849 ms. Treat small differences between settings or
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
zig build bench-cancellation -Doptimize=ReleaseFast
zig build bench-subgraphs -Doptimize=ReleaseFast -Dlexer=scalar
zig build bench-policy -Doptimize=ReleaseFast
zig build bench-markup -Doptimize=ReleaseFast
zig build bench-markup -Doptimize=ReleaseFast -- --scopes-only
zig build bench-markup -Doptimize=ReleaseFast -- --graphviz-only
zig build bench-composition -Doptimize=ReleaseFast
zig build check-benches  # only checks that they compile
```

Repeat everything with `-Doptimize=ReleaseSafe`. Repeat the first four with
`-Dlexer=block` too; the others already cover both scanners where it matters.
Run each one five times and take the median. `bench-markup` also accepts
`-- --rules-only` and `-- --validation-only` for shorter runs.

`bench-policy` warms each case for at least 150 ms and averages four parses per
sample, because two short warm-up parses didn't reliably settle the first case.
