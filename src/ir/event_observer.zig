//! Compile-time event forwarding. The ordinary route uses Builder directly.
const e = @import("../dot/events.zig");

pub fn Errors(comptime Observer: type) type {
    return @typeInfo(@typeInfo(@TypeOf(Observer.onEvent)).@"fn".return_type.?).error_union.error_set;
}

pub fn Consumer(comptime Builder: type, comptime ObserverType: ?type) type {
    const Observer = ObserverType orelse return Builder;
    const begin = !@hasDecl(Observer, "wants_begin_statement") or Observer.wants_begin_statement;
    const observer_recovery = !@hasDecl(Observer, "recover_statements") or Observer.recover_statements;
    const independent = Builder.retains_partial and !observer_recovery;
    return struct {
        const Self = @This();
        pub const wants_begin_statement = true; // Required for IR staging.
        pub const recover_statements = Builder.retains_partial or observer_recovery;
        pub const observations: e.Observations = if (@hasDecl(Observer, "observations")) Observer.observations else .none;
        pub const statement_extents = @hasDecl(Observer, "statement_extents") and Observer.statement_extents;
        pub const coverage = true;
        const has_context = @hasDecl(Observer, "ScopeContext");
        pub const ScopeContext = if (independent and has_context) ?e.Context(Observer) else e.Context(Observer);
        const tracks_statements = begin or observer_recovery or observations.statementTracking();
        // Internal composition notification, not another public event. The
        // parser reports rejection before synchronization, even when no
        // statement was begun (e.g. a stray semicolon). The observer's terminal
        // trace must not depend on whether a later skipped event can be emitted.
        pub const parser_recovery = if (independent) struct {
            pub fn rejecting(self: *Self, reason: e.AbortReason, owner: ?e.Owner) void {
                if (self.terminal or !self.started) return;
                if (tracks_statements) if (owner) |value| self.observer.onAbort(.{ .statement = .{
                    .owner = value,
                    .span = .{ .start = @backingInt(value.statement), .len = 0 },
                    .reason = reason,
                } });
                self.observer.onAbort(.{ .document = reason });
                self.terminal = true;
            }
        } else struct {};

        builder: *Builder,
        observer: *Observer,
        failure: ?Errors(Observer) = null,
        stopped: bool = false,
        started: bool = false,
        terminal: bool = false,
        undelivered_begin: bool = false,

        pub inline fn onEvent(self: *Self, event: e.Event) (Builder.Error || Errors(Observer))!e.Action {
            if ((!independent or !self.terminal) and (begin or event != .begin_statement)) {
                // One additional bounded delivery. Callback bodies have the
                // same caller-owned work contract as standalone DOT events.
                self.builder.b.work.spend(1) catch |err| {
                    self.undelivered_begin = event == .begin_statement;
                    self.builder.failure = err;
                    return err;
                };
                self.started = true;
                const action = self.observer.onEvent(event) catch |err| {
                    self.failure = err;
                    return err;
                };
                if (action == .stop) {
                    self.stopped = true;
                    return .stop;
                }
                if (event == .end_document) self.terminal = true;
            }
            // Editor observations carry no semantic contributions. The parser
            // already accounts for their own dispatch and metadata work.
            switch (event) {
                .identifier, .statement_head, .document_name, .subgraph_name, .token_preview, .token_preview_end, .delimiter => return .proceed,
                else => return self.builder.onEvent(event),
            }
        }

        pub fn onAbort(self: *Self, abort: e.Abort) void {
            if (!self.terminal and self.started) {
                if (abort == .document or (tracks_statements and !self.undelivered_begin)) self.observer.onAbort(abort);
                if (abort == .document) self.terminal = true;
            }
            self.builder.onAbort(abort);
        }

        pub fn suspendScope(self: *Self) ScopeContext {
            if (has_context) {
                if (independent and self.terminal) return null;
                return self.observer.suspendScope();
            }
        }

        pub fn restoreScope(self: *Self, context: ScopeContext) void {
            if (has_context) {
                if (independent) {
                    if (self.terminal) return;
                    self.observer.restoreScope(context.?);
                } else self.observer.restoreScope(context);
            }
        }
    };
}
