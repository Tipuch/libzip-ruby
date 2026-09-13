require_relative "helper"

class ArchiveFileTest < Minitest::Test
    def setup
        @dir = Dir.mktmpdir
        @zip_path = File.join(@dir, "test.zip")
        @src = File.join(@dir, "src.txt")
        File.write(@src, "hello")
    end

    def teardown = FileUtils.remove_entry(@dir)

    def test_open_close_lifecycle
        zip = LibZip::File.open(@zip_path, create: true)
        refute zip.closed?
        zip.close
        assert zip.closed?
    end

    def test_double_close_raises_entry_error
        zip = LibZip::File.open(@zip_path, create: true)
        zip.close
        assert_raises(LibZip::EntryError) { zip.close }
    end

    def test_missing_file_raises_not_found
        zip = LibZip::File.open(@zip_path, create: true)
        assert_raises(LibZip::NotFoundError) { zip.add("ghost", "/nope/nada.txt") }
        zip.close
    end

    def test_directory_source_raises_invalid_argument
        zip = LibZip::File.open(@zip_path, create: true)
        assert_raises(LibZip::InvalidArgumentError) { zip.add("d", @dir) }
        zip.close
    end

    def test_archive_is_a_real_zip
        zip = LibZip::File.open(@zip_path, create: true)
        zip.add("src.txt", @src)
        zip.close
        data = File.binread(@zip_path)
        assert_equal "PK", data[0, 2]           # zip magic bytes
        assert_includes data, "src.txt"         # entry name in central directory
        assert_includes data, "hello"           # stored content
    end

    def test_block_form_closes_on_success
      result = LibZip::File.open(@zip_path, create: true) do |zip|
        zip.add("a.txt", @src)
        :block_return_value
      end
      assert_equal :block_return_value, result   # open returns the block's value
      assert File.exist?(@zip_path)
    end

    def test_block_form_discards_on_exception
      assert_raises(RuntimeError) do
        LibZip::File.open(@zip_path, create: true) do |zip|
          zip.add("a.txt", @src)
          raise "boom"
        end
      end
      refute File.exist?(@zip_path)  # discarded, not committed
    end
end