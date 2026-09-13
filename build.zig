const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    const rubyhdrdir = ruby_config(b, "rubyhdrdir") catch |err| {
        @panic(@errorName(err));
    };

    const rubyarchhdrdir = ruby_config(b, "rubyarchhdrdir") catch |err| {
        @panic(@errorName(err));
    };

    // Zig's translate-c preprocessor (aro) mishandles a directive line whose
    // only payload is a complete block comment (`# /* ... */`).  It swallows
    // the following line, which throws the `#if`/`#endif` stack out of balance
    // and makes ruby.h fail to translate.  Ruby's headers use that style a lot,
    // so translate against a copy with those lines removed.
    const headers = b.addWriteFiles();
    const hdr = sanitizeHeaders(b, headers, rubyhdrdir, "hdr");
    const archhdr = sanitizeHeaders(b, headers, rubyarchhdrdir, "archhdr");

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_c.addIncludePath(hdr);
    translate_c.addIncludePath(archhdr);
    translate_c.linkSystemLibrary("zip", .{});
    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const translate_c_module = translate_c.createModule();
    const mod = b.addModule("zip_ruby", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
        .imports = &.{.{
            .name = "c",
            .module = translate_c_module,
        }},
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const lib = b.addLibrary(.{
        .name = "zip_ruby",
        .root_module = mod,
        .linkage = .dynamic,
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(lib);

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .imports = &.{.{ .name = "c", .module = translate_c_module }},
    });

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const unit_tests = b.addTest(.{
        .root_module = tests_mod,
    });

    // A run step that will run the test executable.
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    const ruby_tests = b.addSystemCommand(&.{
        "ruby",
        "-I",
        "zig-out/lib",
        "-e",
        "Dir.glob('test/**/*_test.rb').each { |f| require File.expand_path(f) }",
    });

    ruby_tests.setCwd(b.path("."));
    ruby_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&ruby_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

/// Copy every header under `dir_path` into `wf` beneath `prefix`, dropping the
/// preprocessor lines that aro cannot handle.  Returns the include path.
fn sanitizeHeaders(
    b: *std.Build,
    wf: *std.Build.Step.WriteFile,
    dir_path: []const u8,
    prefix: []const u8,
) std.Build.LazyPath {
    const io = b.graph.io;

    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.panic("open {s}: {s}", .{ dir_path, @errorName(err) });
    };
    defer dir.close(io);

    var walker = dir.walk(b.allocator) catch |err| @panic(@errorName(err));
    defer walker.deinit();

    while (walker.next(io) catch |err| @panic(@errorName(err))) |entry| {
        if (entry.kind != .file) continue;

        const source = entry.dir.readFileAlloc(
            io,
            entry.basename,
            b.allocator,
            .limited(16 * 1024 * 1024),
        ) catch |err| std.debug.panic("read {s}: {s}", .{ entry.path, @errorName(err) });

        const dest = b.pathJoin(&.{ prefix, entry.path });
        _ = wf.add(dest, stripCommentOnlyDirectives(b.allocator, source));
    }

    return wf.getDirectory().path(b, prefix);
}

/// Remove lines of the form `# /* ... */` -- a null directive carrying nothing
/// but one complete block comment.  Every other line is kept verbatim, so line
/// counts shift but no code changes.
fn stripCommentOnlyDirectives(gpa: std.mem.Allocator, source: []const u8) []const u8 {
    var out = std.ArrayList(u8).initCapacity(gpa, source.len) catch @panic("OOM");

    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        if (!isCommentOnlyDirective(line)) {
            out.appendSlice(gpa, line) catch @panic("OOM");
        }
        out.append(gpa, '\n') catch @panic("OOM");
    }

    return out.items;
}

fn isCommentOnlyDirective(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] != '#') return false;

    const body = std.mem.trimStart(u8, trimmed[1..], " \t");
    if (!std.mem.startsWith(u8, body, "/*")) return false;

    // Block comments do not nest, so the first `*/` closes it.  Only drop the
    // line when that close is the end of the line; an unterminated comment
    // continues onto later lines and must be left alone.
    const end = std.mem.indexOf(u8, body[2..], "*/") orelse return false;
    return 2 + end + 2 == body.len;
}

fn ruby_config(b: *std.Build, key: []const u8) ![]const u8 {
    const result = try std.process.run(b.allocator, b.graph.io, .{ .argv = &.{
        "ruby",
        "-rrbconfig",
        "-e",
        "print RbConfig::CONFIG[ARGV[0]]",
        "--",
        key,
    } });
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                return error.RubyConfigFailed;
            }
        },
        else => return error.RubyConfigFailed,
    }

    const value = std.mem.trim(u8, result.stdout, " \t\r\n");

    if (value.len == 0) {
        return error.RubyConfigMissing;
    }

    return b.allocator.dupe(u8, value);
}
