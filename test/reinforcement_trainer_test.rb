# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require "rbconfig"
require_relative "../reinforcement_trainer"

class ReinforcementTrainerTest < Minitest::Test
  def test_positive_return_policy_gradient_moves_preference_toward_rewarding_action
    policy = LearnedPlayer.new(empty_model)
    board = Board1010.new(options: [Board1010::TILES[:dot], Board1010::TILES[:sq2]])
    legal = policy.legal_actions(board)
    expected = ActionFeatures::NAMES.to_h do |name|
      [name, legal.sum {|_action, features| features.fetch(name) } / legal.size]
    end
    square = legal.find {|action, _features| action == [1, 0, 0] }.last
    square_action_features = ActionFeatures.extract(board, 1, 0, 0)
    dot_action_features = ActionFeatures.extract(board, 0, 0, 0)
    prior_difference = policy.score(square_action_features) - policy.score(dot_action_features)

    policy.update_policy_gradient!(chosen_features: square, expected_features: expected,
                                   advantage: 4.0, learning_rate: 0.1)

    assert_operator policy.score(square_action_features) - policy.score(dot_action_features), :>, prior_difference
  end

  def test_policy_gradient_matches_finite_difference_at_non_unit_temperatures
    [0.5, 2.0].each do |temperature|
      model = empty_model
      model.fetch("weights")["tile_dot"] = 0.3
      policy = LearnedPlayer.new(model)
      chosen_value = 1.1
      other_value = -0.4
      weight = policy.weights.fetch("tile_dot")
      chosen_probability = 1.0 / (1.0 + Math.exp(weight * (other_value - chosen_value) / temperature))
      expected_value = chosen_probability * chosen_value + (1.0 - chosen_probability) * other_value
      chosen = ActionFeatures::NAMES.to_h {|name| [name, 0.0] }
      expected = chosen.dup
      chosen["tile_dot"] = chosen_value
      expected["tile_dot"] = expected_value

      log_probability = lambda do |candidate_weight|
        logits = [candidate_weight * chosen_value / temperature,
                  candidate_weight * other_value / temperature]
        maximum = logits.max
        Math.log(Math.exp(logits.first - maximum) / logits.sum {|value| Math.exp(value - maximum) })
      end
      delta = 1e-5
      finite_difference = (log_probability.call(weight + delta) - log_probability.call(weight - delta)) / (2.0 * delta)
      learning_rate = 1e-5
      policy.update_policy_gradient!(chosen_features: chosen, expected_features: expected,
                                     advantage: 1.0, learning_rate: learning_rate,
                                     temperature: temperature)
      estimated_gradient = (policy.weights.fetch("tile_dot") - weight) / learning_rate

      assert_in_delta finite_difference, estimated_gradient, 1e-5, "temperature #{temperature}"
    end
  end

  def test_training_writes_evaluated_versioned_checkpoints_and_selected_pointer
    Dir.mktmpdir do |directory|
      store = RLCheckpointStore.new(directory: directory)
      result = ReinforcementTrainer.new.train(initial_model: empty_model, episode_count: 1,
                                               random_seed: 13, seeds: [1_000_000],
                                               tuning_seeds: [2_000_000], checkpoint_interval: 1,
                                               checkpoint_store: store)
      repeated = ReinforcementTrainer.new.train(initial_model: empty_model, episode_count: 1,
                                                 random_seed: 13, seeds: [1_000_000],
                                                 tuning_seeds: [2_000_000], checkpoint_interval: 1,
                                                 checkpoint_store: store)
      selected = LearnedPlayer.load(result.selected_pointer)
      checkpoint = JSON.parse(File.read(result.checkpoints.last.fetch(:path)))

      assert_equal 1, result.global_step
      assert_equal [1_000_000], result.episodes
      assert_equal result.model.fetch("weights"), repeated.model.fetch("weights")
      assert_equal result.model.dig("reinforcement_learning", "training_rewards"),
                   repeated.model.dig("reinforcement_learning", "training_rewards")
      assert_equal 1, checkpoint.dig("reinforcement_learning", "global_step")
      assert_equal "sgd", checkpoint.dig("reinforcement_learning", "optimizer", "name")
      assert_equal [2_000_000], checkpoint.dig("reinforcement_learning", "evaluated_tuning_seeds")
      selected_checkpoint = JSON.parse(File.read(result.best_checkpoint))
      assert_equal selected_checkpoint.fetch("weights"), selected.model.fetch("weights")
      assert File.file?(result.selected_pointer)
    end
  end

  def test_cli_default_checkpoint_interval_matches_trainer_default
    assert_equal 10, ReinforcementTrainer::DEFAULT_CHECKPOINT_INTERVAL
    Dir.mktmpdir do |directory|
      model_path = File.join(directory, "model.json")
      checkpoint_directory = File.join(directory, "checkpoints")
      File.write(model_path, JSON.generate(empty_model))
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, "scripts/learn.rb", "train-rl", "--model", model_path,
        "--episodes", "2", "--seeds", "1000000,1000001",
        "--tuning-seeds", "2000000", "--checkpoints", checkpoint_directory
      )

      assert status.success?, stderr
      assert_equal 2, JSON.parse(stdout).fetch("checkpoints").size,
                   "initial plus final checkpoint; no interval checkpoint before episode 10"
    end
  end

  def test_resume_preserves_baseline_and_advances_step_without_overwriting_checkpoint
    Dir.mktmpdir do |directory|
      store = RLCheckpointStore.new(directory: directory)
      initial = ReinforcementTrainer.new.train(initial_model: empty_model, episode_count: 1,
                                                random_seed: 23, seeds: [1_000_010],
                                                tuning_seeds: [2_000_010], checkpoint_interval: 1,
                                                checkpoint_store: store)
      first_checkpoint = initial.checkpoints.last.fetch(:path)
      checkpoint_count_before_resume = Dir.glob(File.join(directory, "reinforce-step-*.json")).size
      first_baseline_size = JSON.parse(File.read(first_checkpoint)).dig("reinforcement_learning", "baseline_by_decision").size
      resumed = ReinforcementTrainer.new.train(initial_model: first_checkpoint, resume: first_checkpoint,
                                                episode_count: 1, random_seed: 23, seeds: [1_000_011],
                                                tuning_seeds: [2_000_010], checkpoint_interval: 1,
                                                checkpoint_store: store)

      assert_equal 2, resumed.global_step
      assert_equal [1_000_010, 1_000_011], resumed.model.dig("reinforcement_learning", "episode_seeds")
      assert_operator resumed.model.dig("reinforcement_learning", "baseline_by_decision").size, :>=, first_baseline_size
      assert File.file?(first_checkpoint)
      assert_equal checkpoint_count_before_resume + 1, Dir.glob(File.join(directory, "reinforce-step-*.json")).size
      assert_equal true, resumed.checkpoints.first.fetch(:existing)
    end
  end

  def test_rejects_held_out_training_seeds_and_tuning_seeds
    error = assert_raises(ArgumentError) do
      ReinforcementTrainer.new.train(initial_model: empty_model, episode_count: 1,
                                      seeds: [LearningSeedSets.fetch(:held_out).first],
                                      tuning_seeds: [LearningSeedSets.fetch(:tuning).first])
    end
    assert_match "training seeds", error.message
    assert_match "held_out seed set", error.message

    error = assert_raises(ArgumentError) do
      ReinforcementTrainer.new.train(initial_model: empty_model, episode_count: 1,
                                      seeds: [LearningSeedSets.fetch(:training).first],
                                      tuning_seeds: [LearningSeedSets.fetch(:held_out).first])
    end
    assert_match "held-out", error.message
  end

  def test_training_seed_count_error_names_both_counts
    error = assert_raises(ArgumentError) do
      ReinforcementTrainer.new.train(initial_model: empty_model, episode_count: 2,
                                      seeds: [1_000_000], tuning_seeds: [2_000_000])
    end
    assert_match "--seeds has 1 seed but --episodes is 2", error.message
  end

  def test_automatic_selection_keeps_better_checkpoint_and_rescores_different_seed_lists
    Dir.mktmpdir do |directory|
      store = RLCheckpointStore.new(directory: directory)
      previous = store.save(empty_model, step: 1)
      candidate = store.save(empty_model, step: 2)
      store.select(previous, tuning_evaluation: {"seeds" => [2_000_000], "mean_score" => 100.0})

      kept = store.select_if_better(candidate, tuning_evaluation: {"seeds" => [2_000_000], "mean_score" => 99.0})
      assert_equal false, kept.fetch(:selection_changed)
      assert_equal previous, kept.fetch(:selected_checkpoint)
      equal = store.select_if_better(candidate, tuning_evaluation: {"seeds" => [2_000_000], "mean_score" => 100.0})
      assert_equal false, equal.fetch(:selection_changed)

      rescored = store.select_if_better(candidate,
                                        tuning_evaluation: {"seeds" => [2_000_001], "mean_score" => 99.0}) do |path|
        assert_equal previous, path
        {"seeds" => [2_000_001], "mean_score" => 100.5}
      end
      assert_equal true, rescored.fetch(:previous_rescored)
      assert_equal false, rescored.fetch(:selection_changed)

      promoted = store.select_if_better(candidate,
                                        tuning_evaluation: {"seeds" => [2_000_001], "mean_score" => 101.0}) do |path|
        assert_equal previous, path
        {"seeds" => [2_000_001], "mean_score" => 100.5}
      end
      assert_equal true, promoted.fetch(:selection_changed)
      assert_equal candidate, promoted.fetch(:selected_checkpoint)

      unchanged = store.select_if_better(previous,
                                         tuning_evaluation: {"seeds" => [2_000_001], "mean_score" => 101.0}) do
        flunk "matching tuning results should not need rescoring"
      end
      assert_equal false, unchanged.fetch(:selection_changed)
    end
  end

  def test_selection_command_evaluates_only_tuning_seeds_and_writes_pointer
    Dir.mktmpdir do |directory|
      checkpoint = File.join(directory, "checkpoint.json")
      File.write(checkpoint, JSON.pretty_generate(empty_model))
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "scripts/learn.rb", "select",
                                               "--checkpoint", checkpoint,
                                               "--tuning-seeds", "2000000")
      assert status.success?, stderr
      summary = JSON.parse(stdout)
      assert_equal [2_000_000], summary.dig("tuning_evaluation", "seeds")
      assert File.file?(summary.fetch("selected_pointer"))
      assert_equal 1, LearnedPlayer.load(summary.fetch("selected_pointer")).model.fetch("schema_version")
    end
  end

  private

  def empty_model
    {"schema_version" => LearnedPlayer::MODEL_SCHEMA_VERSION,
     "feature_version" => ActionFeatures::VERSION,
     "feature_names" => ActionFeatures::NAMES,
     "weights" => ActionFeatures::NAMES.to_h {|name| [name, 0.0] }}
  end
end
