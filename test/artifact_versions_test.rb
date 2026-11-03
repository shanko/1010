# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/lesson_collector"
require_relative "../lib/lesson_analyzer"
require_relative "../lib/game_log"

class ArtifactVersionsTest < Minitest::Test
  def test_legacy_trace_fixtures_replay_with_explicitly_unrecorded_rule_versions
    {"samples/manual_score_1184.moves" => 2, "samples/manual_score_930.moves" => 3}.each do |path, version|
      trace = GameTrace.read(path)
      assert_equal version, trace.format_version
      assert_nil trace.rule_version
      assert_equal trace.final_score, GameTrace.replay(trace).score
    end
  end

  def test_new_trace_records_current_rules_and_rejects_unknown_rules_during_analysis
    Dir.mktmpdir do |directory|
      board = Board1010.new(options: [Tile.fetch(:dot)])
      log = GameLog.new(board: board, mode: "test", directory: directory)
      log.finish(reason: "stopped", score: 0)
      trace = GameTrace.read(log.path)
      assert_equal 4, trace.format_version
      assert_equal GameRules::VERSION, trace.rule_version
      File.write(log.path, File.read(log.path).sub("r#{GameRules::VERSION}\n", "r999\n"))
      error = assert_raises(ArgumentError) { LessonAnalyzer.new.analyze(log.path) }
      assert_match "rule version 999", error.message
      assert_match "matching game rules", error.message
    end
  end

  def test_new_lesson_records_source_and_runtime_versions
    lesson = LessonAnalyzer.new.analyze("samples/manual_score_1184.moves", time_budget_seconds: 0)
    assert_equal 2, lesson.fetch(:schema_version)
    assert_equal GameRules::VERSION, lesson.dig(:versions, :rule)
    assert_equal GameSimulator::VERSION, lesson.dig(:versions, :simulator)
    assert_equal 2, lesson.dig(:versions, :source_trace)
  end

  def test_training_rejects_each_mismatched_new_lesson_version
    Dir.mktmpdir do |directory|
      fixture = JSON.parse(File.read("test/fixtures/lesson-v2.json"))
      %w[rule simulator source_trace search].each do |name|
        lesson = Marshal.load(Marshal.dump(fixture))
        if name == "search"
          lesson["search"]["version"] = 999
        else
          lesson["versions"][name] = 999
        end
        File.write(File.join(directory, "bad.json"), JSON.generate(lesson))
        error = assert_raises(ArgumentError) { ImitationTrainer.new.train(directory: directory) }
        assert_match name, error.message
        assert_match(/matching|recollect/, error.message)
      end
    end
  end

  def test_historical_lessons_require_opt_in_and_reproduce_training_weights
    Dir.mktmpdir do |directory|
      LessonCollector.new.collect(seeds: [1_000_000], max_states: 500, max_rollouts: 8,
                                  store: LessonStore.new(directory: directory))
      expected = ImitationTrainer.new.train(directory: directory, epochs: 1)
      path = Dir[File.join(directory, "*.json")].fetch(0)
      lesson = JSON.parse(File.read(path))
      lesson["schema_version"] = 1
      lesson.delete("versions")
      File.write(path, JSON.generate(lesson))
      error = assert_raises(ArgumentError) { ImitationTrainer.new.train(directory: directory, epochs: 1) }
      assert_match "--allow-legacy-lessons", error.message
      actual = ImitationTrainer.new.train(directory: directory, epochs: 1, allow_legacy_lessons: true)
      assert_equal expected.model.fetch("weights"), actual.model.fetch("weights")
      assert_equal true, actual.model.dig("training", "allow_legacy_lessons")
    end
  end

  def test_original_v1_fixture_remains_readable_for_historical_replay
    lesson = LessonStore.read("test/fixtures/lesson-v1.json")
    assert_equal 1, lesson.fetch("schema_version")
    assert_equal lesson.fetch("actual_score"), LessonStore.replay(lesson, "actual_sequence").score
  end
end
