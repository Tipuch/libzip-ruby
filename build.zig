const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const rubyhdrdir = ruby_config(b, "rubyhdrdir") catch |err| {
        @panic(@errorName(err));
    };

    const rubyarchhdrdir = ruby_config(b, "rubyarchhdrdir") catch |err| {
        @panic(@errorName(err));
    };

    // Zig's translate-c preprocessor (aro) mishandles a null directive: a `#`
    // with no payload, or with a complete block comment as its only payload
    // (`# /* ... */`).  It eats the following line, which throws the
    // `#if`/`#endif` stack out of balance and makes ruby.h fail to translate.
    // Ruby's headers use both forms, so translate using a copy with those
    // lines removed.
    const headers = b.addWriteFiles();
    const hdr = sanitizeHeaders(b, headers, rubyhdrdir, "hdr");
    const archhdr = sanitizeHeaders(b, headers, rubyarchhdrdir, "archhdr");

    // Bundled libzip + zlib, fetched by the package manager and statically
    // digested into the extension, so the gem needs no runtime dependency.
    const zlib_dep = b.dependency("zlib", .{ .target = target, .optimize = optimize });
    const libzip_dep = b.dependency("libzip", .{ .target = target, .optimize = optimize });
    const mbedtls_dep = b.dependency("mbedtls", .{ .target = target, .optimize = optimize });

    const zlib_static = addZlib(b, zlib_dep, target, optimize);
    const mbedcrypto_static = mbedtls_dep.artifact("mbedtls");
    // Its objects end up inside libzip_ruby.so, like zlib's and libzip's, so
    // they must be PIC.  We set it here because the flag belongs to mbedTLS's
    // own build.zig, which doesn't: on a glibc target PIC is the default and
    // the omission is invisible, while a musl target defaults to non-PIC and
    // the link fails on thousands of absolute relocations.
    mbedcrypto_static.root_module.pic = true;
    const libzip_static = addLibZip(b, libzip_dep, zlib_dep, mbedtls_dep, zlib_static, mbedcrypto_static, target, optimize);

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // TranslateC keeps a separate include-path list (it isn't a Compile step, so
    // there is no `root_module` here); the paths are searched in call order.
    translate_c.addIncludePath(hdr);
    translate_c.addIncludePath(archhdr);
    // The zipconf.h/config.h we wrote must win over the dependency's copies,
    // and both must win over any system libzip: the headers c.h translates
    // with have to be the ones we statically link.  Note we do
    // NOT linkSystemLibrary("zip") any more.
    translate_c.addIncludePath(b.path("vendor/libzip"));
    translate_c.addIncludePath(libzip_dep.path("lib"));

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // addModule defines a module that we intend to make available for importing
    // to our consumers; consumers specify which one they want by name.
    const translate_c_module = translate_c.createModule();
    const mod = b.addModule("zip_ruby", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "c",
            .module = translate_c_module,
        }},
    });

    // libzip-ruby.gemspec defines the version: it's what `gem build` writes into
    // the .gem and what script/package tags a release with.  We read it once
    // here and hand it to Zig as a generated import, so LibZip::VERSION (see
    // src/root.zig) can't differ from it.
    const build_options = b.addOptions();
    build_options.addOption([:0]const u8, "version", gemVersion(b));
    mod.addOptions("build_options", build_options);

    const lib = b.addLibrary(.{
        .name = "zip_ruby",
        .root_module = mod,
        .linkage = .dynamic,
    });
    // Static libzip (and, through it, static zlib) - not the system one.  The
    // resulting .so must have no NEEDED entries besides libc/ld.
    lib.root_module.linkLibrary(libzip_static);

    if (target.result.os.tag == .macos) {
        // On Darwin a Ruby extension is a Mach-O bundle with rb_* references
        // are resolved when the interpreter dlopen()s it, which ld64 only
        // permits with `-undefined dynamic_lookup`.  Linux allows undefined
        // symbols in a shared object by default, hence the branch.
        lib.linker_allow_shlib_undefined = true;
    }

    // Installed into the prefix when running `zig build` (default `zig-out/`).
    b.installArtifact(lib);

    // The Zig tests don't link Ruby, on purpose: src/tests.zig only imports
    // the pure-logic modules, so the test binary needs no interpreter symbols.
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .imports = &.{.{ .name = "c", .module = translate_c_module }},
    });
    const unit_tests = b.addTest(.{ .root_module = tests_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);

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
}

/// zlib's sources, so libzip has no `-lz` to resolve at runtime.
const zlib_sources = [_][]const u8{
    "adler32.c",  "compress.c", "crc32.c",   "deflate.c", "gzclose.c",
    "gzlib.c",    "gzread.c",   "gzwrite.c", "inflate.c", "infback.c",
    "inftrees.c", "inffast.c",  "trees.c",   "uncompr.c", "zutil.c",
};

fn addZlib(
    b: *std.Build,
    dep: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // These objects end up inside libzip_ruby.so, so they must be PIC.
        .pic = true,
    });
    mod.addIncludePath(dep.path(""));
    mod.addCSourceFiles(.{
        .root = dep.path(""),
        .files = &zlib_sources,
        // zconf.h only defines Z_HAVE_UNISTD_H when HAVE_UNISTD_H is set, and
        // gz*.c call read()/write()/close() directly.  Without this they fail
        // with "call to undeclared function".
        // -fvisibility=hidden keeps adler32/crc32/inflate out of the dynamic
        // symbol table: they're private to this .so, not a zlib re-export.
        .flags = &.{ "-DHAVE_UNISTD_H=1", "-fvisibility=hidden" },
    });

    return b.addLibrary(.{ .name = "zlib", .linkage = .static, .root_module = mod });
}

/// libzip with AES support, but without bzip2/lzma/zstd.
/// All cryptographic operations are supplied by libzip and mbedcrypto.
fn addLibZip(
    b: *std.Build,
    dep: *std.Build.Dependency,
    zlib_dep: *std.Build.Dependency,
    mbedtls_dep: *std.Build.Dependency,
    zlib: *std.Build.Step.Compile,
    mbedcrypto: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });
    // vendor/libzip first: zipint.h includes "config.h" BEFORE "zip.h", and our
    // zipconf.h/config.h are the hand-resolved ones for this static build.
    mod.addIncludePath(b.path("vendor/libzip"));
    mod.addIncludePath(dep.path("lib"));
    mod.addIncludePath(mbedtls_dep.path("include"));
    mod.addCMacro("HAVE_CRYPTO", "1");
    mod.addCMacro("HAVE_MBEDTLS", "1");
    // libzip includes <zlib.h>.  On a native build clang will cheerfully find the
    // *system* one via the host include dirs; cross targets have no system
    // zlib, and linkLibrary() doesn't propagate include dirs to a dependent's
    // C compilation.  Point at the exact matching bundled header instead so
    // native and cross builds compile with the same zlib.
    mod.addIncludePath(zlib_dep.path(""));
    mod.addCSourceFiles(.{
        .root = dep.path("lib"),
        .files = &libzip_sources,
        // ZIP_STATIC only blanks ZIP_EXTERN; it does *not* hide the symbols
        // (upstream gets hidden visibility from CMake's C_VISIBILITY_PRESET).
        // Without this, our statically linked libzip exports ~180 symbols that
        // can be preempted by - or preempt - another gem's libzip.
        .flags = &.{"-fvisibility=hidden"},
    });

    // libzip's error strings live in zip_err_str.c, which is *generated* by
    // CMake (cmake/GenerateZipErrorStrings.cmake) and therefore missing from the
    // release tarball.  Without it the link fails on _zip_err_str /
    // _zip_err_details.  It's derived from the `/* <type> <description> */`
    // comments on ZIP_ER_* in zip.h and ZIP_ER_DETAIL_* in zipint.h, so we
    // regenerate it as a build step -- LazyPath.getPath() has been removed, so
    // dependency files can no longer be read at configure time.
    const gen = b.addExecutable(.{
        .name = "gen-zip-err-str",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/gen_zip_err_str.zig"),
            .target = b.graph.host, // host tool: never cross-compiled
            .optimize = .ReleaseSafe,
        }),
    });
    const run = b.addRunArtifact(gen);
    run.addFileArg(dep.path("lib/zip.h"));
    run.addFileArg(dep.path("lib/zipint.h"));
    const err_str = run.addOutputFileArg2("zip_err_str.c", .{ .make_absolute = true });
    mod.addCSourceFile(.{ .file = err_str, .flags = &.{"-fvisibility=hidden"} });

    mod.linkLibrary(zlib);
    mod.linkLibrary(mbedcrypto);

    return b.addLibrary(.{ .name = "zip", .linkage = .static, .root_module = mod });
}

/// From lib/CMakeLists.txt, with the 3 AES sources enabled.
/// Excluded: bzip2, lzma and zstd.
const libzip_sources = [_][]const u8{
    "zip_add.c",                          "zip_add_dir.c",                      "zip_add_entry.c",                  "zip_algorithm_deflate.c",             "zip_buffer.c",
    "zip_close.c",                        "zip_delete.c",                       "zip_dir_add.c",                    "zip_dirent.c",                        "zip_discard.c",
    "zip_entry.c",                        "zip_error.c",                        "zip_error_clear.c",                "zip_error_get.c",                     "zip_error_get_sys_type.c",
    "zip_error_strerror.c",               "zip_error_to_str.c",                 "zip_extra_field.c",                "zip_extra_field_api.c",               "zip_fclose.c",
    "zip_fdopen.c",                       "zip_file_add.c",                     "zip_file_error_clear.c",           "zip_file_error_get.c",                "zip_file_get_comment.c",
    "zip_file_get_external_attributes.c", "zip_file_get_offset.c",              "zip_file_rename.c",                "zip_file_replace.c",                  "zip_file_set_comment.c",
    "zip_file_set_encryption.c",          "zip_file_set_external_attributes.c", "zip_file_set_mtime.c",             "zip_file_strerror.c",                 "zip_fopen.c",
    "zip_fopen_encrypted.c",              "zip_fopen_index.c",                  "zip_fopen_index_encrypted.c",      "zip_fread.c",                         "zip_fseek.c",
    "zip_ftell.c",                        "zip_get_archive_comment.c",          "zip_get_archive_flag.c",           "zip_get_encryption_implementation.c", "zip_get_file_comment.c",
    "zip_get_name.c",                     "zip_get_num_entries.c",              "zip_get_num_files.c",              "zip_hash.c",                          "zip_io_util.c",
    "zip_libzip_version.c",               "zip_memdup.c",                       "zip_name_locate.c",                "zip_new.c",                           "zip_open.c",
    "zip_pkware.c",                       "zip_progress.c",                     "zip_random_unix.c",                "zip_realloc.c",                       "zip_rename.c",
    "zip_replace.c",                      "zip_set_archive_comment.c",          "zip_set_archive_flag.c",           "zip_set_default_password.c",          "zip_set_file_comment.c",
    "zip_set_file_compression.c",         "zip_set_name.c",                     "zip_source_accept_empty.c",        "zip_source_begin_write.c",            "zip_source_begin_write_cloning.c",
    "zip_source_buffer.c",                "zip_source_call.c",                  "zip_source_close.c",               "zip_source_commit_write.c",           "zip_source_compress.c",
    "zip_source_crc.c",                   "zip_source_error.c",                 "zip_source_file_common.c",         "zip_source_file_stdio.c",             "zip_source_file_stdio_named.c",
    "zip_source_free.c",                  "zip_source_function.c",              "zip_source_get_dostime.c",         "zip_source_get_file_attributes.c",    "zip_source_is_deleted.c",
    "zip_source_layered.c",               "zip_source_open.c",                  "zip_source_pass_to_lower_layer.c", "zip_source_pkware_decode.c",          "zip_source_pkware_encode.c",
    "zip_source_read.c",                  "zip_source_remove.c",                "zip_source_rollback_write.c",      "zip_source_seek.c",                   "zip_source_seek_write.c",
    "zip_source_stat.c",                  "zip_source_supports.c",              "zip_source_tell.c",                "zip_source_tell_write.c",             "zip_source_window.c",
    "zip_source_write.c",                 "zip_source_zip.c",                   "zip_source_zip_new.c",             "zip_stat.c",                          "zip_stat_index.c",
    "zip_stat_init.c",                    "zip_strerror.c",                     "zip_string.c",                     "zip_unchange.c",                      "zip_unchange_all.c",
    "zip_unchange_archive.c",             "zip_unchange_data.c",                "zip_utf-8.c",                      "zip_crypto_mbedtls.c",                "zip_winzip_aes.c",
    "zip_source_winzip_aes_decode.c",     "zip_source_winzip_aes_encode.c",
};

/// Copy each header under `dir_path` into `wf` beneath `prefix`, removing the
/// preprocessor lines that aro can't handle.  Returns the include path.
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
        _ = wf.add(dest, stripNullDirectives(b.allocator, source));
    }

    return wf.getDirectory().path(b, prefix);
}

/// Remove null directive lines -- a bare `#`, or a `#` whose only payload is
/// one complete block comment.  All other lines are kept as-is, so line
/// counts shift but no code changes.
fn stripNullDirectives(gpa: std.mem.Allocator, source: []const u8) []const u8 {
    var out = std.ArrayList(u8).initCapacity(gpa, source.len) catch @panic("OOM");

    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        if (!isNullDirective(line)) {
            out.appendSlice(gpa, line) catch @panic("OOM");
        }
        out.append(gpa, '\n') catch @panic("OOM");
    }

    return out.items;
}

fn isNullDirective(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] != '#') return false;

    const body = std.mem.trimStart(u8, trimmed[1..], " \t");
    if (body.len == 0) return true;
    if (!std.mem.startsWith(u8, body, "/*")) return false;

    // Block comments don't nest, so the first `*/` closes it.  Only remove the
    // line when that close is the end of the line; an unterminated comment
    // continues on later lines and must be left as it is.
    const end = std.mem.indexOf(u8, body[2..], "*/") orelse return false;
    return 2 + end + 2 == body.len;
}

// Ask RubyGems for the gemspec's version instead of searching the file: the
// gemspec is a Ruby program, and Gem::Specification.load is the only reader
// guaranteed to match what `gem build` uses.  `ruby` is already a build
// dependency (ruby_config below), so this adds no new requirement.
fn gemVersion(b: *std.Build) [:0]const u8 {
    const result = std.process.run(b.allocator, b.graph.io, .{ .argv = &.{
        "ruby",
        "-rrubygems",
        "-e",
        "print Gem::Specification.load(ARGV[0]).version",
        "--",
        b.root.joinString(b.graph.arena, "libzip-ruby.gemspec") catch @panic("OOM"),
    } }) catch |err| @panic(@errorName(err));
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        @panic("failed to read the version out of libzip-ruby.gemspec");
    }

    const version = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (version.len == 0) {
        @panic("libzip-ruby.gemspec has no version");
    }

    return b.allocator.dupeSentinel(u8, version, 0) catch @panic("OOM");
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
