# frozen_string_literal: true

require_relative "board"

# Applies recorded moves in order while validating tile identity, legality,
# offer batches, undo state and the final score.
class OfferReplay
  attr_reader :board

  def initialize(board:, offers: nil, strict_offers: true, random_deal: false)
    @board = board
    @offers = offers&.map {|batch| batch.map {|tile| tile.is_a?(Tile) ? tile : Tile.fetch(tile) } }
    @strict_offers = strict_offers
    @random_deal = random_deal
    @next_offer = 0
    if @offers && !@offers.empty?
      @board.replace_options(@offers.first)
      @next_offer = 1
    end
    @history = []
  end

  # A move may be a hash with option/row/col/tile keys or [option,row,col].
  def apply(move, capture: false)
    option, row, col, tile_name = move_values(move)
    check_tile!(option, tile_name)

    @history << [@board.copy, @next_offer]
    batch_exhausted = @board.options.size == 1
    result = @board.play(option, row, col, deal: false, capture: capture)
    unless result
      @history.pop
      raise ArgumentError, "move is not legal on the recorded board"
    end

    feed_next_batch if batch_exhausted
    result
  end

  # Trace files include explicit deal events. Applying the move already feeds
  # the corresponding batch; this method verifies the duplicate event record.
  def feed_deal(tiles)
    names = tiles.map {|tile| tile.is_a?(Tile) ? tile.name : Tile.fetch(tile).name }
    raise ArgumentError, "recorded deal does not match the consumed offer" unless @board.options.map(&:name) == names

    @board
  end

  def undo
    snapshot = @history.pop
    raise ArgumentError, "undo has no corresponding move" unless snapshot

    @board, @next_offer = snapshot
    @board
  end

  def finish!(expected_score: nil, require_all_offers: true)
    if expected_score && @board.score != Integer(expected_score)
      raise ArgumentError, "final score mismatch: expected #{expected_score}, replayed #{@board.score}"
    end
    if @offers && @strict_offers && require_all_offers && @next_offer != @offers.size
      raise ArgumentError, "move sequence leaves unused offer batches"
    end

    @board
  end

  def self.replay(board:, moves:, offers:, expected_score: nil, strict_offers: true, random_deal: false)
    replay = new(board: board, offers: offers, strict_offers: strict_offers, random_deal: random_deal)
    moves.each {|move| replay.apply(move) }
    replay.finish!(expected_score: expected_score)
  end

  private

  def check_tile!(option, tile_name)
    tile = @board.options[option]
    if tile_name && (!tile || tile.name != tile_name.to_sym)
      raise ArgumentError, "move selects #{tile_name.inspect} but option #{option} differs"
    end
    raise ArgumentError, "move selects missing option #{option}" unless tile
  end

  # Without strict offers, partial lesson sequences may legitimately stop at a
  # batch boundary, so a missing batch is not an error.
  def feed_next_batch
    next_batch = @offers && @offers[@next_offer]
    if next_batch
      @board.replace_options(next_batch)
      @next_offer += 1
    elsif @strict_offers
      raise ArgumentError, "offers end before the move sequence"
    elsif @random_deal
      @board.deal_if_needed
    end
  end

  def move_values(move)
    if move.is_a?(Hash)
      option, row, col, tile = hash_move_values(move)
    elsif move.first == :move
      _type, tile, option, row, col = move
    else
      option, row, col = move
    end
    [Integer(option), Integer(row), Integer(col), tile]
  end

  # Moves from lessons have String keys; captured simulation moves have Symbols.
  def hash_move_values(move)
    field = ->(key) { move.fetch(key) { move.fetch(key.to_s) } }
    [*%i[option row col].map(&field), move[:tile] || move["tile"]]
  end
end
