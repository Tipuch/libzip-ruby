//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const c = @import("c");
const errors = @import("errors.zig");
const archive = @import("archive.zig");
const entry = @import("entry.zig");
const output_stream = @import("output_stream.zig");
const input_stream = @import("input_stream.zig");

const build_options = @import("build_options");
const VERSION: [:0]const u8 = build_options.version;

export fn Init_libzip_ruby() void {
    c.rb_ext_ractor_safe(true);
    const libzip = c.rb_define_module("LibZip");
    errors.defineClasses(libzip);
    entry.defineClass(libzip);
    archive.defineClass(libzip);
    output_stream.defineClass(libzip);
    input_stream.defineClass(libzip);
    const version = c.rb_str_new_cstr(VERSION);
    c.rb_define_const(libzip, "VERSION", version);
}
