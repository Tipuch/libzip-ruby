require "rbconfig"

# The entry point: `require "libzip"`.
#
# A precompiled gem ships one extension per Ruby ABI under
# lib/libzip_ruby/<abi>/, <abi> being the major.minor of the interpreter it was
# built for (an extension built for 4.0 loads on any 4.0.x).  In a source
# checkout that directory does not exist and we fall through to $LOAD_PATH,
# which `zig build`/`script/package` point at zig-out/lib.
abi = RbConfig::CONFIG["ruby_version"][/\A\d+\.\d+/]
precompiled = File.expand_path("libzip_ruby/#{abi}", __dir__)
$LOAD_PATH.unshift(precompiled) if File.directory?(precompiled)

require "libzip_ruby"

# Everything this gem defines lives under LibZip.  There is deliberately no
# top-level `Zip` constant: rubyzip owns that name, and defining a second, much
# smaller `Zip` would hijack any transitive `require "zip"` that resolves to us.
