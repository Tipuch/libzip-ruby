# libzip-ruby

Ruby bindings for [libzip](https://libzip.org), the C library for reading and
writing zip archives.

- **No compile step.** libzip and zlib are statically linked into the
  extension and published precompiled per platform, so `gem install` calls no
  C toolchain.
- **No runtime dependencies.** No system libzip, no zlib, no OpenSSL needed. .
- **Familiar surface.** `LibZip::File.open` / `#add` / `#get_output_stream` /
  `#read`.
- **Encryption included.** AES-128/192/256 reading and writing, plus read-only
  ZipCrypto, with the crypto performed by a statically linked mbedTLS.

Requires Ruby 3.3 or newer.

Full API documentation: <https://tipuch.github.io/libzip-ruby/>, or `ri
LibZip::File` once the gem is installed.

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

No `unzip` installation is needed here. The archives are plain zip
files, so `unzip -l archive.zip` shows the exact bytes you wrote.

## Working with `LibZip::File`

### Opening

```ruby
LibZip::File.open("archive.zip")                  # read an existing archive
LibZip::File.open("archive.zip", create: true)    # create it if it does not exist
```

`create: true` has no effect when the file already exists (it doesn't truncate),
so it's safe to use whenever you intend to write. Opening a path that doesn't
exist without it gives `LibZip::NotFoundError`.

### Block form

Both `File.open` and `get_output_stream` take a block, and both have the same
2 guarantees:

```ruby
result = LibZip::File.open("archive.zip", create: true) do |zip|
  zip.add("a.txt", "a.txt")
  :whatever_the_block_returns
end
result  #=> :whatever_the_block_returns
```

- On normal exit the archive is closed and **committed**; the block's value is
  returned from `open`.
- If the block fails, the archive is **thrown away**: the half-written file is
  removed and the exception propagates. No truncated zip is left behind.

The same contract applies per entry with `get_output_stream`: if the block
fails, that entry isn't added, while entries written earlier (and already
committed) remain.

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

Without a block you control the lifecycle:

```ruby
zip = LibZip::File.open("archive.zip", create: true)
zip.add("a.txt", "a.txt")
zip.closed?  #=> false
zip.close    # writes the central directory, flushes to disk
zip.closed?  #=> true
```

`close` on an already closed archive gives `LibZip::EntryError`, and using a
closed archive gives the same thing, so a double `close` is a visible bug, not
a quiet one.

### Adding entries

```ruby
zip.add(entry_name, source_path)
```

`add` loads `source_path` from disk when the archive is written, and returns the
archive, so calls chain:

```ruby
LibZip::File.open("archive.zip", create: true) do |zip|
  zip.add("a.txt", "a.txt").add("docs/b.txt", "b.txt")
end
```

The source must be a regular file: a missing path gives
`LibZip::NotFoundError`, a directory gives `LibZip::InvalidArgumentError`.

### Writing entries from memory

```ruby
zip = LibZip::File.open("archive.zip", create: true)
out = zip.get_output_stream("data.csv")
out.write("a,b,c\n")     #=> 6, the number of bytes written
out << "1,2,3\n"         #=> the stream, so it chains
out.close                #=> commits the entry
zip.close
```

A stream buffers in memory and is only added to the archive when it's closed
(or when the block returns), so a stream you leave open, including one passed to
the garbage collector, is thrown away.

### Reading entries

```ruby
zip.read("greeting.txt")
```

Returns the entry's bytes as an `ASCII-8BIT` string. Reading an entry that isn't
in the archive gives `LibZip::NotFoundError`.

### Listing entries

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

What an entry records:

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

Entries are snapshots, so their metadata remains readable after the archive is
closed; using the `File` after that gives `LibZip::EntryError`.

`#glob` matches entry names with `File.fnmatch?` semantics; `*` doesn't cross
a `/`, and directory entries match without the trailing slash they're stored
with:

```ruby
zip.glob("*.txt")     # => ["greeting.txt"]                 (not docs/notes.txt)
zip.glob("**/*.txt")  # => ["greeting.txt", "docs/notes.txt"]
zip.glob("docs")      # => the "docs/" entry itself
zip.glob("**/*.rb") { |entry| entry.name }   # also yields each match
```

Matching is case-sensitive on each platform, unlike `Dir.glob` on macOS.
`*`, `?`, `[...]` and `{a,b}` all work; `**` matches zero or more directories.

### Deleting entries

```ruby
removed = zip.remove("old.txt")
removed = zip.remove(entry)          # an Entry works too
removed.name                          # => "old.txt"
removed.size                          # still readable after zip.close
```

`remove` returns the entry it deleted, a snapshot taken before the
deletion, so the metadata remains readable after that. If the name isn't in the
archive you get `LibZip::NotFoundError`, and so does a second `remove` of the
same name. There is no other outcome: you get the entry back, or you get an
exception.

Like `add`, removal is marked immediately and written when the archive is
closed; closing commits, and there's no `discard`. Inside the block form, a block
that fails keeps the archive on disk as it was. Removing the only remaining
entry would produce an empty archive, and libzip won't write those: the file is
removed from disk instead of being written again with an empty directory.

### Renaming entries

```ruby
renamed = zip.rename("draft.txt", "final.txt")
renamed = zip.rename(entry, "final.txt")     # an Entry works too
renamed.name                                  # => "final.txt"
renamed.size                                  # metadata comes along
```

`rename` returns the entry as it is after the rename, a snapshot like the one
`remove` gives you, so it remains readable once the archive is closed. Size,
CRC, time and compression are preserved; only the name changes.

Renaming moves 1 record, not a subtree: the children of a directory entry keep
the names they were stored with, whatever the directory is called after that.

A missing `old_name` gives `LibZip::NotFoundError`, and a `new_name` that's
already taken gives `LibZip::AlreadyExistsError`. Directory has to match at
both ends (a directory entry keeps its trailing `/`).

### Overwriting

`add` and `get_output_stream` both pass `ZIP_FL_OVERWRITE`, so writing the same
entry name a second time replaces the first copy instead of raising
`LibZip::AlreadyExistsError`.

## Comments

A zip file has room for 1 comment on the archive and 1 on each entry.

```ruby
LibZip::File.open("archive.zip", create: true) do |zip|
  zip.add("a.txt", "a.txt")

  zip.comment = "built by the nightly job"
  zip.set_comment("a.txt", "the important one")
end

LibZip::File.open("archive.zip") do |zip|
  zip.comment              # => "built by the nightly job"
  zip["a.txt"].comment     # => "the important one"
end
```

Both are written when the archive is closed. `nil` clears a comment, and a
missing comment comes back as `nil`, not as `""`.

The zip format gives the field 16 bits, so a comment longer than 65535 bytes
gives `LibZip::InvalidArgumentError`. Entry comments come back through
`Entry#comment`, and like the rest of an entry's metadata they're a snapshot:
still readable after the archive is closed.

## Reading entries as a stream

`read` loads the entire entry into a String. `get_input_stream` gives you the
entry as a stream instead, so memory remains flat no matter how big the entry is:

```ruby
LibZip::File.open("archive.zip") do |zip|
  stream = zip.get_input_stream("big.csv")

  stream.read          # => the rest of the entry, as a String
  stream.read(1024)    # => at most 1024 bytes
  stream.eof?          # => true once the entry is exhausted
  stream.closed?       # => true after #close, or after the archive closed
  stream.close         # frees the entry handle; idempotent
end
```

The block form closes the stream on the way out, including when the block fails:

```ruby
LibZip::File.open("archive.zip") do |zip|
  zip.get_input_stream("big.csv") do |stream|
    stream.read(64 * 1024) until stream.eof?
  end
end
```

## Encryption

libzip takes care of the cryptography. AES-128, AES-192 and AES-256 are supported for reading and writing.
Traditional ZipCrypto is supported for reading, and reading only.

**Writing.** Pass `encryption:` (and optionally `password:`) to `add` or
`get_output_stream`:

```ruby
LibZip::File.open("secrets.zip", create: true) do |zip|
  zip.add("notes.txt", "notes.txt", encryption: :aes256, password: "hunter2")

  zip.get_output_stream("todo.txt", encryption: :aes128) do |out|
    out.write("buy milk")
  end
end
```

Accepted values are `:aes128`, `:aes192`, `:aes256`, `:none` and `nil`.
`:pkware` is turned off for writing: libzip documents ZipCrypto as deprecated.

**Reading.** The password can come from the archive, from the call, or from
`File#password=`:

```ruby
# archive default: every read falls back to it
LibZip::File.open("secrets.zip", password: "hunter2") do |zip|
  zip.read("notes.txt")
  zip.read("todo.txt")
end

# per call, overriding the default
LibZip::File.open("secrets.zip") do |zip|
  zip.read("notes.txt", password: "hunter2")
  zip.get_input_stream("notes.txt", password: "hunter2") { |s| s.read }
end

# set it after opening
LibZip::File.open("secrets.zip") do |zip|
  zip.password = "hunter2"     # no getter: passwords are not readable back
  zip.read("notes.txt")
end
```

An explicit `password:` overrides the archive default, so a bad password on
the call fails even when the archive was opened with the right one.

- Encryption is **per entry**. One archive can mix plain, AES-128 and ZipCrypto
  entries, each with a separate password; `File.open(password:)` only sets a
  default that each read falls back to.
- `nil` or `""` means "use the archive default"; it doesn't mean "empty
  password".
- A password without `encryption:` on a write gives
  `LibZip::InvalidArgumentError`, as does encrypting with no password at all
  (not per entry, not as an archive default).
- Missing or incorrect passwords give `LibZip::PasswordError` when the entry is
  read, not when the archive is opened.
- **Names, comments and the central directory remain unencrypted.** Zip
  encryption protects entry contents only; anyone can list what is inside.
- AES entries use AE-2, which stores no CRC, so the HMAC is the only integrity
  check for them and `Entry#crc` may be `0`. Tampering surfaces as
  `LibZip::DecompressionError` when the entry is read to the end.
- Crypto is using mbedTLS 3.6, statically linked like libzip and zlib.

## API reference

`LibZip::File`: the archive.

| method | notes |
| --- | --- |
| `File.open(path, create: false, password: nil) { \|zip\| }` | block form closes the archive |
| `#close`, `#closed?` | closes live input streams first |
| `#password=` | archive default password; `nil` clears it |
| `#read(name, password: nil)` | entire entry, as a String |
| `#get_input_stream(name, password: nil) { \|stream\| }` | streamed read |
| `#add(name, source_path, encryption: nil, password: nil)` | copies a file from disk |
| `#get_output_stream(name, encryption: nil, password: nil) { \|out\| }` | writes from memory |
| `#remove(name)` | deletes an entry |
| `#rename(old_name, new_name)` | renames an entry |
| `#comment`, `#comment=` | archive comment |
| `#set_comment(name, comment)` | per-entry comment |
| `#entries`, `#each`, `#each_entry` | snapshots of the central directory |
| `#names`, `#size`, `#length` | entry names, entry count |
| `#include?`, `#find_entry`, `#[]` | lookup, `nil` when missing |
| `#get_entry(name)` | lookup; a missing entry → `LibZip::NotFoundError` |
| `#glob(pattern)` | entries with a name matching a pattern |

`LibZip::Entry`: one central-directory record.

| method | notes |
| --- | --- |
| `#name`, `#index` | UTF-8 name, index in the archive |
| `#size`, `#compressed_size`, `#crc` | uncompressed size, compressed size, CRC-32 |
| `#time`, `#mtime` | modification time |
| `#compression_method` | `Entry::STORED` or `Entry::DEFLATED` |
| `#encryption_method` | libzip's numeric method (see constants below) |
| `#encrypted?` | `encryption_method != Entry::NONE` |
| `#directory?` | entry is a directory |
| `#comment`, `#to_s`, `#inspect` | per-entry comment and formatting |

Each accessor above except `#name`, `#index` and `#directory?` returns `nil`
when the archive did not record that field. `#encrypted?` returns `false` in that case.

`LibZip::Entry` also defines the numeric encryption constants, so metadata can
be checked without guesswork: `NONE`, `TRAD_PKWARE`, `AES_128`, `AES_192`,
`AES_256`.

`LibZip::InputStream`: `#read([length])`, `#eof?`, `#closed?`, `#close`.

`LibZip::OutputStream`: `#write(string)`, `#<<(string)`, `#close`.

## Errors

Everything libzip reports is a `LibZip::Error` (a `StandardError`), mapped to a
subclass by the kind of failure, so you can rescue narrowly:

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
| `LibZip::PasswordError` | password missing or incorrect |
| `LibZip::EntryError` | an entry used after the archive closed, or a stale entry |
| `LibZip::UnsupportedError` | operation or encryption method libzip can't do |
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

## Under the hood

- libzip 1.11.4, zlib 1.3.2 and mbedTLS 3.6 are pinned in `build.zig.zon` and
  compiled into a single shared object per platform; only libc (and libm)
  remains a runtime dependency.
- The build is Zig only (`build.zig`), including the small host program that
  regenerates libzip's error strings from the libzip headers.
- `script/package` builds the platform gems; `.github/workflows/package.yml`
  runs it in CI.

To contribute to the project:

```sh
mise install           # Zig 0.17-dev and Ruby, per mise.toml
zig build              # builds zig-out/lib/libzip_ruby.so
zig build test         # Zig unit tests + the minitest suite
script/doc             # API docs into doc/html
script/doc --check     # doc/api.rb vs. the built extension
script/package list    # platform matrix, and what this host can build
```

The API reference is written out by hand in `doc/api.rb`.

## License

Apache License 2.0. The full text is in `LICENSE`.

The extension links 3 libraries statically, so their terms travel with the
gem:

- libzip 1.11.4 is BSD 3-Clause.
- zlib 1.3.2 is the zlib license.
- mbedTLS 3.6.6 is Apache-2.0.
