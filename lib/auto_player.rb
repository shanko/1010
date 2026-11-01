# frozen_string_literal: true

# auto_player.rb: how the computer chooses its moves in "auto" mode.
#
# Each strategy gets the board, the tile and every position where the tile
# fits, and returns the position to use. Ties go to the position found first
# (top-left first). Choose one with `./1010 auto <strategy>`.
require_relative "board"
require_relative "learned_player"

class AutoPlayer
  STRATEGIES       = %i[first_fit last_fit random_fit shanko jc sam codex_1 codex_sam].freeze
  VALID_STRATEGIES = (STRATEGIES + [:learned]).freeze
  DEFAULT_STRATEGY = :sam

  attr_reader :strategy

  # `random` picks which tile to play for the randomized strategies. Keep it
  # separate from the board's random numbers, so seeded runs stay reproducible.
  def initialize(strategy=DEFAULT_STRATEGY, random: Random.new, model: nil)
    strategy = strategy.to_sym
    unless VALID_STRATEGIES.include?(strategy)
      raise ArgumentError, "unknown strategy #{strategy.inspect}, use one of: #{VALID_STRATEGIES.join(', ')}"
    end

    @strategy = strategy
    @random   = random
    return unless strategy == :learned

    raise ArgumentError, "learned strategy requires a model hash or model path" unless model

    @learned_player = if model.is_a?(LearnedPlayer)
                        model
                      elsif model.is_a?(String)
                        LearnedPlayer.load(model)
                      else
                        LearnedPlayer.new(model)
                      end
  end

  # [option index, row, col] for the next move, or nil if no tile fits.
  # Picks a random tile among those that fit somewhere, then the best spot for it.
  def choose_move(board)
    return @learned_player.choose_move(board, random: @random) if @learned_player
    return choose_codex_1_move(board) if @strategy == :codex_1
    return choose_codex_sam_move(board) if @strategy == :codex_sam

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

    if @strategy == :codex_1
      index = board.options.index(tile)
      index = board.options.length if index.nil?
      return positions.max_by {|row, col| codex_1_mobility(board, index, row, col, tile) }
    end

    return sam(board, tile, positions) if @strategy == :codex_sam

    send(@strategy, board, tile, positions)
  end

  private

  # Compare every legal tile-placement pair, choosing the move that leaves the
  # other tiles in this offer playable with the most room for future moves.
  def choose_codex_1_move(board)
    board.options.each_with_index.flat_map do |tile, index|
      board.positions_for(tile).map do |row, col|
        [codex_1_mobility(board, index, row, col), [index, row, col]]
      end
    end.max_by(&:first)&.last
  end

  # Let Codex 1 choose the tile, then let Sam choose that tile's placement.
  def choose_codex_sam_move(board)
    codex_choice = choose_codex_1_move(board)
    return unless codex_choice

    index = codex_choice.first
    tile = board.options[index]
    row, col = sam(board, tile, board.positions_for(tile))
    [index, row, col]
  end

  def codex_1_mobility(board, index, row, col, tile=nil)
    branch = board.copy
    if index == board.options.length
      branch.replace_options([tile])
      index = 0
    end
    return [0, [], 0] unless branch.play(index, row, col, deal: false)

    placements = branch.options.map {|remaining| branch.positions_for(remaining).size }.sort
    [placements.count(&:positive?), placements, placements.sum]
  end

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
  def shanko(board, tile, positions)
    positions.max_by {|row, col| board.footprint_neighbours(tile, row, col) }
  end

  # Suggested by JC: like shanko, but treat the edge cells as if their
  # neighbours are always occupied.
  def jc(board, tile, positions)
    positions.max_by {|row, col| board.footprint_contact(tile, row, col) }
  end

  # Suggested by Sam: the position that completely fills the most rows and
  # columns when the tile is placed. Falls back to jc's choice on a tie.
  def sam(board, tile, positions)
    line_scores = board.line_completion_scores(tile, positions)
    contact_scores = positions.map {|row, col| board.footprint_contact(tile, row, col) }
    best = positions.each_with_index.max_by do |_position, index|
      [line_scores[index], contact_scores[index]]
    end
    best.first
  end

  # Suggested by Andy (not implemented yet): "the position which results into
  # minimum empty cells after placing the tile but before clearing the filled
  # rows and columns". As worded, every position leaves the same number of
  # empty cells (the tile always covers the same number of squares), so this
  # idea needs a different measure before it can tell positions apart.
end
