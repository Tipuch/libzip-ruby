const c = @import("c");
const std = @import("std");
const errors = @import("errors.zig");

pub const Op = enum {
    read,
    write,
};

pub const Method = enum(c.zip_uint16_t) {
    none = c.ZIP_EM_NONE,
    pkware = c.ZIP_EM_TRAD_PKWARE,
    aes128 = c.ZIP_EM_AES_128,
    aes192 = c.ZIP_EM_AES_192,
    aes256 = c.ZIP_EM_AES_256,
};

pub const Config = struct {
    method: Method = .none,
    password_rb: c.VALUE = c.Qnil,
};

fn getSymbol(value: c.VALUE) [*:0]const u8 {
    if (!c.RB_TYPE_P(value, c.RUBY_T_SYMBOL)) {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .invalid_argument))], "encryption must be a Symbol");
    }

    const string = c.rb_sym2str(value);
    return @ptrCast(c.RSTRING_PTR(string));
}

fn parseMethod(value: c.VALUE) Method {
    const name = getSymbol(value);

    return std.meta.stringToEnum(Method, std.mem.span(name)) orelse {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .invalid_argument))], "unknown encryption method: %s", name);
    };
}

fn isValidMethod(method: Method, op: Op) bool {
    switch (op) {
        .read => switch (method) {
            .none, .pkware, .aes128, .aes192, .aes256 => {},
        },

        .write => switch (method) {
            .none => {},
            .pkware => {
                c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .invalid_argument))], "ZipCrypto writing is not supported");
                return false;
            },
            .aes128, .aes192, .aes256 => {},
        },
    }

    const encode: c_int = switch (op) {
        .read => 0,
        .write => 1,
    };

    if (c.zip_encryption_method_supported(
        @backingInt(@as(Method, method)),
        encode,
    ) == 0) {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .unsupported))], "encryption method (%s) is not supported by this build", @tagName(method).ptr);
    }

    return true;
}

pub fn parse(options: c.VALUE, op: Op) Config {
    if (options == c.Qnil) {
        return .{};
    }

    if (!c.RB_TYPE_P(options, c.RUBY_T_HASH)) {
        c.rb_raise(c.rb_eTypeError, "expected options hash");
    }

    var config = Config{};

    const encryption_value = c.rb_hash_lookup2(
        options,
        c.ID2SYM(c.rb_intern("encryption")),
        c.Qnil,
    );

    if (encryption_value != c.Qnil) {
        config.method = parseMethod(encryption_value);
        _ = isValidMethod(config.method, op);
    }

    const password_value = c.rb_hash_lookup2(options, c.ID2SYM(c.rb_intern("password")), c.Qnil);

    if (password_value != c.Qnil) {
        var password = password_value;
        _ = c.rb_string_value(&password);
        config.password_rb = password;
    }

    switch (op) {
        .read => {},

        .write => switch (config.method) {
            .none => {
                if (config.password_rb != c.Qnil) {
                    c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .invalid_argument))], "password requires encryption");
                }
            },

            .pkware, .aes128, .aes192, .aes256 => {},
        },
    }
    return config;
}

pub fn methodVal(config: *const Config) c.zip_uint16_t {
    return @backingInt(@as(Method, config.method));
}

pub fn passwordPtr(config: *const Config) ?[*:0]const u8 {
    if (config.password_rb == c.Qnil) {
        return null;
    }

    var password = config.password_rb;

    return c.rb_string_value_cstr(&password);
}

pub fn optionsHash(argc: c_int, argv: [*c]c.VALUE, required: c_int) c.VALUE {
    if (argc == required) {
        return c.Qnil;
    }

    if (argc != required + 1) {
        c.rb_error_arity(argc, required, required + 1);
    }

    const options = argv[@intCast(required)];

    if (!c.RB_TYPE_P(options, c.RUBY_T_HASH)) {
        c.rb_raise(c.rb_eTypeError, "expected options hash");
    }

    return options;
}
