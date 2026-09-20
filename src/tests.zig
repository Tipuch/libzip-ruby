test {
    _ = @import("errors.zig"); // forces analysis of errors.zig, pulling in its tests
    _ = @import("entry.zig");
    _ = @import("cast.zig");
}
