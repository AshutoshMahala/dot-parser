# Performance

Throughput and allocator measurements below are the historical 0.3.0 baseline.
They were taken by hand on one machine, so treat them as a guide, not a promise.
Runs on the same machine vary by about ±8%. Current development type sizes are
listed separately under [current layouts](#current-development-layouts).

## Setup

- Release 0.3.0 (commit `4c494b9`), measured 2026-09-19
- Native aarch64 macOS, Zig 0.16.0, `ReleaseFast`
- Each figure is the median of 5 runs, each the median of 9 rounds after 2
  warm-up rounds
- Inputs are valid ASCII. Malformed input, non-ASCII input and real-world files
  were not measured.

The newer HTML-like label features have no recorded baseline yet.

## Parse and validate

A 2.7 MB file with 200,000 statements, alternating nodes (`a;`) and edges
(`a -> b;`), parsed and validated with the default settings:

| Memory | Time | Speed |
| --- | ---: | ---: |
| Allocator, no size hints | 12.3 ms | about 213 MiB/s |
| Allocator, with size hints from `measure` | 10.7 ms | about 244 MiB/s |

That is 17 to 21% faster than 0.2.0. The block scanner gave the same speed
within measurement noise.

## Memory

| What | Size |
| --- | ---: |
| Document for the 200,000-statement file | 6.8 MB (34 bytes per statement) |
| Arena used, without size hints | 37.6 MB (about 14× the source) |
| Arena used, with size hints | 8.4 MB (about 3× the source) |
| 0.3.0 fixed session (default settings) | 1,080 bytes |
| 0.3.0 fixed session with metering and cancellation | 1,144 bytes |

The source text is never copied, so it isn't included in the document size.
Arena figures include space left behind when lists grow; this is why
[size hints](MEMORY.md#option-2-an-arena) matter for arenas.

Sizes of the main records on a 64-bit target: node statement 16 bytes, edge
statement 36 bytes, subgraph 36 bytes, statement entry 8 bytes.

## Current development layouts

Checked on aarch64 macOS with Zig 0.16.0, 2026-10-04. These are `@sizeOf` values
for the current development implementation, **not** updated 0.3.0 benchmark
results or portable ABI guarantees.

| Type | Size |
| --- | ---: |
| `dot.Profile(.{}).Session` | 1,088 bytes |
| Fixed DOT session with metering and cancellation | 1,152 bytes |
| `dot.lexer.For(.scalar)` | 64 bytes |
| `dot.lexer.For(.block)` | 152 bytes |

The controlled session uses `.execution = .{ .metering = true, .cancellation = true }`
with other settings left at their defaults. Session sizes exclude source bytes,
document pools, nesting scratch and diagnostic storage supplied separately.
Use the actual types and `@sizeOf` for your target instead of hard-coding these
numbers into memory reservations. [Layout tests](../tests/layouts.zig) guard this
table on the stated target so changes require a documentation review.

## Scanners

The two scanners give identical results. On the lexer benchmark:

| Input pattern | Scalar | Block |
| --- | ---: | ---: |
| Short names and punctuation | 9.2 ms | 8.4 ms |
| Keywords and numbers | 8.9 ms | 8.8 ms |
| Quoted strings and comments | 4.7 ms | 7.4 ms |
| One very long name | 4.7 ms | 3.4 ms |

Neither wins everywhere. Scalar is the default because end to end it is just
as fast, it uses less memory, and it doesn't depend on vector instructions. See
[two scanners](EXECUTION.md#two-scanners).

## Step-by-step sessions

200,000 statements in a fixed session, scalar scanner, 256 credits per call:

| Metering | Cancellation | Time |
| --- | --- | ---: |
| off | off | 5.0 ms |
| on | off | 6.9 ms |
| off | on | 8.0 ms |
| on | on | 8.7 ms |

Cancellation costs time because the callback is checked before every step,
even when it never asks to stop.

## Subgraphs

100,000 subgraphs, side by side or nested 100,000 deep, take about 4 ms either
way. Nesting depth doesn't slow parsing down.

## Running the benchmarks

Run each benchmark on its own, not at the same time as other heavy work:

```sh
zig build bench -Doptimize=ReleaseFast              # parse + validate, memory
zig build bench-lexer -Doptimize=ReleaseFast        # scanners alone
zig build bench-session -Doptimize=ReleaseFast      # step-by-step sessions
zig build bench-subgraphs -Doptimize=ReleaseFast    # nested and side-by-side subgraphs
zig build bench-policy -Doptimize=ReleaseFast       # fixed vs run-time settings
zig build bench-markup -Doptimize=ReleaseFast       # HTML-like label parser
zig build bench-composition -Doptimize=ReleaseFast  # DOT with label checking
zig build check-benches                             # only check that they compile
```

The first four accept `-Dlexer=scalar` or `-Dlexer=block` to choose the scanner.

The fuzz tests run briefly as part of `zig build test`. For a longer run:

```sh
zig build -Doptimize=ReleaseFast test --fuzz=1000
```
