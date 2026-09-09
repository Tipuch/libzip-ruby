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

const ErrorKind = enum {
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

const ErrorGroup = struct { kind: ErrorKind, codes: []ExitCode };

const error_table = [_]ErrorGroup{
    .{ .kind = .corrupt_archive, .codes = &.{ ExitCode.multidisk, ExitCode.nozip, ExitCode.incons, ExitCode.compressed_data } },
    .{ .kind = .io, .codes = &.{ ExitCode.eof, ExitCode.rename, ExitCode.close, ExitCode.seek, ExitCode.open, ExitCode.tmpopen, ExitCode.remove, ExitCode.tell } },
    .{ .kind = .read, .codes = &.{ExitCode.read} },
    .{ .kind = .write, .codes = &.{ExitCode.write} },
    .{ .kind = .decompression, .codes = &.{ExitCode.crc} },
    .{ .kind = .compression, .codes = &.{ExitCode.compnotsupp} },
    .{ .kind = .unsupported, .codes = &.{ ExitCode.encrnotsupp, ExitCode.opnotsupp } },
    .{ .kind = .not_found, .codes = &.{ExitCode.noent} },
    .{ .kind = .already_exists, .codes = &.{ExitCode.exists} },
    .{ .kind = .invalid_argument, .codes = &.{ExitCode.inval} },
    .{ .kind = .permission, .codes = &.{ExitCode.rdonly} },
    .{ .kind = .password, .codes = &.{ ExitCode.nopasswd, ExitCode.wrongpasswd } },
    .{ .kind = .entry, .codes = &.{ ExitCode.zipclosed, ExitCode.changed, ExitCode.deleted, ExitCode.inuse } },
    .{ .kind = .internal, .codes = &.{ ExitCode.zlib, ExitCode.memory, ExitCode.internal } },
};
