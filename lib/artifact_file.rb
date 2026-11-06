# frozen_string_literal: true

require "fileutils"
require "tempfile"

# Shared collision checks and atomic replacement for complete saved artifacts.
# Live append-only game logs deliberately use their own exclusive writer.
module ArtifactFile
  def self.canonical_path(path)
    path = File.expand_path(path)
    return File.realpath(path) if File.exist?(path) || File.symlink?(path)

    File.join(canonical_path(File.dirname(path)), File.basename(path))
  end

  def self.same_file?(first, second)
    canonical_path(first) == canonical_path(second) ||
      (File.exist?(first) && File.exist?(second) && File.identical?(first, second))
  end

  def self.distinct!(*paths)
    paths.combination(2).each do |first, second|
      next unless same_file?(first, second)

      raise ArgumentError, "artifact paths must differ: #{first} and #{second}"
    end
  end

  # Validate the staged bytes, if requested, before replacing any existing file.
  def self.write(path, text)
    destination = canonical_path(path)
    FileUtils.mkdir_p(File.dirname(destination))
    Tempfile.create([".1010-", ".tmp"], File.dirname(destination)) do |file|
      file.write(text)
      file.flush
      file.fsync
      yield file.path if block_given?
      file.close
      File.rename(file.path, destination)
    end
    path
  end
end
