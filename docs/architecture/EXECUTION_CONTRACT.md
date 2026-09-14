# Optional bounded execution contract

Status: implemented for fixed-storage sessions; experimental 0.x API

Date: 2026-09-13

Requirements: R-MOD-009–013, R-MEM-001/003, R-SEC-002/003, R-CON-002

Related decision: [Q27](../internal/OpenQuestions.md)

The existing run-to-completion APIs remain the default. `BoundedSession` now
provides fixed-storage budgeted parsing; `FixedSession` independently selects
metering and cancellation at compile time. See the [user guide](../EXECUTION.md)
and [runnable example](../../examples/bounded.zig). Public event sinks, allocator-
backed bounded sessions, streaming input and bounded validation remain deferred.

### Implemented groundwork: lexical scanning

`src/lexer.zig` contains the single scanner implementation. `root.zig` exposes
only Token, Result and ordinary Lexer; the parser imports internal scan helpers.
Each lexical credit performs one source-byte or EOF examination, with cached-byte
classification and incremental position tracking.
Returning a lexical token is not a syntax-sink event; grammar and event dispatch
are separately charged by the parser.

| Input-dependent path | Continuation and charging |
| --- | --- |
| Whitespace, line comments | One byte per scan step, including CR and LF separately |
| Block comments | Separate slash/body/star states; EOF diagnostics reuse the saved opener |
| Bare/deferred identifiers | One byte per step; keyword classification uses a fixed-size cached word, not a source reread |
| Numerals/operators | Saved dash, leading-dot, integer and fraction states |
| Quoted text/escapes | Saved quote opener and escape state; no segment restart on yield |
| Concatenation trivia | Saved quoted end and trivia mode; after a completed token, trailing trivia may be revisited once, with every reread charged |
| Location tracking | Advance from the byte already examined; no post-token bulk scan |

`nextBounded` stays private. Tests cover budget partitions, all continuation
states, zero-credit nonmutation, terminal latching, frontier monotonicity,
independent examination counts, random inputs, and megabyte-scale runs. The
ordinary specialization has no budget or frontier counters, but the shared
continuation machinery has measured costs; see [baselines](../BASELINES.md).
Its driver enters the known trivia state directly: ordinary `next()` cannot
yield, and every nonterminal token completion restores that state. The metered
specialization still dispatches from saved state, even for an unbounded `next()`
call after a yield. Both paths retain the same microsteps and source-fetch site.
Fixed-storage sessions expose bounded parsing and opt-in cancellation. The
cancellable driver uses one-examination scan calls so it can poll at each safe
point; these calls resume saved state even when metering is disabled.

The driver materializes completed lexical results at one shared exit rather
than within each compile-time-expanded state branch. An explicit completion
tag is a transient microstep result, never a saved continuation or public
outcome. This reduces generated-code overhead without changing the number of
credits charged, terminal behavior, or the resumable state exposed by a yield.

### Implemented groundwork: grammar and syntax events

The private `parser.Machine` now specializes at compile time for immediate or
metered execution. Both use the same grammar helpers and callback payloads.
The metered specialization retains one token, a pending action, and accepted
statement/pair counts; no event queue, allocation, or source-sized copy is added.

| Phase | Charged operation and saved continuation |
| --- | --- |
| Scan | Delegate remaining credits to the scanner; save its completed token |
| Grammar | One fixed-size transition over the saved token; optionally schedule an action |
| Dispatch | Attempt one normal callback, including begin and commit; update accepted counts only on success |
| Lookahead replay | After an owner event, a separate grammar credit processes its saved terminator/next-statement token without rescanning |
| Chain continuation | Save one operator, accept its endpoint in a grammar step, then attempt one separately charged link callback; no chain-sized loop or temporary list |
| Terminal | Return the latched result with zero work and no repeated callbacks |

Zero credits leave normal work untouched. One-credit calls can yield before
begin, pair, owner, and commit callbacks; successful commit is immediately
terminal. Failures still perform at most one diagnostic attempt and one cleanup
abort, even when discovered on the last credit. Callback/allocator work remains
excluded as specified below. Progress counts accepted syntax events, not
statement/pair reservations or semantically validated output.

Identifier-only chains retain the first edge in machine state. Continuations
stream directly into the link pool; the chain-owner callback consumes their
compact range and all pending attributes. Only that accepted owner increments
completed statements. Cancellation/abort discards staged links with the other
pools; validation and the public pairwise edge iterator remain unbudgeted.

Tests compare budget partitions with ordinary parsing, independently count
source examinations, grammar transitions and callback attempts, and cover every
prefix, all callback failures, refused diagnostics, output limits, arbitrary
bytes and megabyte inputs. The ordinary specialization compiles out pending-work
and audit fields and dispatches immediately. Neither path duplicates the grammar.
Fixed-storage sessions own their builder and machine by value, rebinding the
builder pointer before driving so moves between calls cannot leave self-pointers
dangling. A cached public terminal result prevents repeated storage diagnostics
or document handoff. No pool view is exposed before commit.

`cancel()` and `deinit()` terminate unfinished work without a positive budget.
`reset()` first terminates old work, then reuses the pools; previous document
views must be retired. Aborted pool bytes are not erased, only logically discarded.

## 1. Scope and optionality

Use one shared grammar with independently selectable metering and cancellation
policies. Disabled policies must compile out their counters, hooks, and checks;
do not add a mandatory per-byte runtime flag test. Measure remaining shared
continuation-state, code-size and throughput costs rather than claiming the
entire architectural change is free.

The first slice covers borrowed, immutable contiguous input, the current syntax
subset, and fixed-storage document construction. No OS clock, worker, mandatory
atomics, chunked input, recovery, semantic lowering, or execution tree is required.
The source, storage, cancellation context and session must remain alive across
yields. One caller owns a session; it must not be reentered from a callback.

Run-to-completion and bounded operation must use the same syntax decisions.
Validation and explicit identifier decoding remain separate operations; this
slice does not make them bounded.

## 2. Budget accounting

A call receives a nonnegative number of work credits. Credits are an abstract
accounting measure, not CPU instructions, elapsed time, bytes of output, or a
cross-version performance currency.

Each **microstep** costs one credit, charged before it starts. A microstep may do
one of the following:

- **Scan:** obtain and examine at most one source byte, or detect EOF, with a
  fixed amount of classification, position tracking and lexical-state update.
  Lookahead reads and rereads require credits too. Reusing cached byte values
  within fixed-size local logic does not fetch another byte.
- **Advance grammar:** perform one bounded state transition using already
  available token/state data, without scanning source or iterating an
  input-sized collection. Fixed-size keyword recognition is allowed; an
  identifier-length comparison loop is not.
- **Dispatch:** attempt one normal syntax event. Preparing the event must be
  bounded; the consumer invocation is a callout with the exclusion below.

These classes are mutually exclusive for charging. A byte-consuming transition
can update lexical state in that scan step; it need not pay twice for the same
bounded action. It must not hide additional scanning or event dispatch.

Any input-dependent loop must advance through charged, resumable microsteps.
This includes trivia, long identifiers, escape handling, quoted concatenation
glue, deferred identifier runs, and position tracking. A completed token followed
by a bulk uncharged location scan would violate the contract. A batch/SIMD path
may run only if it reserves all corresponding credits first and maintains the
same documented accounting.

For a call with budget N:

- At most N charged microsteps execute; there is no budget overshoot.
- At most N source-byte fetches occur; administrative steps may consume
  credits without advancing the source.
- The next microstep is not begun if no credit remains.
- Unused credits are not implicitly carried into the next call.
- Credit arithmetic must not wrap. A per-call remaining counter suffices;
  unbounded lifetime counters are not required.

A budget of one must make progress on a nonterminal, uncancelled session with
available input. No lexical construct may require a larger minimum budget.
A zero budget performs no microsteps or normal syntax-event dispatch. It may
observe cancellation and perform the terminal housekeeping described below;
otherwise it returns a resumable yield. A latched terminal result is returned
unchanged, regardless of budget.

Per-call exhaustion yields; it is not a resource error. A total-operation work
limit is a different policy and is deferred. Statement, attribute and storage
limits keep their existing terminal resource/storage outcomes. `max_nesting` is
also a terminal policy limit, not work credit; root depth is zero.

Subgraph entry and exit each have a separately charged normal callback. One
fixed-frame push happens in the opening grammar transition and one pop after an
accepted exit; neither walks ancestors. Failure/cancellation resets active frame
length and aborts staged output without synthetic close events. `completed_statements`
counts a scope at accepted exit, while `max_statements` counts its reservation.
Scratch capacity exhaustion is a storage failure, distinct from nesting policy.

### Exclusions and bounded housekeeping

Allocator execution, consumer/observer/cancellation hooks, rendering, and
consumer-owned copying are not bounded by parser credits. A slow callback can
make a call slow regardless of N. This is not a hard real-time or end-to-end
wall-clock guarantee.

Bundled growable builders can copy large pools, so the first bounded retained
document API uses fixed storage. Metering a parser does not silently make its
allocator-backed builder bounded. A future such API must state its weaker
guarantee or separately budget its materialization work.

Entry/exit bookkeeping, returning a snapshot, and cancellation polling have
fixed parser-side cost. On a terminal path, allow **at most one diagnostic
delivery attempt and one abort callback** outside the remaining work credit.
This lets an error or cancellation discovered on the final microstep terminate
cleanly. This exception permits no extra source scan or normal syntax events.
Callback and cleanup duration remains excluded. Successful commit is a normal
charged dispatch, not a housekeeping exception.

## 3. Yield, cancellation, failure and completion

**Yield:** retain all lexical/grammar continuation state, in-flight spans,
lookahead, and staged pairs. Emit neither a diagnostic nor an abort. Resume
exactly where work stopped; do not restart a token or comment because a call
ended. Yielding does not expose a usable completed document.

**Cancellation:** observe a caller-owned hook at entry and before each next
microstep. After a successful callback returns, check before further work;
entry and boundary checks may coincide. At most N + 1 polls are needed for
N microsteps. A pending request is therefore observed before another microstep,
not after another whole token. No elapsed-time latency bound is promised.

Cancellation is terminal, carries its own outcome, and is not a syntax error.
Do not emit a failure diagnostic merely because the caller cancelled. Abort
once if document begin was attempted; before begin, no sink lifecycle event is
needed. Discard staged data and expose no completed document. The hook is a
non-failing request predicate, not a place to reenter the session. Cross-thread
or signal adapters own synchronization and signal-safety; ordinary unsynchronized
shared flags are not made safe by the parser.

**Failure:** a syntax, storage or sink failure already obtained is handled
under the existing outcome/delivery rules. Do not replace a concrete failure with
a cancellation observed afterwards. Diagnostics rejected
by their sink still do not mask the original outcome. Abort after a begin attempt
follows the existing cleanup exception, including a failed begin callback.

**Completion:** after EOF and all required syntax checks, dispatch commit.
A successful commit latches success immediately; later cancellation cannot undo
it. A failed commit follows the existing failure/abort path. If credits end
before commit, yield without claiming success.

On a live terminal session, results are idempotent: further calls return the
cached result without polling, scanning, emitting diagnostics, committing or
aborting again.

A caller abandoning a yielded session must explicitly cancel/dispose it according
to its ownership API; silently dropping it cannot promise an abort callback.
The implementation must supply and test a terminal cleanup route that does not
depend on supplying another positive work budget.

## 4. Progress and determinism

Expose a small by-value snapshot: current phase, source progress, completed
statement count, completed key/value-pair count, and work used in this call.

Source progress is one past the highest byte offset examined by the scanner,
initialized to zero. EOF costs work but does not advance this monotonic frontier.
Call it `source_frontier` rather than implying that every examined byte has
already been accepted into a token or statement. It can include lookahead and
an incomplete lexical construct. This sharpens the earlier “bytes consumed”
wording; work accounting remains separate because rereads and grammar steps
cost work without moving that frontier.

A pair counts when its complete pair/assignment event is accepted; a statement
counts when its final statement event is accepted. Thus a yielded attribute list
can have completed pairs but no completed owning statement. These counters are
not promises that the document will eventually commit. No whole-pipeline
percentage or automatic progress callback is required.

With the same build, input, policies and successful deterministic consumers,
partitioning the budget differently must preserve final syntax, event order,
diagnostics and total charged work. Zero-budget polls do not add charged work.
Cancellation schedules and user callback behavior are external inputs.
No numeric accounting stability across versions is promised.

## 5. Acceptance tests and delivery order

Acceptance gates for the fixed-storage driver (retain when extending it):

1. **Accounting audit:** enumerate every input-dependent loop and callout.
   Instrument microsteps and actual source examinations independently; verify
   the N-step bound, the housekeeping exception, and no hidden full-token scan.
2. **Every boundary:** use budgets 0, 1, 2 and irregular partitions. Suspend
   between CR/LF, comment delimiters, escape bytes, quote/`+` glue, numerals,
   key/`=`/value, closing brackets, EOF and commit. Compare with uninterrupted
   parsing, including exact locations and event ordering.
3. **Long scans:** exercise megabyte-scale trivia, comments and identifiers.
   Repeated one-credit calls must terminate with near-linear total work and
   constant continuation storage. Resumption must not repeatedly rescan prefixes.
4. **Lifecycle:** cancel before begin, inside every lexical state, with staged
   pairs, after a statement, and before commit. Verify one terminal notification,
   no partial document, repeat-call idempotence, and cleanup on abandonment.
5. **Precedence and delivery:** test a failing begin/event/commit callback,
   rejected diagnostics, empty diagnostic bags, cancellation arriving during a
   successful versus failed callback, and failure on the final credit.
6. **Memory:** verify no allocation in fixed-storage operation, storage
   exhaustion after a yield, source/storage lifetime rules, and session reuse
   after terminal cleanup. Pausing must not copy retained source or staged pools.
7. **Optionality:** inspect consumed builds with metering/cancellation enabled
   independently and disabled together. Compare binary size, session size and
   ordinary-driver throughput against the pre-change baseline. Disabled hooks
   must be unreachable, not merely unused at runtime.
8. **Portability:** compile consumed fixed-storage paths for a freestanding
   target, with no core clock, thread, signal or atomic dependency.

Implemented delivery: resumable scanning → metered grammar/event dispatch →
fixed-storage session → cancellation/lifecycle handling → public API/examples.
The public surface is `BoundedSession`, `FixedSession(ExecutionFeatures)`,
`SessionProgress`, `ExecutionPhase`, and `Cancellation`. Cancellation hooks
are borrowed context/predicate pairs, not OS tokens or synchronization primitives.
All source scans remain resumable; no supported lexical form requires a minimum
budget greater than one.

### Port-suffix continuation

The parser saves the target reference (node/first endpoint, right endpoint or
chain continuation), its optional first/second components and the most recent
colon. A completed suffix dispatches `portedReference`, returning a document-local
handle from the builder. This is one normal charged event attempt, including
failure; it does not increment statement or pair progress. The private sink
contract's other normal methods still return `E!void`.

The terminating lookahead is replayed through the resumed owning grammar state,
not rescanned. A chain continuation similarly waits until its optional suffix is
complete before dispatching `edgeLink`. Every replay costs a grammar unit, and
every callback has its own dispatch unit. There is no variable-length suffix or
chain loop inside one transition. Cancellation/abort discards staged records;
only document commit exposes them. Ports require no new source scan, clock,
allocator, cancellation protocol, or public event-sink API.

Further syntax, recovery, public pull sinks, streaming input, total-work limits,
scheduling and bounded validation are outside this contract's implemented scope.
Measured optionality and callout costs are recorded in [baselines](../BASELINES.md).
