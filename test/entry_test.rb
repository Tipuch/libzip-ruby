require_relative "helper"
require "tmpdir"
require "zlib"

# The Ruby-level tests can't tell *which* rule decided `directory?` (the
# trailing-slash rule applies first on `docs/`). The per-rule coverage is in
# the Zig unit tests for nameIsDirectory / attributesAreDirectory.
# ENTRIES_ZIP is defined in helper.rb.

class EntryTest < Minitest::Test
  NAMES = ["b.txt", "app.rb", "café.txt", "docs/", "docs/a.txt"].freeze

  def setup
    @dir = Dir.mktmpdir
    @zip_path = File.join(@dir, "test.zip")
    @src = File.join(@dir, "src.txt")
    File.write(@src, "hello\n")
    @zip = LibZip::File.open(ENTRIES_ZIP)
  end

  def teardown
    @zip.close unless @zip.closed?
    FileUtils.remove_entry(@dir)
  end

  def test_names_in_archive_order
    assert_equal NAMES, @zip.names
  end

  def test_entries_returns_entry_objects
    entries = @zip.entries
    assert_instance_of Array, entries
    assert(entries.all? { |e| e.is_a?(LibZip::Entry) })
    assert_equal NAMES, entries.map(&:name)
  end

  def test_size_and_length_are_the_entry_count
    assert_equal 5, @zip.size
    assert_equal 5, @zip.length
  end

  def test_enumerable_is_mixed_in
    # Ruby's Enumerable is included in the C class, so these must all work
    # without us defining them.
    assert_equal NAMES, @zip.map(&:name)
    assert_equal ["docs/"], @zip.select(&:directory?).map(&:name)
    assert_equal 1, @zip.count(&:directory?)
    assert_equal 5, @zip.count
  end

  def test_metadata_of_a_file_entry
    entry = @zip.find_entry("app.rb")
    assert_equal "app.rb", entry.name
    assert_equal 1, entry.index
    assert_equal 10, entry.size
    assert_equal Zlib.crc32("import io\n"), entry.crc
    assert_kind_of Integer, entry.compressed_size
    assert_equal LibZip::Entry::DEFLATED, entry.compression_method
    assert_equal 0, entry.encryption_method
    refute entry.encrypted?
    refute entry.directory?
  end

  def test_metadata_of_the_directory_entry
    entry = @zip["docs/"]
    assert_equal "docs/", entry.name
    assert entry.directory?
    assert_equal 0, entry.size
    # rubyzip parity: a directory always reports STORED, whatever the central
    # directory claims (entry.rb:190).
    assert_equal LibZip::Entry::STORED, entry.compression_method
  end

  def test_nested_entry_is_not_a_directory
    refute @zip.find_entry("docs/a.txt").directory?
  end

  def test_unicode_name_is_tagged_utf8
    entry = @zip.find_entry("café.txt")
    assert_equal Encoding::UTF_8, entry.name.encoding
    assert entry.name.valid_encoding?
  end

  def test_time_and_mtime_are_times
    entry = @zip.find_entry("b.txt")
    assert_instance_of Time, entry.time
    assert_equal entry.time, entry.mtime
  end

  def test_to_s_and_inspect
    entry = @zip.find_entry("app.rb")
    assert_equal "app.rb", entry.to_s
    assert_match(/\A#<LibZip::Entry name="app\.rb"/, entry.inspect)
  end

  def test_find_entry_returns_nil_when_missing
    assert_nil @zip.find_entry("ghost.txt")
  end

  def test_get_entry_raises_when_missing
    assert_raises(LibZip::NotFoundError) { @zip.get_entry("ghost.txt") }
  end

  def test_bracket_lookup_is_find_entry
    assert_equal "docs/a.txt", @zip["docs/a.txt"].name
    assert_nil @zip["ghost.txt"]
  end

  def test_include_accepts_a_string_or_an_entry
    assert @zip.include?("app.rb")
    refute @zip.include?("ghost.txt")
    assert @zip.include?(@zip.find_entry("app.rb"))
  end

  def test_include_is_an_exact_match
    # Decision, pinned: we look the stored name up as-is. rubyzip keys on
    # name.chomp("/"), so the rubyzip include?("docs") is true; this one isn't.
    # A documented difference, not an oversight.
    assert @zip.include?("docs/")
    refute @zip.include?("docs")
  end

  def test_each_with_a_block_yields_and_returns_the_array
    seen = []
    returned = @zip.each { |entry| seen << entry.name }
    assert_equal NAMES, seen
    # rubyzip's File#each delegates to Array#each, which returns the array.
    assert_equal NAMES, returned.map(&:name)
  end

  def test_each_without_a_block_returns_an_enumerator
    enum = @zip.each
    assert_instance_of Enumerator, enum
    assert_equal NAMES, enum.to_a.map(&:name)
  end

  def test_each_is_lazy_through_the_enumerator
    assert_equal ["b.txt", "app.rb"], @zip.each.first(2).map(&:name)
  end

  def test_each_entry_is_an_alias
    assert_equal NAMES, @zip.each_entry.to_a.map(&:name)
  end

  def test_glob_star_respects_path_separators
    # FNM_PATHNAME: `*` doesn't cross a `/`, so docs/a.txt is excluded.
    assert_equal ["b.txt", "café.txt"], @zip.glob("*.txt").map(&:name)
    assert_equal ["docs/a.txt"], @zip.glob("docs/*").map(&:name)
  end

  def test_glob_double_star_matches_zero_directories_too
    assert_equal ["b.txt", "café.txt", "docs/a.txt"], @zip.glob("**/*.txt").map(&:name)
  end

  def test_glob_matches_a_directory_without_the_trailing_slash
    # The stored name is "docs/"; we chomp it before matching, so the pattern a
    # human writes works.
    assert_equal ["docs/"], @zip.glob("docs").map(&:name)
  end

  def test_glob_supports_extglob_and_character_classes
    assert_equal ["b.txt", "app.rb"], @zip.glob("{b,a}*").map(&:name)
    assert_equal ["b.txt", "app.rb", "café.txt"], @zip.glob("[a-c]*").map(&:name)
  end

  def test_glob_with_no_match_is_empty
    assert_equal [], @zip.glob("*.nope")
  end

  def test_glob_with_a_block_yields_matches_and_returns_the_array
    yielded = []
    returned = @zip.glob("**/*.txt") { |entry| yielded << entry.name }
    assert_equal ["b.txt", "café.txt", "docs/a.txt"], yielded
    assert_equal 3, returned.size
  end

  def test_entries_survive_close
    # Entries are a snapshot taken out of the central directory, so their
    # metadata remains valid after the archive is closed.
    entry = @zip.find_entry("app.rb")
    @zip.close
    assert_equal "app.rb", entry.name
    refute entry.directory?
  end

  def test_entries_after_close_raise
    @zip.close
    assert_raises(LibZip::EntryError) { @zip.entries }
    assert_raises(LibZip::EntryError) { @zip.names }
  end

  def test_each_call_takes_a_fresh_snapshot
    first = @zip.entries
    second = @zip.entries
    refute_same first, second
    assert_equal first.map(&:name), second.map(&:name)
  end

  # A zip with zero entries is just an end-of-central-directory record: the
  # 4-byte signature "PK\x05\x06" plus 18 zero bytes (spec 4.3.22).
  def test_empty_archive
    path = File.join(@dir, "empty.zip")
    File.binwrite(path, "PK\x05\x06" + ("\x00" * 18))
    LibZip::File.open(path) do |zip|
      assert_equal [], zip.entries
      assert_equal [], zip.names
      assert_equal 0, zip.size
      assert_nil zip.find_entry("anything")
    end
  end

  def test_create_then_close_with_no_writes_creates_no_file
    # libzip won't write archives with no entries, on purpose
    # (zip_close.c:65): closing throws the archive away instead of creating
    # the file. The setting to opt in is
    # ZIP_AFL_CREATE_OR_KEEP_FILE_FOR_EMPTY_ARCHIVE, which we don't set.
    # Useful to know, instead of a surprise later.
    path = File.join(@dir, "untouched.zip")
    LibZip::File.open(path, create: true) { |zip| assert_equal 0, zip.size }
    refute File.exist?(path), "empty archive was written to disk"
  end

  def test_entries_reflect_writes_made_in_this_session
    # flags == 0 means "current in-memory state", so an entry added but not yet
    # written to disk is already visible. This is the path in zip_stat_index
    # that delegates to zip_source_stat instead of reading the central
    # directory.
    LibZip::File.open(@zip_path, create: true) do |zip|
      zip.add("one.txt", @src)
      zip.get_output_stream("docs/two.txt") { |stream| stream << "streamed\n" }
      assert_equal ["docs/two.txt", "one.txt"], zip.names.sort
      assert_equal 2, zip.size
      assert zip.find_entry("docs/two.txt").directory? == false
    end
    LibZip::File.open(@zip_path) do |zip|
      assert_equal ["docs/two.txt", "one.txt"], zip.names.sort
    end
  end
end
