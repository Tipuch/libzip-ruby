# doc/api.rb - the API reference, and only that.
#
# The extension is written in Zig (src/*.zig). RDoc can read a C extension but
# not a Zig one, so the Ruby surface is written out here: each body is empty,
# and the working code is whatever rb_define_method points at.
#
# This file is outside lib/, off the $LOAD_PATH, so it can't be required by
# mistake; loading it would shadow the extension with empty methods. It goes
# into the gem (spec.extra_rdoc_files) so that `ri LibZip::File` works from an
# installed gem, and `script/doc --check` compares it with the loaded
# extension, so the 2 can't fall out of step.

# Ruby bindings for libzip[https://libzip.org], with libzip, zlib and mbedTLS
# linked into the extension.
#
#   require "libzip"
#
#   LibZip::File.open("archive.zip", create: true) do |zip|
#     zip.add("hello.txt", "hello.txt")
#   end
#
# Start at LibZip::File. A listing gives LibZip::Entry snapshots,
# LibZip::InputStream and LibZip::OutputStream move entry bytes in and out, and
# anything that fails is a LibZip::Error.
module LibZip
  # The gem version, written into the extension at build time from
  # libzip-ruby.gemspec.
  VERSION = "0.1.0"

  # A zip archive, open for reading, writing, or both.
  #
  # An archive is a transaction: entries added, removed and renamed are noted
  # as you go, and #close writes them to disk. The block form of ::open commits
  # on normal exit and throws the archive away if the block fails, so a failed
  # write can't leave a truncated zip behind.
  #
  #   LibZip::File.open("archive.zip", create: true) do |zip|
  #     zip.add("a.txt", "a.txt")
  #     zip.get_output_stream("b.txt") { |out| out.write("from memory") }
  #   end
  #
  #   LibZip::File.open("archive.zip") do |zip|
  #     zip.names                 # => ["a.txt", "b.txt"]
  #     zip.read("b.txt")         # => "from memory"
  #   end
  #
  # File includes Enumerable over its LibZip::Entry records, so #map, #select
  # and the rest work on a listing.
  #
  # Once the archive is closed, all of these fail with LibZip::EntryError.
  class File
    include Enumerable

    # Opens the archive at +path+.
    #
    # With +create+ the archive is created when +path+ doesn't exist; an
    # existing file is opened as it is and isn't truncated, so +create+ is safe
    # to pass whenever you intend to write. Without it, a missing +path+ fails
    # with LibZip::NotFoundError.
    #
    # +password+ becomes the archive default: the password each read of an
    # encrypted entry falls back to. See #password=, and the call-level
    # +password+ of #read and #get_input_stream.
    #
    # Without a block you get the archive and you call #close yourself. With a
    # block the archive is yielded; on normal exit it's closed and committed
    # and the block's value comes back from ::open. If the block fails, the
    # archive is thrown away: no bytes are written, and an archive that ::open
    # had just created is removed from disk.
    #
    #   LibZip::File.open("archive.zip")                 # read
    #   LibZip::File.open("archive.zip", create: true)   # read and write
    #   LibZip::File.open("secrets.zip", password: "hunter2") { |zip| ... }
    #
    # A 2nd argument that isn't a Hash is a TypeError.
    def self.open(path, create: false, password: nil) # :yields: zip
    end

    # Writes the central directory, flushes the archive to disk, and releases
    # it. Live input streams on this archive are closed first.
    #
    # Returns +nil+. Closing an already closed archive fails with
    # LibZip::EntryError, so a double #close is a visible bug.
    #
    # An archive that was created and then not written to produces no file:
    # libzip won't write an empty archive, and removing the last remaining
    # entry deletes the file instead.
    def close
    end

    # Whether the archive has been closed.
    def closed?
    end

    # Adds +source_path+ from disk as the entry +name+, and returns +self+, so
    # calls chain.
    #
    #   zip.add("a.txt", "a.txt").add("docs/b.txt", "b.txt")
    #
    # The file is read when the archive is written, not now, so a source that
    # disappears, or that can't be read any more, shows up as an error from
    # #close. An entry of the same name is replaced.
    #
    # +encryption+ is one of +:aes128+, +:aes192+, +:aes256+, +:none+ or +nil+,
    # and needs a +password+, either here or as the archive default. +:pkware+
    # (ZipCrypto) isn't allowed for writing.
    #
    # Fails with LibZip::NotFoundError when +source_path+ doesn't exist,
    # LibZip::PermissionError when it can't be read, and
    # LibZip::InvalidArgumentError when it isn't a regular file, when
    # +password+ comes without +encryption+, or when +encryption+ isn't one of
    # the symbols above.
    def add(name, source_path, encryption: nil, password: nil)
    end

    # Loads the entry +name+ and returns its bytes as an ASCII-8BIT String.
    #
    # +password+ decrypts this one entry and overrides the archive default, so
    # an incorrect password here fails even when the archive was opened with
    # the correct one.
    #
    # Fails with LibZip::NotFoundError when there's no such entry,
    # LibZip::PasswordError when the password is missing or incorrect,
    # LibZip::DecompressionError when the data doesn't match its CRC or its AES
    # HMAC, and LibZip::CorruptArchiveError when the entry is shorter or longer
    # than the size in the central directory.
    #
    # Use #get_input_stream for an entry too large to keep in memory.
    def read(name, password: nil)
    end

    # Returns a LibZip::InputStream over the entry +name+, which pulls the entry
    # in chunks instead of building 1 String.
    #
    #   zip.get_input_stream("big.csv") do |stream|
    #     stream.read(64 * 1024) until stream.eof?
    #   end
    #
    # With a block the stream is yielded and closed on the way out, including
    # when the block fails, and the block's value comes back. Without one you
    # get the stream; close it with LibZip::InputStream#close, or let #close on
    # the archive do it.
    #
    # +password+ works as in #read. Fails with LibZip::NotFoundError when
    # there's no such entry.
    def get_input_stream(name, password: nil) # :yields: stream
    end

    # Returns a LibZip::OutputStream that writes the entry +name+ from memory.
    #
    #   zip.get_output_stream("data.csv") do |out|
    #     out.write("a,b,c\n")
    #     out << "1,2,3\n"
    #   end
    #
    # The stream buffers what you give it and adds the entry only when it's
    # closed. A stream left to the garbage collector, or one where the block
    # failed, contributes no entry, while entries written before it remain.
    # An entry of the same name is replaced.
    #
    # With a block the stream is yielded, committed on normal exit, and the
    # block's value comes back. Without one you get the stream, and
    # LibZip::OutputStream#close commits it.
    #
    # +encryption+ and +password+ work as in #add.
    def get_output_stream(name, encryption: nil, password: nil) # :yields: stream
    end

    # Deletes an entry, named by String or by the LibZip::Entry, and returns it
    # as a snapshot taken before the deletion, so its metadata remains readable
    # after the deletion and after the archive closes.
    #
    #   removed = zip.remove("old.txt")
    #   removed.size   # => 1234
    #
    # The entry disappears from the listing at once; #close writes the file
    # again. Removing the last remaining entry deletes the archive from disk
    # instead of writing an empty one.
    #
    # Fails with LibZip::NotFoundError when the entry isn't in the archive,
    # including on a 2nd #remove of the same name, and
    # LibZip::InvalidArgumentError for a LibZip::Entry belonging to another
    # archive. There's no 3rd outcome: you get the entry back, or you get an
    # exception.
    def remove(name)
    end

    # Renames an entry, named by String or by the LibZip::Entry, and returns a
    # snapshot taken after the rename. Size, CRC, time and compression are
    # preserved.
    #
    #   zip.rename("draft.txt", "final.txt")
    #
    # A rename moves 1 record: the children of a directory entry keep the names
    # they were stored with, whatever the directory is called now.
    #
    # Fails with LibZip::NotFoundError when +old_name+ isn't in the archive,
    # LibZip::AlreadyExistsError when +new_name+ already is, and
    # LibZip::InvalidArgumentError when 1 name has the trailing +/+ of a
    # directory entry and the other doesn't, or for a LibZip::Entry belonging
    # to another archive.
    def rename(old_name, new_name)
    end

    # Returns the central directory as an Array of LibZip::Entry snapshots.
    #
    # No extraction happens, and no entry bytes are read. The array is built
    # fresh on each call, so it reflects entries added or removed since the
    # previous one.
    def entries
    end

    # Passes each LibZip::Entry to the block, and returns the full Array.
    # Without a block, returns an Enumerator.
    #
    # This is what File's Enumerable methods run on.
    #
    #   zip.map(&:name)
    #   zip.select(&:directory?)
    def each # :yields: entry
    end

    # Same as #each. Named for what it passes to the block, and the method an
    # Enumerator from #each calls.
    def each_entry # :yields: entry
    end

    # Returns the entry names as an Array of UTF-8 Strings, directory entries
    # included, with the trailing +/+ they're stored with.
    def names
    end

    # Number of entries in the archive, not counting the ones removed since it
    # was opened.
    def size
    end
    alias length size

    # Whether +name+ is an entry of this archive. Accepts a String or a
    # LibZip::Entry.
    def include?(name)
    end

    # Returns the LibZip::Entry named +name+, or +nil+ when the archive has no
    # such entry. See #get_entry to fail instead.
    def find_entry(name)
    end
    alias [] find_entry

    # Returns the LibZip::Entry named +name+, or fails with
    # LibZip::NotFoundError. See #find_entry to get +nil+ instead.
    def get_entry(name)
    end

    # Returns the LibZip::Entry records matching +pattern+, and passes each of
    # them to the block if one is given.
    #
    #   zip.glob("*.txt")     # => the .txt entries at the top level
    #   zip.glob("**/*.txt")  # => the .txt entries at any depth
    #   zip.glob("docs")      # => the "docs/" entry
    #
    # Matching is ::File.fnmatch? with +FNM_PATHNAME+, +FNM_DOTMATCH+ and
    # +FNM_EXTGLOB+: <tt>*</tt> doesn't cross a +/+, <tt>**</tt> matches 0 or
    # more directories, <tt>?</tt>, <tt>[...]</tt> and <tt>{a,b}</tt> all work,
    # and a leading dot isn't special. A directory entry matches without the
    # trailing +/+ it's stored with.
    #
    # Unlike Dir.glob on macOS, matching is case-sensitive on all platforms.
    def glob(pattern) # :yields: entry
    end

    # The archive comment, as a UTF-8 String, or +nil+ when the archive has
    # none. A comment that isn't valid UTF-8 comes back as ASCII-8BIT, instead
    # of as a broken String.
    def comment
    end

    # Sets the archive comment, which #close writes. +nil+ clears it.
    #
    # A comment longer than 65535 bytes, the limit of the field in the zip
    # format, fails with LibZip::InvalidArgumentError.
    def comment=(comment)
    end

    # Sets the comment of the entry +name+, and returns +self+. +nil+ clears
    # it. Read it back with LibZip::Entry#comment.
    #
    # The comment is stored as UTF-8 when its bytes are valid UTF-8, and as raw
    # bytes otherwise. Fails with LibZip::NotFoundError when there's no such
    # entry, and LibZip::InvalidArgumentError past the 65535-byte limit.
    def set_comment(name, comment)
    end

    # Sets the archive default password: the one used for an encrypted entry
    # read with no +password+ argument. +nil+ clears it.
    #
    # There's no reader; a password that goes in doesn't come back out.
    #
    # Zip encryption covers entry contents only. Names, comments and the
    # central directory remain in the clear whatever the password.
    def password=(password)
    end
  end

  # One record of the central directory: what the archive stores about an entry,
  # without reading the entry.
  #
  # An Entry is an immutable snapshot taken when it was listed, so its metadata
  # remains readable after the entry is removed and after the archive is
  # closed. It isn't a handle: pass the name to LibZip::File#read for the
  # bytes.
  #
  #   entry = zip["docs/a.txt"]
  #   entry.name                 # => "docs/a.txt"
  #   entry.size                 # => 1234
  #   entry.compression_method   # => LibZip::Entry::DEFLATED
  #
  # Each accessor except #name, #index and #directory? returns +nil+ when the
  # archive didn't store that field, which a zip written by another tool is
  # free to skip.
  #
  # Entries come from LibZip::File#entries, #each, #[], #find_entry,
  # #get_entry, #glob, #remove and #rename; there's no public constructor.
  class Entry
    # Compression method: stored, no compression.
    STORED = 0

    # Compression method: deflate.
    DEFLATED = 8

    # Encryption method: none. What #encryption_method gives for a plain entry.
    NONE = 0

    # Encryption method: traditional PKWARE (ZipCrypto). Readable, and not
    # allowed for writing, since libzip documents it as broken.
    TRAD_PKWARE = 1

    # Encryption method: AES-128 (Winzip AE-2).
    AES_128 = 257

    # Encryption method: AES-192 (Winzip AE-2).
    AES_192 = 258

    # Encryption method: AES-256 (Winzip AE-2).
    AES_256 = 259

    # The entry name, as a UTF-8 String. Directory entries keep the trailing
    # +/+ they're stored with.
    def name
    end

    # The entry's position in the archive, counting from 0.
    def index
    end

    # The uncompressed size in bytes, or +nil+ when the archive didn't store
    # it.
    def size
    end

    # The size in bytes as stored, after compression, or +nil+ when the archive
    # didn't store it.
    def compressed_size
    end

    # The CRC-32 of the uncompressed data as an Integer, or +nil+ when the
    # archive didn't store it.
    #
    # AES entries use AE-2, which keeps no CRC, so this can be 0 for them;
    # their integrity check is the HMAC, verified when the entry is read to the
    # end.
    def crc
    end

    # The modification time, as a Time, or +nil+ when the archive didn't store
    # it.
    def time
    end
    alias mtime time

    # STORED or DEFLATED, or +nil+ when the archive didn't store it. Directory
    # entries give STORED.
    def compression_method
    end

    # libzip's numeric encryption method: NONE, TRAD_PKWARE, AES_128, AES_192
    # or AES_256. +nil+ when the archive didn't store it.
    def encryption_method
    end

    # Whether the entry's contents are encrypted, which means #encryption_method
    # is anything but NONE. +false+ when the archive didn't store the method.
    def encrypted?
    end

    # Whether this entry is a directory.
    #
    # True for a name ending in +/+, and for an entry with external attributes
    # that agree: a UNIX mode with +S_IFDIR+, or the MS-DOS directory bit.
    # That's how a directory written by another tool is identified.
    def directory?
    end

    # The entry comment, as a UTF-8 String, or +nil+ when it has none. A
    # comment that isn't valid UTF-8 comes back as ASCII-8BIT. Set it with
    # LibZip::File#set_comment.
    def comment
    end

    # The entry name, so an Entry interpolates into a String as its name.
    def to_s
    end

    # <tt>#&lt;LibZip::Entry name="docs/a.txt" size=1234&gt;</tt>
    def inspect
    end
  end

  # A read handle on 1 entry, from LibZip::File#get_input_stream.
  #
  # The entry is decompressed and decrypted in chunks as you read, so memory
  # remains flat whatever the entry's size.
  #
  #   LibZip::File.open("archive.zip") do |zip|
  #     zip.get_input_stream("big.csv") do |stream|
  #       stream.read(64 * 1024) until stream.eof?
  #     end
  #   end
  #
  # A stream keeps a libzip handle and has to be closed. The block form of
  # LibZip::File#get_input_stream does that for you; otherwise #close does, and
  # LibZip::File#close closes whatever is still open on that archive.
  class InputStream
    # Returns +length+ bytes, or the rest of the entry when +length+ is
    # omitted.
    #
    # Returns an ASCII-8BIT String. A short read means the entry ended: fewer
    # than +length+ bytes come back, and the call after that gives +nil+. With
    # no +length+, a stream already at EOF gives <tt>""</tt>, the same
    # distinction IO makes. <tt>read(0)</tt> gives <tt>""</tt> and consumes no
    # bytes, even at EOF.
    #
    # Fails with ArgumentError for a negative +length+, LibZip::EntryError once
    # the stream is closed, and LibZip::DecompressionError when the data
    # doesn't match its CRC or its AES HMAC, which is only known once the entry
    # has been read to the end.
    def read(length = nil)
    end

    # Whether the entry has been read to the end. Fails with
    # LibZip::EntryError once the stream is closed.
    def eof?
    end

    # Whether the stream has been closed, by #close or by closing the archive.
    def closed?
    end

    # Releases the entry handle. Returns +nil+, and has no effect on a stream
    # that's already closed.
    def close
    end
  end

  # A write handle on 1 entry, from LibZip::File#get_output_stream.
  #
  #   zip.get_output_stream("data.csv") do |out|
  #     out.write("a,b,c\n")
  #     out << "1,2,3\n"
  #   end
  #
  # What you write is buffered in memory, and becomes an entry only on #close,
  # which the block form calls for you. A stream that isn't closed, because the
  # block failed or because the garbage collector took it, adds no entry. The
  # entry is written to disk when the archive is closed.
  class OutputStream
    # Appends +string+ to the buffer, and returns the number of bytes written.
    # Binary data, NUL bytes included, is written as given.
    #
    # Fails with LibZip::EntryError once the stream has been closed, or the
    # archive has.
    def write(string)
    end

    # Appends +string+ and returns +self+, so writes chain.
    #
    #   out << "Hello, " << "world!\n"
    def <<(string)
    end

    # Adds the buffered bytes to the archive as the entry, and returns +nil+.
    # LibZip::File#close writes the archive to disk.
    #
    # Encryption is set up here, so a bad encryption setup shows up on #close
    # instead of on #write.
    def close
    end
  end

  # Base class for anything this gem fails with, and a StandardError, so a
  # single +rescue LibZip::Error+ handles all of them.
  #
  #   begin
  #     LibZip::File.open("archive.zip") { |zip| zip.read("nope.txt") }
  #   rescue LibZip::NotFoundError => e
  #     warn "missing entry: #{e.message}"
  #   rescue LibZip::Error => e
  #     warn "libzip error: #{e.message}"
  #   end
  #
  # Each libzip error code maps to one of the subclasses below; a code with no
  # better home comes back as LibZip::Error.
  class Error < StandardError
  end

  # An operation or an encryption method libzip can't perform.
  class UnsupportedError < Error
  end

  # An open, seek, tell, close, rename or remove of an underlying file failed,
  # or a file ended sooner than expected.
  class IoError < Error
  end

  # Reading archive data failed.
  class ReadError < Error
  end

  # Writing archive data failed.
  class WriteError < Error
  end

  # No such archive, entry, or source file.
  class NotFoundError < Error
  end

  # An entry exists where one must not, as when renaming to a name that's
  # taken.
  class AlreadyExistsError < Error
  end

  # Not a zip file, truncated, inconsistent, multi-disk, or with compressed
  # data that makes no sense.
  class CorruptArchiveError < Error
  end

  # The compression method isn't supported.
  class CompressionError < Error
  end

  # Decompression failed: the data doesn't match its CRC or its AES HMAC.
  class DecompressionError < Error
  end

  # An argument libzip or this gem turns away: a directory as a source file, a
  # comment past 65535 bytes, an unknown +encryption+, a password without
  # encryption, an entry from another archive.
  class InvalidArgumentError < Error
  end

  # The archive is read-only, or the operation isn't allowed on it.
  class PermissionError < Error
  end

  # The password is missing or incorrect. Comes when the entry is read, not
  # when the archive is opened.
  class PasswordError < Error
  end

  # An entry, stream or archive used after it was closed, deleted or changed.
  class EntryError < Error
  end

  # libzip or zlib failed internally, or ran out of memory.
  class InternalError < Error
  end
end
