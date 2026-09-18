require_relative "helper"
require "digest"
require "open3"

class InputStreamTest < Minitest::Test
  PYTHON_ZIP = <<~PYTHON
    import sys
    import zipfile

    source_path, archive_path, compression = sys.argv[1:]
    method = zipfile.ZIP_STORED if compression == "stored" else zipfile.ZIP_DEFLATED
    with zipfile.ZipFile(archive_path, "w", compression=method) as archive:
        archive.write(source_path, "data.bin")
        archive.writestr("empty.bin", b"")
  PYTHON

  def setup
    @dir = Dir.mktmpdir
    @source_path = File.join(@dir, "source.bin")
    @stored_path = File.join(@dir, "stored.zip")
    @deflated_path = File.join(@dir, "deflated.zip")

    @content = (0...100_000).map { |index| index % 251 }.pack("C*")
    File.binwrite(@source_path, @content)

    create_archive(@stored_path, "stored")
    create_archive(@deflated_path, "deflated")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def create_archive(path, compression)
    _stdout, stderr, status = Open3.capture3(
      "python3",
      "-c",
      PYTHON_ZIP,
      @source_path,
      path,
      compression,
    )
    assert status.success?, "python3 failed: #{stderr}"
  end

  def each_archive
    [@stored_path, @deflated_path].each do |path|
      zip = LibZip::File.open(path)
      yield zip
    ensure
      zip&.close unless zip&.closed?
    end
  end

  def test_reads_stored_and_deflated_entries_in_small_chunks
    each_archive do |zip|
      [1, 1024, 65_536].each do |chunk_size|
        stream = zip.get_input_stream("data.bin")
        chunks = []
        while (chunk = stream.read(chunk_size))
          chunks << chunk
        end

        assert_equal Digest::SHA256.hexdigest(@content), Digest::SHA256.hexdigest(chunks.join)
        assert stream.eof?
        stream.close
      end
    end
  end

  def test_read_without_length_returns_remaining_bytes
    each_archive do |zip|
      stream = zip.get_input_stream("data.bin")

      result = stream.read

      assert_equal @content, result
      assert_equal Encoding::BINARY, result.encoding
      assert stream.eof?
      assert_equal "", stream.read
      stream.close
    end
  end

  def test_read_length_returns_at_most_requested_bytes
    each_archive do |zip|
      stream = zip.get_input_stream("data.bin")

      assert_equal @content.byteslice(0, 7), stream.read(7)
      assert_equal @content.byteslice(7, 1_024), stream.read(1_024)
      assert_equal @content.byteslice(1_031, 3), stream.read(3)
      stream.close
    end
  end

  def test_read_zero_returns_empty_binary_string_without_consuming
    each_archive do |zip|
      stream = zip.get_input_stream("data.bin")

      result = stream.read(0)

      assert_equal "", result
      assert_equal Encoding::BINARY, result.encoding
      refute stream.eof?
      assert_equal @content.byteslice(0, 1), stream.read(1)
      stream.close
    end
  end

  def test_read_at_eof_returns_nil_but_read_without_length_returns_empty_string
    each_archive do |zip|
      stream = zip.get_input_stream("data.bin")
      stream.read

      assert_nil stream.read(1)
      assert_equal "", stream.read
      stream.close
    end
  end

  def test_empty_entry_has_expected_eof_behavior
    each_archive do |zip|
      stream = zip.get_input_stream("empty.bin")

      refute_nil stream.read
      assert_equal "", stream.read
      assert_nil stream.read(1)
      assert stream.eof?
      stream.close
    end
  end

  def test_close_is_idempotent_and_operations_after_close_raise
    each_archive do |zip|
      stream = zip.get_input_stream("data.bin")
      stream.close

      assert stream.closed?
      stream.close
      assert_raises(LibZip::EntryError) { stream.read }
      assert_raises(LibZip::EntryError) { stream.read(1) }
      assert_raises(LibZip::EntryError) { stream.eof? }
    end
  end

  def test_archive_close_closes_open_streams
    zip = LibZip::File.open(@stored_path)
    stream = zip.get_input_stream("data.bin")
    assert_equal @content.byteslice(0, 4), stream.read(4)

    zip.close

    assert zip.closed?
    assert stream.closed?
    assert_raises(LibZip::EntryError) { stream.read(1) }
  end

  def test_multiple_open_streams_are_closed_with_archive
    zip = LibZip::File.open(@stored_path)
    first = zip.get_input_stream("data.bin")
    second = zip.get_input_stream("empty.bin")

    zip.close

    assert first.closed?
    assert second.closed?
  end

  def test_block_form_returns_block_value_and_closes_stream
    stream = nil
    result = nil

    zip = LibZip::File.open(@stored_path)
    result = zip.get_input_stream("data.bin") do |candidate|
      stream = candidate
      assert_equal @content.byteslice(0, 5), candidate.read(5)
      :block_result
    end

    assert_equal :block_result, result
    assert stream.closed?
    zip.close
  end

  def test_block_form_closes_stream_when_block_raises
    stream = nil
    zip = LibZip::File.open(@stored_path)

    assert_raises(RuntimeError) do
      zip.get_input_stream("data.bin") do |candidate|
        stream = candidate
        raise "boom"
      end
    end

    assert stream.closed?
    zip.close
  end

  def test_archive_block_exception_closes_stream_before_discarding_archive
    stream = nil
    archive = nil

    assert_raises(RuntimeError) do
      LibZip::File.open(@stored_path) do |candidate|
        archive = candidate
        stream = candidate.get_input_stream("data.bin")
        raise "boom"
      end
    end

    assert archive.closed?
    assert stream.closed?
  end

  def test_missing_entry_raises_not_found
    zip = LibZip::File.open(@stored_path)
    assert_raises(LibZip::NotFoundError) { zip.get_input_stream("missing.bin") }
    zip.close
  end
end
