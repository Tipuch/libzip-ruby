# libzip-ruby

Ruby bindings for [libzip](https://libzip.org), the C library for reading and
writing zip archives.

- **Nothing to compile.** libzip and zlib are statically linked into the
  extension and shipped precompiled per platform, so `gem install` never calls a
  C toolchain.
- **No runtime dependencies.** No system libzip, no zlib, no OpenSSL needed.
  The bundled libzip symbols are hidden, so it also coexists happily with a
  system libzip or with rubyzip.
- **Familiar shape.** `LibZip::File.open` / `#add` / `#get_output_stream` /
  `#read` - rubyzip's method names, under our own `LibZip` namespace.

Requires Ruby 3.3 or newer.

## Installation

### Bundler

```ruby
# Gemfile
gem "libzip-ruby"
```

```sh
bundle install
```

### RubyGems

```sh
gem install libzip-ruby
```

Precompiled extensions are published for these platforms:

| platform | notes |
| --- | --- |
| `x86_64-linux`, `aarch64-linux` | glibc |
| `x86_64-linux-musl`, `aarch64-linux-musl` | Alpine and other musl systems |
| `x86_64-darwin`, `arm64-darwin` | macOS, Intel and Apple silicon |

Each gem carries one extension per Ruby ABI (3.3, 3.4, 4.0) and picks the right
one at load time, so a single gem serves every patch release of those lines.

### Requiring

```ruby
require "libzip-ruby"  # ← what Bundler auto-requires; sets up everything
require "libzip_ruby"  # the bare extension: LibZip::*
require "libzip"       # the entry point: ABI loader + the extension
```

All three load the same extension, and everything they define lives under the
`LibZip` namespace: there is no top-level `Zip` constant. That is deliberate -
rubyzip already owns `Zip`, and we would rather not define a second, smaller
copy of it that a transitive `require "zip"` might pick up by accident.

> **If rubyzip is also in your bundle,** `require "zip"` is unambiguously rubyzip and
> `require "libzip"` is unambiguously this gem. The two coexist in one process.

## Quick start

Write an archive from a file on disk:

```ruby
require "libzip"

LibZip::File.open("archive.zip", create: true) do |zip|
  zip.add("hello.txt", "hello.txt")  # entry name, path on disk
end
```

Write an entry from memory:

```ruby
require "libzip"

LibZip::File.open("archive.zip", create: true) do |zip|
  zip.get_output_stream("greeting.txt") do |out|
    out.write("Hello, ")
    out << "world!\n"
    out << "written by libzip"
  end
end
```

Read an entry back:

```ruby
require "libzip"

zip = LibZip::File.open("archive.zip")
zip.read("greeting.txt")  #=> "Hello, world!\nwritten by libzip"
zip.close
```

Nothing here needs `unzip` to be installed — but the archives are ordinary zip
files, so `unzip -l archive.zip` sees exactly what you wrote.

## Working with `LibZip::File`

### Opening

```ruby
LibZip::File.open("archive.zip")                  # read an existing archive
LibZip::File.open("archive.zip", create: true)    # create it if it does not exist
```

`create: true` is a no-op when the file already exists (it does not truncate),
so it is safe to use whenever you intend to write. Opening a path that does not
exist without it raises `LibZip::NotFoundError`.

### Block form

Both `File.open` and `get_output_stream` take a block, and both have the same
two guarantees:

```ruby
result = LibZip::File.open("archive.zip", create: true) do |zip|
  zip.add("a.txt", "a.txt")
  :whatever_the_block_returns
end
result  #=> :whatever_the_block_returns
```

- On normal exit the archive is closed and **committed**; the block's value is
  returned from `open`.
- If the block raises, the archive is **discarded**: the half-written file is
  removed and the exception propagates. You never leave a truncated zip behind.

The same contract applies per entry with `get_output_stream`: if the block
raises, that entry is not added, while entries written earlier (and already
committed) stay.

```ruby
LibZip::File.open("archive.zip", create: true) do |zip|
  zip.get_output_stream("kept.txt") { |out| out.write("kept") }

  begin
    # partial.txt never lands in the archive; kept.txt still does
    zip.get_output_stream("dropped.txt") do |out|
      out.write("partial")
      raise "boom"
    end
  rescue RuntimeError
    # carry on
  end
end
```

### Manual `close`

Without a block you own the lifecycle:

```ruby
zip = LibZip::File.open("archive.zip", create: true)
zip.add("a.txt", "a.txt")
zip.closed?  #=> false
zip.close    # writes the central directory, flushes to disk
zip.closed?  #=> true
```

`close` on an already closed archive raises `LibZip::EntryError`, and using a
closed archive raises the same thing, so a double `close` is a loud bug rather
than a silent one.

### Adding entries

```ruby
zip.add(entry_name, source_path)
```

`add` reads `source_path` from disk when the archive is written, and returns the
archive, so calls chain:

```ruby
LibZip::File.open("archive.zip", create: true) do |zip|
  zip.add("a.txt", "a.txt").add("docs/b.txt", "b.txt")
end
```

The source must be a regular file: a missing path raises
`LibZip::NotFoundError`, a directory raises `LibZip::InvalidArgumentError`.

### Writing entries from memory

```ruby
zip = LibZip::File.open("archive.zip", create: true)
out = zip.get_output_stream("data.csv")
out.write("a,b,c\n")     #=> 6, the number of bytes written
out << "1,2,3\n"         #=> the stream, so it chains
out.close                #=> commits the entry
zip.close
```

A stream buffers in memory and is only added to the archive when it is closed
(or when its block returns), so a stream you never close, including one left to
the garbage collector is simply dropped.

### Reading entries

```ruby
zip.read("greeting.txt")
```

Returns the entry's bytes as an `ASCII-8BIT` string. Reading an entry that is not
in the archive raises `LibZip::NotFoundError`.

### Listing entries

Nothing is extracted and no entry bytes are read: every `LibZip::Entry` is a
snapshot taken straight out of the central directory.

```ruby
LibZip::File.open("archive.zip") do |zip|
  zip.names                     # => ["docs/", "docs/a.txt", "greeting.txt"]
  zip.size                      # => 3   (alias: #length)

  zip.entries                   # => [LibZip::Entry, ...]; fresh snapshot per call
  zip["docs/a.txt"]             # => the Entry, or nil    (alias: #find_entry)
  zip.get_entry("docs/a.txt")   # => the Entry, or raises LibZip::NotFoundError
  zip.include?("docs/a.txt")    # => true

  zip.each { |entry| ... }      # File includes Enumerable
  zip.map(&:name)
  zip.select(&:directory?)
end
```

What an entry knows:

```ruby
entry = zip["docs/a.txt"]
entry.name                 # => "docs/a.txt" (UTF-8)
entry.size                 # => 1234, uncompressed
entry.compressed_size      # => 456
entry.crc                  # => 4023222625
entry.time                 # => 2026-09-16 17:06:40 +0700   (alias: #mtime)
entry.compression_method   # => LibZip::Entry::DEFLATED (8) or #STORED (0)
entry.directory?           # => false
entry.encrypted?           # => false
entry.index                # => 1, the entry's position in the archive
entry.to_s                 # => "docs/a.txt"
```

Entries are snapshots, so their metadata stays readable after the archive is
closed; using the `File` itself afterwards raises `LibZip::EntryError`.

`#glob` matches entry names with `File.fnmatch?` semantics — `*` does not cross
a `/` — and directory entries match without the trailing slash they are stored
with:

```ruby
zip.glob("*.txt")     # => ["greeting.txt"]                 (not docs/notes.txt)
zip.glob("**/*.txt")  # => ["greeting.txt", "docs/notes.txt"]
zip.glob("docs")      # => the "docs/" entry itself
zip.glob("**/*.rb") { |entry| entry.name }   # also yields each match
```

Matching is case-sensitive on every platform, unlike `Dir.glob` on macOS.
`*`, `?`, `[...]` and `{a,b}` all work; `**` matches zero or more directories.

### Deleting entries

```ruby
removed = zip.remove("old.txt")
removed = zip.remove(entry)          # an Entry works too
removed.name                          # => "old.txt"
removed.size                          # still readable after zip.close
```

`remove` returns the entry that went away — a snapshot taken before the
deletion, so its metadata stays readable afterwards. If the name is not in the
archive it raises `LibZip::NotFoundError`, and so does a second `remove` of the
same name. There is no third outcome: you get the entry back, or you get an
exception.

Like `add`, removal is marked immediately and written when the archive is
closed — closing commits, there is no `discard`. Inside the block form, a block
that raises leaves the archive on disk untouched. Removing the only remaining
entry leaves an empty archive, and libzip refuses to write those: the file is
removed from disk instead of being rewritten with an empty directory.

### Overwriting

`add` and `get_output_stream` both pass `ZIP_FL_OVERWRITE`, so writing the same
entry name twice replaces the first copy instead of raising
`LibZip::AlreadyExistsError`. That is what makes the "drop a file into an
existing archive" pattern above work.

## Errors

Everything libzip reports is a `LibZip::Error` (a `StandardError`), mapped onto a
subclass by what went wrong, so you can rescue precisely:

| class | raised for |
| --- | --- |
| `LibZip::Error` | base class; also used for codes with no better home |
| `LibZip::IoError` | read/write/seek/EOF/open failures on the underlying files |
| `LibZip::ReadError`, `LibZip::WriteError` | a failed read or write of archive data |
| `LibZip::NotFoundError` | no such archive, entry or source file |
| `LibZip::AlreadyExistsError` | an entry that exists where it must not |
| `LibZip::CorruptArchiveError` | not a zip, truncated, inconsistent, multi-disk |
| `LibZip::CompressionError`, `LibZip::DecompressionError` | unsupported method, CRC mismatch |
| `LibZip::InvalidArgumentError` | bad argument, e.g. a directory as a source |
| `LibZip::PermissionError` | read-only archive or disallowed operation |
| `LibZip::PasswordError` | password missing or wrong |
| `LibZip::EntryError` | an entry used after the archive closed, or a stale entry |
| `LibZip::UnsupportedError` | operation or encryption method libzip cannot do |
| `LibZip::InternalError` | libzip/zlib internal failure, out of memory |

```ruby
begin
  LibZip::File.open("archive.zip") { |zip| zip.read("nope.txt") }
rescue LibZip::NotFoundError => e
  warn "missing entry: #{e.message}"
rescue LibZip::Error => e
  warn "libzip said: #{e.message}"
end
```

## What is not here yet

This is an early release (`LibZip::VERSION` is `0.1.0`). The write path and
entry listing are in place:

- no delete, rename or comment handling
- no encryption (reading or writing password-protected entries)
- reads are buffered whole-entry, not streamed (`zip_fread` in a loop is not
  exposed yet)

The pieces above are the roadmap; the API for them will follow the shapes
already established here.

## Under the hood

- libzip 1.11.4 and zlib are pinned in `build.zig.zon` and compiled into a
  single shared object per platform; only libc remains a runtime dependency.
- The build is pure Zig (`build.zig`), including the small host program that
  regenerates libzip's error strings from its headers.
- `script/package` builds the platform gems; `.github/workflows/package.yml`
  drives it in CI.

To hack on it:

```sh
mise install           # Zig 0.17-dev and Ruby, per mise.toml
zig build              # builds zig-out/lib/libzip_ruby.so
zig build test         # Zig unit tests + the minitest suite
script/package list    # platform matrix, and what this host can build
```

## License

MIT.
