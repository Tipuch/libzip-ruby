const std = @import("std");
const c = @import("c");

pub const Entry = struct {
    archive_rb: c.VALUE,
    index: c.zip_uint64_t,
    name_rb: c.VALUE,
    comment_rb: c.VALUE,
    valid: c.zip_uint64_t,
    size: c.zip_uint64_t,
    comp_size: c.zip_uint64_t,
    crc: c.zip_uint32_t,
    mtime: c.time_t,
    comp_method: c.zip_uint16_t,
    encryption_method: c.zip_uint16_t,
    is_dir: bool,
};

const OPSYS_FAT: c.zip_uint8_t = 0;
const OPSYS_UNIX: c.zip_uint8_t = 3;

const S_IFMT: c.zip_uint32_t = 0o170000;
const S_IFDIR: c.zip_uint32_t = 0o040000;
const DOS_ATTR_DIRECTORY: c.zip_uint32_t = 0x10;

pub var entry_class: c.VALUE = undefined;
const entry_type: c.rb_data_type_t = .{
    .wrap_struct_name = "LibZip::Entry",
    .function = .{ .dmark = @ptrCast(&markEntry), .dfree = @ptrCast(&freeEntry), .dsize = null },
    .data = null,
    .flags = c.RUBY_TYPED_FREE_IMMEDIATELY,
};

fn getEntry(self: c.VALUE) *Entry {
    return @ptrCast(@alignCast(c.rb_check_typeddata(self, &entry_type)));
}

fn markEntry(raw: ?*anyopaque) callconv(.c) void {
    const entry: *Entry = @ptrCast(@alignCast(raw.?));
    c.rb_gc_mark(entry.archive_rb);
    c.rb_gc_mark(entry.name_rb);
    c.rb_gc_mark(entry.comment_rb);
}

fn freeEntry(raw: ?*anyopaque) callconv(.c) void {
    c.ruby_xfree(raw.?);
}

pub fn createEntry(archive_rb: c.VALUE, index: c.zip_uint64_t, stat: *const c.zip_stat_t, is_dir: bool) c.VALUE {
    const name: [*:0]const u8 = stat.name orelse "";
    const entry: *Entry = @ptrCast(@alignCast(c.ruby_xmalloc(@sizeOf(Entry))));
    entry.* = .{
        .archive_rb = archive_rb,
        .index = index,
        .name_rb = c.rb_utf8_str_new_cstr(name),
        .valid = stat.valid,
        .comment_rb = c.Qnil,
        .size = stat.size,
        .comp_size = stat.comp_size,
        .crc = stat.crc,
        .mtime = stat.mtime,
        .comp_method = stat.comp_method,
        .encryption_method = stat.encryption_method,
        .is_dir = is_dir,
    };
    return c.TypedData_Wrap_Struct(entry_class, &entry_type, entry);
}

pub fn nameIsDirectory(name: []const u8) bool {
    return name.len > 0 and name[name.len - 1] == '/';
}

pub fn attributesAreDirectory(opsys: c.zip_uint8_t, attributes: c.zip_uint32_t) bool {
    return switch (opsys) {
        OPSYS_UNIX => (attributes >> 16) & S_IFMT == S_IFDIR,
        OPSYS_FAT => (attributes & DOS_ATTR_DIRECTORY) != 0,
        else => false,
    };
}

pub fn defineClass(libzip: c.VALUE) void {
    entry_class = c.rb_define_class_under(libzip, "Entry", c.rb_cObject);
    c.rb_undef_alloc_func(entry_class);

    c.rb_define_const(entry_class, "STORED", c.INT2NUM(c.ZIP_CM_STORE));
    c.rb_define_const(entry_class, "DEFLATED", c.INT2NUM(c.ZIP_CM_DEFLATE));

    c.rb_define_method(entry_class, "name", @ptrCast(&entryName), 0);
    c.rb_define_method(entry_class, "index", @ptrCast(&entryIndex), 0);
    c.rb_define_method(entry_class, "size", @ptrCast(&entrySize), 0);
    c.rb_define_method(entry_class, "compressed_size", @ptrCast(&entryCompressedSize), 0);
    c.rb_define_method(entry_class, "crc", @ptrCast(&entryCrc), 0);
    c.rb_define_method(entry_class, "time", @ptrCast(&entryTime), 0);
    c.rb_define_method(entry_class, "mtime", @ptrCast(&entryTime), 0);
    c.rb_define_method(entry_class, "compression_method", @ptrCast(&entryCompressionMethod), 0);
    c.rb_define_method(entry_class, "encryption_method", @ptrCast(&entryEncryptionMethod), 0);
    c.rb_define_method(entry_class, "encrypted?", @ptrCast(&entryEncrypted), 0);
    c.rb_define_method(entry_class, "directory?", @ptrCast(&entryDirectory), 0);
    c.rb_define_method(entry_class, "to_s", @ptrCast(&entryToS), 0);
    c.rb_define_method(entry_class, "inspect", @ptrCast(&inspectEntry), 0);
}

fn entryName(self: c.VALUE) callconv(.c) c.VALUE {
    return getEntry(self).name_rb;
}
fn entryIndex(self: c.VALUE) callconv(.c) c.VALUE {
    return c.ULL2NUM(getEntry(self).index);
}
fn entrySize(self: c.VALUE) callconv(.c) c.VALUE {
    return c.ULL2NUM(getEntry(self).size);
}
fn entryCompressedSize(self: c.VALUE) callconv(.c) c.VALUE {
    return c.ULL2NUM(getEntry(self).comp_size);
}
fn entryCrc(self: c.VALUE) callconv(.c) c.VALUE {
    const entry = getEntry(self);

    if (entry.valid & c.ZIP_STAT_CRC == 0) return c.Qnil;
    return c.UINT2NUM(getEntry(self).crc);
}

fn entryTime(self: c.VALUE) callconv(.c) c.VALUE {
    return c.rb_funcall(c.rb_cTime, c.rb_intern("at"), 1, c.TIMET2NUM(getEntry(self).mtime));
}

fn entryCompressionMethod(self: c.VALUE) callconv(.c) c.VALUE {
    const entry = getEntry(self);
    const method: c_int = if (entry.is_dir) c.ZIP_CM_STORE else entry.comp_method;
    return c.INT2NUM(method);
}

fn entryEncryptionMethod(self: c.VALUE) callconv(.c) c.VALUE {
    return c.UINT2NUM(getEntry(self).encryption_method);
}

fn entryEncrypted(self: c.VALUE) callconv(.c) c.VALUE {
    return if (getEntry(self).encryption_method != 0) c.Qtrue else c.Qfalse;
}

fn entryDirectory(self: c.VALUE) callconv(.c) c.VALUE {
    return if (getEntry(self).is_dir) c.Qtrue else c.Qfalse;
}

fn entryToS(self: c.VALUE) callconv(.c) c.VALUE {
    return getEntry(self).name_rb;
}

fn inspectEntry(self: c.VALUE) callconv(.c) c.VALUE {
    const entry = getEntry(self);
    return c.rb_sprintf("#<LibZip::Entry name=%s size=%llu>", c.RSTRING_PTR(c.rb_inspect(entry.name_rb)), entry.size);
}

fn unixMode(mode: u32) c.zip_uint32_t {
    return @as(c.zip_uint32_t, mode) << 16;
}

test "nameIsDirectory: only a trailing slash counts" {
    try std.testing.expect(nameIsDirectory("docs/"));
    try std.testing.expect(nameIsDirectory("a/b/c/"));
    try std.testing.expect(nameIsDirectory("/"));
    try std.testing.expect(nameIsDirectory("a dir with spaces/"));

    try std.testing.expect(!nameIsDirectory("docs"));
    try std.testing.expect(!nameIsDirectory("a/b/c"));
    try std.testing.expect(!nameIsDirectory("docs/.."));
    try std.testing.expect(!nameIsDirectory("a\\b")); // backslash is not a separator
}

test "nameIsDirectory: empty name does not panic" {
    // libzip hands us a NULL name for a slot we can't read; createEntry turns
    // that into "". name[name.len - 1] must not index out of bounds.
    try std.testing.expect(!nameIsDirectory(""));
}

test "attributesAreDirectory: UNIX reads the st_mode from the high bits" {
    const os = OPSYS_UNIX;
    try std.testing.expect(attributesAreDirectory(os, unixMode(0o040755))); // directory
    try std.testing.expect(!attributesAreDirectory(os, unixMode(0o100644))); // regular file
    try std.testing.expect(!attributesAreDirectory(os, unixMode(0o120777))); // symlink
    try std.testing.expect(!attributesAreDirectory(os, 0)); // creator stored no mode
    // The DOS bit means nothing when opsys says UNIX.
    try std.testing.expect(!attributesAreDirectory(os, DOS_ATTR_DIRECTORY));
}

test "attributesAreDirectory: MS-DOS reads the low attribute byte" {
    const os = OPSYS_FAT;
    try std.testing.expect(attributesAreDirectory(os, DOS_ATTR_DIRECTORY));
    try std.testing.expect(attributesAreDirectory(os, DOS_ATTR_DIRECTORY | 0x01)); // dir + read-only
    try std.testing.expect(!attributesAreDirectory(os, 0x20)); // archive bit: a file
    try std.testing.expect(!attributesAreDirectory(os, 0));
    // A UNIX mode written by a DOS creator must not be read as a mode.
    try std.testing.expect(!attributesAreDirectory(os, unixMode(0o040755)));
}

test "attributesAreDirectory: no guessing for other creator OSes" {
    const macos: c.zip_uint8_t = 19; // OS X
    const mac_classic: c.zip_uint8_t = 7; // Macintosh
    try std.testing.expect(!attributesAreDirectory(macos, unixMode(0o040755)));
    try std.testing.expect(!attributesAreDirectory(mac_classic, DOS_ATTR_DIRECTORY));
    try std.testing.expect(!attributesAreDirectory(255, unixMode(0o040755)));
}
