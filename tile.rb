# frozen_string_literal: true

# Immutable, precomputed description of one 1010! tile shape.
# Struct keeps this value object compatible with Ruby versions before Data.
class Tile < Struct.new(:name, :id, :rows, :offsets, :row_masks, :col_masks, :placements, :anchor, :area, :height, :width, keyword_init: true)
  EMPTY = 0

  def initialize(name:, id:, rows:)
    rows = rows.map {|row| row.dup.freeze }.freeze
    offsets = rows.each_with_index.flat_map do |values, row|
      values.each_with_index.filter_map do |value, col|
        [row, col, value].freeze unless value == EMPTY
      end
    end.freeze
    row_masks = rows.map do |values|
      values.each_with_index.sum {|value, col| value == EMPTY ? 0 : (1 << col) }
    end.freeze
    col_masks = rows.first.size.times.map do |col|
      rows.each_with_index.sum {|values, row| values[col] == EMPTY ? 0 : (1 << row) }
    end.freeze
    anchor = rows.first.index {|value| value != EMPTY }
    placements = (0..(10 - rows.size)).flat_map do |board_row|
      (anchor..[10 - rows.first.size + anchor, 9].min).map do |board_col|
        mask = row_masks.each_with_index.sum {|bits, row_offset| bits << ((board_row + row_offset) * 10 + board_col - anchor) }
        [board_row, board_col, mask].freeze
      end
    end.freeze
    super(name: name.to_sym, id: Integer(id), rows: rows, offsets: offsets, row_masks: row_masks, col_masks: col_masks, placements: placements,
          anchor: anchor, area: offsets.size, height: rows.size, width: rows.first.size)
    freeze
  end

  SHAPES = {
    dot: [[1]],
    hl2: [[2, 2]],
    hl3: [[3, 3, 3]],
    hl4: [[4, 4, 4, 4]],
    hl5: [[5, 5, 5, 5, 5]],
    vl2: [[2], [2]],
    vl3: [[3], [3], [3]],
    vl4: [[4], [4], [4], [4]],
    vl5: [[5], [5], [5], [5], [5]],
    sq2: [[2, 2], [2, 2]],
    sq3: [[3, 3, 3], [3, 3, 3], [3, 3, 3]],
    bl2: [[2, 0], [2, 2]],
    bl3: [[3, 0, 0], [3, 0, 0], [3, 3, 3]],
    tl2: [[2, 2], [0, 2]],
    tl3: [[3, 3, 3], [0, 0, 3], [0, 0, 3]],
    br2: [[0, 2], [2, 2]],
    br3: [[0, 0, 3], [0, 0, 3], [3, 3, 3]],
    tr2: [[2, 2], [2, 0]],
    tr3: [[3, 3, 3], [3, 0, 0], [3, 0, 0]]
  }.freeze
  BY_NAME = SHAPES.each_with_index.to_h do |(name, rows), index|
    [name, new(name: name, id: index + 1, rows: rows)]
  end.freeze
  NAMES = BY_NAME.keys.freeze
  ALL = BY_NAME.values.freeze

  def self.fetch(name)
    key = name.respond_to?(:to_sym) ? name.to_sym : name
    BY_NAME.fetch(key) { raise ArgumentError, "unknown tile #{name.inspect}" }
  end
end
