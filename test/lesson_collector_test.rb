# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/lesson_collector"

class LessonCollectorTest < Minitest::Test
  def test_collected_complete_seed_lesson_replays_actual_and_candidate
    Dir.mktmpdir do |directory|
      result = LessonCollector.new.collect(seeds: [1_000_000], strategy: :sam,
                                           time_budget_seconds: 5, beam_width: 4,
                                           max_states: 500, max_rollouts: 8,
                                           store: LessonStore.new(directory: directory))
      path = Dir.glob(File.join(directory, "*.json")).fetch(0)
      lesson = LessonStore.read(path)
      actual = LessonStore.replay(lesson, "actual_sequence")
      candidate = LessonStore.replay(lesson, "candidate_sequence")

      assert_equal 1, result.episodes
      assert_equal 1, result.lessons_saved
      assert_equal "improved", lesson.fetch("outcome")
      assert_lesson_records_work_budgets(lesson)
      assert_operator lesson.fetch("candidate_score"), :>, lesson.fetch("actual_score")
      assert_equal lesson.fetch("actual_score"), actual.score
      assert_equal lesson.fetch("candidate_score"), candidate.score
      assert actual.game_over?
      assert candidate.game_over?
      assert_equal lesson.fetch("candidate_offers").first, lesson.fetch("actual_offers").first
    end
  end

  def test_collector_does_not_save_time_capped_results
    Dir.mktmpdir do |directory|
      ticks = 0.0
      result = LessonCollector.new.collect(seeds: [1_000_000], strategy: :sam,
                                           time_budget_seconds: 0.01, max_states: 100,
                                           max_rollouts: 10,
                                           store: LessonStore.new(directory: directory),
                                           clock: -> { ticks += 0.02 })

      assert_equal 0, result.lessons_saved
      assert_empty Dir.glob(File.join(directory, "*.json"))
    end
  end

  def test_collector_rejects_seeds_outside_training_range
    error = assert_raises(ArgumentError) do
      LessonCollector.new.collect(seeds: [LearningSeedSets.fetch(:held_out).first])
    end
    assert_match "lesson collection seeds must belong to the training seed set", error.message
  end

  private

  def assert_lesson_records_work_budgets(lesson)
    assert_equal 8, lesson.dig("search", "max_rollouts")
    assert_operator lesson.dig("search", "explored_rollouts"), :>, 0
    refute lesson["search"].key?("elapsed_seconds")
  end
end
