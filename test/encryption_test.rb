require_relative "helper"
require "fileutils"
require "open3"
require "tmpdir"

# Encryption coverage for plan 06.
#
# Our writer produces the AES fixtures for the read paths (the binding is the
# only AES writer on this machine). Cross-tool coverage uses 7-Zip when it is
# installed: it's the only external writer here that can emit AES (`-mem=AES256`)
# as well as traditional ZipCrypto (`-mem=ZipCrypto`). AES-128/192 fixtures from
# an external tool aren't available; 7-Zip's zip handler only writes AES-256.
class EncryptionTest < Minitest::Test
    SEVEN_ZIP = "/usr/bin/7z"
    PASSWORD = "correct horse battery staple"
    OTHER_PASSWORD = "a different password"
    CONTENT = ("libzip encryption payload\n" * 4096).freeze
    AES_METHODS = {
        aes128: LibZip::Entry::AES_128,
        aes192: LibZip::Entry::AES_192,
        aes256: LibZip::Entry::AES_256,
    }.freeze

    def setup
        @dir = Dir.mktmpdir
        @zip_path = File.join(@dir, "test.zip")
        @source_path = File.join(@dir, "source.bin")
        File.binwrite(@source_path, CONTENT)
    end

    def teardown
        FileUtils.remove_entry(@dir)
    end

    def write_archive(entry = "data.bin", options = {})
        LibZip::File.open(@zip_path, create: true) do |zip|
            zip.add(entry, @source_path, **{ encryption: :aes256, password: PASSWORD }.merge(options))
        end
    end

    def assert_reads_with(entry, password, content = CONTENT)
        LibZip::File.open(@zip_path, password: password) do |zip|
            assert_equal content, zip.read(entry)
        end
    end

    # --- write paths -------------------------------------------------------

    def test_add_writes_aes_entries_with_the_expected_metadata
        AES_METHODS.each do |symbol, method|
            path = File.join(@dir, "#{symbol}.zip")
            LibZip::File.open(path, create: true) do |zip|
                zip.add("data.bin", @source_path, encryption: symbol, password: PASSWORD)
            end

            LibZip::File.open(path) do |zip|
                entry = zip.get_entry("data.bin")
                assert_equal method, entry.encryption_method
                assert entry.encrypted?
                assert_equal CONTENT.bytesize, entry.size
            end
        end
    end

    def test_output_stream_writes_aes_entries
        LibZip::File.open(@zip_path, create: true) do |zip|
            zip.get_output_stream("data.bin", encryption: :aes256, password: PASSWORD) do |stream|
                stream.write(CONTENT)
            end
        end

        LibZip::File.open(@zip_path) do |zip|
            assert_equal LibZip::Entry::AES_256, zip.get_entry("data.bin").encryption_method
        end

        assert_reads_with("data.bin", PASSWORD)
    end

    def test_output_stream_uses_the_archive_default_password
        LibZip::File.open(@zip_path, create: true, password: PASSWORD) do |zip|
            zip.get_output_stream("data.bin", encryption: :aes128) { |stream| stream.write(CONTENT) }
        end

        assert_reads_with("data.bin", PASSWORD)
    end

    def test_add_uses_the_archive_default_password
        LibZip::File.open(@zip_path, create: true, password: PASSWORD) do |zip|
            zip.add("data.bin", @source_path, encryption: :aes256)
        end

        assert_reads_with("data.bin", PASSWORD)
    end

    # With no per-entry password and no archive default, libzip turns away the
    # entry while the archive is being closed.
    def test_encrypting_without_any_password_raises
        assert_raises(LibZip::InvalidArgumentError) do
            LibZip::File.open(@zip_path, create: true) do |zip|
                zip.add("data.bin", @source_path, encryption: :aes256)
            end
        end
    end

    def test_unencrypted_entries_keep_none
        LibZip::File.open(@zip_path, create: true) do |zip|
            zip.add("plain.bin", @source_path)
            zip.add("secret.bin", @source_path, encryption: :aes256, password: PASSWORD)
        end

        LibZip::File.open(@zip_path) do |zip|
            plain = zip.get_entry("plain.bin")
            assert_equal LibZip::Entry::NONE, plain.encryption_method
            refute plain.encrypted?
            assert_equal CONTENT, zip.read("plain.bin")

            secret = zip.get_entry("secret.bin")
            assert_equal LibZip::Entry::AES_256, secret.encryption_method
            assert secret.encrypted?
        end
    end

    def test_empty_entry_round_trips
        empty = File.join(@dir, "empty.bin")
        File.binwrite(empty, "")

        LibZip::File.open(@zip_path, create: true) do |zip|
            zip.add("empty.bin", empty, encryption: :aes256, password: PASSWORD)
        end

        LibZip::File.open(@zip_path, password: PASSWORD) do |zip|
            assert_equal "", zip.read("empty.bin")
            assert_equal "", zip.get_input_stream("empty.bin").read
        end
    end

    def test_unicode_name_and_comment_round_trip
        name = "données/rapport éàü.txt"
        LibZip::File.open(@zip_path, create: true) do |zip|
            zip.add(name, @source_path, encryption: :aes256, password: PASSWORD)
            zip.set_comment(name, "chiffré")
        end

        LibZip::File.open(@zip_path, password: PASSWORD) do |zip|
            assert_equal CONTENT, zip.read(name)
            assert_equal "chiffré", zip.get_entry(name).comment
        end
    end

    def test_repeated_writes_overwrite_the_encrypted_entry
        write_archive
        write_archive("data.bin", password: OTHER_PASSWORD)
        assert_reads_with("data.bin", OTHER_PASSWORD)
    end

    # --- read paths --------------------------------------------------------

    def test_read_uses_a_per_call_password
        write_archive("data.bin", password: OTHER_PASSWORD)
        assert_reads_with("data.bin", OTHER_PASSWORD)
    end

    def test_password_assignment_after_open
        write_archive

        LibZip::File.open(@zip_path) do |zip|
            zip.password = PASSWORD
            assert_equal CONTENT, zip.read("data.bin")
        end
    end

    def test_read_without_a_password_raises_password_error
        write_archive

        LibZip::File.open(@zip_path) do |zip|
            assert_raises(LibZip::PasswordError) { zip.read("data.bin") }
            assert_raises(LibZip::PasswordError) { zip.get_input_stream("data.bin") }
        end
    end

    def test_read_with_a_wrong_password_raises_password_error
        write_archive

        LibZip::File.open(@zip_path, password: "wrong") do |zip|
            assert_raises(LibZip::PasswordError) { zip.read("data.bin") }
            assert_raises(LibZip::PasswordError) { zip.get_input_stream("data.bin").read }
        end
    end

    def test_wrong_password_overrides_a_correct_default
        write_archive

        LibZip::File.open(@zip_path, password: PASSWORD) do |zip|
            assert_raises(LibZip::PasswordError) { zip.read("data.bin", password: "wrong") }
        end
    end

    def test_input_stream_reads_encrypted_entry_in_chunks
        write_archive

        LibZip::File.open(@zip_path, password: PASSWORD) do |zip|
            stream = zip.get_input_stream("data.bin")
            chunks = []
            chunks << stream.read(1) until stream.eof?
            assert_equal CONTENT, chunks.join
            assert stream.eof?
        end
    end

    def test_input_stream_block_form_reads_encrypted_entry
        write_archive

        LibZip::File.open(@zip_path) do |zip|
            result = zip.get_input_stream("data.bin", password: PASSWORD) do |stream|
                stream.read
            end
            assert_equal CONTENT, result
        end
    end

    def test_read_of_a_large_encrypted_entry_is_verified
        big = "x" * (512 * 1024)
        big_path = File.join(@dir, "big.bin")
        File.binwrite(big_path, big)

        LibZip::File.open(@zip_path, create: true) do |zip|
            zip.add("big.bin", big_path, encryption: :aes192, password: PASSWORD)
        end

        LibZip::File.open(@zip_path, password: PASSWORD) do |zip|
            assert_equal big, zip.read("big.bin")
        end
    end

    # --- option validation -------------------------------------------------

    def test_pkware_writes_are_rejected
        assert_raises(LibZip::InvalidArgumentError) do
            LibZip::File.open(@zip_path, create: true) do |zip|
                zip.add("data.bin", @source_path, encryption: :pkware, password: PASSWORD)
            end
        end

        assert_raises(LibZip::InvalidArgumentError) do
            LibZip::File.open(@zip_path, create: true) do |zip|
                zip.get_output_stream("data.bin", encryption: :pkware, password: PASSWORD)
            end
        end
    end

    def test_unknown_encryption_symbol_is_rejected
        assert_raises(LibZip::InvalidArgumentError) do
            LibZip::File.open(@zip_path, create: true) do |zip|
                zip.add("data.bin", @source_path, encryption: :rot13, password: PASSWORD)
            end
        end
    end

    def test_password_without_encryption_is_rejected
        assert_raises(LibZip::InvalidArgumentError) do
            LibZip::File.open(@zip_path, create: true) do |zip|
                zip.add("data.bin", @source_path, password: PASSWORD)
            end
        end
    end

    def test_none_with_a_password_is_rejected
        assert_raises(LibZip::InvalidArgumentError) do
            LibZip::File.open(@zip_path, create: true) do |zip|
                zip.get_output_stream("data.bin", encryption: :none, password: PASSWORD)
            end
        end
    end

    def test_encryption_option_must_be_a_symbol
        assert_raises(LibZip::InvalidArgumentError) do
            LibZip::File.open(@zip_path, create: true) do |zip|
                zip.add("data.bin", @source_path, encryption: "aes256", password: PASSWORD)
            end
        end
    end

    # --- external tools ----------------------------------------------------

    def test_reads_an_externally_written_aes_256_archive
        skip "7-Zip not installed" unless File.executable?(SEVEN_ZIP)

        _out, err, status = Open3.capture3(
            SEVEN_ZIP, "a", "-tzip", "-mem=AES256", "-p#{PASSWORD}", @zip_path, @source_path
        )
        assert status.success?, "7z failed: #{err}"

        LibZip::File.open(@zip_path) do |zip|
            assert_equal LibZip::Entry::AES_256, zip.get_entry("source.bin").encryption_method
        end

        assert_reads_with("source.bin", PASSWORD)
    end

    def test_reads_an_externally_written_zipcrypto_archive
        skip "7-Zip not installed" unless File.executable?(SEVEN_ZIP)

        _out, err, status = Open3.capture3(
            SEVEN_ZIP, "a", "-tzip", "-mem=ZipCrypto", "-p#{PASSWORD}", @zip_path, @source_path
        )
        assert status.success?, "7z failed: #{err}"

        LibZip::File.open(@zip_path) do |zip|
            assert_equal LibZip::Entry::TRAD_PKWARE, zip.get_entry("source.bin").encryption_method
            assert zip.get_entry("source.bin").encrypted?
        end

        assert_reads_with("source.bin", PASSWORD)
    end

    def test_zipcrypto_reads_without_a_password_raise_password_error
        skip "7-Zip not installed" unless File.executable?(SEVEN_ZIP)

        Open3.capture3(SEVEN_ZIP, "a", "-tzip", "-mem=ZipCrypto", "-p#{PASSWORD}", @zip_path, @source_path)

        LibZip::File.open(@zip_path) do |zip|
            assert_raises(LibZip::PasswordError) { zip.read("source.bin") }
        end
    end

    def test_external_tool_reads_what_we_wrote
        skip "7-Zip not installed" unless File.executable?(SEVEN_ZIP)

        write_archive

        _out, err, status = Open3.capture3(SEVEN_ZIP, "t", "-p#{PASSWORD}", @zip_path)
        assert status.success?, "7z could not verify our archive: #{err}"
    end

    def test_external_tool_reads_our_unencrypted_entries_without_a_password
        skip "7-Zip not installed" unless File.executable?(SEVEN_ZIP)

        LibZip::File.open(@zip_path, create: true) do |zip|
            zip.add("plain.bin", @source_path)
            zip.add("secret.bin", @source_path, encryption: :aes256, password: PASSWORD)
        end

        _out, err, status = Open3.capture3(SEVEN_ZIP, "e", "-p#{PASSWORD}", "-o#{@dir}", @zip_path, "plain.bin")
        assert status.success?, "7z failed: #{err}"
        assert_equal CONTENT, File.binread(File.join(@dir, "plain.bin"))
    end
end
