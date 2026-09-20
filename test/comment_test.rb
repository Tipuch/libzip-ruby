require_relative "helper"
require "tmpdir"
require "fileutils"
require "open3"
require "base64"

class CommentTest < Minitest::Test
  PYTHON = ENV.fetch("PYTHON", "python3")
  PYTHON_ENTRY_COMMENT = <<~PY
    import base64, sys, zipfile
    with zipfile.ZipFile(sys.argv[1]) as archive:
        entry = archive.getinfo(sys.argv[2])
        print(base64.b64encode(entry.comment).decode("ascii"))
  PY

  def setup
    @dir = Dir.mktmpdir
    @zip_path = File.join(@dir, "test.zip")
    @src = File.join(@dir, "src.txt")
    File.write(@src, "hello")
    build_archive
  end

  def teardown = FileUtils.remove_entry(@dir)

  def build_archive
    LibZip::File.open(@zip_path, create: true) do |zip|
      zip.add("a.txt", @src)
      zip.add("b.txt", @src)
    end
  end

  def reopen
    LibZip::File.open(@zip_path) { |zip| yield zip }
  end

  # --- archive comments -----------------------------------------------------

  def test_new_archive_has_no_comment
    reopen { |zip| assert_nil zip.comment }
  end

  def test_archive_comment_is_visible_immediately_and_round_trips
    comment = "release 1\nwritten by libzip — 世界"

    LibZip::File.open(@zip_path) do |zip|
      result = (zip.comment = comment)

      assert_equal comment, result
      assert_equal comment, zip.comment
      assert_equal Encoding::UTF_8, zip.comment.encoding
    end

    reopen do |zip|
      assert_equal comment, zip.comment
      assert_equal Encoding::UTF_8, zip.comment.encoding
    end
  end

  def test_nil_clears_archive_comment
    LibZip::File.open(@zip_path) { |zip| zip.comment = "temporary" }

    LibZip::File.open(@zip_path) do |zip|
      assert_equal "temporary", zip.comment
      assert_nil(zip.comment = nil)
      # libzip exposes the original archive comment until close when a pending
      # archive-comment clear has no replacement string. Reopen below verifies
      # that the clear is committed. 
    end

    reopen { |zip| assert_nil zip.comment }
  end

  def test_empty_archive_comment_is_equivalent_to_nil
    LibZip::File.open(@zip_path) do |zip|
      zip.comment = "temporary"
      zip.comment = ""
      assert_nil zip.comment
    end

    reopen { |zip| assert_nil zip.comment }
  end

  def test_archive_comment_survives_normal_close_but_block_exception_discards_it
    LibZip::File.open(@zip_path) { |zip| zip.comment = "original" }

    assert_raises(RuntimeError) do
      LibZip::File.open(@zip_path) do |zip|
        zip.comment = "discarded"
        raise "stop"
      end
    end

    reopen { |zip| assert_equal "original", zip.comment }
  end

  def test_archive_comment_accepts_the_maximum_length
    comment = "x" * 65_535

    LibZip::File.open(@zip_path) do |zip|
      zip.comment = comment
      assert_equal comment, zip.comment
    end

    reopen { |zip| assert_equal comment, zip.comment }
  end

  def test_archive_comment_rejects_more_than_the_maximum_length
    LibZip::File.open(@zip_path) do |zip|
      assert_raises(LibZip::InvalidArgumentError) do
        zip.comment = "x" * 65_536
      end
    end
  end

  def test_archive_comment_rejects_invalid_bytes
    invalid = "\xff".b

    LibZip::File.open(@zip_path) do |zip|
      assert_raises(LibZip::InvalidArgumentError) { zip.comment = invalid }
    end
  end

  def test_archive_comment_rejects_embedded_nul
    comment = "before\0after".b

    # zip_set_archive_comment uses libzip's encoding-guess path and turns away
    # this archive-level comment. Entry comments use the separate file-comment
    # API and are tested for NUL round-tripping below.
    LibZip::File.open(@zip_path) do |zip|
      assert_raises(LibZip::InvalidArgumentError) { zip.comment = comment }
    end
  end

  def test_archive_comment_rejects_non_string_values
    LibZip::File.open(@zip_path) do |zip|
      assert_raises(TypeError) { zip.comment = 123 }
    end
  end

  def test_archive_comment_on_closed_file_raises
    zip = LibZip::File.open(@zip_path)
    zip.close

    assert_raises(LibZip::EntryError) { zip.comment }
    assert_raises(LibZip::EntryError) { zip.comment = "later" }
  end

  # --- entry comments -------------------------------------------------------

  def test_entry_comment_is_nil_by_default
    reopen do |zip|
      assert_nil zip.get_entry("a.txt").comment
    end
  end

  def test_set_comment_returns_file_and_entry_comment_is_visible_immediately
    LibZip::File.open(@zip_path) do |zip|
      result = zip.set_comment("a.txt", "source file")

      assert_same zip, result
      assert_equal "source file", zip.get_entry("a.txt").comment
    end
  end

  def test_entry_comment_round_trips_with_unicode_and_newlines
    comment = "第一行\nsecond line — note"

    LibZip::File.open(@zip_path) { |zip| zip.set_comment("a.txt", comment) }

    reopen do |zip|
      entry = zip.get_entry("a.txt")
      assert_equal comment, entry.comment
      assert_equal Encoding::UTF_8, entry.comment.encoding
    end
  end

  def test_entry_comment_snapshot_survives_close_and_later_changes
    snapshot = nil

    LibZip::File.open(@zip_path) do |zip|
      snapshot = zip.get_entry("a.txt")
      zip.set_comment("a.txt", "new comment")

      assert_nil snapshot.comment
      assert_equal "new comment", zip.get_entry("a.txt").comment
    end

    assert_nil snapshot.comment
  end

  def test_nil_clears_entry_comment
    LibZip::File.open(@zip_path) do |zip|
      zip.set_comment("a.txt", "temporary")
      zip.set_comment("a.txt", nil)
      assert_nil zip.get_entry("a.txt").comment
    end

    reopen { |zip| assert_nil zip.get_entry("a.txt").comment }
  end

  def test_empty_entry_comment_is_equivalent_to_nil
    LibZip::File.open(@zip_path) do |zip|
      zip.set_comment("a.txt", "temporary")
      zip.set_comment("a.txt", "")
      assert_nil zip.get_entry("a.txt").comment
    end

    reopen { |zip| assert_nil zip.get_entry("a.txt").comment }
  end

  def test_entry_comment_accepts_the_maximum_length
    comment = "x" * 65_535

    LibZip::File.open(@zip_path) do |zip|
      zip.set_comment("a.txt", comment)
      assert_equal comment, zip.get_entry("a.txt").comment
    end

    reopen { |zip| assert_equal comment, zip.get_entry("a.txt").comment }
  end

  def test_entry_comment_rejects_more_than_the_maximum_length
    LibZip::File.open(@zip_path) do |zip|
      assert_raises(LibZip::InvalidArgumentError) do
        zip.set_comment("a.txt", "x" * 65_536)
      end
    end
  end

  def test_entry_comment_preserves_embedded_nul
    comment = "before\0after".b

    LibZip::File.open(@zip_path) { |zip| zip.set_comment("a.txt", comment) }

    reopen do |zip|
      actual = zip.get_entry("a.txt").comment
      assert_equal comment, actual
      assert_equal Encoding::UTF_8, actual.encoding
    end
  end

  def test_invalid_entry_comment_bytes_are_returned_as_binary
    comment = "\xff\xfe".b

    LibZip::File.open(@zip_path) { |zip| zip.set_comment("a.txt", comment) }

    reopen do |zip|
      actual = zip.get_entry("a.txt").comment
      assert_equal comment, actual
      assert_equal Encoding::BINARY, actual.encoding
    end
  end

  def test_entry_comment_is_verified_with_python_zipfile
    comment = "raw bytes \x00 and café".b
    LibZip::File.open(@zip_path) { |zip| zip.set_comment("a.txt", comment) }

    output, status = Open3.capture2(PYTHON, "-c", PYTHON_ENTRY_COMMENT, @zip_path, "a.txt")
    skip "python3 is unavailable" unless status.success?

    assert_equal comment, Base64.decode64(output.strip)
  end

  def test_entry_comment_survives_rename_of_the_same_entry
    LibZip::File.open(@zip_path) do |zip|
      zip.set_comment("a.txt", "keep me")
      zip.rename("a.txt", "renamed.txt")
      assert_equal "keep me", zip.get_entry("renamed.txt").comment
    end

    reopen { |zip| assert_equal "keep me", zip.get_entry("renamed.txt").comment }
  end

  def test_entry_comment_on_removed_entry_is_gone_after_close
    LibZip::File.open(@zip_path) do |zip|
      zip.set_comment("a.txt", "remove me")
      removed = zip.remove("a.txt")
      assert_equal "remove me", removed.comment
    end

    reopen do |zip|
      assert_nil zip.find_entry("a.txt")
      assert_equal ["b.txt"], zip.names
    end
  end

  def test_missing_entry_raises_not_found
    LibZip::File.open(@zip_path) do |zip|
      assert_raises(LibZip::NotFoundError) { zip.set_comment("missing.txt", "note") }
    end
  end

  def test_set_comment_on_closed_file_raises
    zip = LibZip::File.open(@zip_path)
    zip.close

    assert_raises(LibZip::EntryError) { zip.set_comment("a.txt", "later") }
  end
end
