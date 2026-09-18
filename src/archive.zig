const std = @import("std");
const c = @import("c");
const errors = @import("errors.zig");
const entry = @import("entry.zig");
const output_stream = @import("output_stream.zig");

var io_threaded: std.Io.Threaded = undefined;
var io: std.Io = undefined;

var fnm_pathname: c_int = 0;
var fnm_dotmatch: c_int = 0;
var fnm_extglob: c_int = 0;

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
    fnm_pathname = c.NUM2INT(c.rb_const_get(c.rb_cFile, c.rb_intern("FNM_PATHNAME")));
    fnm_dotmatch = c.NUM2INT(c.rb_const_get(c.rb_cFile, c.rb_intern("FNM_DOTMATCH")));
    fnm_extglob = c.NUM2INT(c.rb_const_get(c.rb_cFile, c.rb_intern("FNM_EXTGLOB")));
    c.rb_include_module(file_class, c.rb_mEnumerable);
    c.rb_define_method(file_class, "closed?", @ptrCast(&fileClosed), 0);
    c.rb_define_method(file_class, "close", @ptrCast(&closeFile), 0);
    c.rb_define_singleton_method(file_class, "open", @ptrCast(&openFile), -1);
    c.rb_define_method(file_class, "add", @ptrCast(&addFile), 2);
    c.rb_define_method(file_class, "read", @ptrCast(&readFile), 1);
    c.rb_define_method(file_class, "get_output_stream", @ptrCast(&getOutputStream), 1);
    c.rb_define_method(file_class, "remove", @ptrCast(&removeFile), 1);
    c.rb_define_method(file_class, "rename", @ptrCast(&renameFile), 2);
    c.rb_define_method(file_class, "entries", @ptrCast(&entries), 0);
    c.rb_define_method(file_class, "each", @ptrCast(&eachEntry), 0);
    c.rb_define_method(file_class, "each_entry", @ptrCast(&eachEntry), 0);
    c.rb_define_method(file_class, "names", @ptrCast(&names), 0);
    c.rb_define_method(file_class, "size", @ptrCast(&countEntries), 0);
    c.rb_define_method(file_class, "length", @ptrCast(&countEntries), 0);
    c.rb_define_method(file_class, "include?", @ptrCast(&includeEntry), 1);
    c.rb_define_method(file_class, "find_entry", @ptrCast(&findEntry), 1);
    c.rb_define_method(file_class, "get_entry", @ptrCast(&getEntryByName), 1);
    c.rb_define_method(file_class, "[]", @ptrCast(&findEntry), 1);
    c.rb_define_method(file_class, "glob", @ptrCast(&glob), 1);
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

fn statEntry(self: c.VALUE, file: *File, index: c.zip_uint64_t) c.VALUE {
    const archive = file.archive orelse return c.Qnil;
    var stat: c.zip_stat_t = undefined;
    c.zip_stat_init(&stat);
    if (c.zip_stat_index(archive, index, 0, &stat) < 0) return c.Qnil;
    return entry.createEntry(self, index, &stat, isDirectory(archive, index, stat.name));
}

fn entries(self: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    const archive = file.archive orelse {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))], "archive already closed");
    };

    const num_entries = c.zip_get_num_entries(archive, 0);
    if (num_entries < 0) errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));

    const ary = c.rb_ary_new_capa(@intCast(num_entries));
    var i: c.zip_uint64_t = 0;
    while (i < @as(c.zip_uint64_t, @intCast(num_entries))) : (i += 1) {
        const obj = statEntry(self, file, i);
        if (obj != c.Qnil) _ = c.rb_ary_push(ary, obj);
    }
    return ary;
}

fn eachEntry(self: c.VALUE) callconv(.c) c.VALUE {
    if (c.rb_block_given_p() == 0) return c.rb_enumeratorize(self, c.rb_id2sym(c.rb_intern("each_entry")), 0, null);
    const list = entries(self);
    var i: c_long = 0;
    while (i < c.RARRAY_LEN(list)) : (i += 1) _ = c.rb_yield(c.rb_ary_entry(list, i));
    return list;
}

fn isDirectory(archive: *c.zip_t, index: c.zip_uint64_t, name: [*c]const u8) bool {
    const name_bytes = if (name) |n| std.mem.span(n) else return false;
    if (entry.nameIsDirectory(name_bytes)) return true;

    var opsys: c.zip_uint8_t = 0;
    var attrs: c.zip_uint32_t = 0;
    if (c.zip_file_get_external_attributes(archive, index, 0, &opsys, &attrs) < 0) return false;
    return entry.attributesAreDirectory(opsys, attrs);
}

fn countEntries(self: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    const archive = file.archive orelse {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))], "archive already closed");
    };
    const num_entries = c.zip_get_num_entries(archive, 0);
    if (num_entries < 0) errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));

    var active_entries: c.zip_uint64_t = 0;
    var i: c.zip_uint64_t = 0;
    while (i < @as(c.zip_uint64_t, @intCast(num_entries))) : (i += 1) {
        if (c.zip_get_name(archive, i, 0) != null) active_entries += 1;
    }
    return c.ULL2NUM(@intCast(active_entries));
}

fn findEntry(self: c.VALUE, name_val: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    const archive = file.archive orelse {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))], "archive already closed");
    };
    var name_v = name_val;
    const name = c.rb_string_value_cstr(&name_v);
    const index = c.zip_name_locate(archive, name, 0);
    if (index < 0) return c.Qnil;
    return statEntry(self, file, @intCast(index));
}

fn getEntryByName(self: c.VALUE, name_val: c.VALUE) callconv(.c) c.VALUE {
    const found = findEntry(self, name_val);
    if (found == c.Qnil) {
        var name_v = name_val;
        c.rb_raise(
            errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .not_found))],
            "entry not found: %s",
            c.rb_string_value_cstr(&name_v),
        );
    }
    return found;
}

fn includeEntry(self: c.VALUE, name_val: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    const archive = file.archive orelse {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))], "archive already closed");
    };
    const name_rb = if (c.RTEST(c.rb_obj_is_kind_of(name_val, entry.entry_class)))
        c.rb_funcall(name_val, c.rb_intern("to_s"), 0)
    else
        name_val;
    var name_v = name_rb;
    const name = c.rb_string_value_cstr(&name_v);
    return if (c.zip_name_locate(archive, name, 0) >= 0) c.Qtrue else c.Qfalse;
}

fn glob(self: c.VALUE, pattern_val: c.VALUE) callconv(.c) c.VALUE {
    var pattern_v = pattern_val;
    _ = c.rb_string_value(&pattern_v);

    const list = entries(self);
    const result = c.rb_ary_new_capa(c.RARRAY_LEN(list));

    const chomp = c.rb_intern("chomp");
    const fnmatch = c.rb_intern("fnmatch");
    const slash = c.rb_str_new_cstr("/");
    const flags = c.INT2NUM(fnm_pathname | fnm_dotmatch | fnm_extglob);

    var i: c_long = 0;
    while (i < c.RARRAY_LEN(list)) : (i += 1) {
        const e = c.rb_ary_entry(list, i);

        const name = c.rb_funcall(c.rb_funcall(e, c.rb_intern("to_s"), 0), chomp, 1, slash);
        if (c.RTEST(c.rb_funcall(c.rb_cFile, fnmatch, 3, pattern_v, name, flags))) {
            _ = c.rb_ary_push(result, e);
            if (c.rb_block_given_p() != 0) _ = c.rb_yield(e);
        }
    }
    return result;
}

fn names(self: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    const archive = file.archive orelse {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))], "archive already closed");
    };
    const num_entries = c.zip_get_num_entries(archive, 0);
    if (num_entries < 0) errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));

    const ary = c.rb_ary_new_capa(@intCast(num_entries));
    var i: c.zip_uint64_t = 0;
    while (i < @as(c.zip_uint64_t, @intCast(num_entries))) : (i += 1) {
        const name: [*:0]const u8 = c.zip_get_name(archive, i, 0) orelse continue;
        _ = c.rb_ary_push(ary, c.rb_utf8_str_new_cstr(name));
    }
    return ary;
}

fn removeFile(self: c.VALUE, name_or_entry: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    const archive = file.archive orelse {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))], "archive already closed");
    };

    const is_entry = c.RTEST(c.rb_obj_is_kind_of(name_or_entry, entry.entry_class));

    if (is_entry and entry.getArchive(name_or_entry) != self) {
        c.rb_raise(
            errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .invalid_argument))],
            "entry belongs to a different archive",
        );
    }

    const name_rb = if (is_entry)
        c.rb_funcall(name_or_entry, c.rb_intern("to_s"), 0)
    else
        name_or_entry;

    var name_v = name_rb;
    const name = c.rb_string_value_cstr(&name_v);

    const index = c.zip_name_locate(archive, name, 0);
    if (index < 0) {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .not_found))], "entry not found: %s", name);
    }

    const snapshot = statEntry(self, file, @intCast(index));
    if (snapshot == c.Qnil) {
        c.rb_raise(
            errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .not_found))],
            "entry not found: %s",
            name,
        );
    }

    if (c.zip_delete(archive, @intCast(index)) < 0) {
        errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));
    }

    return snapshot;
}

fn renameFile(self: c.VALUE, name_or_entry: c.VALUE, new_name_val: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    const archive = file.archive orelse {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))], "archive already closed");
    };

    const is_entry = c.RTEST(c.rb_obj_is_kind_of(name_or_entry, entry.entry_class));
    if (is_entry and entry.getArchive(name_or_entry) != self) {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .invalid_argument))], "entry belongs to a different archive");
    }

    const name_rb = if (is_entry)
        c.rb_funcall(name_or_entry, c.rb_intern("to_s"), 0)
    else
        name_or_entry;
    var name_v = name_rb;
    const name = c.rb_string_value_cstr(&name_v);
    var new_name_v = new_name_val;

    const new_name = c.rb_string_value_cstr(&new_name_v);

    const index = c.zip_name_locate(archive, name, 0);
    if (index < 0) {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .not_found))], "entry not found: %s", name);
    }

    if (entry.nameIsDirectory(std.mem.span(name)) != entry.nameIsDirectory(std.mem.span(new_name))) {
        c.rb_raise(
            errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .invalid_argument))],
            "cannot rename %s to %s: a directory entry keeps its trailing /",
            name,
            new_name,
        );
    }

    if (c.zip_file_rename(archive, @intCast(index), new_name, 0) < 0) {
        errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));
    }

    const snapshot = statEntry(self, file, @intCast(index));
    if (snapshot == c.Qnil) {
        c.rb_raise(
            errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .not_found))],
            "entry not found: %s",
            new_name,
        );
    }
    return snapshot;
}
