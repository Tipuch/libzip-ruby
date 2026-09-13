require_relative "helper"

class OutputStreamTest < Minitest::Test
    def setup
        @dir = Dir.mktmpdir
        @zip_path = File.join(@dir, "test.zip")
    end

    def teardown = FileUtils.remove_entry(@dir)

    def test_write_and_close_commits_entry
        zip = LibZip::File.open(@zip_path, create: true)
        stream = zip.get_output_stream("hello.txt")
        stream.write("hello ")
        stream.write("world")
        stream.close
        zip.close

        zip = LibZip::File.open(@zip_path)
        assert_equal "hello world", zip.read("hello.txt")
        zip.close
    end

    def test_shovel_alias_appends
        zip = LibZip::File.open(@zip_path, create: true)
        stream = zip.get_output_stream("a.txt")
        stream << "one" << "two"
        stream.close
        zip.close

        zip = LibZip::File.open(@zip_path)
        assert_equal "onetwo", zip.read("a.txt")
        zip.close
    end

    def test_block_form_commits_on_exit
        LibZip::File.open(@zip_path, create: true) do |zip|
            zip.get_output_stream("myFile") { |f| f.write "myFile contains just this" }
        end

        zip = LibZip::File.open(@zip_path)
        assert_equal "myFile contains just this", zip.read("myFile")
        zip.close
    end

    def test_write_after_close_raises
        zip = LibZip::File.open(@zip_path, create: true)
        stream = zip.get_output_stream("a.txt")
        stream.write("x")
        stream.close
        assert_raises(LibZip::EntryError) { stream.write("y") }
        zip.close
    end

    def test_exception_in_block_does_not_commit
        zip = LibZip::File.open(@zip_path, create: true)
        zip.get_output_stream("keep.txt") { |f| f.write "keep me" }
        assert_raises(RuntimeError) do
            zip.get_output_stream("b.txt") do |f|
                f.write "partial"
                raise "boom"
            end
        end
        zip.close

        zip = LibZip::File.open(@zip_path)
        assert_equal "keep me", zip.read("keep.txt")
        assert_raises(LibZip::NotFoundError) { zip.read("b.txt") }
        zip.close
    end

    def test_stream_on_closed_archive_raises
        zip = LibZip::File.open(@zip_path, create: true)
        zip.close
        assert_raises(LibZip::EntryError) { zip.get_output_stream("a.txt") }
    end

    def test_write_returns_byte_count
        zip = LibZip::File.open(@zip_path, create: true)
        stream = zip.get_output_stream("a.txt")
        assert_equal 5, stream.write("hello")
        stream.close
        zip.close
    end
end