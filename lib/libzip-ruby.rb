# This file exists only so that `gem "libzip-ruby"` works without a `require:`
# option: Bundler auto-requires the gem name, and RubyGems' default file for
# `libzip-ruby` is `libzip-ruby.rb`.  The real entry point is `libzip.rb`.
require_relative "libzip"
