# frozen_string_literal: true

# Immutable, precomputed description of one 1010! tile shape.
# Struct keeps this value object compatible with Ruby versions before Data.
Tile = Struct.new(:name, :id, :rows, :offsets, :row_masks, :col_masks, :placements, :anchor, :area, :height,
                  :width, keyword_init: true)

class Tile
  EMPTY = 0

  def initialize(name:, id:, rows:)
    super(name: name.to_sym, id: Integer(id), **self.class.shape_fields(rows))
    freeze
  end

  # Everything the board needs to know about a shape, computed once.
  def self.shape_fields(rows)
    rows = rows.map {|row| row.dup.freeze }.freeze
    offsets = offsets_for(rows)
    row_masks = row_masks_for(rows)
    anchor = rows.first.index {|value| value != EMPTY }
    {rows: rows, offsets: offsets, row_masks: row_masks, col_masks: col_masks_for(rows),
     placements: placements_for(rows, row_masks, anchor), anchor: anchor,
     area: offsets.size, height: rows.size, width: rows.first.size}
  end

  # [row, col, value] of each filled square, relative to the tile's top-left.
  def self.offsets_for(rows)
    rows.each_with_index.flat_map {|values, row|
      values.each_with_index.filter_map do |value, col|
        [row, col, value].freeze unless value == EMPTY
      end
    }.freeze
  end

  def self.row_masks_for(rows)
    rows.map {|values|
      values.each_with_index.sum {|value, col| value == EMPTY ? 0 : (1 << col) }
    }.freeze
  end

  def self.col_masks_for(rows)
    rows.first.size.times.map {|col|
      rows.each_with_index.sum {|values, row| values[col] == EMPTY ? 0 : (1 << row) }
    }.freeze
  end

  # The 100-bit board mask of the tile's squares, with its top row at `row`
  # and its left column at `left`.
  def self.board_mask(row_masks, row, left)
    row_masks.each_with_index.sum {|mask, offset| mask << (((row + offset) * 10) + left) }
  end

  # [row, col, board mask] for every anchor position that keeps the tile on the board.
  def self.placements_for(rows, row_masks, anchor)
    (0..(10 - rows.size)).flat_map {|board_row|
      (anchor..[10 - rows.first.size + anchor, 9].min).map do |board_col|
        [board_row, board_col, board_mask(row_masks, board_row, board_col - anchor)].freeze
      end
    }.freeze
  end

  # Tile formations. Each row array is one row of the shape, top to bottom;
  # 0 is an empty square and any other value is the tile's colour.
  # Suffix N is the line length / square side / L arm length.
  # L shapes are named by the corner where their two arms meet, except tl and
  # tr, whose names are swapped relative to their geometry (kept as-is because
  # the names are model feature keys, e.g. "tile_tl2" in models/learned.json).
  SHAPES = {
    dot: [[1]],                                         # single square
    hl2: [[2, 2]],                                      # horizontal line of 2 squares
    hl3: [[3, 3, 3]],                                   # horizontal line of 3 squares
    hl4: [[4, 4, 4, 4]],                                # horizontal line of 4 squares
    hl5: [[5, 5, 5, 5, 5]],                             # horizontal line of 5 squares
    vl2: [[2], [2]],                                    # vertical line of 2 squares
    vl3: [[3], [3], [3]],                               # vertical line of 3 squares
    vl4: [[4], [4], [4], [4]],                          # vertical line of 4 squares
    vl5: [[5], [5], [5], [5], [5]],                     # vertical line of 5 squares
    sq2: [[2, 2], [2, 2]],                              # 2x2 square
    sq3: [[3, 3, 3], [3, 3, 3], [3, 3, 3]],             # 3x3 square
    bl2: [[2, 0], [2, 2]],                              # L, corner bottom-left, arms of 2 (3 squares)
    bl3: [[3, 0, 0], [3, 0, 0], [3, 3, 3]],             # L, corner bottom-left, arms of 3 (5 squares)
    tl2: [[2, 2], [0, 2]],                              # L, corner top-right, arms of 2 (3 squares)
    tl3: [[3, 3, 3], [0, 0, 3], [0, 0, 3]],             # L, corner top-right, arms of 3 (5 squares)
    br2: [[0, 2], [2, 2]],                              # L, corner bottom-right, arms of 2 (3 squares)
    br3: [[0, 0, 3], [0, 0, 3], [3, 3, 3]],             # L, corner bottom-right, arms of 3 (5 squares)
    tr2: [[2, 2], [2, 0]],                              # L, corner top-left, arms of 2 (3 squares)
    tr3: [[3, 3, 3], [3, 0, 0], [3, 0, 0]]              # L, corner top-left, arms of 3 (5 squares)
  }.freeze
  BY_NAME = SHAPES.each_with_index.to_h {|(name, rows), index|
    [name, new(name: name, id: index + 1, rows: rows)]
  }.freeze
  NAMES = BY_NAME.keys.freeze
  ALL = BY_NAME.values.freeze

  def self.fetch(name)
    key = name.respond_to?(:to_sym) ? name.to_sym : name
    BY_NAME.fetch(key) { raise ArgumentError, "unknown tile #{name.inspect}" }
  end

  def placement_mask(row, col)
    self.class.board_mask(row_masks, row, col - anchor)
  end
end
