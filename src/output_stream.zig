const std = @import("std");
const c = @import("c");
const errors = @import("errors.zig");
const encryption = @import("encryption.zig");

pub const OutputStream = struct {
    archive_rb: c.VALUE,
    name_rb: c.VALUE,
    password_rb: c.VALUE,
    archive: ?*c.zip_t,
    buffer: []u8,
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
    if (!stream.committed and stream.buffer.len > 0) {
        std.heap.c_allocator.free(stream.buffer);
    }
    c.ruby_xfree(stream);
}

const stream_type: c.rb_data_type_t = .{
    .wrap_struct_name = "LibZip::OutputStream",
    .function = .{ .dmark = markStream, .dfree = freeStream, .dsize = null },
    .data = null,
    .flags = c.RUBY_TYPED_FREE_IMMEDIATELY,
};

pub var stream_class: c.VALUE = undefined;

pub fn create(archive: ?*c.zip_t, archive_rb: c.VALUE, name_rb: c.VALUE, config: *const encryption.Config) c.VALUE {
    const stream: *OutputStream = @ptrCast(@alignCast(c.ruby_xmalloc(@sizeOf(OutputStream))));
    stream.* = .{
        .archive_rb = archive_rb,
        .name_rb = name_rb,
        .password_rb = config.password_rb,
        .archive = archive,
        .buffer = &.{},
        .committed = false,
        .encryption_method = config.method,
    };
    const obj = c.TypedData_Wrap_Struct(stream_class, &stream_type, stream);
    if (c.rb_block_given_p() != 0) {
        return c.rb_ensure(@ptrCast(&streamBody), obj, @ptrCast(&ensureStream), obj);
    }
    return obj;
}

fn writeStream(self: c.VALUE, str_val: c.VALUE) callconv(.c) c.VALUE {
    const len = appendBytes(getStream(self), str_val);

    return c.INT2NUM(@as(c_int, @intCast(len)));
}

fn shovelStream(self: c.VALUE, str_val: c.VALUE) callconv(.c) c.VALUE {
    _ = appendBytes(getStream(self), str_val);
    return self;
}

fn commitStream(stream: *OutputStream) void {
    if (stream.committed) return;
    const archive = stream.archive orelse {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))], "archive already closed");
    };
    const name = c.rb_string_value_cstr(&stream.name_rb);

    const source = c.zip_source_buffer(archive, stream.buffer.ptr, stream.buffer.len, 1);
    if (source == null) {
        errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));
    }
    stream.committed = true;

    const index = c.zip_file_add(archive, name, source, c.ZIP_FL_OVERWRITE);
    if (index < 0) {
        c.zip_source_free(source);
        errors.raiseCode(c.zip_error_code_zip(c.zip_get_error(archive)));
    }

    if (stream.encryption_method != .none) {
        var password = stream.password_rb;
        const password_ptr = if (password == c.Qnil) null else c.rb_string_value_cstr(&password);

        if (c.zip_file_set_encryption(archive, @intCast(index), @backingInt(@as(encryption.Method, stream.encryption_method)), password_ptr) < 0) {
            const zip_error_code = c.zip_error_code_zip(c.zip_get_error(archive));
            _ = c.zip_delete(archive, @intCast(index));
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
        if (stream.buffer.len > 0) std.heap.c_allocator.free(stream.buffer);
        stream.committed = true;
        stream.buffer = &.{};
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
    var str_v = str_val;
    _ = c.rb_string_value_cstr(&str_v);
    const ptr = c.RSTRING_PTR(str_v);
    const len: usize = @intCast(c.RSTRING_LEN(str_v));

    const old_buffer = stream.buffer;
    const new_buffer = std.heap.c_allocator.realloc(old_buffer, old_buffer.len + len) catch {
        c.rb_raise(errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .internal))], "out of memory");
    };
    @memcpy(new_buffer[old_buffer.len..], ptr[0..len]);
    stream.buffer = new_buffer;
    return @intCast(len);
}

pub fn defineClass(libzip: c.VALUE) void {
    stream_class = c.rb_define_class_under(libzip, "OutputStream", c.rb_cObject);
    c.rb_undef_alloc_func(stream_class);
    c.rb_define_method(stream_class, "write", @ptrCast(&writeStream), 1);
    c.rb_define_method(stream_class, "<<", @ptrCast(&shovelStream), 1);
    c.rb_define_method(stream_class, "close", @ptrCast(&closeStream), 0);
}
