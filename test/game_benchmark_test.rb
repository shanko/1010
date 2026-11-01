# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require "tmpdir"
require "open3"
require "rbconfig"
require_relative "../lib/game_simulator"

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
    assert_equal 0,
                 report.fetch(:pairwise_score_deltas).fetch(:first_fit).fetch(:first_fit).fetch(:summary).fetch(:mean)
    %i[score placed_tiles cleared_lines option_batches].each do |metric|
      assert baseline.fetch(:metrics).fetch(metric).key?(:percentile_10)
      assert baseline.fetch(:metrics).fetch(metric).key?(:percentile_90)
    end
  end

  def test_rejects_empty_duplicate_and_unknown_inputs
    assert_raises(ArgumentError) { GameBenchmark.run(seeds: [], strategies: [:jc]) }
    assert_raises(ArgumentError) { GameBenchmark.run(seeds: [1, 1], strategies: [:jc]) }
    assert_raises(ArgumentError) { GameBenchmark.run(seeds: [1], strategies: [:bogus]) }
    assert_raises(ArgumentError) { GameBenchmark.run(seeds: [1], workers: 0) }
  end

  def test_parallel_evaluation_preserves_seed_order_and_all_results
    options = {seeds: [9, 3, 5], strategies: %i[first_fit jc]}
    serial = GameBenchmark.run(**options)
    parallel = GameBenchmark.run(**options, workers: 2)

    assert_equal serial.fetch(:strategies), parallel.fetch(:strategies)
    assert_equal serial.fetch(:pairwise_score_deltas), parallel.fetch(:pairwise_score_deltas)
  end

  def test_failed_worker_does_not_write_a_partial_benchmark_report
    Dir.mktmpdir do |directory|
      output = File.join(directory, "report.json")
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "scripts/benchmark.rb", "--strategies", "first_fit",
                                               "--seeds", "1,2", "--workers", "2", "--max-moves", "1",
                                               "--output", output)
      refute status.success?
      assert_includes stderr, "benchmark worker failed; no complete report was written"
      refute File.exist?(output)
    end
  end

  def test_summarize_uses_nearest_rank_percentiles_and_population_deviation
    summary = GameBenchmark.summarize([1, 2, 3, 4, 5])

    assert_equal 3.0, summary[:mean]
    assert_equal 3, summary[:median]
    assert_equal 1, summary[:percentile_10]
    assert_equal 5, summary[:percentile_90]
    assert_in_delta Math.sqrt(2), summary[:standard_deviation], 0.000_001
  end

  def test_learned_benchmark_accepts_a_model_file_path
    model = {"schema_version"  => LearnedPlayer::MODEL_SCHEMA_VERSION,
             "feature_version" => ActionFeatures::VERSION,
             "feature_names"   => ActionFeatures::NAMES,
             "weights"         => ActionFeatures::NAMES.to_h {|name| [name, 0.0] }}
    Tempfile.create(["learned-model", ".json"]) do |file|
      file.write(JSON.generate(model))
      file.flush
      report = GameBenchmark.run(seeds: [3_000_000], strategies: [:learned], models: {learned: file.path})

      assert_equal 1, report.fetch(:strategies).fetch(:learned).fetch(:per_seed).size
    end
  end

  def test_named_models_are_compared_on_identical_seeds
    model = {"schema_version"  => LearnedPlayer::MODEL_SCHEMA_VERSION,
             "feature_version" => ActionFeatures::VERSION,
             "feature_names"   => ActionFeatures::NAMES,
             "weights"         => ActionFeatures::NAMES.to_h {|name| [name, 0.0] }}
    report = GameBenchmark.run(seeds: [3_000_000], strategies: %i[imitation reinforcement],
                               models: {imitation: model, reinforcement: model})

    assert_equal :imitation, report.dig(:strategies, :imitation, :per_seed).first.fetch(:strategy)
    assert_equal :reinforcement, report.dig(:strategies, :reinforcement, :per_seed).first.fetch(:strategy)
    assert_equal 0, report.dig(:pairwise_score_deltas, :reinforcement, :imitation, :summary, :mean)
  end

  def test_cli_keeps_named_models_when_strategies_flag_follows_them
    Dir.mktmpdir do |directory|
      model = {"schema_version"  => LearnedPlayer::MODEL_SCHEMA_VERSION,
               "feature_version" => ActionFeatures::VERSION,
               "feature_names"   => ActionFeatures::NAMES,
               "weights"         => ActionFeatures::NAMES.to_h {|name| [name, 0.0] }}
      path = File.join(directory, "model.json")
      output = File.join(directory, "report.json")
      File.write(path, JSON.generate(model))
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "scripts/benchmark.rb",
                                               "--comparison-model", "imitation=#{path}",
                                               "--strategies", "first_fit", "--seeds", "3", "--output", output)
      assert status.success?, stderr
      report = JSON.parse(File.read(output))
      assert_equal %w[first_fit imitation], report.fetch("strategies").keys
      assert_equal ActionFeatures::VERSION, report.dig("models", "imitation", "feature_version")
      assert_equal 64, report.dig("models", "imitation", "sha256").size
    end
  end
end
