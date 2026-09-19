Gem::Specification.new do |spec|
  spec.name     = "libzip-ruby"
  # Single source of truth: build.zig reads this file and stamps the value into
  # LibZip::VERSION, script/package tags the release, so they cannot disagree.
  spec.version  = "0.1.0"
  spec.summary  = "libzip bindings for Ruby, with libzip and zlib linked in"
  # Placeholders, replace before the first release.
  spec.authors  = ["Jean-Paul Pierre Louis Fiorini"]
  spec.email    = ["fiorini751@proton.me"]
  spec.license  = "Apache-2.0"

  # The oldest interpreter we ship a compiled extension for (script/package).
  spec.required_ruby_version = ">= 3.3"

  # script/package sets this while assembling a precompiled gem, so the .gem
  # carries its own platform; a plain `gem build` stays platform-independent.
  spec.platform = Gem::Platform.new(ENV["LIBZIP_RUBY_PLATFORM"]) if ENV["LIBZIP_RUBY_PLATFORM"]

  spec.files         = Dir["lib/**/*"] + ["libzip-ruby.gemspec", "LICENSE"]
  spec.require_paths = ["lib"]
end
