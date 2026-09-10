const std = @import("std");
const c = @import("c");
const errors = @import("errors.zig");

const File = struct {
    archive: ?*c.zip_t,
};

fn freeArchive(archive_ptr: ?*anyopaque) callconv(.c) void {
    const raw = archive_ptr orelse return;
    const file: *File = @ptrCast(@alignCast(raw));

    if (file.archive) |archive| {
        _ = c.zip_discard(archive);
    }
    c.ruby_xfree(file);
}

const file_type: c.rb_data_type_t = .{
    .wrap_struct_name = "LibZip::File",
    .function = .{ .dmark = null, .dfree = freeArchive, .dsize = null },
    .data = null,
    .flags = c.RUBY_TYPED_FREE_IMMEDIATELY,
};

pub var file_class: c.VALUE = undefined;

pub fn defineClass(libzip: c.VALUE) void {
    file_class = c.rb_define_class_under(libzip, "File", c.rb_cObject);
    c.rb_undef_alloc_func(file_class);
    c.rb_define_method(file_class, "closed?", @ptrCast(&fileClosed), 0);
    c.rb_define_method(file_class, "close", @ptrCast(&closeFile), 0);
    c.rb_define_singleton_method(file_class, "open", @ptrCast(&openFile), -1);
}

fn fileClosed(self: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    return if (file.archive == null) c.Qtrue else c.Qfalse;
}

fn getFile(self: c.VALUE) *File {
    return @ptrCast(@alignCast(c.rb_check_typeddata(self, &file_type)));
}

fn openFile(argc: c_int, argv: [*c]c.VALUE, klass: c.VALUE) callconv(.c) c.VALUE {
    _ = klass;
    if (argc < 1 or argc > 2) c.rb_error_arity(argc, 1, 2);
    var path_val: c.VALUE = argv[0];
    const path = c.rb_string_value_cstr(&path_val);

    var flags: c_int = 0;
    if (argc > 1) {
        const opts = argv[1];
        if (!c.RB_TYPE_P(opts, c.RUBY_T_HASH)) {
            c.rb_raise(c.rb_eTypeError, "no implicit conversion of String into Hash");
        }
        const create_val = c.rb_hash_lookup2(
            opts,
            c.ID2SYM(c.rb_intern("create")),
            c.Qfalse,
        );
        if (c.RTEST(create_val)) flags |= c.ZIP_CREATE;
    }

    var zip_exit_code: c_int = 0;
    const maybe_archive = c.zip_open(path, flags, &zip_exit_code);

    if (maybe_archive == null) {
        var zip_error: c.zip_error_t = undefined;
        c.zip_error_init_with_code(&zip_error, zip_exit_code);
        const msg = c.zip_error_strerror(&zip_error);
        const exception_class = switch (errors.categorize(zip_exit_code)) {
            .err => |kind| errors.error_class_registry[@backingInt(kind)],
            .ok, .unknown => errors.base_error_class,
        };
        c.rb_exc_raise(c.rb_exc_new_cstr(exception_class, msg));
    }

    const archive = maybe_archive.?;

    const file: *File = @ptrCast(@alignCast(c.ruby_xmalloc(@sizeOf(File))));
    file.* = .{ .archive = archive };
    return c.TypedData_Wrap_Struct(file_class, &file_type, file);
}

fn closeFile(self: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    const archive = file.archive orelse {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))], "archive already closed");
    };

    if (c.zip_close(archive) < 0) {
        const zip_error = c.zip_get_error(archive);
        const zip_exit_code = c.zip_error_code_zip(zip_error);
        const message = c.zip_error_strerror(zip_error);
        const exception_class = switch (errors.categorize(zip_exit_code)) {
            .err => |kind| errors.error_class_registry[@backingInt(kind)],
            .ok, .unknown => errors.base_error_class,
        };
        _ = c.zip_discard(archive);
        file.archive = null;
        c.rb_exc_raise(c.rb_exc_new_cstr(exception_class, message));
    }

    file.archive = null;
    return c.Qnil;
}
