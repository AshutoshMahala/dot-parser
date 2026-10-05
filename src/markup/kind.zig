//! Source-shaped node/event kinds, independent of retained storage.
//! Leaf discriminants occupy the otherwise-unused name start when length is zero.
pub const Kind = enum(u32) { text, comment, cdata, element };
