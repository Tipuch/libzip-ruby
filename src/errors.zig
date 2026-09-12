const std = @import("std");
const c = @import("c");

pub const ExitCode = enum(c_int) {
    ok = c.ZIP_ER_OK, // N No error
    multidisk = c.ZIP_ER_MULTIDISK, // N Multi-disk zip archives not supported
    rename = c.ZIP_ER_RENAME, // S Renaming temporary file failed
    close = c.ZIP_ER_CLOSE, // S Closing zip archive failed
    seek = c.ZIP_ER_SEEK, // S Seek error
    read = c.ZIP_ER_READ, // S Read error
    write = c.ZIP_ER_WRITE, // S Write error
    crc = c.ZIP_ER_CRC, // N CRC error
    zipclosed = c.ZIP_ER_ZIPCLOSED, // N Containing zip archive was closed
    noent = c.ZIP_ER_NOENT, // N No such file
    exists = c.ZIP_ER_EXISTS, // N File already exists
    open = c.ZIP_ER_OPEN, // S Can't open file
    tmpopen = c.ZIP_ER_TMPOPEN, // Failure to create temporary file
    zlib = c.ZIP_ER_ZLIB, // Z Zlib error
    memory = c.ZIP_ER_MEMORY, // N Malloc failure
    changed = c.ZIP_ER_CHANGED, // N Entry has been changed
    compnotsupp = c.ZIP_ER_COMPNOTSUPP, // N Compression method not supported
    eof = c.ZIP_ER_EOF, // N Premature end of file
    inval = c.ZIP_ER_INVAL, // N Invalid argument
    nozip = c.ZIP_ER_NOZIP, // N Not a zip archive
    internal = c.ZIP_ER_INTERNAL, // N Internal error
    incons = c.ZIP_ER_INCONS, // L Zip archive inconsistent
    remove = c.ZIP_ER_REMOVE, // S Can't remove file
    deleted = c.ZIP_ER_DELETED, // N Entry has been deleted
    encrnotsupp = c.ZIP_ER_ENCRNOTSUPP, // N Encryption method not supported
    rdonly = c.ZIP_ER_RDONLY, // N Read-only archive
    nopasswd = c.ZIP_ER_NOPASSWD, // N No password provided
    wrongpasswd = c.ZIP_ER_WRONGPASSWD, // N Wrong password provided
    opnotsupp = c.ZIP_ER_OPNOTSUPP, // N Operation not supported
    inuse = c.ZIP_ER_INUSE, // N Resource still in use
    tell = c.ZIP_ER_TELL, // S Tell error
    compressed_data = c.ZIP_ER_COMPRESSED_DATA, // N Compressed data invalid
    cancelled = c.ZIP_ER_CANCELLED, // N Operation cancelled
    data_length = c.ZIP_ER_DATA_LENGTH, // N Unexpected length of data
    not_allowed = c.ZIP_ER_NOT_ALLOWED, // N Not allowed in torrentzip
    truncated_zip = c.ZIP_ER_TRUNCATED_ZIP, // N Possibly truncated or corrupted zip archive
};

pub const ErrorKind = enum {
    unsupported,
    io,
    read,
    write,
    not_found,
    already_exists,
    corrupt_archive,
    compression,
    decompression,
    invalid_argument,
    permission,
    password,
    entry,
    internal,
};

const ErrorGroup = struct { kind: ErrorKind, codes: []const ExitCode };

const error_table = [_]ErrorGroup{
    .{ .kind = .corrupt_archive, .codes = &.{ ExitCode.multidisk, ExitCode.nozip, ExitCode.incons, ExitCode.compressed_data, ExitCode.truncated_zip } },
    .{ .kind = .io, .codes = &.{ ExitCode.eof, ExitCode.rename, ExitCode.close, ExitCode.seek, ExitCode.open, ExitCode.tmpopen, ExitCode.remove, ExitCode.tell } },
    .{ .kind = .read, .codes = &.{ExitCode.read} },
    .{ .kind = .write, .codes = &.{ExitCode.write} },
    .{ .kind = .decompression, .codes = &.{ExitCode.crc} },
    .{ .kind = .compression, .codes = &.{ExitCode.compnotsupp} },
    .{ .kind = .unsupported, .codes = &.{ ExitCode.encrnotsupp, ExitCode.opnotsupp } },
    .{ .kind = .not_found, .codes = &.{ExitCode.noent} },
    .{ .kind = .already_exists, .codes = &.{ExitCode.exists} },
    .{ .kind = .invalid_argument, .codes = &.{ExitCode.inval} },
    .{ .kind = .permission, .codes = &.{ ExitCode.rdonly, ExitCode.not_allowed } },
    .{ .kind = .password, .codes = &.{ ExitCode.nopasswd, ExitCode.wrongpasswd } },
    .{ .kind = .entry, .codes = &.{ ExitCode.zipclosed, ExitCode.changed, ExitCode.deleted, ExitCode.inuse, ExitCode.cancelled } },
    .{ .kind = .internal, .codes = &.{ ExitCode.zlib, ExitCode.memory, ExitCode.internal, ExitCode.data_length } },
};

pub var base_error_class: c.VALUE = undefined;
pub var error_class_registry: [std.enums.values(ErrorKind).len]c.VALUE = undefined;

pub fn defineClasses(libzip: c.VALUE) void {
    base_error_class = c.rb_define_class_under(libzip, "Error", c.rb_eStandardError);

    inline for (std.enums.values(ErrorKind)) |kind| {
        error_class_registry[@backingInt(kind)] = c.rb_define_class_under(libzip, comptime className(kind), base_error_class);
    }
}

fn className(comptime kind: ErrorKind) [:0]const u8 {
    comptime {
        const tag = @tagName(kind);
        var buf: []const u8 = "";
        var upper = true;
        for (tag) |ch| {
            if (ch == '_') {
                upper = true;
                continue;
            }
            buf = buf ++ [_]u8{if (upper) std.ascii.toUpper(ch) else ch};
            upper = false;
        }
        return buf ++ "Error";
    }
}

pub fn kindFor(code: ExitCode) ?ErrorKind {
    for (error_table) |error_group| {
        if (std.mem.findScalar(ExitCode, error_group.codes, code) != null) {
            return error_group.kind;
        }
    }
    return null;
}

pub const ExitCodeCategory = union(enum) {
    ok,
    err: ErrorKind,
    unknown: c_int,
};

pub fn categorize(raw: c_int) ExitCodeCategory {
    const code = std.enums.fromInt(ExitCode, raw) orelse return .{ .unknown = raw };
    if (kindFor(code)) |kind| return .{ .err = kind };
    return .ok;
}

pub fn raiseCode(raw: c_int) noreturn {
    var zip_error: c.zip_error_t = undefined;
    c.zip_error_init_with_code(&zip_error, raw);
    const rb_class = switch(categorize(raw)) {
        .err => |kind| error_class_registry[@intFromEnum(kind)],
        .ok, .unknown => base_error_class,
    };
    c.rb_exc_raise(c.rb_exc_new_cstr(rb_class, c.zip_error_strerror(&zip_error)));
}

test "className converts tags to Ruby names" {
    try std.testing.expectEqualStrings("InternalError", comptime className(.internal));

    try std.testing.expectEqualStrings("NotFoundError", comptime className(.not_found));

    try std.testing.expectEqualStrings("IoError", comptime className(.io));
}

test "categorize: ok, known error, unknown code" {
    try std.testing.expectEqual(ExitCodeCategory.ok, categorize(c.ZIP_ER_OK));

    try std.testing.expectEqual(
        ExitCodeCategory{ .err = .already_exists },
        categorize(c.ZIP_ER_EXISTS),
    );
    try std.testing.expectEqual(
        ExitCodeCategory{ .unknown = 999 },
        categorize(999),
    );
}

test "kindFor covers every ExitCode" {
    inline for (std.enums.values(ExitCode)) |code| {
        if (code == .ok) continue;
        if (kindFor(code) == null) {
            std.debug.print("uncovered ExitCode: {any}\n", .{code});
            return error.TestUnexpectedResult;
        }
    }
}

test "kindFor returns null for ok" {
    try std.testing.expectEqual(@as(?ErrorKind, null), kindFor(.ok));
}
