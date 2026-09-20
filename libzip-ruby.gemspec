Gem::Specification.new do |spec|
  spec.name     = "libzip-ruby"
  # Single source of truth: build.zig reads this file and stamps the value into
  # LibZip::VERSION, script/package tags the release, so they cannot disagree.
  spec.version  = "0.1.0"
  spec.summary  = "libzip bindings for Ruby, with libzip and zlib linked in"
  spec.description = <<~TEXT
    Ruby bindings for libzip, the C library for reading and writing zip
    archives.
  TEXT
  spec.authors  = ["Jean-Paul Pierre Louis Fiorini"]
  spec.email    = ["fiorini751@proton.me"]
  spec.license  = "Apache-2.0"

  # The oldest interpreter we ship a compiled extension for (script/package).
  spec.required_ruby_version = ">= 3.3"

  # script/package sets this while assembling a precompiled gem, so the .gem
  # carries its own platform; a plain `gem build` stays platform-independent.
  spec.platform = Gem::Platform.new(ENV["LIBZIP_RUBY_PLATFORM"]) if ENV["LIBZIP_RUBY_PLATFORM"]

  spec.homepage = "https://github.com/Tipuch/libzip-ruby"
  # No homepage_uri: spec.homepage already is that URL, and RubyGems complains
  # when 2 metadata keys point at the same URL.
  spec.metadata = {
    "source_code_uri"       => spec.homepage,
    "bug_tracker_uri"       => "#{spec.homepage}/issues",
    "documentation_uri"     => "https://tipuch.github.io/libzip-ruby/",
    "rubygems_mfa_required" => "true",
  }

  spec.files         = Dir["lib/**/*"] + Dir["doc/*.rb"] +
                       ["libzip-ruby.gemspec", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  # RubyGems documents require_paths + extra_rdoc_files at install time, and
  # the entire API is written out in doc/api.rb (the extension is Zig, which
  # RDoc can't parse), so `ri LibZip::File` works only if it's listed here.
  spec.extra_rdoc_files = Dir["doc/*.rb"] + ["README.md"]
  spec.rdoc_options = ["--main", "README.md", "--title", "libzip-ruby #{spec.version}"]
end
