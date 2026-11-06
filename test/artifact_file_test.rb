# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/artifact_file"
require_relative "../lib/game_improver"

class ArtifactFileTest < Minitest::Test
  def test_failed_validation_preserves_existing_bytes_and_removes_staging_file
    Dir.mktmpdir do |directory|
      path = File.join(directory, "saved.json")
      File.write(path, "original")
      assert_raises(ArgumentError) do
        ArtifactFile.write(path, "replacement") { raise ArgumentError, "invalid artifact" }
      end
      assert_equal "original", File.read(path)
      assert_equal ["saved.json"], Dir.children(directory)
      ArtifactFile.write(path, "valid")
      assert_equal "valid", File.read(path)
    end
  end

  # Every collision must fail before parsing, search, or any output write.
  def test_improvement_rejects_source_and_output_aliases_before_writing
    Dir.mktmpdir do |directory|
      source = File.join(directory, "source.moves")
      output = File.join(directory, "output.moves")
      symlink = File.join(directory, "symlink.moves")
      hardlink = File.join(directory, "hardlink.moves")
      File.write(source, "source bytes")
      File.write(output, "output bytes")
      File.symlink(source, symlink)
      File.link(source, hardlink)
      [[output, source], [output, output], [source, "report.json"],
       [output, symlink], [output, hardlink], [symlink, "report.json"]].each do |trace_path, report_path|
        error = assert_raises(ArgumentError) do
          GameImprover.new.improve(source, output_path: trace_path, report_path: report_path)
        end
        assert_match "paths must differ", error.message
        assert_equal "source bytes", File.read(source)
        assert_equal "output bytes", File.read(output)
      end
    end
  end

  def test_aliases_through_parent_directories_are_rejected_for_new_files
    Dir.mktmpdir do |directory|
      File.symlink(directory, File.join(directory, "alias"))
      assert_raises(ArgumentError) do
        ArtifactFile.distinct!(File.join(directory, "new.moves"), File.join(directory, "alias", "new.moves"))
      end
    end
  end

  def test_invalid_searched_trajectory_does_not_replace_an_existing_trace
    Dir.mktmpdir do |directory|
      path = File.join(directory, "out.moves")
      File.write(path, "old trace")
      trace = GameTrace.read("samples/manual_score_930.moves")
      baseline = LessonAnalyzer.new.final_trajectory(trace)
      assert_raises(ArgumentError) do
        GameTraceWriter.write(path, source: trace, offers: baseline[:offers],
                              sequence: baseline[:sequence], expected_score: trace.final_score + 1)
      end
      assert_equal "old trace", File.read(path)
    end
  end
end
