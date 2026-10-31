# frozen_string_literal: true

require "minitest/autorun"
require_relative "../game_simulator"

class GameBenchmarkTest < Minitest::Test
  def test_reports_metrics_and_paired_seed_differences
    report = GameBenchmark.run(seeds: [5, 9, 12], strategies: %i[first_fit jc])
    baseline = report.fetch(:strategies).fetch(:first_fit)
    comparison = report.fetch(:strategies).fetch(:jc)

    assert_equal [5, 9, 12], report.fetch(:seeds)
    assert_equal 3, baseline.fetch(:metrics).fetch(:score).fetch(:count)
    assert_equal 3, baseline.fetch(:per_seed).size
    assert_equal 3, comparison.fetch(:paired_score_delta_vs_baseline).fetch(:count)
    assert_equal 0, baseline.fetch(:paired_score_delta_vs_baseline).fetch(:mean)
    %i[score placed_tiles cleared_lines option_batches].each do |metric|
      assert baseline.fetch(:metrics).fetch(metric).key?(:percentile_10)
      assert baseline.fetch(:metrics).fetch(metric).key?(:percentile_90)
    end
  end

  def test_rejects_empty_duplicate_and_unknown_inputs
    assert_raises(ArgumentError) { GameBenchmark.run(seeds: [], strategies: [:jc]) }
    assert_raises(ArgumentError) { GameBenchmark.run(seeds: [1, 1], strategies: [:jc]) }
    assert_raises(ArgumentError) { GameBenchmark.run(seeds: [1], strategies: [:bogus]) }
  end

  def test_summarize_uses_nearest_rank_percentiles_and_population_deviation
    summary = GameBenchmark.summarize([1, 2, 3, 4, 5])

    assert_equal 3.0, summary[:mean]
    assert_equal 3, summary[:median]
    assert_equal 1, summary[:percentile_10]
    assert_equal 5, summary[:percentile_90]
    assert_in_delta Math.sqrt(2), summary[:standard_deviation], 0.000_001
  end
end
