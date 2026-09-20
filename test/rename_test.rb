require_relative "helper"
require "tmpdir"
require "fileutils"
require "zlib"
require "json"

# `rename` changes the entry's name in place: same index, same content, same
# metadata, new name. The change is written when the archive is closed. It
# returns a snapshot of the renamed entry, and snapshots taken *before* the
# rename keep the old name — they're snapshots, not handles.
#
# Kind (directory-ness) comes from the trailing slash of the stored name, so
# a rename that would change it gets turned away, instead of producing
# an entry other tools would read differently.
class RenameTest < Minitest::Test
  # Checks the archive with a foreign tool. The fixture is python-generated
  # anyway, so python3 is already part of the test story; skip if it's missing
  # instead of failing.
  PYTHON = ENV.fetch("PYTHON", "python3")
  PYTHON_SCRIPT = <<~PY
    import json, sys, zipfile
    z = zipfile.ZipFile(sys.argv[1])
    print(json.dumps([{"name": i.filename, "flags": i.flag_bits} for i in z.infolist()]))
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
      zip.add("keep.txt", @src)
    end
  end

  def reopen_names
    reopen_names_of(@zip_path)
  end

  def reopen_names_of(path)
    LibZip::File.open(path) { |zip| zip.names }
  end

  def foreign_zip
    path = File.join(@dir, "foreign.zip")
    FileUtils.cp(ENTRIES_ZIP, path)
    path
  end

  # --- the return value -----------------------------------------------------

  def test_rename_returns_the_renamed_entry
    LibZip::File.open(@zip_path) do |zip|
      renamed = zip.rename("a.txt", "renamed.txt")

      assert_instance_of LibZip::Entry, renamed
      assert_equal "renamed.txt", renamed.name
      assert_equal 5, renamed.size
      assert_equal Zlib.crc32("hello"), renamed.crc
    end
  end

  def test_rename_accepts_an_entry_instead_of_a_name
    LibZip::File.open(@zip_path) do |zip|
      renamed = zip.rename(zip.find_entry("a.txt"), "renamed.txt")

      assert_equal "renamed.txt", renamed.name
    end

    assert_equal ["renamed.txt", "b.txt", "keep.txt"], reopen_names
  end

  def test_snapshots_handed_out_before_the_rename_keep_the_old_name
    LibZip::File.open(@zip_path) do |zip|
      stale = zip.find_entry("a.txt")
      renamed = zip.rename(stale, "renamed.txt")

      # snapshots are values, not handles: they don't track the archive
      assert_equal "a.txt", stale.name
      assert_equal "renamed.txt", renamed.name
    end
  end

  def test_rename_snapshot_survives_close
    renamed = nil
    LibZip::File.open(@zip_path) { |zip| renamed = zip.rename("a.txt", "renamed.txt") }

    assert_equal "renamed.txt", renamed.name
    assert_equal 5, renamed.size
  end

  # --- the change ------------------------------------------------------------

  def test_rename_is_visible_immediately_and_committed_by_close
    LibZip::File.open(@zip_path) do |zip|
      zip.rename("a.txt", "renamed.txt")

      assert zip.include?("renamed.txt")
      refute zip.include?("a.txt")
      assert_nil zip.find_entry("a.txt")
      assert_raises(LibZip::NotFoundError) { zip.get_entry("a.txt") }
      assert_equal "hello", zip.read("renamed.txt")
    end

    assert_equal ["renamed.txt", "b.txt", "keep.txt"], reopen_names
  end

  def test_rename_keeps_the_entry_in_place
    # zip_file_rename sets a name; it doesn't move the entry to the end the way
    # remove-then-add does. Order is part of what users see.
    LibZip::File.open(@zip_path) do |zip|
      zip.rename("b.txt", "middle.txt")

      assert_equal ["a.txt", "middle.txt", "keep.txt"], zip.names
      assert_equal 1, zip.find_entry("middle.txt").index
    end

    assert_equal ["a.txt", "middle.txt", "keep.txt"], reopen_names
  end

  def test_rename_preserves_everything_but_the_name
    LibZip::File.open(@zip_path) do |zip|
      before = zip.find_entry("a.txt")
      after = zip.rename("a.txt", "renamed.txt")

      assert_equal before.size, after.size
      assert_equal before.compressed_size, after.compressed_size
      assert_equal before.crc, after.crc
      assert_equal before.time, after.time
      assert_equal before.compression_method, after.compression_method
      assert_equal before.index, after.index
    end
  end

  def test_listings_stay_consistent_after_rename
    LibZip::File.open(@zip_path) do |zip|
      zip.rename("a.txt", "renamed.txt")

      assert_equal ["renamed.txt", "b.txt", "keep.txt"], zip.names
      assert_equal 3, zip.size
      assert_equal 3, zip.entries.length
      assert_equal ["b.txt", "keep.txt", "renamed.txt"], zip.glob("*.txt").map(&:name).sort
      assert_equal 3, zip.count
    end
  end

  def test_rename_can_change_only_the_case
    # lookups are case-sensitive everywhere, so this is a real rename
    LibZip::File.open(@zip_path) do |zip|
      zip.rename("a.txt", "A.TXT")

      refute zip.include?("a.txt")
      assert zip.include?("A.TXT")
    end

    assert_equal ["A.TXT", "b.txt", "keep.txt"], reopen_names
  end

  def test_unicode_new_name_round_trips
    LibZip::File.open(@zip_path) { |zip| zip.rename("a.txt", "café.txt") }

    LibZip::File.open(@zip_path) do |zip|
      entry = zip.find_entry("café.txt")

      assert_equal "café.txt", entry.name
      assert_equal Encoding::UTF_8, entry.name.encoding
      assert_equal "hello", zip.read("café.txt")
    end
  end

  def test_unicode_new_name_sets_the_utf8_general_purpose_bit
    # Bit 11 of the general purpose flag is the archive claiming the name is
    # UTF-8. Our reader would agree with us either way; this checks what a
    # foreign parser makes of the bytes.
    LibZip::File.open(@zip_path) { |zip| zip.rename("a.txt", "café.txt") }

    names = foreign_zip_info(@zip_path)

    assert_includes names.map { |e| e["name"] }, "café.txt"
    caf = names.find { |e| e["name"] == "café.txt" }
    assert_equal 0x800, caf["flags"] & 0x800, "UTF-8 flag (bit 11) not set"
  end

  # --- the errors -----------------------------------------------------------

  def test_rename_missing_name_raises_not_found_and_touches_nothing
    before = File.binread(@zip_path)

    LibZip::File.open(@zip_path) do |zip|
      assert_raises(LibZip::NotFoundError) { zip.rename("nope.txt", "x.txt") }
      assert_equal ["a.txt", "b.txt", "keep.txt"], zip.names
    end

    assert_equal before, File.binread(@zip_path)
  end

  def test_rename_of_a_removed_entry_raises_not_found
    LibZip::File.open(@zip_path) do |zip|
      zip.remove("a.txt")

      assert_raises(LibZip::NotFoundError) { zip.rename("a.txt", "renamed.txt") }
    end
  end

  def test_rename_onto_an_existing_name_raises_already_exists_and_changes_nothing
    before = File.binread(@zip_path)

    LibZip::File.open(@zip_path) do |zip|
      assert_raises(LibZip::AlreadyExistsError) { zip.rename("a.txt", "b.txt") }

      # no entry is disturbed
      assert_equal ["a.txt", "b.txt", "keep.txt"], zip.names
      assert_equal "hello", zip.read("a.txt")
      assert_equal "hello", zip.read("b.txt")
    end

    assert_equal before, File.binread(@zip_path)
  end

  def test_rename_onto_a_name_freed_by_remove_succeeds
    # the removed slot is invisible to name lookup, so it must not count as taken
    LibZip::File.open(@zip_path) do |zip|
      zip.remove("b.txt")
      zip.rename("a.txt", "b.txt")

      assert_equal ["b.txt", "keep.txt"], zip.names
      assert_equal "hello", zip.read("b.txt")
    end

    assert_equal ["b.txt", "keep.txt"], reopen_names
  end

  def test_entry_from_another_archive_raises_invalid_argument
    other_path = File.join(@dir, "other.zip")
    LibZip::File.open(other_path, create: true) { |zip| zip.add("a.txt", @src) }

    LibZip::File.open(@zip_path) do |zip|
      other = LibZip::File.open(other_path)

      assert_raises(LibZip::InvalidArgumentError) { zip.rename(other.find_entry("a.txt"), "x.txt") }
      assert_equal ["a.txt", "b.txt", "keep.txt"], zip.names

      other.close
    end
  end

  # --- kind (directory-ness) ------------------------------------------------

  def test_renaming_a_file_to_a_directory_name_raises_invalid_argument
    before = File.binread(@zip_path)

    LibZip::File.open(@zip_path) do |zip|
      assert_raises(LibZip::InvalidArgumentError) { zip.rename("a.txt", "stuff/") }
      assert_equal ["a.txt", "b.txt", "keep.txt"], zip.names
    end

    assert_equal before, File.binread(@zip_path)
  end

  def test_renaming_a_directory_to_a_file_name_raises_invalid_argument
    zip_path = foreign_zip
    before = File.binread(zip_path)

    LibZip::File.open(zip_path) do |zip|
      # docs/ shows directory-ness in both the trailing slash and the external
      # attributes; a name without the slash would contradict the attributes
      assert_raises(LibZip::InvalidArgumentError) { zip.rename("docs/", "stuff") }

      assert_equal ["b.txt", "app.rb", "café.txt", "docs/", "docs/a.txt"], zip.names
    end

    assert_equal before, File.binread(zip_path)
  end

  def test_renaming_a_directory_keeps_its_kind
    zip_path = foreign_zip

    LibZip::File.open(zip_path) do |zip|
      renamed = zip.rename("docs/", "stuff/")

      assert_equal "stuff/", renamed.name
      assert renamed.directory?
    end

    LibZip::File.open(zip_path) do |zip|
      assert_equal ["b.txt", "app.rb", "café.txt", "stuff/", "docs/a.txt"], zip.names
      assert zip.include?("stuff/")
    end
  end

  def test_rename_does_not_move_children
    # No cascading, just like rubyzip: the child keeps the old path prefix.
    zip_path = foreign_zip

    LibZip::File.open(zip_path) do |zip|
      zip.rename("docs/", "stuff/")

      assert zip.include?("docs/a.txt")
      assert_equal "inside\n", zip.read("docs/a.txt")
      refute zip.include?("stuff/a.txt")
    end

    assert_equal ["b.txt", "app.rb", "café.txt", "stuff/", "docs/a.txt"], reopen_names_of(zip_path)
  end

  # --- lifecycle and arguments ---------------------------------------------

  def test_rename_inside_a_block_that_raises_commits_nothing
    before = File.binread(@zip_path)

    assert_raises(RuntimeError) do
      LibZip::File.open(@zip_path) do |zip|
        zip.rename("a.txt", "renamed.txt")
        raise "boom"
      end
    end

    assert_equal before, File.binread(@zip_path)
    assert_equal ["a.txt", "b.txt", "keep.txt"], reopen_names
  end

  def test_rename_after_close_raises_entry_error
    zip = LibZip::File.open(@zip_path)
    zip.close

    assert_raises(LibZip::EntryError) { zip.rename("a.txt", "renamed.txt") }
  end

  def test_rename_argument_handling
    LibZip::File.open(@zip_path) do |zip|
      assert_raises(ArgumentError) { zip.rename("a\0b.txt", "x.txt") }
      assert_raises(ArgumentError) { zip.rename("a.txt", "x\0y.txt") }
      assert_raises(TypeError) { zip.rename(:a_txt, "x.txt") }
      assert_raises(TypeError) { zip.rename("a.txt", :x_txt) }
      assert_raises(ArgumentError) { zip.rename("a.txt") }
      assert_raises(ArgumentError) { zip.rename }
    end

    assert_equal ["a.txt", "b.txt", "keep.txt"], reopen_names
  end

  private

  def foreign_zip_info(path) 
    # Checks the archive with python's zipfile, which shares no code with us.
    out = IO.popen([PYTHON, "-c", PYTHON_SCRIPT, path], &:read)
    unless $?.success?
      skip "#{PYTHON} not available"
    end
    JSON.parse(out)
  rescue Errno::ENOENT
    skip "#{PYTHON} not available"
  end
end
