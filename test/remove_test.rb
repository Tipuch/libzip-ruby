require_relative "helper"
require "tmpdir"
require "fileutils"
require "zlib"

# `remove` marks the entry deleted; the change is written by `close` (libzip's
# convention — there is no #discard). The return value is a snapshot taken
# *before* the deletion, so its metadata stays readable after the archive is
# closed. A name that is not present raises LibZip::NotFoundError.
#
# The archive is always built with LibZip::File itself, except where the test is
# specifically about a foreign tool's archive (the fixture).
FIXTURE = File.expand_path("fixtures/entries.zip", __dir__)

class RemoveTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @zip_path = File.join(@dir, "test.zip")
    @src = File.join(@dir, "src.txt")
    File.write(@src, "hello")
    build_archive
  end

  def teardown = FileUtils.remove_entry(@dir)

  # a.txt, b.txt, keep.txt — always leave a survivor so closing never empties
  # the archive (see test_removing_the_last_entry_leaves_no_file).
  def build_archive
    LibZip::File.open(@zip_path, create: true) do |zip|
      zip.add("a.txt", @src)
      zip.add("b.txt", @src)
      zip.add("keep.txt", @src)
    end
  end

  def reopen_names
    LibZip::File.open(@zip_path) { |zip| zip.names }
  end

  def test_remove_returns_the_removed_entry
    LibZip::File.open(@zip_path) do |zip|
      removed = zip.remove("a.txt")

      assert_instance_of LibZip::Entry, removed
      assert_equal "a.txt", removed.name
      assert_equal 5, removed.size
      assert_equal Zlib.crc32("hello"), removed.crc
    end
  end

  def test_remove_accepts_an_entry_instead_of_a_name
    LibZip::File.open(@zip_path) do |zip|
      removed = zip.remove(zip.find_entry("a.txt"))

      assert_instance_of LibZip::Entry, removed
      assert_equal "a.txt", removed.name
    end

    assert_equal ["b.txt", "keep.txt"], reopen_names
  end

  def test_removal_is_visible_immediately_and_committed_by_close
    LibZip::File.open(@zip_path) do |zip|
      zip.remove("a.txt")

      refute zip.include?("a.txt")
      assert_nil zip.find_entry("a.txt")
      assert_raises(LibZip::NotFoundError) { zip.get_entry("a.txt") }
      assert_equal ["b.txt", "keep.txt"], zip.map(&:name)
    end

    assert_equal ["b.txt", "keep.txt"], reopen_names
  end

  def test_removed_entry_is_hidden_from_every_lookup_but_the_others_survive
    LibZip::File.open(@zip_path) do |zip|
      zip.remove("a.txt")

      assert_equal ["b.txt", "keep.txt"], zip.glob("*.txt").map(&:name)
      assert_equal 5, zip.find_entry("b.txt").size
      assert_equal "hello", zip.read("keep.txt")
    end
  end

  def test_listing_stays_consistent_after_remove
    LibZip::File.open(@zip_path) do |zip|
      zip.remove("a.txt")

      # A deleted entry must disappear from *every* listing, not just the ones
      # that go through zip_stat_index. libzip keeps the slot around until
      # close and reports zip_get_name(index, 0) == NULL for it, which is why
      # names/size have to filter on that instead of trusting the raw count.
      assert_equal ["b.txt", "keep.txt"], zip.names
      assert_equal 2, zip.size
      assert_equal 2, zip.length
      assert_equal 2, zip.entries.length
    end
  end

  def test_remove_twice_raises_not_found
    LibZip::File.open(@zip_path) do |zip|
      removed = zip.remove("a.txt")

      assert_raises(LibZip::NotFoundError) { zip.remove("a.txt") }
      # the snapshot we handed back is stale by definition: its name no longer
      # resolves, so passing it back raises too
      assert_raises(LibZip::NotFoundError) { zip.remove(removed) }
    end
  end

  def test_remove_missing_name_raises_not_found_and_touches_nothing
    before = File.binread(@zip_path)

    LibZip::File.open(@zip_path) do |zip|
      assert_raises(LibZip::NotFoundError) { zip.remove("nope.txt") }
      assert_raises(LibZip::NotFoundError) { zip.remove("A.TXT") } # case-sensitive
      assert_equal ["a.txt", "b.txt", "keep.txt"], zip.names
    end

    assert_equal before, File.binread(@zip_path)
  end

  def test_remove_by_name_and_by_entry_reach_the_same_entry
    LibZip::File.open(@zip_path) do |zip|
      by_name = zip.remove("a.txt")
      by_entry = zip.remove(zip.find_entry("b.txt"))

      assert_equal "a.txt", by_name.name
      assert_equal "b.txt", by_entry.name
    end

    assert_equal ["keep.txt"], reopen_names
  end

  def test_entry_from_another_archive_raises_invalid_argument
    other_path = File.join(@dir, "other.zip")
    LibZip::File.open(other_path, create: true) { |zip| zip.add("a.txt", @src) }

    LibZip::File.open(@zip_path) do |zip|
      other = LibZip::File.open(other_path)

      assert_raises(LibZip::InvalidArgumentError) do
        zip.remove(other.find_entry("a.txt"))
      end

      # and our same-named entry is still there
      assert_equal ["a.txt", "b.txt", "keep.txt"], zip.names

      other.close
    end

    assert_equal ["a.txt", "b.txt", "keep.txt"], reopen_names
  end

  def test_remove_inside_a_block_that_raises_commits_nothing
    before = File.binread(@zip_path)

    assert_raises(RuntimeError) do
      LibZip::File.open(@zip_path) do |zip|
        zip.remove("a.txt")
        raise "boom"
      end
    end

    assert_equal before, File.binread(@zip_path)
    assert_equal ["a.txt", "b.txt", "keep.txt"], reopen_names
  end

  def test_remove_then_add_the_same_name
    LibZip::File.open(@zip_path) do |zip|
      zip.remove("a.txt")
      zip.add("a.txt", @src)

      # libzip appends the new entry rather than reusing the freed slot, so the
      # live entry count is unchanged: 3 entries were there, one was removed,
      # one re-added.
      assert_equal 3, zip.entries.length
      assert_equal 1, zip.names.count("a.txt")
    end

    assert_equal ["b.txt", "keep.txt", "a.txt"], reopen_names
  end

  def test_removing_a_directory_entry
    foreign = File.join(@dir, "foreign.zip")
    FileUtils.cp(FIXTURE, foreign)

    LibZip::File.open(foreign) do |zip|
      removed = zip.remove("docs/")

      assert_instance_of LibZip::Entry, removed
      assert_equal "docs/", removed.name
      assert removed.directory?

      # the directory entry is gone, the file inside it is not
      assert_equal ["b.txt", "app.rb", "café.txt", "docs/a.txt"], zip.names
      assert_equal "inside\n", zip.read("docs/a.txt")
    end

    assert_equal ["b.txt", "app.rb", "café.txt", "docs/a.txt"], reopen_names_of(foreign)
  end

  def test_removing_the_last_entry_leaves_no_file
    # Same libzip rule as plan 01: zip_close.c refuses to write an archive with
    # no entries, so closing removes the file instead of writing a 22-byte EOCD.
    solo = File.join(@dir, "solo.zip")
    LibZip::File.open(solo, create: true) { |zip| zip.add("only.txt", @src) }

    LibZip::File.open(solo) { |zip| zip.remove("only.txt") }

    refute File.exist?(solo), "emptied archive should not exist on disk"
  end

  def test_close_without_changes_does_not_rewrite_the_file
    before = File.binread(@zip_path)

    LibZip::File.open(@zip_path, create: true) { |_zip| }

    assert_equal before, File.binread(@zip_path)
  end

  def test_remove_after_close_raises_entry_error
    zip = LibZip::File.open(@zip_path)
    zip.close

    assert_raises(LibZip::EntryError) { zip.remove("a.txt") }
  end

  def test_remove_argument_handling
    LibZip::File.open(@zip_path) do |zip|
      assert_raises(ArgumentError) { zip.remove("a\0b.txt") }
      assert_raises(TypeError) { zip.remove(:a_txt) }
      assert_raises(TypeError) { zip.remove(42) }
      assert_raises(ArgumentError) { zip.remove }
    end

    assert_equal ["a.txt", "b.txt", "keep.txt"], reopen_names
  end

  private

  def reopen_names_of(path)
    LibZip::File.open(path) { |zip| zip.names }
  end
end
