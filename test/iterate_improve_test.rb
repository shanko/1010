# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require "rbconfig"
require_relative "../lib/lesson_analyzer"

class IterateImproveTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/iterate_improve.rb", __dir__)
  SOURCE = File.expand_path("../samples/manual_score_930.moves", __dir__)
  IMPROVED = File.expand_path("../samples/improved_score_34944.moves", __dir__)

  def prefixes(output)
    output.scan(/== round \d+: .*splice at (\d+)/).flatten.map(&:to_i)
  end

  def test_missing_improvement_counts_as_failure_and_prefix_uses_retained_moves
    Dir.mktmpdir do |directory|
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, SCRIPT, SOURCE, "--rounds", "3", "--patience", "2", "--time", "0", "--outdir", directory
      )
      assert status.success?, stderr
      retained = LessonAnalyzer.new.final_trajectory(GameTrace.read(SOURCE)).fetch(:sequence).size
      assert_equal [(retained * 0.90).to_i, (retained * 0.86).to_i], prefixes(stdout)
      assert_empty Dir[File.join(directory, "*.moves")]
    end
  end

  def child_search_stub(directory)
    hook = File.join(directory, "child_search_stub.rb")
    File.write(hook, <<~RUBY)
      require "fileutils"
      Kernel.prepend(Module.new do
        def system(*arguments, **)
          @search_calls = (@search_calls || 0) + 1
          if @search_calls == 2
            output = arguments.fetch(arguments.index("--output") + 1)
            FileUtils.cp(ENV.fetch("ITERATE_IMPROVED_FIXTURE"), output)
          end
          true
        end
      end)
    RUBY
    hook
  end

  def test_improvement_becomes_the_base_and_resets_consecutive_failures
    Dir.mktmpdir do |directory|
      hook = child_search_stub(directory)
      stdout, stderr, status = Open3.capture3(
        {"ITERATE_IMPROVED_FIXTURE" => IMPROVED}, RbConfig.ruby, "-r", hook, SCRIPT, SOURCE,
        "--rounds", "5", "--patience", "2", "--outdir", File.join(directory, "results")
      )
      assert status.success?, stderr
      chosen = prefixes(stdout)
      assert_equal 4, chosen.size # failure, improvement, failure, failure
      moves = GameTrace.read(IMPROVED).events.count {|event| event.first == :move }
      assert_equal (moves * 0.90).to_i, chosen[2]
      assert_equal (moves * 0.86).to_i, chosen[3]
      assert_includes stdout, "new best: 34944"
      assert_includes stdout, "done: best 34944"
    end
  end
end
