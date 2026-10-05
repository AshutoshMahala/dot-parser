const markup = @import("markup_parser");
const Code = enum {
    bad,
    pub fn info(_: Code) markup.diagnostic.Code.Info {
        var metadata = markup.diagnostic.Code.invalid_byte.info();
        metadata.sequence = 0;
        return metadata;
    }
};
comptime {
    markup.wdp.Registry(Code, "custom").validate();
}
