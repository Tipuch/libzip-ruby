require "minitest/autorun"
require "libzip_ruby"

# test/fixtures/entries.zip was written by python3's zipfile, not by us: a
# UNIX-created archive with a real 0o40755 external attribute on `docs/` and a
# foreign tool's UTF-8 name. Our own writer can produce neither, so it is the
# only way to exercise entries that came from somewhere else.
#
# Defined here rather than in one test file: the runner loads every test file
# into a single process, so a per-file constant collides with
# "already initialized constant".
ENTRIES_ZIP = File.expand_path("fixtures/entries.zip", __dir__)
