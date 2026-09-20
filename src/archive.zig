const std = @import("std");
const c = @import("c");
const errors = @import("errors.zig");
const entry = @import("entry.zig");
const output_stream = @import("output_stream.zig");
const input_stream = @import("input_stream.zig");
const encryption = @import("encryption.zig");
const cast = @import("cast.zig");

const READ_BUFFER_SIZE: c.zip_uint64_t = 8 * 1024;
// An uncompressed size from the archive is attacker-controlled, so it may
// size the first allocation and no more than that.
const READ_PREALLOC_CAP: c_long = 4 * 1024 * 1024;

var fnm_pathname: c_int = 0;
var fnm_dotmatch: c_int = 0;
var fnm_extglob: c_int = 0;

const File = struct {
    archive: ?*c.zip_t,
    input_streams: ?*input_stream.InputStream,
};

const file_type: c.rb_data_type_t = .{
    .wrap_struct_name = "LibZip::File",
    .function = .{ .dmark = null, .dfree = freeArchive, .dsize = sizeArchive },
    .data = null,
    .flags = c.RUBY_TYPED_FREE_IMMEDIATELY,
};

fn sizeArchive(archive_ptr: ?*const anyopaque) callconv(.c) usize {
    if (archive_ptr == null) return 0;
    return @sizeOf(File);
}

fn freeArchive(archive_ptr: ?*anyopaque) callconv(.c) void {
    const raw = archive_ptr orelse return;
    const file: *File = @ptrCast(@alignCast(raw));

    input_stream.closeAllStreams(&file.input_streams);

    if (file.archive) |archive| {
        _ = c.zip_discard(archive);
    }
    c.ruby_xfree(file);
}

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
    c.rb_define_method(file_class, "add", @ptrCast(&addFile), -1);
    c.rb_define_method(file_class, "read", @ptrCast(&readFile), -1);
    c.rb_define_method(file_class, "get_output_stream", @ptrCast(&getOutputStream), -1);
    c.rb_define_method(file_class, "get_input_stream", @ptrCast(&getInputStream), -1);
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
    c.rb_define_method(file_class, "comment", @ptrCast(&getComment), 0);
    c.rb_define_method(file_class, "comment=", @ptrCast(&setComment), 1);
    c.rb_define_method(file_class, "set_comment", @ptrCast(&setEntryComment), 2);
    c.rb_define_method(file_class, "password=", @ptrCast(&setPassword), 1);
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

/// The live zip_t behind a LibZip::File, or null once closed. Streams resolve
/// the archive through this instead of caching a pointer that closing releases.
pub fn archiveOf(self: c.VALUE) ?*c.zip_t {
    return getFile(self).archive;
}

fn openFile(argc: c_int, argv: [*c]c.VALUE, klass: c.VALUE) callconv(.c) c.VALUE {
    _ = klass;
    if (argc < 1 or argc > 2) c.rb_error_arity(argc, 1, 2);
    var path_val: c.VALUE = argv[0];
    const path = c.rb_string_value_cstr(&path_val);

    var flags: c_int = 0;
    var opts: c.VALUE = c.Qnil;
    if (argc > 1) {
        opts = argv[1];
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

    // Everything that can raise happens before zip_open: between the open and
    // the wrap, no owner of the zip_t would release it.
    var password = if (opts == c.Qnil) c.Qnil else c.rb_hash_lookup2(opts, c.ID2SYM(c.rb_intern("password")), c.Qnil);
    const password_ptr = if (password == c.Qnil) null else c.rb_string_value_cstr(&password);

    var zip_exit_code: c_int = 0;
    const maybe_archive = c.zip_open(path, flags, &zip_exit_code);

    if (maybe_archive == null) {
        errors.raiseCode(zip_exit_code);
    }

    const archive = maybe_archive.?;
    if (password_ptr) |ptr| {
        if (c.zip_set_default_password(archive, ptr) < 0) {
            const error_code = c.zip_error_code_zip(c.zip_get_error(archive));
            _ = c.zip_discard(archive);
            errors.raiseCode(error_code);
        }
    }

    const file: *File = @ptrCast(@alignCast(c.ruby_xmalloc(@sizeOf(File))));
    file.* = .{ .archive = archive, .input_streams = null };
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

    input_stream.closeAllStreams(&file.input_streams);

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

    input_stream.closeAllStreams(&file.input_streams);

    if (c.zip_close(archive) < 0) {
        const zip_error = c.zip_get_error(archive);
        const zip_exit_code = c.zip_error_code_zip(zip_error);
        _ = c.zip_discard(archive);
        file.archive = null;
        errors.raiseCode(zip_exit_code);
    }
    file.archive = null;
}

fn addFile(argc: c_int, argv: [*c]c.VALUE, self: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    const archive = file.archive orelse {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))], "archive already closed");
    };
    if (argc < 2 or argc > 3) {
        c.rb_error_arity(argc, 2, 3);
    }
    const encryption_config = encryption.parse(encryption.optionsHash(argc, argv, 2), .write);

    var name_v = argv[0];
    var src_v = argv[1];
    const name = c.rb_string_value_cstr(&name_v);
    const src = c.rb_string_value_cstr(&src_v);

    const src_path = std.mem.span(src);
    // Stack-local, not a global: rb_ext_ractor_safe(true) lets these methods
    // run in parallel Ractors.
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    const io = io_threaded.io();
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

    // A failed add is a per-entry error, as it's in libzip: release what this
    // call allocated and keep the archive usable.
    const zip_src = c.zip_source_file(archive, src, 0, -1);
    if (zip_src == null) {
        errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));
    }

    const index = c.zip_file_add(archive, name, zip_src, c.ZIP_FL_OVERWRITE);
    if (index < 0) {
        const zip_exit_code = c.zip_error_code_zip(c.zip_get_error(archive));
        c.zip_source_free(zip_src);
        errors.raiseCode(zip_exit_code);
    }
    const entry_index = cast.entryIndex(index);

    if (encryption_config.method != .none and c.zip_file_set_encryption(archive, entry_index, encryption.methodVal(&encryption_config), encryption.passwordPtr(&encryption_config)) < 0) {
        const zip_exit_code = c.zip_error_code_zip(c.zip_get_error(archive));
        _ = c.zip_delete(archive, entry_index);
        errors.raiseCode(zip_exit_code);
    }

    return self;
}

fn readFile(argc: c_int, argv: [*c]c.VALUE, self: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    const archive = file.archive orelse {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))], "archive already closed");
    };

    if (argc < 1 or argc > 2) {
        c.rb_error_arity(argc, 1, 2);
    }
    const opts = encryption.optionsHash(argc, argv, 1);
    const encryption_config = encryption.parse(opts, .read);

    var name_rb = argv[0];
    const name = c.rb_string_value_cstr(&name_rb);

    var stat: c.zip_stat_t = undefined;
    c.zip_stat_init(&stat);
    if (c.zip_stat(archive, name, 0, &stat) < 0) {
        errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));
    }
    // Without this, a size the archive left out looks the same as an empty
    // entry.
    const size_known = (stat.valid & c.ZIP_STAT_SIZE) != 0;

    const maybe_file =
        if (encryption_config.password_rb == c.Qnil)
            c.zip_fopen(archive, name, 0)
        else
            c.zip_fopen_encrypted(
                archive,
                name,
                0,
                encryption.passwordPtr(&encryption_config),
            );

    const zip_file = maybe_file orelse {
        errors.raiseCode(
            c.zip_error_code_zip(c.zip_get_error(archive)),
        );
    };

    // Reserve up to the limit, then grow as the data actually shows up.
    const reserve: c_long = if (size_known)
        @min(cast.rubyLength(stat.size), READ_PREALLOC_CAP)
    else
        0;
    const result = c.rb_str_buf_new(reserve);

    var buffer: [READ_BUFFER_SIZE]u8 = undefined;
    var total: c.zip_uint64_t = 0;
    while (true) {
        const amount = c.zip_fread(zip_file, &buffer, READ_BUFFER_SIZE);
        if (amount < 0) {
            const error_code = c.zip_error_code_zip(c.zip_file_get_error(zip_file));
            _ = c.zip_fclose(zip_file);
            errors.raiseCode(error_code);
        }
        if (amount == 0) break;
        _ = c.rb_str_cat(result, &buffer, amount);
        total += cast.readAmount(amount);
    }
    _ = c.zip_fclose(zip_file);

    // Detects an entry shorter or longer than it claims.
    if (size_known and total != stat.size) {
        errors.raiseCode(c.ZIP_ER_INCONS);
    }

    return result;
}

fn getInputStream(argc: c_int, argv: [*c]c.VALUE, self: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    const archive = file.archive orelse {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))], "archive already closed");
    };

    if (argc < 1 or argc > 2) {
        c.rb_error_arity(argc, 1, 2);
    }
    const options = encryption.optionsHash(argc, argv, 1);
    const encryption_config = encryption.parse(options, .read);

    var name_rb = argv[0];
    const name = c.rb_string_value_cstr(&name_rb);

    var stat: c.zip_stat_t = undefined;
    c.zip_stat_init(&stat);

    if (c.zip_stat(archive, name, 0, &stat) < 0) {
        errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));
    }

    return input_stream.create(
        archive,
        self,
        &file.input_streams,
        name,
        stat.size,
        (stat.valid & c.ZIP_STAT_SIZE) != 0,
        &encryption_config,
    );
}

fn getOutputStream(argc: c_int, argv: [*c]c.VALUE, self: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    _ = file.archive orelse {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))], "archive already closed");
    };

    if (argc < 1 or argc > 2) {
        c.rb_error_arity(argc, 1, 2);
    }
    const encryption_config = encryption.parse(encryption.optionsHash(argc, argv, 1), .write);

    var name_v = argv[0];
    _ = c.rb_string_value_cstr(&name_v);

    return output_stream.create(self, name_v, &encryption_config);
}

fn statEntry(self: c.VALUE, file: *File, index: c.zip_uint64_t) c.VALUE {
    const archive = file.archive orelse return c.Qnil;
    var stat: c.zip_stat_t = undefined;
    c.zip_stat_init(&stat);
    if (c.zip_stat_index(archive, index, 0, &stat) < 0) return c.Qnil;
    return entry.createEntry(self, archive, index, &stat, isDirectory(archive, index, stat.name));
}

fn entries(self: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    const archive = file.archive orelse {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))], "archive already closed");
    };

    const num_entries = c.zip_get_num_entries(archive, 0);
    if (num_entries < 0) errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));
    const count = cast.entryCount(num_entries);

    const ary = c.rb_ary_new_capa(cast.rubyLength(count));
    var i: c.zip_uint64_t = 0;
    while (i < count) : (i += 1) {
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
    const count = cast.entryCount(num_entries);

    var active_entries: c.zip_uint64_t = 0;
    var i: c.zip_uint64_t = 0;
    while (i < count) : (i += 1) {
        if (c.zip_get_name(archive, i, 0) != null) active_entries += 1;
    }
    return c.ULL2NUM(active_entries);
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
    return statEntry(self, file, cast.entryIndex(index));
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
    const count = cast.entryCount(num_entries);

    const ary = c.rb_ary_new_capa(cast.rubyLength(count));
    var i: c.zip_uint64_t = 0;
    while (i < count) : (i += 1) {
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

    const snapshot = statEntry(self, file, cast.entryIndex(index));
    if (snapshot == c.Qnil) {
        c.rb_raise(
            errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .not_found))],
            "entry not found: %s",
            name,
        );
    }

    if (c.zip_delete(archive, cast.entryIndex(index)) < 0) {
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

    if (c.zip_file_rename(archive, cast.entryIndex(index), new_name, 0) < 0) {
        errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));
    }

    const snapshot = statEntry(self, file, cast.entryIndex(index));
    if (snapshot == c.Qnil) {
        c.rb_raise(
            errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .not_found))],
            "entry not found: %s",
            new_name,
        );
    }
    return snapshot;
}

fn getComment(self: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    const archive = file.archive orelse {
        c.rb_raise(
            errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))],
            "archive already closed",
        );
    };

    var length: c_int = 0;
    const ptr = c.zip_get_archive_comment(archive, &length, c.ZIP_FL_ENC_RAW);
    if (ptr == null) {
        errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));
    }

    if (length <= 0) return c.Qnil;

    const result = c.rb_str_new(ptr, length);
    const utf8 = c.rb_enc_find_index("UTF-8");
    const binary = c.rb_enc_find_index("ASCII-8BIT");

    _ = c.rb_enc_associate_index(result, utf8);

    if (c.rb_enc_str_coderange(result) == c.RUBY_ENC_CODERANGE_BROKEN) {
        _ = c.rb_enc_associate_index(result, binary);
    }

    return result;
}

fn setComment(self: c.VALUE, value: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    const archive = file.archive orelse {
        c.rb_raise(
            errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))],
            "archive already closed",
        );
    };

    if (value == c.Qnil) {
        if (c.zip_set_archive_comment(archive, null, 0) < 0) {
            errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));
        }
        return value;
    }

    var comment = value;
    _ = c.rb_string_value(&comment);

    // Bounded before truncating: truncating first lets a length with legal-
    // looking low bits through.
    const length = cast.commentLength(c.RSTRING_LEN(comment));
    const ptr = c.RSTRING_PTR(comment);

    if (c.zip_set_archive_comment(archive, ptr, length) < 0) {
        errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));
    }

    return value;
}

fn setEntryComment(
    self: c.VALUE,
    name_val: c.VALUE,
    comment_val: c.VALUE,
) callconv(.c) c.VALUE {
    const file = getFile(self);
    const archive = file.archive orelse {
        c.rb_raise(
            errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))],
            "archive already closed",
        );
    };

    var name_v = name_val;
    const name = c.rb_string_value_cstr(&name_v);

    const index = c.zip_name_locate(archive, name, 0);
    if (index < 0) {
        c.rb_raise(
            errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .not_found))],
            "entry not found: %s",
            name,
        );
    }

    var comment_v = comment_val;
    var comment_ptr: [*c]const u8 = null;
    var comment_len: c.zip_uint16_t = 0;
    var flags: c.zip_flags_t = c.ZIP_FL_ENC_GUESS;

    if (comment_val != c.Qnil) {
        _ = c.rb_string_value(&comment_v);

        comment_len = cast.commentLength(c.RSTRING_LEN(comment_v));
        comment_ptr = c.RSTRING_PTR(comment_v);

        const encoding = c.rb_enc_get_index(comment_v);
        const utf8 = c.rb_enc_find_index("UTF-8");
        const valid = c.rb_enc_str_coderange(comment_v) != c.RUBY_ENC_CODERANGE_BROKEN;

        if (encoding == utf8 and valid) {
            flags = c.ZIP_FL_ENC_UTF_8;
        }
    }

    if (c.zip_file_set_comment(archive, cast.entryIndex(index), comment_ptr, comment_len, flags) < 0) {
        errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));
    }

    return self;
}

fn setPassword(self: c.VALUE, password_rb: c.VALUE) callconv(.c) c.VALUE {
    const file = getFile(self);
    const archive = file.archive orelse {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))], "archive already closed");
    };

    const password = if (password_rb == c.Qnil) null else blk: {
        var string = password_rb;
        break :blk c.rb_string_value_cstr(&string);
    };

    if (c.zip_set_default_password(archive, password) < 0) {
        errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));
    }

    return password_rb;
}
