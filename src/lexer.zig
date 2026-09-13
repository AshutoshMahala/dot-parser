//! Raw-byte lexer for the currently supported DOT subset.
//!
//! Recognizes the current subset: every DOT keyword (`graph` maps to the
//! `undigraph` kind at reading time, `digraph`, `strict`, `node`, `edge`, and the deferred
//! `subgraph`); bare ASCII, numeral, and quoted identifiers;
//! `{`, `}`, `;`, `[`, `]`, `=`, `,`; the
//! edge operators `--` and `->`; whitespace (space, tab, LF, CRLF, CR);
//! and comments (`//`, `/* ... */`, and `#` through the physical line end).
//! Comments are skipped without retention. See docs/SUPPORTED_SYNTAX.md for
//! the comment and physical-location compatibility policy.
//!
//! Guarantees:
//! - Spans borrow from the caller's source; no allocation ever (R-MEM-001).
//! - State is instance-owned (R-ROB-003); no OS or filesystem access.
//! - Every `next` call either consumes input or returns a terminal result
//!   (`eof` or a failure); the lexer cannot loop forever.
//! - Every keyword tokenizes, including keywords of deferred constructs:
//!   whether `subgraph` legally introduces a subgraph or sits in an illegal
//!   grammar position is the parser's decision, which the lexer cannot
//!   make. Only *lexical* deferred constructs — HTML/non-ASCII identifiers,
//!   ports — are
//!   reported here as structured `profile_unsupported_feature` failures,
//!   distinct from invalid syntax (R-MOD-006).
//!   Detection stops at the introducer: neither the construct's body nor
//!   the remaining input is checked, so an unsupported result makes no
//!   whole-input validity claim.

// The scanner factory and metered driver are package-internal. Keep this
// public module limited to the existing run-to-completion lexical surface.
const machine = @import("lexer_machine.zig");
pub const Token = machine.Token;
pub const Result = machine.Result;
pub const Lexer = machine.Lexer;
