const std = @import("std");
const c = @import("c");
const errors = @import("errors.zig");
const output_stream = @import("output_stream.zig");

var io_threaded: std.Io.Threaded = undefined;
var io: std.Io = undefined;

pub fn initIo() void {
    io_threaded = std.Io.Threaded.init_single_threaded;
    io = io_threaded.io();
}

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
    c.rb_define_method(file_class, "add", @ptrCast(&addFile), 2);
    c.rb_define_method(file_class, "read", @ptrCast(&readFile), 1);
    c.rb_define_method(file_class, "get_output_stream", @ptrCast(&getOutputStream), 1);
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
        errors.raiseCode(zip_exit_code);
    }

    const archive = maybe_archive.?;

    const file: *File = @ptrCast(@alignCast(c.ruby_xmalloc(@sizeOf(File))));
    file.* = .{ .archive = archive };
    const obj = c.TypedData_Wrap_Struct(file_class, &file_type, file);

    if (c.rb_block_given_p() != 0) {
        return c.rb_ensure(@ptrCast(&openBody), obj, @ptrCast(&openEnsure), obj);
    }

    return obj;
}

fn openBody(obj: c.VALUE) callconv(.c) c.VALUE {
    const result = c.rb_yield(obj);
    closeFileLibzip(getFile(obj));
    return result;
}

fn openEnsure(obj: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(obj);
    if (file.archive) |archive| {
        _ = c.zip_discard(archive);
        file.archive = null;
    }
    return c.Qnil;
}

fn closeFile(self: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    if (file.archive == null) {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))], "archive already closed");
    }

    closeFileLibzip(file);
    return c.Qnil;
}

fn closeFileLibzip(file: *File) void {
    const archive = file.archive orelse return;
    if (c.zip_close(archive) < 0) {
        const zip_error = c.zip_get_error(archive);
        const zip_exit_code = c.zip_error_code_zip(zip_error);
        _ = c.zip_discard(archive);
        file.archive = null;
        errors.raiseCode(zip_exit_code);
    }
    file.archive = null;
}

fn addFile(self: c.VALUE, name_val: c.VALUE, src_val: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    const archive = file.archive orelse {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))], "archive already closed");
    };

    var name_v = name_val;
    var src_v = src_val;
    const name = c.rb_string_value_cstr(&name_v);
    const src = c.rb_string_value_cstr(&src_v);

    const src_path = std.mem.span(src);
    const stat = std.Io.Dir.cwd().statFile(io, src_path, .{}) catch |err| {
        const kind: errors.ErrorKind = switch (err) {
            error.FileNotFound => .not_found,
            error.AccessDenied => .permission,
            else => .io,
        };
        c.rb_raise(
            errors.error_class_registry[@backingInt(kind)],
            "can't open source file at %s",
            src,
        );
    };
    if (stat.kind != .file) {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .invalid_argument))], "%s is not a regular file", src);
    }

    const zip_src = c.zip_source_file(archive, src, 0, -1);
    if (zip_src == null) {
        const zip_error = c.zip_get_error(archive);
        const zip_exit_code = c.zip_error_code_zip(zip_error);
        _ = c.zip_discard(archive);
        file.archive = null;
        errors.raiseCode(zip_exit_code);
    }

    if (c.zip_file_add(archive, name, zip_src, c.ZIP_FL_OVERWRITE) < 0) {
        const zip_error = c.zip_get_error(archive);
        const zip_exit_code = c.zip_error_code_zip(zip_error);
        c.zip_source_free(zip_src);
        file.archive = null;
        errors.raiseCode(zip_exit_code);
    }

    return self;
}

fn readFile(self: c.VALUE, name_val: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    const archive = file.archive orelse {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))], "archive already closed");
    };

    var name_v = name_val;
    const name = c.rb_string_value_cstr(&name_v);

    var stat: c.zip_stat_t = undefined;
    if (c.zip_stat(archive, name, 0, &stat) < 0) {
        errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));
    }

    const zip_file = c.zip_fopen(archive, name, 0) orelse {
        errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));
    };

    const result = c.rb_str_new(null, @intCast(stat.size));
    const read_exit_code = c.zip_fread(zip_file, c.RSTRING_PTR(result), stat.size);
    _ = c.zip_fclose(zip_file);

    if (read_exit_code < 0 or @as(u64, @intCast(read_exit_code)) != stat.size) {
        errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));
    }

    return result;
}

fn getOutputStream(self: c.VALUE, name_rb: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    const archive = file.archive orelse {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))], "archive already closed");
    };

    var name_v = name_rb;
    _ = c.rb_string_value_cstr(&name_v);

    return output_stream.create(archive, self, name_v);
}
