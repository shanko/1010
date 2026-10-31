# frozen_string_literal: true

# auto_player.rb: how the computer chooses its moves in "auto" mode.
#
# Each strategy gets the board, the tile and every position where the tile
# fits, and returns the position to use. Ties go to the position found first
# (top-left first). Choose one with `ruby game_1010.rb auto <strategy>`.
require_relative "board"
require_relative "learned_player"

class AutoPlayer
  STRATEGIES       = %i[first_fit last_fit random_fit shanko jc sam].freeze
  VALID_STRATEGIES = (STRATEGIES + [:learned]).freeze
  DEFAULT_STRATEGY = :jc

  attr_reader :strategy

  # `random` picks which tile to play. Keep it separate from the board's
  # random numbers, so a recorded game deals the same tiles when played back.
  def initialize(strategy=DEFAULT_STRATEGY, random: Random.new, model: nil)
    strategy = strategy.to_sym
    unless VALID_STRATEGIES.include?(strategy)
      raise ArgumentError, "unknown strategy #{strategy.inspect}, use one of: #{VALID_STRATEGIES.join(', ')}"
    end

    @strategy = strategy
    @random   = random
    if strategy == :learned
      raise ArgumentError, "learned strategy requires a model hash or model path" unless model

      @learned_player = model.is_a?(String) ? LearnedPlayer.load(model) : LearnedPlayer.new(model)
    end
  end

  # [option index, row, col] for the next move, or nil if no tile fits.
  # Picks a random tile among those that fit somewhere, then the best spot for it.
  def choose_move(board)
    return @learned_player.choose_move(board, random: @random) if @learned_player

    fitting = board.options.each_index.select {|index| board.fits_anywhere?(board.options[index]) }
    return nil if fitting.empty?

    index = fitting.sample(random: @random)
    row, col = best_position(board, board.options[index])
    [index, row, col]
  end

  # The [row, col] this strategy would pick for the tile, or nil if it fits nowhere.
  def best_position(board, tile)
    return @learned_player.best_position(board, tile, random: @random) if @learned_player

    positions = board.positions_for(tile)
    return nil if positions.empty?

    send(@strategy, board, tile, positions)
  end

  private

  # The first position found.
  def first_fit(_board, _tile, positions)
    positions.first
  end

  # The last position found.
  def last_fit(_board, _tile, positions)
    positions.last
  end

  # Any position, at random.
  def random_fit(_board, _tile, positions)
    positions.sample(random: @random)
  end

  # The position with the most neighbours occupied (in other words: the
  # fewest neighbouring cells empty).
  def shanko(board, _tile, positions)
    positions.max_by {|row, col| board.filled_neighbours(row, col) }
  end

  # Suggested by JC: like shanko, but treat the edge cells as if their
  # neighbours are always occupied.
  def jc(board, _tile, positions)
    positions.max_by {|row, col| board.filled_neighbours(row, col) + board.edges_touched(row, col) }
  end

  # Suggested by Sam: the position that completely fills the most rows and
  # columns when the tile is placed. Falls back to jc's choice on a tie.
  def sam(board, tile, positions)
    positions.max_by do |row, col|
      [board.lines_completed_by(tile, row, col), board.filled_neighbours(row, col) + board.edges_touched(row, col)]
    end
  end

  # Suggested by Andy (not implemented yet): "the position which results into
  # minimum empty cells after placing the tile but before clearing the filled
  # rows and columns". As worded, every position leaves the same number of
  # empty cells (the tile always covers the same number of squares), so this
  # idea needs a different measure before it can tell positions apart.
end
