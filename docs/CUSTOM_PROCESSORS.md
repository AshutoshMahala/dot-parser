# Bringing your own processor

The DOT parser finds every HTML-like `<...>` value and can hand each one to a
*processor* to check what is inside. The built-in processor is the markup
parser, `markup.Profile(...)`. You can bind your own instead, for example to:

- allow only the tags Graphviz supports
- check a different markup dialect
- add your own checks before or after the built-in ones

Processors are chosen at compile time. There is no plugin registry, and nothing
can be swapped while the program runs. In return, the compiler checks the
wiring and leaves out anything you don't use.

## Binding a processor

```zig
const Parser = dot.Profile(.{ .processors = .{ .markup = MyLabels } });

var bag = Parser.GrowableDiagnosticBag.init(allocator, .{});
defer bag.deinit();
var result = try Parser.parseAndValidate(allocator, source, bag.sink(), .{
    .markup = .{}, // your processor's Options
    .markup_resources = .{}, // your processor's ParseResources
});
defer result.deinit(allocator);
```

Everything else works as in [checking every label](LABELS.md#check-every-label-while-parsing):
one bag for DOT and your diagnostics, `result.dot`, `result.markup`, and
`result.documentValid()`.

## What your processor must declare

The compiler checks that your processor type declares all of these:

| Declaration | Requirement |
| --- | --- |
| `Policies` | Its settings binding. See [giving your processor settings](#giving-your-processor-settings). |
| `Options` | Per-call options. The caller passes them as `.markup`. |
| `prepare(options)` | Returns `Prepared`, or an error union with `Policies.Error`. Must not scan, allocate or call back. |
| `Prepared.initWorkspace(allocator, resources)` | Returns a `Workspace`. Must not scan, allocate or call back; buffers grow later. |
| `Workspace.parseAndValidate(fragment, sink)` | Checks one value. Returns `InputError!Result`. |
| `Workspace.deinit()` | Frees the workspace's buffers. DOT calls it exactly once, on every exit, including failures. |
| `Diagnostic` | Your diagnostic type. It must have a `span` field. |
| `DiagnosticSink` | `dot.reporting.Sink(Diagnostic)` |
| `ParseResources` | Passed to `initWorkspace`. The caller supplies them as `.markup_resources`. |
| `InputError` | Errors for bad fragment input, such as `markup.Fragment.Error` |
| `console.Adapter` | Optional. Needed only if the caller uses `Parser.console` to print diagnostics. |

`Result` needs three members, with the same meaning as
[markup results](MARKUP.md#checking-many-fragments):

| Member | Meaning |
| --- | --- |
| `has_errors` | Errors were found in this value |
| `documentValid()` | The value was fully checked and has no errors |
| `stopped()` | A stop that isn't about the input: cancel, a memory or buffer failure, or the sink stopping or failing |

## Rules it must follow

1. **Report in original positions.** DOT passes each value as a
   [fragment](MARKUP.md#parsing-part-of-a-larger-file) with its offset in the
   DOT file. Turn every span you report (main, related, and fix spans) into an
   original position with `fragment.rebase(span)`, exactly once.
2. **Respect the sink.** After the sink returns `.stop` or an error, report
   nothing more and return. `stopped()` must then be true.
3. **Follow your own `on_error` setting.** DOT decides whether to check the
   next value only after you return.
4. **Never turn unsupported input into success.** Reporting it quietly is fine;
   treating it as checked is not.
5. **Don't keep results.** DOT reads each result straight away and then calls
   you again for the next value. A result only needs to stay valid until the
   next call or `deinit()`.

## A starting point

The simplest way to meet all of this is to wrap the built-in markup parser and
add your own checks around it:

```zig
const MyLabels = struct {
    const Base = markup.Profile(.{});
    pub const Policies = Base.Policies;
    pub const Options = Base.Options;
    pub const Diagnostic = markup.Diagnostic;
    pub const DiagnosticSink = markup.DiagnosticSink;
    pub const InputError = markup.Fragment.Error;
    pub const ParseResources = struct {};
    pub const console = markup.console;

    pub const Prepared = struct {
        inner: Base.Prepared,
        pub fn initWorkspace(self: @This(), allocator: std.mem.Allocator, _: ParseResources) Workspace {
            return .{ .inner = self.inner.initWorkspace(allocator, .{}) };
        }
    };

    pub const Workspace = struct {
        inner: Base.Workspace,
        pub fn parseAndValidate(self: *@This(), input: markup.Fragment, sink: DiagnosticSink) InputError!markup.FixedFragmentResult {
            // Add your own checks here, reporting rebased spans.
            return self.inner.parseAndValidate(input, sink);
        }
        pub fn deinit(self: *@This()) void {
            self.inner.deinit();
        }
    };

    pub fn prepare(options: Options) Prepared {
        return .{ .inner = Base.prepare(options) };
    }
};
```

[custom_processor.zig](../examples/custom_processor.zig) is a runnable version
that also uses `ParseResources` to count the labels it checks.

A processor that doesn't wrap the markup parser needs its own diagnostic type,
its own result type with the three members above, and, if you want console
output, its own `console.Adapter`.

## Giving your processor settings

A processor's settings use the same system as DOT and markup: compiled
defaults, with optional run-time changes. `dot.processor.PolicyBinding` builds
that from a *schema* you write:

| Schema member | Requirement |
| --- | --- |
| `Policy` | The settings a caller can pass. Fields are optional; `null` means "keep the default". |
| `Effective` | The fully resolved settings |
| `defaults` | An `Effective` value |
| `resolve(baseline, patch)` | Combines the defaults with a patch. No allocation, no side effects. |
| `check(effective, patch)` | Returns `.valid`, or `.invalid` with an `Issue`. No side effects. |
| `Error` | `error{}` if every combination is valid |
| `Check`, `Issue` | `union(enum) { valid }` when nothing can fail. Otherwise `union(enum) { valid, invalid: Issue }`, where `Issue` is an enum with an `asError()` method. |

```zig
const Schema = struct {
    pub const Policy = struct { target: ?u8 = null };
    pub const Effective = struct { target: u8 };
    pub const defaults: Effective = .{ .target = '!' };
    pub const Error = error{};
    pub const Check = union(enum) { valid };
    pub fn resolve(baseline: Effective, patch: Policy) Effective {
        return .{ .target = patch.target orelse baseline.target };
    }
    pub fn check(_: Effective, _: Policy) Check {
        return .valid;
    }
};

const Marker = struct {
    pub const Policies = dot.processor.PolicyBinding(Schema, .{ .runtime_policy = true });
};
```

## Preparing settings for several processors

`dot.processor.PolicySet` prepares the settings of several named processors at
once. Sets can nest, for example DOT → markup → your own string checker. Each
run-time setting is checked once, before any work starts. A set with only
compile-time settings takes no space.

```zig
const Labels = markup.Profile(.{ .runtime_policy = true });
const Group = dot.processor.PolicySet(.{ .parser = Labels, .marker = Marker });
const App = dot.processor.PolicySet(.{ .dot = dot.Profile(.{}), .markup = Group });

const state = try App.prepare(.{ .markup = .{
    .parser = .{ .policy = .{ .validation = .{ .duplicate_attribute = .warning } } },
    .marker = .{ .policy = .{ .target = '?' } },
} });
const ready: Labels.Prepared = .{ .policies = state.markup.parser };
// Reuse `ready` without preparing again.
```

A set only prepares settings. It doesn't run processors or decide their order.
Your code calls each one, and `fragment.child(span)` keeps positions correct for
a value nested inside another.

## Limits

- During DOT parsing, label processing runs to completion. A profile with a
  bound processor has no step-by-step `Session`.
- Processors only see the inside of existing `<...>` values. They can't add new
  DOT name syntax or statements.
- Binding a processor doesn't sandbox it. It runs with the same access as the
  rest of your program.

## Examples

- [custom_processor.zig](../examples/custom_processor.zig): bind your own
  processor and pass it resources
- [composed_markup.zig](../examples/composed_markup.zig): the built-in processor
  bound the same way

Run them with `zig build examples`. Each program is also installed in
`zig-out/bin/`.
