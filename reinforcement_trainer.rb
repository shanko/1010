# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "game_simulator"
require_relative "learned_player"

# Versioned, append-only RL checkpoints and a separate selected-checkpoint pointer.
class RLCheckpointStore
  def initialize(directory: File.join(LessonStore::DIRECTORY, "checkpoints"))
    @directory = directory
  end

  def save(model, step:)
    FileUtils.mkdir_p(@directory)
    timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%S%6NZ")
    path = File.join(@directory, "reinforce-step-#{Integer(step)}-#{timestamp}.json")
    suffix = 0
    while File.exist?(path)
      suffix += 1
      path = File.join(@directory, "reinforce-step-#{Integer(step)}-#{timestamp}-#{suffix}.json")
    end
    File.write(path, JSON.pretty_generate(model) + "\n")
    path
  end

  def select(path, tuning_evaluation:)
    FileUtils.mkdir_p(@directory)
    pointer = {"schema_version" => 1, "selected_checkpoint" => File.basename(path),
               "tuning_evaluation" => tuning_evaluation}
    temporary = File.join(@directory, "selected.json.tmp-#{Process.pid}")
    File.write(temporary, JSON.pretty_generate(pointer) + "\n")
    File.rename(temporary, File.join(@directory, "selected.json"))
    File.join(@directory, "selected.json")
  ensure
    File.delete(temporary) if temporary && File.exist?(temporary)
  end
end

# REINFORCE with a rolling per-decision return baseline. Rewards are tile areas,
# so the undiscounted return is exactly final game score from the decision.
class ReinforcementTrainer
  Result = Struct.new(:model, :episodes, :global_step, :best_checkpoint,
                      :selected_pointer, :best_tuning_evaluation, :checkpoints,
                      keyword_init: true)

  def train(initial_model:, episode_count:, random_seed: 1, learning_rate: 0.01,
            temperature: 1.0, baseline_decay: 0.9, seeds: nil,
            tuning_seeds: LearningSeedSets.fetch(:tuning).first(20),
            checkpoint_interval: 10, checkpoint_store: RLCheckpointStore.new,
            resume: nil)
    episode_count = Integer(episode_count)
    learning_rate = Float(learning_rate)
    temperature = Float(temperature)
    baseline_decay = Float(baseline_decay)
    checkpoint_interval = Integer(checkpoint_interval)
    raise ArgumentError, "episode_count must be positive" unless episode_count.positive?
    raise ArgumentError, "learning_rate must be finite and positive" unless learning_rate.finite? && learning_rate.positive?
    raise ArgumentError, "temperature must be finite and positive" unless temperature.finite? && temperature.positive?
    raise ArgumentError, "baseline_decay must be in [0, 1)" unless baseline_decay.finite? && baseline_decay >= 0 && baseline_decay < 1
    raise ArgumentError, "checkpoint_interval must be positive" unless checkpoint_interval.positive?
    raise ArgumentError, "RL cannot train on the held-out seed set" if tuning_seeds.any? {|seed| LearningSeedSets::DEFINITIONS.fetch(:held_out).cover?(Integer(seed)) }

    source = resume ? LearnedPlayer.load(resume).model : normalize_model(initial_model)
    rl_state = source.fetch("reinforcement_learning", {})
    global_step = Integer(rl_state.fetch("global_step", 0))
    if rl_state["random_seed"] && Integer(rl_state["random_seed"]) != Integer(random_seed)
      raise ArgumentError, "resume random_seed must match the checkpoint"
    end
    training_seeds = seeds ? seeds.map {|seed| Integer(seed) } :
      LearningSeedSets.fetch(:training).drop(global_step).first(episode_count)
    unless training_seeds.size == episode_count && training_seeds.all? {|seed| LearningSeedSets::DEFINITIONS.fetch(:training).cover?(seed) }
      raise ArgumentError, "RL episode seeds must contain #{episode_count} training seeds"
    end
    tuning_seeds = tuning_seeds.map {|seed| Integer(seed) }
    raise ArgumentError, "tuning seeds must be non-empty and belong to the tuning set" if tuning_seeds.empty? || !tuning_seeds.all? {|seed| LearningSeedSets::DEFINITIONS.fetch(:tuning).cover?(seed) }

    model = JSON.parse(JSON.generate(source))
    model["reinforcement_learning"] = {
      "algorithm" => "reinforce_with_rolling_return_baseline",
      "optimizer" => {"name" => "sgd", "state" => "stateless"},
      "global_step" => global_step,
      "random_seed" => Integer(random_seed),
      "baseline_decay" => baseline_decay,
      "baseline_by_decision" => rl_state.fetch("baseline_by_decision", []),
      "episode_seeds" => Array(rl_state.fetch("episode_seeds", [])),
      "training_rewards" => Array(rl_state.fetch("training_rewards", []))
    }
    player = LearnedPlayer.new(model)
    baseline = model.dig("reinforcement_learning", "baseline_by_decision")
    trained_seeds = []
    checkpoints = []

    current_eval = evaluate(player.model, tuning_seeds)
    best_eval = current_eval
    best_path = checkpoint_store.save(checkpoint_model(player.model, learning_rate, temperature,
                                                        evaluated_seeds: tuning_seeds,
                                                        tuning_evaluation: current_eval), step: global_step)
    checkpoints << {path: best_path, evaluation: current_eval}

    episode_count.times do |episode_index|
      episode_seed = training_seeds.fetch(episode_index)
      trajectory, episode_score = run_episode(player, episode_seed,
                                               random_seed: random_seed, step: global_step,
                                               temperature: temperature)
      returns = Array.new(trajectory.size)
      cumulative = 0.0
      (trajectory.size - 1).downto(0) do |index|
        cumulative += trajectory[index][:reward]
        returns[index] = cumulative
      end

      trajectory.each_with_index do |entry, index|
        prior_baseline = baseline[index] || 0.0
        advantage = returns[index] - prior_baseline
        player.update_policy_gradient!(chosen_features: entry[:chosen_features],
                                       expected_features: entry[:expected_features],
                                       advantage: advantage, learning_rate: learning_rate)
      end
      returns.each_with_index do |value, index|
        baseline[index] = baseline[index] ? baseline[index] * baseline_decay + value * (1.0 - baseline_decay) : value
      end

      global_step += 1
      trained_seeds << episode_seed
      rl = player.model.fetch("reinforcement_learning")
      rl["global_step"] = global_step
      rl["episode_seeds"] << episode_seed
      rl["training_rewards"] << episode_score
      rl["baseline_by_decision"] = baseline

      final_episode = episode_index == episode_count - 1
      next unless (global_step % checkpoint_interval).zero? || final_episode

      evaluation = evaluate(player.model, tuning_seeds)
      checkpoint_model = checkpoint_model(player.model, learning_rate, temperature,
                                           evaluated_seeds: tuning_seeds,
                                           tuning_evaluation: evaluation)
      path = checkpoint_store.save(checkpoint_model, step: global_step)
      checkpoints << {path: path, evaluation: evaluation}
      if evaluation.fetch("mean_score") > best_eval.fetch("mean_score")
        best_eval = evaluation
        best_path = path
      end
    end

    selected_pointer = checkpoint_store.select(best_path, tuning_evaluation: best_eval)
    Result.new(model: player.model, episodes: trained_seeds, global_step: global_step,
               best_checkpoint: best_path, selected_pointer: selected_pointer,
               best_tuning_evaluation: best_eval, checkpoints: checkpoints)
  end

  private

  def normalize_model(model)
    return LearnedPlayer.load(model).model if model.is_a?(String)

    LearnedPlayer.new(model).model
  end

  def run_episode(player, seed, random_seed:, step:, temperature:)
    session_random = Random.new(seed)
    session_random.rand(2**32) # reserve the player's simulator stream
    board = Board1010.new(random: Random.new(session_random.rand(2**32)))
    board.deal_if_needed
    sample_random = Random.new((Integer(random_seed) ^ (Integer(step) * 2_654_435_761)) % (2**32))
    trajectory = []
    until board.game_over?
      sample = player.sample_action(board, random: sample_random, temperature: temperature)
      action = sample.fetch(:action)
      move = board.play(*action)
      raise RuntimeError, "sampled RL action was illegal" unless move

      trajectory << {chosen_features: sample.fetch(:chosen_features),
                     expected_features: sample.fetch(:expected_features), reward: move.placed.size}
    end
    score = trajectory.sum {|entry| entry.fetch(:reward) }
    raise RuntimeError, "RL episode score invariant failed" unless score == board.score

    [trajectory, score]
  end

  def evaluate(model, seeds)
    report = GameBenchmark.run(seeds: seeds, strategies: [:learned], models: {learned: model})
    strategy = report.fetch(:strategies).fetch(:learned)
    {"seeds" => seeds, "mean_score" => strategy.fetch(:metrics).fetch(:score).fetch(:mean),
     "score_summary" => strategy.fetch(:metrics).fetch(:score),
     "per_seed" => strategy.fetch(:per_seed)}
  end

  def checkpoint_model(model, learning_rate, temperature, evaluated_seeds: nil,
                       tuning_evaluation: nil)
    copy = JSON.parse(JSON.generate(model))
    rl = copy.fetch("reinforcement_learning")
    rl["learning_rate"] = learning_rate
    rl["exploration_temperature"] = temperature
    rl["tuning_evaluation"] = tuning_evaluation if tuning_evaluation
    rl["evaluated_tuning_seeds"] = evaluated_seeds if evaluated_seeds
    copy
  end
end
