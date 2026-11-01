# frozen_string_literal: true

require_relative "board"
require_relative "auto_player"
require_relative "offer_replay"
require "time"
require "tmpdir"

# Runs complete games without Gosu, sleeps, or other UI behavior.
class GameSimulator
  VERSION = 2

  Result = Struct.new(:seed, :strategy, :score, :placed_tiles, :cleared_lines,
                      :option_batches, :moves, :offers, :final_board, :decision_states,
                      keyword_init: true) do
    def summary
      {
        seed:           seed,
        strategy:       strategy,
        score:          score,
        placed_tiles:   placed_tiles,
        cleared_lines:  cleared_lines,
        option_batches: option_batches
      }
    end
  end

  RunState = Struct.new(:board, :offers, :moves, :decision_states, :placed_tiles,
                        :cleared_lines, :placed_area, keyword_init: true)

  def self.run(**options)
    new.run(**options)
  end

  # Constructs the exact initial board used by #run for a root seed.
  def self.initial_board(seed:)
    session_random = Random.new(Integer(seed))
    session_random.rand(2**32) # reserve the auto-player's independent seed
    board = Board1010.new(random: Random.new(session_random.rand(2**32)))
    board.deal_if_needed
    board
  end

  # Replays the captured offers and choices without using the random dealer.
  def self.replay(result)
    raise ArgumentError, "simulation result has no offers" if result.offers.empty?

    board = Board1010.new
    OfferReplay.replay(board: board, moves: result.moves, offers: result.offers,
                       expected_score: result.score)
  end

  def run(seed:, strategy: AutoPlayer::SEARCH_STRATEGY, max_moves: 100_000, model: nil,
          capture_states: false)
    seed = Integer(seed)
    strategy = strategy.to_sym
    state, player = new_run(seed, strategy, model)
    play_until_over(state, player, seed: seed, strategy: strategy,
                    max_moves: max_moves, capture_states: capture_states)
    result_for(state, seed, strategy)
  end

  private

  def new_run(seed, strategy, model)
    # Match the GUI session's stream split: player gets the first derived seed.
    session_random = Random.new(seed)
    player_random = Random.new(session_random.rand(2**32))
    board = Board1010.new(random: Random.new(session_random.rand(2**32)))
    board.deal_if_needed
    state = RunState.new(board: board, offers: [board.options.map(&:name)], moves: [], decision_states: [],
                         placed_tiles: 0, cleared_lines: 0, placed_area: 0)
    [state, AutoPlayer.new(strategy, random: player_random, model: model)]
  end

  def play_until_over(state, player, seed:, strategy:, max_moves:, capture_states:)
    until state.board.game_over?
      raise "simulation exceeded #{max_moves} moves (seed #{seed})" if state.moves.size >= max_moves

      capture_decision_state(state) if capture_states
      play_next_move(state, player, seed, strategy)
    end
    return if state.board.score == state.placed_area

    raise "score invariant failed for seed #{seed}: #{state.board.score} != #{state.placed_area}"
  end

  def capture_decision_state(state)
    state.decision_states << {board: state.board.copy, offer_index: state.offers.size - 1}
  end

  def play_next_move(state, player, seed, strategy)
    index, row, col = player.choose_move(state.board)
    tile = valid_tile!(state.board, [index, row, col], seed: seed, strategy: strategy)
    option_count = state.board.options.size
    move = state.board.play(index, row, col)
    raise "legal move rejected for seed #{seed}" unless move

    record_move(state, move, tile, action: [index, row, col], option_count: option_count)
  end

  def valid_tile!(board, action, seed:, strategy:)
    index, row, col = action
    tile = board.options[index]
    return tile if tile && board.fits?(tile, row, col)

    raise "#{strategy} returned an invalid move for seed #{seed}"
  end

  def record_move(state, move, tile, action:, option_count:)
    index, row, col = action
    state.moves << {tile: tile.name, option: index, row: row, col: col}
    state.placed_tiles += 1
    state.placed_area += move.placed.size
    state.cleared_lines += cleared_line_count(move)
    state.offers << state.board.options.map(&:name) if option_count == 1
  end

  def cleared_line_count(move)
    move.cleared_rows.size + move.cleared_cols.size
  end

  def result_for(state, seed, strategy)
    Result.new(seed: seed, strategy: strategy, score: state.board.score,
               placed_tiles: state.placed_tiles, cleared_lines: state.cleared_lines,
               option_batches: state.offers.size, moves: state.moves, offers: state.offers,
               final_board: state.board, decision_states: state.decision_states)
  end
end

# Paired-seed evaluation and distribution summaries for player strategies.
class GameBenchmark
  SCHEMA_VERSION = 1
  METRICS = %i[score placed_tiles cleared_lines option_batches].freeze

  def self.run(seeds:, strategies: AutoPlayer::STRATEGIES, max_moves: 100_000, models: {}, workers: 1)
    seeds, strategies = validate_inputs(seeds, strategies, models)
    workers = Integer(workers)
    raise ArgumentError, "workers must be positive" unless workers.positive?

    resolved_models = resolve_models(models)
    results = run_strategies(seeds, strategies, resolved_models, max_moves, workers)
    baseline = strategies.first
    pairwise = pairwise_summaries(results, strategies)

    {
      schema_version:        SCHEMA_VERSION,
      simulator_version:     GameSimulator::VERSION,
      generated_at_utc:      Time.now.utc.iso8601,
      baseline_strategy:     baseline,
      seeds:                 seeds,
      strategies:            strategy_summaries(results, strategies, baseline),
      pairwise_score_deltas: pairwise
    }
  end

  def self.validate_inputs(seeds, strategies, models)
    seeds = seeds.map {|seed| Integer(seed) }
    raise ArgumentError, "provide at least one seed" if seeds.empty?
    raise ArgumentError, "seed list must not contain duplicates" unless seeds.uniq.size == seeds.size

    strategies = strategies.map(&:to_sym)
    raise ArgumentError, "provide at least one strategy" if strategies.empty?

    validate_strategies!(strategies, models)
    require_learned_model!(strategies, models)
    [seeds, strategies]
  end
  private_class_method :validate_inputs

  def self.validate_strategies!(strategies, models)
    unknown = strategies - AutoPlayer::VALID_STRATEGIES - models.keys.map(&:to_sym)
    raise ArgumentError, "unknown strategies: #{unknown.join(', ')}" unless unknown.empty?
  end
  private_class_method :validate_strategies!

  def self.require_learned_model!(strategies, models)
    return unless strategies.include?(:learned) && !models.key?(:learned) && !models.key?("learned")

    raise ArgumentError, "benchmarking learned requires models[:learned] or models['learned']"
  end
  private_class_method :require_learned_model!

  def self.resolve_models(models)
    models.transform_keys(&:to_sym).transform_values do |model|
      model.is_a?(String) ? LearnedPlayer.load(model) : model
    end
  end
  private_class_method :resolve_models

  def self.run_strategies(seeds, strategies, models, max_moves, workers)
    strategies.to_h do |strategy|
      policy = models.key?(strategy) ? :learned : strategy
      run = lambda do |batch|
        batch.map do |seed|
          result = GameSimulator.run(seed: seed, strategy: policy, max_moves: max_moves, model: models[strategy])
          GameSimulator::Result.new(**result.summary, strategy: strategy)
        end
      end
      [strategy, workers == 1 ? run.call(seeds) : parallel_episodes(seeds, workers, &run)]
    end
  end
  private_class_method :run_strategies

  # Keep worker creation, reaping and private output cleanup in one scope.
  # rubocop:disable Metrics/AbcSize
  def self.parallel_episodes(seeds, workers)
    raise ArgumentError, "parallel evaluation requires Process.fork support" unless Process.respond_to?(:fork)

    Dir.mktmpdir("1010-benchmark") do |directory|
      jobs = seeds.each_slice((seeds.size.to_f / workers).ceil).with_index.map do |batch, index|
        path = File.join(directory, "#{index}.json")
        pid = Process.fork do
          write_worker_output(path) { yield(batch) }
        end
        [pid, path]
      end
      wait_for_workers(jobs)

      jobs.flat_map {|_pid, path| read_worker_results(path) }
    end
  end
  # rubocop:enable Metrics/AbcSize
  private_class_method :parallel_episodes

  def self.write_worker_output(path)
    File.write(path, JSON.generate(yield.map(&:summary)))
    exit! 0
  rescue StandardError => e
    warn "Benchmark worker failed: #{e.message}"
    exit! 1
  end
  private_class_method :write_worker_output

  def self.wait_for_workers(jobs)
    statuses = jobs.map {|pid, _path| Process.wait2(pid).last }
    raise ArgumentError, "benchmark worker failed; no complete report was written" unless statuses.all?(&:success?)
  end
  private_class_method :wait_for_workers

  def self.read_worker_results(path)
    JSON.parse(File.read(path), symbolize_names: true).map do |summary|
      GameSimulator::Result.new(**summary, strategy: summary.fetch(:strategy).to_sym)
    end
  end
  private_class_method :read_worker_results

  def self.pairwise_summaries(results, strategies)
    strategies.to_h do |candidate|
      [candidate, strategies.to_h do |comparison|
        pairwise_summary(results, candidate, comparison)
      end]
    end
  end
  private_class_method :pairwise_summaries

  def self.pairwise_summary(results, candidate, comparison)
    paired = results.fetch(candidate).zip(results.fetch(comparison)).map do |result, base|
      {seed: result.seed, score_delta: result.score - base.score}
    end
    [comparison, {summary: summarize(paired.map {|entry| entry.fetch(:score_delta) }), per_seed: paired}]
  end
  private_class_method :pairwise_summary

  def self.strategy_summaries(results, strategies, baseline)
    strategies.to_h do |strategy|
      episodes = results.fetch(strategy)
      deltas = episodes.zip(results.fetch(baseline)).map {|result, base|
        {seed: result.seed, score_delta: result.score - base.score}
      }
      [strategy, {metrics:                        metric_summaries(episodes),
                  paired_score_delta_vs_baseline: summarize(deltas.map {|entry| entry[:score_delta] }),
                  per_seed:                       episodes.map(&:summary)}]
    end
  end
  private_class_method :strategy_summaries

  def self.metric_summaries(episodes)
    METRICS.to_h do |metric|
      [metric, summarize(episodes.map {|result| result.public_send(metric) })]
    end
  end
  private_class_method :metric_summaries

  # Nearest-rank percentiles; standard deviation is population standard deviation.
  def self.summarize(values)
    raise ArgumentError, "cannot summarize an empty sample" if values.empty?

    sorted, mean, variance = distribution(values)
    summary(sorted, mean, variance)
  end

  def self.distribution(values)
    sorted = values.sort
    mean = values.sum.to_f / values.size
    variance = values.sum {|value| (value - mean)**2 }.to_f / values.size
    [sorted, mean, variance]
  end
  private_class_method :distribution

  def self.summary(sorted, mean, variance)
    {count: sorted.size, mean: mean, median: percentile(sorted, 0.5),
     standard_deviation: Math.sqrt(variance), minimum: sorted.first,
     percentile_10: percentile(sorted, 0.1), percentile_90: percentile(sorted, 0.9),
     mean_ci_95: confidence_interval(mean, variance, sorted.size), maximum: sorted.last}
  end
  private_class_method :summary

  def self.confidence_interval(mean, variance, count)
    margin = 1.96 * Math.sqrt(variance / count)
    {lower: mean - margin, upper: mean + margin}
  end
  private_class_method :confidence_interval

  def self.percentile(sorted, quantile)
    sorted[[((quantile * sorted.size).ceil - 1), 0].max, sorted.size - 1].min
  end
  private_class_method :percentile
end
