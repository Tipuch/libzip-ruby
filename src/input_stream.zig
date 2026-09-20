const c = @import("c");
const encryption = @import("encryption.zig");
const errors = @import("errors.zig");
const cast = @import("cast.zig");

const BUFFER_SIZE: usize = 8 * 1024;

pub const InputStream = struct {
    archive_rb: c.VALUE,
    head: ?*?*InputStream,
    prev: ?*InputStream,
    next: ?*InputStream,
    zip_file: ?*c.zip_file_t,
    buffer: [*]u8,
    size: c.zip_uint64_t,
    size_known: bool,
    position: c.zip_uint64_t,
    eof: bool,
};

pub var stream_class: c.VALUE = undefined;

fn markStream(raw: ?*anyopaque) callconv(.c) void {
    const ptr = raw orelse return;
    const stream: *InputStream = @ptrCast(@alignCast(ptr));
    c.rb_gc_mark(stream.archive_rb);
}

fn sizeStream(raw: ?*const anyopaque) callconv(.c) usize {
    if (raw == null) return 0;
    return @sizeOf(InputStream) + BUFFER_SIZE;
}

fn freeStream(raw: ?*anyopaque) callconv(.c) void {
    const ptr = raw orelse return;
    const stream: *InputStream = @ptrCast(@alignCast(ptr));
    _ = unlink(stream);
    if (stream.zip_file) |zip_file| {
        _ = c.zip_fclose(zip_file);
        stream.zip_file = null;
    }

    c.ruby_xfree(@ptrCast(stream.buffer));
    c.ruby_xfree(stream);
}

const stream_type: c.rb_data_type_t = .{
    .wrap_struct_name = "LibZip::InputStream",
    .function = .{
        .dmark = markStream,
        .dfree = freeStream,
        .dsize = sizeStream,
    },
    .data = null,
    .flags = c.RUBY_TYPED_FREE_IMMEDIATELY,
};

fn getStream(self: c.VALUE) *InputStream {
    return @ptrCast(@alignCast(c.rb_check_typeddata(self, &stream_type)));
}

fn raiseClosed() noreturn {
    c.rb_raise(
        errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .entry))],
        "stream already closed",
    );
}

fn ensureOpen(stream: *InputStream) void {
    if (stream.zip_file == null) raiseClosed();
}

pub fn create(
    archive: *c.zip_t,
    archive_rb: c.VALUE,
    head: *?*InputStream,
    name: [*c]const u8,
    size: c.zip_uint64_t,
    size_known: bool,
    encryption_config: *const encryption.Config,
) c.VALUE {
    const maybe_file =
        if (encryption_config.password_rb == c.Qnil)
            c.zip_fopen(archive, name, 0)
        else
            c.zip_fopen_encrypted(
                archive,
                name,
                0,
                encryption.passwordPtr(encryption_config),
            );

    const zip_file = maybe_file orelse {
        errors.raiseCode(
            c.zip_error_code_zip(c.zip_get_error(archive)),
        );
    };
    const raw_buffer = c.ruby_xmalloc(BUFFER_SIZE);
    const buffer: [*]u8 = @ptrCast(raw_buffer);

    const stream: *InputStream = @ptrCast(@alignCast(c.ruby_xmalloc(@sizeOf(InputStream))));

    stream.* = .{
        .head = null,
        .prev = null,
        .next = null,
        .archive_rb = archive_rb,
        .zip_file = zip_file,
        .buffer = buffer,
        .size = size,
        .size_known = size_known,
        .position = 0,
        .eof = size_known and size == 0,
    };

    const obj = c.TypedData_Wrap_Struct(
        stream_class,
        &stream_type,
        stream,
    );

    stream.head = head;
    stream.next = head.*;
    if (head.*) |first| first.prev = stream;
    head.* = stream;

    if (c.rb_block_given_p() != 0) {
        return c.rb_ensure(
            @ptrCast(&streamBody),
            obj,
            @ptrCast(&ensureStream),
            obj,
        );
    }

    return obj;
}

fn streamBody(self: c.VALUE) callconv(.c) c.VALUE {
    return c.rb_yield(self);
}

fn ensureStream(self: c.VALUE) callconv(.c) c.VALUE {
    return closeStreamInternal(getStream(self), true);
}

pub fn defineClass(libzip: c.VALUE) void {
    stream_class = c.rb_define_class_under(libzip, "InputStream", c.rb_cObject);

    c.rb_undef_alloc_func(stream_class);

    c.rb_define_method(stream_class, "read", @ptrCast(&readStream), -1);
    c.rb_define_method(stream_class, "eof?", @ptrCast(&streamEof), 0);
    c.rb_define_method(stream_class, "closed?", @ptrCast(&streamClosed), 0);
    c.rb_define_method(stream_class, "close", @ptrCast(&closeStream), 0);
}

fn closeStream(self: c.VALUE) callconv(.c) c.VALUE {
    return closeStreamInternal(getStream(self), true);
}

fn unlink(stream: *InputStream) void {
    if (stream.head) |head| {
        if (stream.prev) |prev| prev.next = stream.next else head.* = stream.next;
        if (stream.next) |next| next.prev = stream.prev;
        stream.head = null;
    }

    stream.prev = null;
    stream.next = null;
}

fn closeStreamInternal(stream: *InputStream, raise_errors: bool) callconv(.c) c.VALUE {
    unlink(stream);
    const zip_file = stream.zip_file orelse {
        stream.eof = true;
        return c.Qnil;
    };

    const exit_code = c.zip_fclose(zip_file);
    stream.zip_file = null;
    stream.eof = true;

    if (raise_errors and exit_code != 0) {
        errors.raiseCode(exit_code);
    }
    return c.Qnil;
}

pub fn closeAllStreams(head: *?*InputStream) void {
    while (head.*) |stream| _ = closeStreamInternal(stream, false);
}

fn streamClosed(self: c.VALUE) callconv(.c) c.VALUE {
    return if (getStream(self).zip_file == null) c.Qtrue else c.Qfalse;
}

fn streamEof(self: c.VALUE) callconv(.c) c.VALUE {
    const stream = getStream(self);
    ensureOpen(stream);
    return if (stream.eof) c.Qtrue else c.Qfalse;
}

fn appendChunk(
    result: c.VALUE,
    stream: *InputStream,
    requested: c.zip_uint64_t,
) c.zip_uint64_t {
    const zip_file = stream.zip_file orelse {
        raiseClosed();
    };

    const amount = c.zip_fread(zip_file, @ptrCast(stream.buffer), requested);

    if (amount < 0) {
        errors.raiseCode(c.zip_error_code_zip(c.zip_file_get_error(zip_file)));
    }

    if (amount == 0) {
        stream.eof = true;
        return 0;
    }

    _ = c.rb_str_cat(result, @ptrCast(stream.buffer), amount);

    const read = cast.readAmount(amount);
    stream.position += read;

    if (stream.size_known and stream.position >= stream.size) {
        stream.eof = true;
    }

    return read;
}

fn readRequested(stream: *InputStream, request: c.zip_uint64_t) c.VALUE {
    const result = c.rb_str_new(null, 0);
    var remaining = request;

    while (remaining > 0 and !stream.eof) {
        const requested = if (remaining < BUFFER_SIZE) remaining else BUFFER_SIZE;

        const amount = appendChunk(result, stream, requested);
        if (amount == 0) break;
        remaining -= amount;
    }

    if (c.RSTRING_LEN(result) == 0 and stream.eof) {
        return c.Qnil;
    }

    return result;
}

fn readFull(stream: *InputStream) c.VALUE {
    const result = c.rb_str_new(null, 0);

    while (!stream.eof) {
        _ = appendChunk(result, stream, BUFFER_SIZE);
    }

    return result;
}

fn readStream(argc: c_int, argv: [*c]c.VALUE, self: c.VALUE) callconv(.c) c.VALUE {
    const stream = getStream(self);
    ensureOpen(stream);

    if (argc == 0) {
        return readFull(stream);
    }

    if (argc != 1) {
        c.rb_error_arity(argc, 0, 1);
    }

    const requested = cast.requestLength(c.NUM2LONG(argv[0]));

    if (requested == 0) {
        return c.rb_str_new(null, 0);
    }

    if (stream.eof) {
        return c.Qnil;
    }

    return readRequested(stream, requested);
}
