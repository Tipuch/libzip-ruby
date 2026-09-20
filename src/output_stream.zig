const std = @import("std");
const c = @import("c");
const errors = @import("errors.zig");
const encryption = @import("encryption.zig");
const archive_mod = @import("archive.zig");
const cast = @import("cast.zig");

pub const OutputStream = struct {
    // Kept as a Ruby object, not as a zip_t*: this stream can still be around
    // after the archive is closed, and a cached pointer would then be freed
    // memory.
    archive_rb: c.VALUE,
    name_rb: c.VALUE,
    password_rb: c.VALUE,
    // Paired with std.c malloc/realloc/free by hand, because libzip releases
    // this with free() once it takes ownership.
    buffer_ptr: ?[*]u8,
    buffer_len: usize,
    committed: bool,
    encryption_method: encryption.Method,
};

fn markStream(ptr: ?*anyopaque) callconv(.c) void {
    const raw = ptr orelse return;
    const stream: *OutputStream = @ptrCast(@alignCast(raw));
    c.rb_gc_mark(stream.archive_rb);
    c.rb_gc_mark(stream.name_rb);
    c.rb_gc_mark(stream.password_rb);
}

fn freeStream(ptr: ?*anyopaque) callconv(.c) void {
    const raw = ptr orelse return;
    const stream: *OutputStream = @ptrCast(@alignCast(raw));
    releaseBuffer(stream);
    c.ruby_xfree(stream);
}

fn sizeStream(ptr: ?*const anyopaque) callconv(.c) usize {
    const raw = ptr orelse return 0;
    const stream: *const OutputStream = @ptrCast(@alignCast(raw));
    return @sizeOf(OutputStream) + stream.buffer_len;
}

/// Free the buffer, unless libzip has already taken ownership of it.
fn releaseBuffer(stream: *OutputStream) void {
    if (stream.buffer_ptr) |ptr| std.c.free(ptr);
    stream.buffer_ptr = null;
    stream.buffer_len = 0;
}

const stream_type: c.rb_data_type_t = .{
    .wrap_struct_name = "LibZip::OutputStream",
    .function = .{ .dmark = markStream, .dfree = freeStream, .dsize = sizeStream },
    .data = null,
    .flags = c.RUBY_TYPED_FREE_IMMEDIATELY,
};

pub var stream_class: c.VALUE = undefined;

pub fn create(archive_rb: c.VALUE, name_rb: c.VALUE, config: *const encryption.Config) c.VALUE {
    const stream: *OutputStream = @ptrCast(@alignCast(c.ruby_xmalloc(@sizeOf(OutputStream))));
    stream.* = .{
        .archive_rb = archive_rb,
        .name_rb = name_rb,
        .password_rb = config.password_rb,
        .buffer_ptr = null,
        .buffer_len = 0,
        .committed = false,
        .encryption_method = config.method,
    };
    const obj = c.TypedData_Wrap_Struct(stream_class, &stream_type, stream);
    if (c.rb_block_given_p() != 0) {
        return c.rb_ensure(@ptrCast(&streamBody), obj, @ptrCast(&ensureStream), obj);
    }
    return obj;
}

/// The live archive behind this stream, or a raise if it has been closed.
fn archiveOf(stream: *const OutputStream) *c.zip_t {
    return archive_mod.archiveOf(stream.archive_rb) orelse {
        c.rb_raise(
            errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))],
            "archive already closed",
        );
    };
}

fn writeStream(self: c.VALUE, str_val: c.VALUE) callconv(.c) c.VALUE {
    return c.LONG2NUM(appendBytes(getStream(self), str_val));
}

fn shovelStream(self: c.VALUE, str_val: c.VALUE) callconv(.c) c.VALUE {
    _ = appendBytes(getStream(self), str_val);
    return self;
}

fn commitStream(stream: *OutputStream) void {
    if (stream.committed) return;
    const archive = archiveOf(stream);
    const name = c.rb_string_value_cstr(&stream.name_rb);

    const source = c.zip_source_buffer(archive, stream.buffer_ptr, stream.buffer_len, 1);
    if (source == null) {
        errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));
    }
    // freep = 1 passes the buffer to libzip; drop the local handle alongside
    // the flag so no later path can free it a second time.
    stream.committed = true;
    stream.buffer_ptr = null;
    stream.buffer_len = 0;

    const index = c.zip_file_add(archive, name, source, c.ZIP_FL_OVERWRITE);
    if (index < 0) {
        c.zip_source_free(source);
        errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));
    }
    const entry_index = cast.entryIndex(index);

    if (stream.encryption_method != .none) {
        var password = stream.password_rb;
        const password_ptr = if (password == c.Qnil) null else c.rb_string_value_cstr(&password);

        if (c.zip_file_set_encryption(archive, entry_index, @backingInt(@as(encryption.Method, stream.encryption_method)), password_ptr) < 0) {
            const zip_error_code = c.zip_error_code_zip(c.zip_get_error(archive));
            _ = c.zip_delete(archive, entry_index);
            errors.raiseCode(zip_error_code);
        }
    }
}

fn closeStream(self: c.VALUE) callconv(.c) c.VALUE {
    commitStream(getStream(self));
    return c.Qnil;
}

fn streamBody(obj: c.VALUE) callconv(.c) c.VALUE {
    const result = c.rb_yield(obj);
    commitStream(getStream(obj));
    return result;
}

fn ensureStream(obj: c.VALUE) callconv(.c) c.VALUE {
    const stream = getStream(obj);
    if (!stream.committed) {
        releaseBuffer(stream);
        stream.committed = true;
    }
    return c.Qnil;
}

fn getStream(self: c.VALUE) *OutputStream {
    return @ptrCast(@alignCast(c.rb_check_typeddata(self, &stream_type)));
}

fn appendBytes(stream: *OutputStream, str_val: c.VALUE) c_long {
    if (stream.committed) {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))], "stream already closed");
    }
    _ = archiveOf(stream);

    var str_v = str_val;
    _ = c.rb_string_value(&str_v);
    const signed_len = c.RSTRING_LEN(str_v);
    if (signed_len <= 0) return 0;
    const len: usize = cast.requestLength(signed_len);

    const new_len = std.math.add(usize, stream.buffer_len, len) catch {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .internal))], "entry too large");
    };
    const raw = std.c.realloc(stream.buffer_ptr, new_len) orelse {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .internal))], "out of memory");
    };
    const buffer: [*]u8 = @ptrCast(raw);
    @memcpy(buffer[stream.buffer_len..new_len], c.RSTRING_PTR(str_v)[0..len]);
    stream.buffer_ptr = buffer;
    stream.buffer_len = new_len;
    return signed_len;
}

pub fn defineClass(libzip: c.VALUE) void {
    stream_class = c.rb_define_class_under(libzip, "OutputStream", c.rb_cObject);
    c.rb_undef_alloc_func(stream_class);
    c.rb_define_method(stream_class, "write", @ptrCast(&writeStream), 1);
    c.rb_define_method(stream_class, "<<", @ptrCast(&shovelStream), 1);
    c.rb_define_method(stream_class, "close", @ptrCast(&closeStream), 0);
}
