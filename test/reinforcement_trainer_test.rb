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

  def test_resume_preserves_baseline_and_advances_step_without_overwriting_checkpoint
    Dir.mktmpdir do |directory|
      store = RLCheckpointStore.new(directory: directory)
      initial = ReinforcementTrainer.new.train(initial_model: empty_model, episode_count: 1,
                                                random_seed: 23, seeds: [1_000_010],
                                                tuning_seeds: [2_000_010], checkpoint_interval: 1,
                                                checkpoint_store: store)
      first_checkpoint = initial.checkpoints.last.fetch(:path)
      first_baseline_size = JSON.parse(File.read(first_checkpoint)).dig("reinforcement_learning", "baseline_by_decision").size
      resumed = ReinforcementTrainer.new.train(initial_model: first_checkpoint, resume: first_checkpoint,
                                                episode_count: 1, random_seed: 23, seeds: [1_000_011],
                                                tuning_seeds: [2_000_010], checkpoint_interval: 1,
                                                checkpoint_store: store)

      assert_equal 2, resumed.global_step
      assert_equal [1_000_010, 1_000_011], resumed.model.dig("reinforcement_learning", "episode_seeds")
      assert_operator resumed.model.dig("reinforcement_learning", "baseline_by_decision").size, :>=, first_baseline_size
      assert File.file?(first_checkpoint)
      refute_equal first_checkpoint, resumed.best_checkpoint
      assert_operator Dir.glob(File.join(directory, "reinforce-step-*.json")).size, :>=, 3
    end
  end

  def test_rejects_held_out_training_seeds_and_tuning_seeds
    error = assert_raises(ArgumentError) do
      ReinforcementTrainer.new.train(initial_model: empty_model, episode_count: 1,
                                      seeds: [LearningSeedSets.fetch(:held_out).first],
                                      tuning_seeds: [LearningSeedSets.fetch(:tuning).first])
    end
    assert_match "training seeds", error.message

    error = assert_raises(ArgumentError) do
      ReinforcementTrainer.new.train(initial_model: empty_model, episode_count: 1,
                                      seeds: [LearningSeedSets.fetch(:training).first],
                                      tuning_seeds: [LearningSeedSets.fetch(:held_out).first])
    end
    assert_match "held-out", error.message
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
