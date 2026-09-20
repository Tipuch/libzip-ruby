require_relative "helper"

# Lifetime and boundary tests. Each case here is an object that can still be
# used after the archive is closed, a value that moves across the Zig/libzip
# boundary through a truncating conversion, or a failure path that must keep
# the archive usable.
#
# The gem is built -Doptimize=ReleaseFast, so Zig's implicit checks aren't
# there in production and these rely on explicit checks in the source. Run
# them under a Debug or ReleaseSafe build with valgrind too.
class MemorySafetyTest < Minitest::Test
    def setup
        @dir = Dir.mktmpdir
        @zip_path = File.join(@dir, "test.zip")
    end

    def teardown = FileUtils.remove_entry(@dir)

    def seeded_zip
        LibZip::File.open(@zip_path, create: true) do |zip|
            zip.get_output_stream("hello.txt") { |f| f.write "hello world" }
        end
        @zip_path
    end

    # --- output streams outliving their archive -------------------------

    def test_output_stream_close_after_archive_close_raises
        zip = LibZip::File.open(@zip_path, create: true)
        stream = zip.get_output_stream("a.txt")
        stream.write("hi")
        zip.close

        assert_raises(LibZip::EntryError) { stream.close }
    end

    def test_output_stream_write_after_archive_close_raises
        zip = LibZip::File.open(@zip_path, create: true)
        stream = zip.get_output_stream("a.txt")
        zip.close

        assert_raises(LibZip::EntryError) { stream.write("hi") }
    end

    def test_output_stream_escaping_open_block_raises
        escaped = nil
        LibZip::File.open(@zip_path, create: true) do |zip|
            escaped = zip.get_output_stream("a.txt")
            escaped.write("hi")
        end

        assert_raises(LibZip::EntryError) { escaped.close }
    end

    def test_output_stream_survives_archive_becoming_garbage
        stream = nil
        2.times do
            zip = LibZip::File.open(@zip_path, create: true)
            stream = zip.get_output_stream("a.txt")
            zip.close
            zip = nil
        end
        GC.start

        assert_raises(LibZip::EntryError) { stream.close }
    end

    # --- input streams outliving their archive --------------------------

    def test_input_stream_read_after_archive_close_raises
        zip = LibZip::File.open(seeded_zip)
        stream = zip.get_input_stream("hello.txt")
        zip.close

        assert_predicate stream, :closed?
        assert_raises(LibZip::EntryError) { stream.read }
    end

    def test_input_stream_escaping_open_block_raises
        escaped = nil
        LibZip::File.open(seeded_zip) { |zip| escaped = zip.get_input_stream("hello.txt") }

        assert_raises(LibZip::EntryError) { escaped.read }
    end

    def test_input_stream_survives_archive_becoming_garbage
        stream = LibZip::File.open(seeded_zip).get_input_stream("hello.txt")
        GC.start

        # The stream marks the archive, so the File must still be alive and the
        # underlying zip_file_t still valid.
        assert_equal "hello world", stream.read
    end

    # --- entries are snapshots, not views -------------------------------

    def test_entry_outlives_archive
        zip = LibZip::File.open(seeded_zip)
        entry = zip.get_entry("hello.txt")
        zip.close
        GC.start

        assert_equal "hello.txt", entry.name
        assert_equal 11, entry.size
        refute_predicate entry, :directory?
    end

    # --- values that move across the boundary ---------------------------

    def test_write_accepts_embedded_null_bytes
        payload = "before\0after".b
        LibZip::File.open(@zip_path, create: true) do |zip|
            zip.get_output_stream("bin") { |f| f.write payload }
        end

        LibZip::File.open(@zip_path) { |zip| assert_equal payload, zip.read("bin").b }
    end

    def test_write_returns_byte_count_for_a_large_string
        # INT2NUM with a c_int cast truncates at 2 GiB. Behind a flag, because
        # the string needs 2 GiB of RSS.
        skip "set LIBZIP_SLOW_TESTS=1" unless ENV["LIBZIP_SLOW_TESTS"]

        big = "x" * ((1 << 31) + 16)
        LibZip::File.open(@zip_path, create: true) do |zip|
            zip.get_output_stream("big") { |f| assert_equal big.bytesize, f.write(big) }
        end
    end

    def test_archive_comment_longer_than_a_u32_is_rejected
        # The length check must happen before the truncating cast, or a length
        # that wraps to <= 65535 gets through.
        skip "set LIBZIP_SLOW_TESTS=1" unless ENV["LIBZIP_SLOW_TESTS"]

        zip = LibZip::File.open(@zip_path, create: true)
        assert_raises(LibZip::InvalidArgumentError) { zip.comment = "x" * ((1 << 32) + 16) }
    ensure
        zip&.close rescue nil
    end

    # --- failed adds must not take the archive with them ----------------

    def test_add_with_missing_source_leaves_archive_usable
        zip = LibZip::File.open(@zip_path, create: true)
        assert_raises(LibZip::NotFoundError) { zip.add("a.txt", File.join(@dir, "nope")) }

        refute_predicate zip, :closed?
        zip.get_output_stream("ok.txt") { |f| f.write "ok" }
        zip.close

        LibZip::File.open(@zip_path) { |z| assert_equal "ok", z.read("ok.txt") }
    end

    def test_add_with_directory_source_leaves_archive_usable
        zip = LibZip::File.open(@zip_path, create: true)
        assert_raises(LibZip::InvalidArgumentError) { zip.add("a.txt", @dir) }

        refute_predicate zip, :closed?
        zip.get_output_stream("ok.txt") { |f| f.write "ok" }
        zip.close

        LibZip::File.open(@zip_path) { |z| assert_equal "ok", z.read("ok.txt") }
    end

    def test_add_with_unreadable_source_reports_at_close
        # libzip opens a zip_source_file lazily, so a source we can't read
        # isn't an error until the archive is written. We inherit that instead
        # of pre-flighting it; the point is that the failure gets reported and
        # no freed pointer is left behind.
        skip "running as root" if Process.uid.zero?
        unreadable = File.join(@dir, "secret")
        File.write(unreadable, "x")
        File.chmod(0o000, unreadable)

        zip = LibZip::File.open(@zip_path, create: true)
        zip.add("a.txt", unreadable)
        refute_predicate zip, :closed?

        assert_raises(LibZip::Error) { zip.close }
        assert_predicate zip, :closed?
    end

    # --- stat.valid ------------------------------------------------------

    def test_read_of_an_entry_added_in_the_same_session
        # A pending entry's zip_stat may lack ZIP_STAT_SIZE; the read path
        # must not treat a missing size as "empty entry".
        zip = LibZip::File.open(@zip_path, create: true)
        zip.get_output_stream("pending.txt") { |f| f.write "not yet on disk" }

        assert_equal "not yet on disk", zip.read("pending.txt")
        assert_equal "not yet on disk", zip.get_input_stream("pending.txt").read
        zip.close
    end
end
