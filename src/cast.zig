const std = @import("std");
const c = @import("c");
const errors = @import("errors.zig");

/// A zip comment field is a 16-bit length on disk.
pub const MAX_COMMENT_LENGTH: c_long = 65_535;

fn raiseCorrupt(comptime message: [:0]const u8, value: u64) noreturn {
    c.rb_raise(
        errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .corrupt_archive))],
        message,
        value,
    );
}

// --- uncompressed sizes and element counts --------------------------------

/// A byte count from the archive, as a Ruby string/array length.
pub fn checkedRubyLength(value: u64) ?c_long {
    return std.math.cast(c_long, value);
}

pub fn rubyLength(value: u64) c_long {
    return checkedRubyLength(value) orelse
        raiseCorrupt("archive declares an entry size of %llu bytes, which is out of range", value);
}

/// `zip_get_num_entries` reports `-1` for an invalid archive.
pub fn checkedEntryCount(value: c.zip_int64_t) ?c.zip_uint64_t {
    if (value < 0) return null;
    return @intCast(value);
}

pub fn entryCount(value: c.zip_int64_t) c.zip_uint64_t {
    return checkedEntryCount(value) orelse
        raiseCorrupt("archive reports an invalid entry count (%lld)", @bitCast(value));
}

/// `zip_name_locate` / `zip_file_add` report `-1` for failure. Calling code
/// checks for that and reports the libzip error; this is the last line of
/// defense keeping a negative value from becoming a huge unsigned index.
pub fn checkedEntryIndex(value: c.zip_int64_t) ?c.zip_uint64_t {
    if (value < 0) return null;
    return @intCast(value);
}

pub fn entryIndex(value: c.zip_int64_t) c.zip_uint64_t {
    return checkedEntryIndex(value) orelse
        raiseCorrupt("archive reports an invalid entry index (%lld)", @bitCast(value));
}

// --- comments -------------------------------------------------------------

/// Checked *before* truncating, so a length that would wrap to something
/// small can't slip past the maximum.
pub fn checkedCommentLength(value: c_long) ?c.zip_uint16_t {
    if (value < 0 or value > MAX_COMMENT_LENGTH) return null;
    return @intCast(value);
}

pub fn commentLength(value: c_long) c.zip_uint16_t {
    return checkedCommentLength(value) orelse {
        c.rb_raise(
            errors.error_class_registry[@backingInt(@as(errors.ErrorKind, .invalid_argument))],
            "comment is too long: maximum is %ld bytes",
            MAX_COMMENT_LENGTH,
        );
    };
}

/// A comment length libzip read out of the archive, as a Ruby string length.
pub fn checkedCommentBytes(value: c.zip_uint32_t) ?c_long {
    return std.math.cast(c_long, value);
}

pub fn commentBytes(value: c.zip_uint32_t) c_long {
    return checkedCommentBytes(value) orelse
        raiseCorrupt("archive declares a comment of %llu bytes, which is out of range", value);
}

// --- stream input ---------------------------------------------------------

/// The `n` in `read(n)`, once a negative value has been turned away.
pub fn checkedRequestLength(value: c_long) ?c.zip_uint64_t {
    if (value < 0) return null;
    return @intCast(value);
}

pub fn requestLength(value: c_long) c.zip_uint64_t {
    return checkedRequestLength(value) orelse {
        c.rb_raise(c.rb_eArgError, "negative length");
    };
}

/// `zip_fread` returns `-1` on error; calling code checks that first.
pub fn checkedReadAmount(value: c.zip_int64_t) ?c.zip_uint64_t {
    if (value < 0) return null;
    return @intCast(value);
}

pub fn readAmount(value: c.zip_int64_t) c.zip_uint64_t {
    return checkedReadAmount(value) orelse
        raiseCorrupt("read returned an invalid byte count (%lld)", @bitCast(value));
}

// --- tests ----------------------------------------------------------------

test "checkedRubyLength rejects sizes past the Ruby length limit" {
    try std.testing.expectEqual(@as(?c_long, 0), checkedRubyLength(0));
    try std.testing.expectEqual(@as(?c_long, 11), checkedRubyLength(11));
    try std.testing.expectEqual(
        @as(?c_long, std.math.maxInt(c_long)),
        checkedRubyLength(std.math.maxInt(c_long)),
    );
    // A crafted central directory can declare any 64-bit size it likes.
    try std.testing.expectEqual(@as(?c_long, null), checkedRubyLength(std.math.maxInt(u64)));
    try std.testing.expectEqual(
        @as(?c_long, null),
        checkedRubyLength(@as(u64, std.math.maxInt(c_long)) + 1),
    );
}

test "checkedEntryCount rejects the -1 libzip uses for failure" {
    try std.testing.expectEqual(@as(?c.zip_uint64_t, 0), checkedEntryCount(0));
    try std.testing.expectEqual(@as(?c.zip_uint64_t, 7), checkedEntryCount(7));
    try std.testing.expectEqual(@as(?c.zip_uint64_t, null), checkedEntryCount(-1));
    try std.testing.expectEqual(@as(?c.zip_uint64_t, null), checkedEntryCount(std.math.minInt(i64)));
}

test "checkedEntryIndex rejects negatives" {
    try std.testing.expectEqual(@as(?c.zip_uint64_t, 0), checkedEntryIndex(0));
    try std.testing.expectEqual(@as(?c.zip_uint64_t, null), checkedEntryIndex(-1));
}

test "checkedCommentLength bounds before it narrows" {
    try std.testing.expectEqual(@as(?c.zip_uint16_t, 0), checkedCommentLength(0));
    try std.testing.expectEqual(@as(?c.zip_uint16_t, 65_535), checkedCommentLength(65_535));
    try std.testing.expectEqual(@as(?c.zip_uint16_t, null), checkedCommentLength(65_536));
    try std.testing.expectEqual(@as(?c.zip_uint16_t, null), checkedCommentLength(-1));
    // The case the old ordering missed: a length with legal-looking low 16 bits.
    try std.testing.expectEqual(@as(?c.zip_uint16_t, null), checkedCommentLength(1 << 32));
    try std.testing.expectEqual(@as(?c.zip_uint16_t, null), checkedCommentLength((1 << 32) + 16));
}

test "checkedRequestLength rejects negatives" {
    try std.testing.expectEqual(@as(?c.zip_uint64_t, 0), checkedRequestLength(0));
    try std.testing.expectEqual(@as(?c.zip_uint64_t, 4096), checkedRequestLength(4096));
    try std.testing.expectEqual(@as(?c.zip_uint64_t, null), checkedRequestLength(-1));
}

test "checkedReadAmount rejects the -1 zip_fread uses for failure" {
    try std.testing.expectEqual(@as(?c.zip_uint64_t, 512), checkedReadAmount(512));
    try std.testing.expectEqual(@as(?c.zip_uint64_t, null), checkedReadAmount(-1));
}
