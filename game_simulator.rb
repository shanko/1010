# frozen_string_literal: true

require_relative "board"
require_relative "auto_player"
require "time"

# Runs complete games without Gosu, sleeps, or other UI behavior.
class GameSimulator
  VERSION = 1

  Result = Struct.new(:seed, :strategy, :score, :placed_tiles, :cleared_lines,
                      :option_batches, :moves, :offers, :final_board,
                      keyword_init: true) do
    def summary
      {
        seed: seed,
        strategy: strategy,
        score: score,
        placed_tiles: placed_tiles,
        cleared_lines: cleared_lines,
        option_batches: option_batches
      }
    end
  end

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

    board = Board1010.new(options: tiles_for(result.offers.first))
    next_offer = 1
    result.moves.each_with_index do |move, move_index|
      tile = board.options[move.fetch(:option)]
      actual_name = Board1010::TILES.key(tile)
      unless actual_name == move.fetch(:tile)
        raise ArgumentError, "captured move #{move_index + 1} does not match its offer"
      end

      batch_exhausted = board.options.size == 1
      unless board.play(move.fetch(:option), move.fetch(:row), move.fetch(:col), deal: false)
        raise ArgumentError, "captured move #{move_index + 1} is not legal"
      end
      if batch_exhausted
        offered = result.offers[next_offer]
        raise ArgumentError, "captured offers end before move #{move_index + 1}" unless offered

        board.replace_options(tiles_for(offered))
        next_offer += 1
      end
    end

    raise ArgumentError, "captured result has unused offer batches" unless next_offer == result.offers.size
    raise ArgumentError, "captured score does not match replay" unless board.score == result.score

    board
  end

  def self.tiles_for(names)
    names.map do |name|
      Board1010::TILES[name.to_sym] || raise(ArgumentError, "captured result has unknown tile #{name.inspect}")
    end
  end
  private_class_method :tiles_for

  def run(seed:, strategy: AutoPlayer::DEFAULT_STRATEGY, max_moves: 100_000)
    seed = Integer(seed)
    strategy = strategy.to_sym

    # Match the GUI session's stream split: the player gets the first derived
    # seed and the first game board gets the second.
    session_random = Random.new(seed)
    player_random = Random.new(session_random.rand(2**32))
    board_random = Random.new(session_random.rand(2**32))
    board = Board1010.new(random: board_random)
    board.deal_if_needed
    player = AutoPlayer.new(strategy, random: player_random)

    offers = [tile_names(board.options)]
    moves = []
    placed_tiles = 0
    cleared_lines = 0
    placed_area = 0

    until board.game_over?
      raise RuntimeError, "simulation exceeded #{max_moves} moves (seed #{seed})" if moves.size >= max_moves

      index, row, col = player.choose_move(board)
      tile = board.options[index]
      raise RuntimeError, "#{strategy} returned an invalid move for seed #{seed}" unless tile && board.fits?(tile, row, col)

      option_count = board.options.size
      tile_name = Board1010::TILES.key(tile)
      move = board.play(index, row, col)
      raise RuntimeError, "legal move rejected for seed #{seed}" unless move

      moves << {tile: tile_name, option: index, row: row, col: col}
      placed_tiles += 1
      placed_area += move.placed.size
      cleared_lines += move.cleared_rows.size + move.cleared_cols.size
      offers << tile_names(board.options) if option_count == 1
    end

    unless board.score == placed_area
      raise RuntimeError, "score invariant failed for seed #{seed}: #{board.score} != #{placed_area}"
    end

    Result.new(seed: seed, strategy: strategy, score: board.score,
               placed_tiles: placed_tiles, cleared_lines: cleared_lines,
               option_batches: offers.size, moves: moves, offers: offers,
               final_board: board)
  end

  private

  def tile_names(tiles)
    tiles.map {|tile| Board1010::TILES.key(tile) }
  end
end

# Paired-seed evaluation and distribution summaries for player strategies.
class GameBenchmark
  SCHEMA_VERSION = 1
  METRICS = %i[score placed_tiles cleared_lines option_batches].freeze

  def self.run(seeds:, strategies: AutoPlayer::STRATEGIES, max_moves: 100_000)
    seeds = seeds.map {|seed| Integer(seed) }
    raise ArgumentError, "provide at least one seed" if seeds.empty?
    raise ArgumentError, "seed list must not contain duplicates" unless seeds.uniq.size == seeds.size

    strategies = strategies.map(&:to_sym)
    raise ArgumentError, "provide at least one strategy" if strategies.empty?
    unknown = strategies - AutoPlayer::STRATEGIES
    raise ArgumentError, "unknown strategies: #{unknown.join(', ')}" unless unknown.empty?

    results = strategies.to_h do |strategy|
      [strategy, seeds.map {|seed| GameSimulator.run(seed: seed, strategy: strategy, max_moves: max_moves) }]
    end
    baseline = strategies.first

    {
      schema_version: SCHEMA_VERSION,
      simulator_version: GameSimulator::VERSION,
      generated_at_utc: Time.now.utc.iso8601,
      baseline_strategy: baseline,
      seeds: seeds,
      strategies: strategies.to_h do |strategy|
        episode_results = results.fetch(strategy)
        metrics = METRICS.to_h do |metric|
          [metric, summarize(episode_results.map {|result| result.public_send(metric) })]
        end
        deltas = episode_results.zip(results.fetch(baseline)).map do |result, base|
          {seed: result.seed, score_delta: result.score - base.score}
        end
        [strategy, {
          metrics: metrics,
          paired_score_delta_vs_baseline: summarize(deltas.map {|delta| delta[:score_delta] }),
          per_seed: episode_results.map(&:summary)
        }]
      end
    }
  end

  # Nearest-rank percentiles; standard deviation is population standard deviation.
  def self.summarize(values)
    raise ArgumentError, "cannot summarize an empty sample" if values.empty?

    sorted = values.sort
    mean = values.sum.to_f / values.size
    variance = values.sum {|value| (value - mean)**2 }.to_f / values.size
    {
      count: values.size,
      mean: mean,
      median: percentile(sorted, 0.5),
      standard_deviation: Math.sqrt(variance),
      minimum: sorted.first,
      percentile_10: percentile(sorted, 0.1),
      percentile_90: percentile(sorted, 0.9),
      maximum: sorted.last
    }
  end

  def self.percentile(sorted, quantile)
    sorted[[((quantile * sorted.size).ceil - 1), 0].max, sorted.size - 1].min
  end
  private_class_method :percentile
end
