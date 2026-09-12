//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const c = @import("c");
const errors = @import("errors.zig");
const archive = @import("archive.zig");

const VERSION = "0.0.0";

export fn Init_libzip_ruby() void {
    archive.initIo();
    c.rb_ext_ractor_safe(true);
    const libzip = c.rb_define_module("LibZip");
    errors.defineClasses(libzip);
    archive.defineClass(libzip);
    const version = c.rb_str_new_cstr(VERSION);
    c.rb_define_const(libzip, "VERSION", version);
}
