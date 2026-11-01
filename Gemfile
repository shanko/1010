# frozen_string_literal: true

source "https://rubygems.org"

# The game window. `bundle install` includes it by default. Headless machines
# that only train or benchmark can skip it: `bundle config set --local without gui`.
# On macOS with Homebrew's sdl2-compat, gosu needs extra link flags to build;
# see "Installation" in README.md.
group :gui do
  gem "gosu", "~> 1.4"
end

group :development, :test do
  gem "minitest"
  gem "rake"
  gem "rubocop", "~> 1.75.0"
  gem "tsort"
end
