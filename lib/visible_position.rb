# frozen_string_literal: true

require_relative "board"

# The player's entire observation. No seed, dealer, RNG, trace or live board is retained.
class VisiblePosition
  GEOMETRY = Board1010.new(random: nil).freeze
  private_constant :GEOMETRY

  attr_reader :occupied_bits, :options, :score

  def self.from_board(board)
    new(occupied_bits: board.occupied_bits, options: board.options, score: board.score)
  end

  def initialize(occupied_bits:, options:, score:)
    raise ArgumentError, "a visible batch contains at most three tiles" if options.size > Board1010::OPTIONS

    @occupied_bits = occupied_bits
    @options = options.dup.freeze
    @score = score
    freeze
  end

  def batch_complete?
    options.empty?
  end

  def each_action(option_index: nil)
    options.each_with_index do |tile, index|
      next if option_index && index != option_index

      tile.placements.each do |row, col, mask|
        yield index, row, col if occupied_bits.nobits?(mask)
      end
    end
  end

  def placement_count(tile)
    tile.placements.count {|_row, _col, mask| occupied_bits.nobits?(mask) }
  end

  def after_move(index, row, col)
    tile = options.fetch(index)
    raise ArgumentError, "illegal visible-batch placement" unless legal_placement?(tile, row, col)

    bits, = GEOMETRY.placement_result(tile, row, col, occupied_bits: occupied_bits)
    remaining = options.dup
    remaining.delete_at(index)
    self.class.new(occupied_bits: bits, options: remaining, score: score + tile.area)
  end

  private

  def legal_placement?(tile, row, col)
    left = col - tile.anchor
    row.between?(0, Board1010::ROWS - tile.height) && left.between?(0, Board1010::COLS - tile.width) &&
      occupied_bits.nobits?(tile.placement_mask(row, col))
  end
end
