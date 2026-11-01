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
    File.write(path, "#{JSON.pretty_generate(model)}\n")
    path
  end

  def select(path, tuning_evaluation:)
    FileUtils.mkdir_p(@directory)
    directory = Pathname.new(File.expand_path(@directory))
    relative_path = Pathname.new(File.expand_path(path)).relative_path_from(directory).to_s
    pointer = {"schema_version" => 1, "selected_checkpoint" => relative_path,
               "tuning_evaluation" => tuning_evaluation}
    temporary = File.join(@directory, "selected.json.tmp-#{Process.pid}")
    File.write(temporary, "#{JSON.pretty_generate(pointer)}\n")
    File.rename(temporary, File.join(@directory, "selected.json"))
    File.join(@directory, "selected.json")
  ensure
    File.delete(temporary) if temporary && File.exist?(temporary)
  end

  # Training may promote a candidate only when its mean is strictly higher on
  # the same tuning seeds as the currently selected model. Manual `select`
  # remains an explicit override.
  def select_if_better(path, tuning_evaluation:, &evaluator)
    pointer_path = File.join(@directory, "selected.json")
    previous = read_pointer(pointer_path)
    previous_checkpoint = checkpoint_path(previous)
    previous_evaluation, rescored = comparable_evaluation(previous, previous_checkpoint, tuning_evaluation, evaluator)
    should_select = better_evaluation?(previous, previous_evaluation, tuning_evaluation)
    selected_pointer = should_select ? select(path, tuning_evaluation: tuning_evaluation) : pointer_path
    {path: selected_pointer, selection_changed: should_select,
     previous_checkpoint: previous_checkpoint, selected_checkpoint: should_select ? path : previous_checkpoint,
     previous_evaluation: previous_evaluation, previous_rescored: rescored}
  rescue JSON::ParserError, KeyError => e
    raise ArgumentError, "invalid selected checkpoint pointer: #{e.message}"
  end

  private

  def read_pointer(path)
    JSON.parse(File.read(path)) if File.file?(path)
  end

  def checkpoint_path(pointer)
    return unless pointer

    path = File.join(@directory, pointer.fetch("selected_checkpoint"))
    raise ArgumentError, "selected checkpoint does not exist: #{path}" unless File.file?(path)

    path
  end

  def comparable_evaluation(previous, checkpoint, current, evaluator)
    evaluation = previous && previous["tuning_evaluation"]
    return [evaluation, false] unless previous && evaluation&.fetch("seeds", nil) != current.fetch("seeds")

    unless evaluator
      raise ArgumentError,
            "selected checkpoint cannot be compared: tuning seed list differs and no evaluator was provided"
    end

    [evaluator.call(checkpoint), true]
  end

  def better_evaluation?(previous, previous_evaluation, current)
    !previous || current.fetch("mean_score") > previous_evaluation.fetch("mean_score")
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
  TrainingState = Struct.new(:player, :baseline, :training_seeds, :tuning_seeds,
                             :global_step, :trained_seeds, :checkpoints,
                             :best_path, :best_eval, keyword_init: true)

  def train(initial_model:, episode_count:, random_seed: 1, learning_rate: 0.01,
            temperature: 1.0, baseline_decay: 0.9, seeds: nil,
            tuning_seeds: LearningSeedSets.fetch(:tuning).first(20),
            checkpoint_interval: DEFAULT_CHECKPOINT_INTERVAL, checkpoint_store: RLCheckpointStore.new,
            resume: nil)
    options = validate_training_options(episode_count: episode_count, random_seed: random_seed,
                                        learning_rate: learning_rate, temperature: temperature,
                                        baseline_decay: baseline_decay, seeds: seeds,
                                        tuning_seeds: tuning_seeds, checkpoint_interval: checkpoint_interval)
    state = start_training(initial_model, resume, options, checkpoint_store)
    train_episodes(state, options, checkpoint_store)
    finish_training(state, checkpoint_store)
  end

  private

  def validate_training_options(episode_count:, random_seed:, learning_rate:, temperature:,
                                baseline_decay:, seeds:, tuning_seeds:, checkpoint_interval:)
    values = {episode_count: Integer(episode_count), random_seed: Integer(random_seed),
              learning_rate: Float(learning_rate), temperature: Float(temperature),
              baseline_decay: Float(baseline_decay), seeds: seeds, tuning_seeds: tuning_seeds,
              checkpoint_interval: Integer(checkpoint_interval)}
    validate_training_values!(values)
    values
  end

  def validate_training_values!(values)
    raise ArgumentError, "episode_count must be positive" unless values[:episode_count].positive?

    validate_positive_finite!(values[:learning_rate], "learning_rate")
    validate_positive_finite!(values[:temperature], "temperature")
    validate_baseline_decay!(values[:baseline_decay])
    raise ArgumentError, "checkpoint_interval must be positive" unless values[:checkpoint_interval].positive?
  end

  def validate_positive_finite!(value, name)
    raise ArgumentError, "#{name} must be finite and positive" unless value.finite? && value.positive?
  end

  def validate_baseline_decay!(value)
    return if value.finite? && value >= 0 && value < 1

    raise ArgumentError, "baseline_decay must be in [0, 1)"
  end

  def start_training(initial_model, resume, options, checkpoint_store)
    source_path, source, rl_state, global_step = training_source(initial_model, resume)
    validate_resume_seed!(rl_state, options[:random_seed])
    training_seeds = validated_training_seeds(options, global_step)
    tuning_seeds = LearningSeedSets.validate!(options[:tuning_seeds], set: :tuning, purpose: "RL tuning")
    player = build_player(source, rl_state, options, global_step)
    state = new_training_state(player, training_seeds, tuning_seeds, global_step)
    initialize_checkpoint(state: state, resume: resume, source_path: source_path,
                          rl_state: rl_state, options: options, checkpoint_store: checkpoint_store)
    state
  end

  def training_source(initial_model, resume)
    path = resolved_checkpoint_path(resume) if resume
    source = resume ? LearnedPlayer.load(resume).model : normalize_model(initial_model)
    rl_state = source.fetch("reinforcement_learning", {})
    [path, source, rl_state, Integer(rl_state.fetch("global_step", 0))]
  end

  def new_training_state(player, training_seeds, tuning_seeds, global_step)
    TrainingState.new(player: player,
                      baseline: player.model.dig("reinforcement_learning", "baseline_by_decision"),
                      training_seeds: training_seeds, tuning_seeds: tuning_seeds,
                      global_step: global_step, trained_seeds: [], checkpoints: [])
  end

  def validate_resume_seed!(rl_state, random_seed)
    return unless rl_state["random_seed"] && Integer(rl_state["random_seed"]) != random_seed

    raise ArgumentError, "resume random_seed must match the checkpoint"
  end

  def validated_training_seeds(options, global_step)
    seeds = if options[:seeds]
              options[:seeds].map {|seed| Integer(seed) }
            else
              LearningSeedSets.fetch(:training).drop(global_step).first(options[:episode_count])
            end
    unless seeds.size == options[:episode_count]
      label = seeds.size == 1 ? "seed" : "seeds"
      raise ArgumentError, "--seeds has #{seeds.size} #{label} but --episodes is #{options[:episode_count]}"
    end

    LearningSeedSets.validate!(seeds, set: :training, purpose: "RL training")
  end

  def build_player(source, rl_state, options, global_step)
    model = JSON.parse(JSON.generate(source))
    model["reinforcement_learning"] = reinforcement_state(rl_state, options, global_step)
    LearnedPlayer.new(model)
  end

  def reinforcement_state(previous, options, global_step)
    {"algorithm" => "reinforce_with_rolling_return_baseline",
     "optimizer" => {"name" => "sgd", "state" => "stateless"},
     "global_step" => global_step, "random_seed" => options[:random_seed],
     "baseline_decay" => options[:baseline_decay],
     "baseline_by_decision" => previous.fetch("baseline_by_decision", []),
     "episode_seeds" => Array(previous.fetch("episode_seeds", [])),
     "training_rewards" => Array(previous.fetch("training_rewards", []))}
  end

  def initialize_checkpoint(state:, resume:, source_path:, rl_state:, options:, checkpoint_store:)
    current = current_evaluation(state.player, resume, rl_state, state.tuning_seeds)
    state.best_eval = current
    state.best_path = initial_checkpoint(state: state, resume: resume, source_path: source_path,
                                         evaluation: current, options: options,
                                         checkpoint_store: checkpoint_store)
  end

  def current_evaluation(player, resume, rl_state, tuning_seeds)
    stored = rl_state["tuning_evaluation"]
    seeds = rl_state["evaluated_tuning_seeds"]
    return stored if resume && stored && seeds == tuning_seeds

    evaluate(player.model, tuning_seeds)
  end

  def initial_checkpoint(state:, resume:, source_path:, evaluation:, options:, checkpoint_store:)
    if resume
      state.checkpoints << {path: source_path, evaluation: evaluation, existing: true}
      return source_path
    end

    model = checkpoint_model(state.player.model, options[:learning_rate], options[:temperature],
                             evaluated_seeds: state.tuning_seeds, tuning_evaluation: evaluation)
    path = checkpoint_store.save(model, step: state.global_step)
    state.checkpoints << {path: path, evaluation: evaluation}
    path
  end

  def train_episodes(state, options, checkpoint_store)
    options[:episode_count].times do |index|
      train_episode(state, index, options, checkpoint_store)
    end
  end

  def train_episode(state, index, options, checkpoint_store)
    seed = state.training_seeds.fetch(index)
    trajectory, score = run_episode(state.player, seed, random_seed: options[:random_seed],
                                    step: state.global_step, temperature: options[:temperature])
    update_episode(state, trajectory, options)
    state.global_step += 1
    state.trained_seeds << seed
    record_episode(state, seed, score)
    checkpoint_after_episode(state, index, options, checkpoint_store)
  end

  def update_episode(state, trajectory, options)
    returns = episode_returns(trajectory)
    update_policy(state.player, state.baseline, trajectory, returns, options)
    update_return_baseline(state.baseline, returns, options[:baseline_decay])
  end

  def episode_returns(trajectory)
    returns = Array.new(trajectory.size)
    cumulative = 0.0
    (trajectory.size - 1).downto(0) do |index|
      cumulative += trajectory[index][:reward]
      returns[index] = cumulative
    end
    returns
  end

  def update_policy(player, baseline, trajectory, returns, options)
    trajectory.each_with_index do |entry, index|
      advantage = returns[index] - (baseline[index] || 0.0)
      player.update_policy_gradient!(chosen_features: entry[:chosen_features],
                                     expected_features: entry[:expected_features],
                                     advantage: advantage, learning_rate: options[:learning_rate],
                                     temperature: options[:temperature])
    end
  end

  def update_return_baseline(baseline, returns, decay)
    returns.each_with_index do |value, index|
      previous = baseline[index]
      baseline[index] = previous ? (previous * decay) + (value * (1.0 - decay)) : value
    end
  end

  def record_episode(state, seed, score)
    rl = state.player.model.fetch("reinforcement_learning")
    rl["global_step"] = state.global_step
    rl["episode_seeds"] << seed
    rl["training_rewards"] << score
    rl["baseline_by_decision"] = state.baseline
  end

  def checkpoint_after_episode(state, index, options, checkpoint_store)
    final = index == options[:episode_count] - 1
    return unless (state.global_step % options[:checkpoint_interval]).zero? || final

    save_evaluated_checkpoint(state, options, checkpoint_store)
  end

  def save_evaluated_checkpoint(state, options, checkpoint_store)
    evaluation = evaluate(state.player.model, state.tuning_seeds)
    model = checkpoint_model(state.player.model, options[:learning_rate], options[:temperature],
                             evaluated_seeds: state.tuning_seeds, tuning_evaluation: evaluation)
    path = checkpoint_store.save(model, step: state.global_step)
    state.checkpoints << {path: path, evaluation: evaluation}
    promote_checkpoint(state, path, evaluation)
  end

  def promote_checkpoint(state, path, evaluation)
    return unless evaluation.fetch("mean_score") > state.best_eval.fetch("mean_score")

    state.best_eval = evaluation
    state.best_path = path
  end

  def finish_training(state, checkpoint_store)
    selection = checkpoint_store.select_if_better(state.best_path, tuning_evaluation: state.best_eval) do |path|
      evaluate(LearnedPlayer.load(path).model, state.tuning_seeds)
    end
    training_result(state, selection)
  end

  def training_result(state, selection)
    Result.new(model: state.player.model, episodes: state.trained_seeds, global_step: state.global_step,
               best_checkpoint: state.best_path, selected_pointer: selection.fetch(:path),
               best_tuning_evaluation: state.best_eval, checkpoints: state.checkpoints,
               selection_changed: selection.fetch(:selection_changed),
               previous_selected_checkpoint: selection.fetch(:previous_checkpoint))
  end

  def normalize_model(model)
    return LearnedPlayer.load(model).model if model.is_a?(String)

    LearnedPlayer.new(model).model
  end

  def resolved_checkpoint_path(path)
    data = JSON.parse(File.read(path))
    return path unless data["selected_checkpoint"]

    File.expand_path(data.fetch("selected_checkpoint"), File.dirname(path))
  rescue JSON::ParserError => e
    raise ArgumentError, "invalid learned policy JSON: #{e.message}"
  end

  def run_episode(player, seed, random_seed:, step:, temperature:)
    board = episode_board(seed)
    board.deal_if_needed
    sample_random = episode_random(random_seed, step)
    trajectory = episode_trajectory(board, player, sample_random, temperature)
    score = trajectory.sum {|entry| entry.fetch(:reward) }
    raise "RL episode score invariant failed" unless score == board.score

    [trajectory, score]
  end

  def episode_board(seed)
    session_random = Random.new(seed)
    session_random.rand(2**32) # reserve the player's simulator stream
    Board1010.new(random: Random.new(session_random.rand(2**32)))
  end

  def episode_random(random_seed, step)
    seed = (Integer(random_seed) ^ (Integer(step) * 2_654_435_761)) % (2**32)
    Random.new(seed)
  end

  def episode_trajectory(board, player, random, temperature)
    trajectory = []
    trajectory << sample_and_play(board, player, random, temperature) until board.game_over?
    trajectory
  end

  def sample_and_play(board, player, random, temperature)
    sample = player.sample_action(board, random: random, temperature: temperature)
    move = board.play(*sample.fetch(:action))
    raise "sampled RL action was illegal" unless move

    {chosen_features: sample.fetch(:chosen_features),
     expected_features: sample.fetch(:expected_features), reward: move.placed.size}
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
