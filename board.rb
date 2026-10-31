# frozen_string_literal: true

# board.rb: the rules of 1010!, with no drawing and no terminal input or output.
#
# The board is a grid of cells with row 0 at the top. An empty cell holds EMPTY;
# a filled cell holds its value and the ID of its exact tile shape.
class Board1010
  ROWS    = 10
  COLS    = 10
  OPTIONS = 3 # tiles offered at a time
  EMPTY   = 0

  # Where the window and the terminal game keep a saved game.
  SAVE_FILE = "1010game.txt"

  # The 19 tile shapes. Each inner array is one row of the tile, top row first:
  # 0 is a gap, any other number is a filled square (and picks its color).
  # HL = horizontal line, VL = vertical line, SQ = square, and
  # BL / TL / BR / TR = the corner shapes.
  TILES = {
    dot: [[1]],

    hl2: [[2, 2]],
    hl3: [[3, 3, 3]],
    hl4: [[4, 4, 4, 4]],
    hl5: [[5, 5, 5, 5, 5]],

    vl2: [[2], [2]],
    vl3: [[3], [3], [3]],
    vl4: [[4], [4], [4], [4]],
    vl5: [[5], [5], [5], [5], [5]],

    sq2: [[2, 2],
          [2, 2]],
    sq3: [[3, 3, 3],
          [3, 3, 3],
          [3, 3, 3]],

    bl2: [[2, 0],
          [2, 2]],
    bl3: [[3, 0, 0],
          [3, 0, 0],
          [3, 3, 3]],

    tl2: [[2, 2],
          [0, 2]],
    tl3: [[3, 3, 3],
          [0, 0, 3],
          [0, 0, 3]],

    br2: [[0, 2],
          [2, 2]],
    br3: [[0, 0, 3],
          [0, 0, 3],
          [3, 3, 3]],

    tr2: [[2, 2],
          [2, 0]],
    tr3: [[3, 3, 3],
          [3, 0, 0],
          [3, 0, 0]]
  }.freeze

  ALL_TILES = TILES.values.freeze

  # When none of the tiles dealt fit, the first one is swapped for the first
  # of these that does.
  SMALL_TILES = TILES.values_at(:hl2, :vl2, :sq2, :bl2, :tl2, :br2, :tr2, :dot).freeze

  # [row, col] steps to the 8 squares around a square.
  NEIGHBOUR_OFFSETS = [[-1, -1], [-1, 0], [-1, 1], [0, -1], [0, 1], [1, -1], [1, 0], [1, 1]].freeze

  # What a move did, so the window can animate it.
  #   placed:                [row, col, value] of each square the tile filled
  #   cells_before_clearing / tile_ids_before_clearing: board state before full lines were emptied
  #   cleared_rows / cleared_cols: the full lines that were emptied
  Move = Struct.new(:placed, :cells_before_clearing, :tile_ids_before_clearing,
                    :cleared_rows, :cleared_cols, keyword_init: true)

  TILE_NAMES = TILES.keys.freeze
  TILE_IDS = TILES.values.each_with_index.to_h {|tile, index| [tile, index + 1] }.freeze

  attr_reader :cells, :tile_ids, :options, :score, :random

  # `random` deals the tiles. Pass Random.new(seed) to get the same tiles every time.
  def initialize(cells: nil, tile_ids: nil, options: [], score: 0, random: Random.new)
    @cells   = cells || Array.new(ROWS) { Array.new(COLS, EMPTY) }
    @tile_ids = tile_ids || @cells.map {|values| values.map {|value| value == EMPTY ? EMPTY : value } }
    @options = options # the tiles waiting to be placed
    @score   = score
    @random  = random
  end

  # A deep copy, used for undo and search branches. Copy the RNG state so
  # advancing one branch cannot change another branch's future offers.
  def copy
    Board1010.new(cells: @cells.map(&:dup), tile_ids: @tile_ids.map(&:dup), options: @options.dup, score: @score, random: @random.dup)
  end

  # The column of the first filled square in the tile's top row. The square
  # you click on is where this square goes.
  def self.anchor(tile)
    tile.first.index {|value| value != EMPTY }
  end

  # ---------------------------------------------------------------------------
  # Playing
  # ---------------------------------------------------------------------------

  # One whole move: puts option `index` with its anchor on (row, col), scores
  # 1 point per square, empties full rows and columns, and deals 3 new tiles
  # once all are used. Returns a Move, or nil if the tile doesn't fit there.
  def play(index, row, col, deal: true)
    tile = @options[index]
    return nil unless tile && fits?(tile, row, col)

    placed = place(tile, row, col)
    @options.delete_at(index)
    cells_before_clearing = @cells.map(&:dup)
    tile_ids_before_clearing = @tile_ids.map(&:dup)
    rows, cols = full_lines
    clear_lines(rows, cols)
    deal_if_needed if deal

    Move.new(placed: placed, cells_before_clearing: cells_before_clearing,
             tile_ids_before_clearing: tile_ids_before_clearing,
             cleared_rows: rows, cleared_cols: cols)
  end

  # The game ends when none of the remaining tiles fit anywhere.
  def game_over?
    @options.none? {|tile| fits_anywhere?(tile) }
  end

  def deal_if_needed
    @options = generate_options if @options.empty?
  end

  # Replaces the offered batch. Used by trace replay to apply recorded offers
  # without consuming random numbers or repeating board-dependent fallback.
  def replace_options(tiles)
    @options = tiles.dup
  end

  # 3 random tiles. If none of them fit anywhere, the first one is swapped for
  # a small tile that does fit.
  def generate_options
    tiles = Array.new(OPTIONS) { ALL_TILES.sample(random: @random) }
    return tiles if tiles.any? {|tile| fits_anywhere?(tile) }

    small = SMALL_TILES.find {|tile| fits_anywhere?(tile) }
    tiles[0] = small if small
    tiles
  end

  # ---------------------------------------------------------------------------
  # Cells and positions
  # ---------------------------------------------------------------------------

  def inside?(row, col)
    row.between?(0, ROWS - 1) && col.between?(0, COLS - 1)
  end

  def empty?(row, col)
    inside?(row, col) && @cells[row][col] == EMPTY
  end

  def filled?(row, col)
    inside?(row, col) && @cells[row][col] != EMPTY
  end

  # [row, col, value] of each square the tile would cover with its anchor on (row, col).
  def cells_for(tile, row, col)
    left = col - Board1010.anchor(tile)
    squares = []
    tile.each_with_index do |values, r|
      values.each_with_index do |value, c|
        squares << [row + r, left + c, value] unless value == EMPTY
      end
    end
    squares
  end

  def fits?(tile, row, col)
    cells_for(tile, row, col).all? {|r, c, _value| empty?(r, c) }
  end

  # The first [row, col] where the tile fits, or nil.
  def find_position(tile)
    every_cell.find {|row, col| fits?(tile, row, col) }
  end

  def fits_anywhere?(tile)
    !find_position(tile).nil?
  end

  # Every [row, col] where the tile fits, top-left first.
  def positions_for(tile)
    every_cell.select {|row, col| fits?(tile, row, col) }
  end

  # Rows and columns that have no empty squares left.
  def full_lines
    rows = (0...ROWS).select {|row| @cells[row].none?(EMPTY) }
    cols = (0...COLS).select {|col| @cells.none? {|values| values[col] == EMPTY } }
    [rows, cols]
  end

  # ---------------------------------------------------------------------------
  # Measures used by the computer player (see auto_player.rb)
  # ---------------------------------------------------------------------------

  # How many of the 8 squares around (row, col) are filled.
  def filled_neighbours(row, col)
    NEIGHBOUR_OFFSETS.count {|dr, dc| filled?(row + dr, col + dc) }
  end

  # 1 for touching the top or bottom edge, plus 1 for touching the left or right edge.
  def edges_touched(row, col)
    [row.zero? || row == ROWS - 1, col.zero? || col == COLS - 1].count(true)
  end

  # How many rows and columns would be full after placing the tile there.
  def lines_completed_by(tile, row, col)
    trial = copy
    trial.place(tile, row, col)
    trial.full_lines.sum(&:size)
  end

  # ---------------------------------------------------------------------------
  # Saving
  # ---------------------------------------------------------------------------

  # A plain text format that is easy to read in an editor:
  #   score=133
  #   options=hl2,sq3,dot
  #   row=0000123000   (one line per row, top row first)
  #   type=0000000000  (base-36 tile type IDs, one line per row)
  def to_save
    lines = ["score=#{@score}", "options=#{@options.map {|tile| TILES.key(tile) }.join(',')}"]
    @cells.each_with_index do |values, row|
      lines << "row=#{values.join}"
      lines << "type=#{@tile_ids[row].map {|id| id.to_s(36) }.join}"
    end
    lines.join("\n")
  end

  # Builds a board from text made by #to_save, or returns nil if the text
  # doesn't look like a saved game.
  def self.from_save(text, random: Random.new)
    fields = parse_save(text)
    rows = fields[:rows]
    return nil if fields[:score].nil? || rows.size != ROWS || rows.any? {|values| values.size != COLS }
    tile_ids = fields[:tile_ids]
    if tile_ids && (tile_ids.size != ROWS || tile_ids.any? {|values| values.size != COLS || values.any? {|id| id.negative? || id > TILE_NAMES.size } })
      return nil
    end

    Board1010.new(cells: rows, tile_ids: tile_ids, options: fields[:options], score: fields[:score], random: random)
  end

  def self.parse_save(text)
    fields = {score: nil, options: [], rows: [], tile_ids: nil}
    text.each_line {|line| parse_save_line(fields, *line.strip.split("=", 2)) }
    fields
  end

  # A line without "=" (or an empty one) has no key or value, and is ignored.
  def self.parse_save_line(fields, key=nil, value=nil)
    case key
    when "score"   then fields[:score] = Integer(value, exception: false)
    when "options" then fields[:options] = value.to_s.split(",").filter_map {|name| TILES[name.to_sym] }
    when "row"     then fields[:rows] << value.to_s.chars.map(&:to_i)
    when "type"    then (fields[:tile_ids] ||= []) << value.to_s.chars.map {|id| id.to_i(36) }
    end
  end
  private_class_method :parse_save, :parse_save_line

  protected

  # Fills the tile's squares and adds 1 point per square. Assumes it fits.
  # Returns [row, col, value] of each square filled.
  def place(tile, row, col)
    squares = cells_for(tile, row, col)
    tile_id = TILE_IDS.fetch(tile)
    squares.each do |r, c, value|
      @cells[r][c] = value
      @tile_ids[r][c] = tile_id
    end
    @score += squares.size
    squares
  end

  private

  def clear_lines(rows, cols)
    rows.each do |row|
      COLS.times do |col|
        @cells[row][col] = @tile_ids[row][col] = EMPTY
      end
    end
    cols.each do |col|
      ROWS.times do |row|
        @cells[row][col] = @tile_ids[row][col] = EMPTY
      end
    end
  end

  def every_cell
    (0...ROWS).to_a.product((0...COLS).to_a)
  end
end
