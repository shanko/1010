# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
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
    relative_path = Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(File.expand_path(@directory))).to_s
    pointer = {"schema_version" => 1, "selected_checkpoint" => relative_path,
               "tuning_evaluation" => tuning_evaluation}
    temporary = File.join(@directory, "selected.json.tmp-#{Process.pid}")
    File.write(temporary, JSON.pretty_generate(pointer) + "\n")
    File.rename(temporary, File.join(@directory, "selected.json"))
    File.join(@directory, "selected.json")
  ensure
    File.delete(temporary) if temporary && File.exist?(temporary)
  end

  # Training may promote a candidate only when its mean is strictly higher on
  # the same tuning seeds as the currently selected model. Manual `select`
  # remains an explicit override.
  def select_if_better(path, tuning_evaluation:)
    pointer_path = File.join(@directory, "selected.json")
    previous = if File.file?(pointer_path)
                 JSON.parse(File.read(pointer_path))
               end
    previous_checkpoint = previous && File.join(@directory, previous.fetch("selected_checkpoint"))
    if previous && !File.file?(previous_checkpoint)
      raise ArgumentError, "selected checkpoint does not exist: #{previous_checkpoint}"
    end
    previous_evaluation = previous && previous["tuning_evaluation"]
    rescored = false
    if previous && previous_evaluation&.fetch("seeds", nil) != tuning_evaluation.fetch("seeds")
      raise ArgumentError, "selected checkpoint cannot be compared: tuning seed list differs and no evaluator was provided" unless block_given?
      raise ArgumentError, "selected checkpoint does not exist: #{previous_checkpoint}" unless File.file?(previous_checkpoint)

      previous_evaluation = yield(previous_checkpoint)
      rescored = true
    end
    should_select = !previous || tuning_evaluation.fetch("mean_score") > previous_evaluation.fetch("mean_score")
    selected_pointer = should_select ? select(path, tuning_evaluation: tuning_evaluation) : pointer_path
    {path: selected_pointer, selection_changed: should_select,
     previous_checkpoint: previous_checkpoint, selected_checkpoint: should_select ? path : previous_checkpoint,
     previous_evaluation: previous_evaluation, previous_rescored: rescored}
  rescue JSON::ParserError, KeyError => error
    raise ArgumentError, "invalid selected checkpoint pointer: #{error.message}"
  end
end

# REINFORCE with a rolling per-decision return baseline. Rewards are tile areas,
# so the undiscounted return is exactly final game score from the decision.
class ReinforcementTrainer
  DEFAULT_CHECKPOINT_INTERVAL = 10

  Result = Struct.new(:model, :episodes, :global_step, :best_checkpoint,
                      :selected_pointer, :best_tuning_evaluation, :checkpoints,
                      :selection_changed, :previous_selected_checkpoint,
                      keyword_init: true)

  def train(initial_model:, episode_count:, random_seed: 1, learning_rate: 0.01,
            temperature: 1.0, baseline_decay: 0.9, seeds: nil,
            tuning_seeds: LearningSeedSets.fetch(:tuning).first(20),
            checkpoint_interval: DEFAULT_CHECKPOINT_INTERVAL, checkpoint_store: RLCheckpointStore.new,
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

    source_path = resolved_checkpoint_path(resume) if resume
    source = resume ? LearnedPlayer.load(resume).model : normalize_model(initial_model)
    rl_state = source.fetch("reinforcement_learning", {})
    global_step = Integer(rl_state.fetch("global_step", 0))
    if rl_state["random_seed"] && Integer(rl_state["random_seed"]) != Integer(random_seed)
      raise ArgumentError, "resume random_seed must match the checkpoint"
    end
    training_seeds = seeds ? seeds.map {|seed| Integer(seed) } :
      LearningSeedSets.fetch(:training).drop(global_step).first(episode_count)
    unless training_seeds.size == episode_count
      raise ArgumentError, "--seeds has #{training_seeds.size} #{training_seeds.size == 1 ? 'seed' : 'seeds'} but --episodes is #{episode_count}"
    end
    invalid_seed = training_seeds.find {|seed| !LearningSeedSets::DEFINITIONS.fetch(:training).cover?(seed) }
    if invalid_seed
      set_name = LearningSeedSets::DEFINITIONS.find {|_name, range| range.cover?(invalid_seed) }&.first || :known
      raise ArgumentError, "seed #{invalid_seed} is in #{set_name} seed set; RL training must use training seeds (#{LearningSeedSets::DEFINITIONS.fetch(:training)})"
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

    stored_eval = rl_state.dig("tuning_evaluation")
    stored_seeds = rl_state["evaluated_tuning_seeds"]
    current_eval = if resume && stored_eval && stored_seeds == tuning_seeds
                     stored_eval
                   else
                     evaluate(player.model, tuning_seeds)
                   end
    best_eval = current_eval
    if resume
      best_path = source_path
      checkpoints << {path: best_path, evaluation: current_eval, existing: true}
    else
      best_path = checkpoint_store.save(checkpoint_model(player.model, learning_rate, temperature,
                                                          evaluated_seeds: tuning_seeds,
                                                          tuning_evaluation: current_eval), step: global_step)
      checkpoints << {path: best_path, evaluation: current_eval}
    end

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
                                       advantage: advantage, learning_rate: learning_rate,
                                       temperature: temperature)
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

    selection = checkpoint_store.select_if_better(best_path, tuning_evaluation: best_eval) do |checkpoint_path|
      evaluate(LearnedPlayer.load(checkpoint_path).model, tuning_seeds)
    end
    selected_pointer = selection.fetch(:path)
    Result.new(model: player.model, episodes: trained_seeds, global_step: global_step,
               best_checkpoint: best_path, selected_pointer: selected_pointer,
               best_tuning_evaluation: best_eval, checkpoints: checkpoints,
               selection_changed: selection.fetch(:selection_changed),
               previous_selected_checkpoint: selection.fetch(:previous_checkpoint))
  end

  private

  def normalize_model(model)
    return LearnedPlayer.load(model).model if model.is_a?(String)

    LearnedPlayer.new(model).model
  end

  def resolved_checkpoint_path(path)
    data = JSON.parse(File.read(path))
    return path unless data["selected_checkpoint"]

    File.expand_path(data.fetch("selected_checkpoint"), File.dirname(path))
  rescue JSON::ParserError => error
    raise ArgumentError, "invalid learned policy JSON: #{error.message}"
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
