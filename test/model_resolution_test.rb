# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../lib/learn_cli"

class ModelResolutionTest < Minitest::Test
  def test_learned_simulation_and_search_require_explicit_models
    error = assert_raises(ArgumentError) { GameSimulator.run(seed: 42, strategy: :learned) }
    assert_match "explicit model", error.message
    error = assert_raises(ArgumentError) { ImprovementSearch.search(seed: 42, strategy: :learned) }
    assert_match "explicit baseline_model:/rollout_model:", error.message
    board = GameSimulator.initial_board(seed: 42)
    assert_raises(ArgumentError) do
      ImprovementSearch.search(starting_board: board, baseline_score: 0, rollout_strategy: :learned)
    end
  end

  def test_collection_cannot_write_unidentified_learned_lessons
    Dir.mktmpdir do |directory|
      out = StringIO.new
      err = StringIO.new
      status = LearnCLI::CollectTraining.new.call(
        ["--strategy", "learned", "--seeds", "1000000", "--output", directory], out: out, err: err
      )
      assert_equal 1, status
      assert_match "explicit --model FILE", err.string
      assert_empty Dir.children(directory)
    end
  end

  def test_analyzer_rejects_implicit_learned_model_before_reading_a_trace
    error = assert_raises(ArgumentError) { LessonAnalyzer.new.analyze("unused.moves", strategy: :learned) }
    assert_match "explicit --model FILE", error.message
  end

  def test_analyze_records_the_explicit_resolved_teacher
    lesson = LessonAnalyzer.new.analyze("samples/manual_score_1184.moves", strategy: :learned,
                                        model: AutoPlayer::DEFAULT_MODEL_PATH, time_budget_seconds: 0)
    expected = LearningModel.provenance(LearnedPlayer.load(AutoPlayer::DEFAULT_MODEL_PATH))
    assert_equal expected.fetch(:model_sha256), lesson.dig(:search, :model_sha256)
    assert_equal expected.fetch(:model_sha256), lesson.fetch(:provenance).first.fetch(:model_sha256)
  end

  def test_explicit_learned_search_is_supported
    model = LearnedPlayer.load(AutoPlayer::DEFAULT_MODEL_PATH)
    result = ImprovementSearch.search(seed: 42, strategy: :learned, baseline_model: model,
                                      time_budget_seconds: 0)
    assert_equal GameSimulator.run(seed: 42, strategy: :learned, model: model).score, result.best_score
  end
end
