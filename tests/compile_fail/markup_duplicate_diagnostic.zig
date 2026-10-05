const markup = @import("markup_parser");
const Code = enum {
    first,
    second,
    pub fn info(_: Code) markup.diagnostic.Code.Info {
        return markup.diagnostic.Code.invalid_byte.info();
    }
};
comptime {
    markup.wdp.Registry(Code, "custom").validate();
}
