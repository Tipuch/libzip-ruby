require_relative "helper"

# A VALUE reachable only from a Zig local, or only from a malloc'd struct the
# GC can't see, is kept alive by luck. GC.stress collects at each allocation
# point, which turns that luck into a reproducible failure.
#
# Native leaks aren't visible from Ruby at all; script/check runs this suite
# under valgrind for those.
class GcSafetyTest < Minitest::Test
    def setup
        @dir = Dir.mktmpdir
        @zip_path = File.join(@dir, "test.zip")
    end

    def teardown = FileUtils.remove_entry(@dir)

    def under_gc_stress
        was = GC.stress
        GC.stress = true
        yield
    ensure
        GC.stress = was
    end

    def seeded
        LibZip::File.open(@zip_path, create: true) do |zip|
            zip.get_output_stream("hello.txt") { |f| f.write "hello world" }
            zip.get_output_stream("dir/nested.txt") { |f| f.write "nested" }
            zip.comment = "archive comment"
        end
        @zip_path
    end

    # --- GC pressure ----------------------------------------------------

    def test_entry_listing_under_gc_stress
        path = seeded
        under_gc_stress do
            LibZip::File.open(path) do |zip|
                assert_equal ["hello.txt", "dir/nested.txt"].sort, zip.names.sort
                zip.each { |e| assert_kind_of String, e.name }
                assert_equal 11, zip.get_entry("hello.txt").size
                assert_match(/LibZip::Entry/, zip.get_entry("hello.txt").inspect)
                assert_equal ["hello.txt"], zip.glob("*.txt").map(&:to_s)
                assert_equal "archive comment", zip.comment
            end
        end
    end

    def test_read_paths_under_gc_stress
        path = seeded
        under_gc_stress do
            LibZip::File.open(path) do |zip|
                assert_equal "hello world", zip.read("hello.txt")
                assert_equal "hello world", zip.get_input_stream("hello.txt").read
                zip.get_input_stream("hello.txt") { |s| assert_equal "hello", s.read(5) }
            end
        end
    end

    def test_write_paths_under_gc_stress
        out = File.join(@dir, "written.zip")
        under_gc_stress do
            LibZip::File.open(out, create: true) do |zip|
                zip.get_output_stream("a.txt") { |f| f.write "a" * 100 }
                zip.set_comment("a.txt", "entry comment")
                zip.comment = "top level"
            end
        end
        LibZip::File.open(out) { |zip| assert_equal "a" * 100, zip.read("a.txt") }
    end

    def test_encryption_option_parsing_under_gc_stress
        out = File.join(@dir, "enc.zip")
        under_gc_stress do
            LibZip::File.open(out, create: true) do |zip|
                zip.get_output_stream("s.txt", encryption: :aes256, password: "pw") do |f|
                    f.write "secret"
                end
            end
            # The symbol name passes to libzip as a raw pointer; a bad one is
            # a freed read that only surfaces when the GC runs in between.
            LibZip::File.open(out) do |zip|
                assert_equal "secret", zip.read("s.txt", password: "pw")
                assert_raises(LibZip::InvalidArgumentError) do
                    zip.read("s.txt", encryption: :nonsense, password: "pw")
                end
            end
        end
    end

    def test_compaction_does_not_break_live_objects
        skip "compaction unsupported" unless GC.respond_to?(:verify_compaction_references)
        path = seeded
        LibZip::File.open(path) do |zip|
            entries = zip.entries
            stream = zip.get_input_stream("hello.txt")
            GC.verify_compaction_references(expand_heap: true, toward: :empty)

            assert_equal "hello world", stream.read
            assert(entries.all? { |e| e.name.is_a?(String) })
            assert_equal "archive comment", zip.comment
        end
    end
end
