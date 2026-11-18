# frozen_string_literal: true

require_relative "game_rules"

# board.rb: the rules of 1010!, with no drawing and no terminal input or output.
#
# The board is a grid of cells with row 0 at the top. An empty cell holds EMPTY;
# a filled cell holds its value and the ID of its exact tile shape.
require_relative "tile"

class Board1010
  ROWS    = 10
  COLS    = 10
  OPTIONS = 3 # tiles offered at a time
  EMPTY   = 0

  # Where the window and the terminal game keep a saved game.
  SAVE_FILE = "1010game.txt"

  # When none of the tiles dealt fit, the first one is swapped for the first
  # of these that does.
  SMALL_TILES = %i[hl2 vl2 sq2 bl2 tl2 br2 tr2 dot].map {|name| Tile.fetch(name) }.freeze

  # [row, col] steps to the 8 squares around a square.
  NEIGHBOUR_OFFSETS = [[-1, -1], [-1, 0], [-1, 1], [0, -1], [0, 1], [1, -1], [1, 0], [1, 1]].freeze
  NEIGHBOUR_MASKS = Array.new(ROWS) {|row|
    Array.new(COLS) {|col|
      NEIGHBOUR_OFFSETS.sum do |dr, dc|
        r = row + dr
        c = col + dc
        r.between?(0, ROWS - 1) && c.between?(0, COLS - 1) ? (1 << ((r * COLS) + c)) : 0
      end
    }.freeze
  }.freeze
  FULL_BOARD_MASK = (1 << (ROWS * COLS)) - 1
  FULL_ROW_MASK = (1 << COLS) - 1
  FULL_COLUMN_MASKS = Array.new(COLS) {|col|
    ROWS.times.sum {|row| 1 << ((row * COLS) + col) }
  }.freeze

  # What a move did, so the window can animate it.
  #   placed:                [row, col, value] of each square the tile filled
  #   cells_before_clearing / tile_ids_before_clearing: board state before full lines were emptied
  #   cleared_rows / cleared_cols: the full lines that were emptied
  Move = Struct.new(:placed, :cells_before_clearing, :tile_ids_before_clearing,
                    :cleared_rows, :cleared_cols, keyword_init: true)

  TILE_NAMES = Tile::NAMES

  # Difficulty levels run from 0 (dots) to 100 (3x3 squares); this one deals
  # plain random tiles.
  NEUTRAL_LEVEL = 50
  MAX_LEVEL = 100
  EASY_TILE = :dot
  HARD_TILE = :sq3

  attr_reader :cells, :tile_ids, :options, :score, :random, :bias

  # `random` deals the tiles. Pass Random.new(seed) to get the same tiles every time.
  # `bias` makes some tiles more likely; see #generate_options.
  def initialize(cells: nil, tile_ids: nil, options: [], score: 0, random: Random.new, bias: {})
    @cells = cells || empty_grid
    @tile_ids = tile_ids || tile_id_grid(@cells)
    @options = normalize_options(options)
    @score   = score
    @random  = random
    @bias    = self.class.normalize_bias(bias)
  end

  # A deep copy, used for undo and search branches. Copy the RNG state so
  # advancing one branch cannot change another branch's future offers.
  def copy
    Board1010.new(cells: @cells.map(&:dup), tile_ids: @tile_ids.map(&:dup), options: @options.dup, score: @score,
                  random: @random.dup, bias: @bias)
  end

  # Checks a bias such as {"dot" => 20} or {SQ3: 30} and returns it frozen,
  # keyed by lower-case tile name, without zero entries: {dot: 20, sq3: 30}.
  # Raises ArgumentError for unknown tiles, percentages outside 0..100, or a
  # total above 100.
  def self.normalize_bias(bias)
    raise ArgumentError, "bias must be a Hash, got #{bias.inspect}" unless bias.is_a?(Hash)

    normalized = bias.each_with_object({}) {|(name, percent), result| add_bias_entry(result, name, percent) }
    total = normalized.values.sum
    raise ArgumentError, "bias percentages add up to #{total}, more than 100" if total > 100

    normalized.reject {|_name, percent| percent.zero? }.freeze
  end

  def self.add_bias_entry(result, name, percent)
    name = Tile.fetch(name.to_s.downcase).name
    raise ArgumentError, "bias lists #{name} more than once" if result.key?(name)

    result[name] = bias_percent(name, percent)
  end

  def self.bias_percent(name, percent)
    valid = percent.is_a?(Numeric) && percent.real? && percent.finite? && percent.between?(0, 100)
    raise ArgumentError, "bias for #{name} must be a percentage from 0 to 100, got #{percent.inspect}" unless valid

    percent
  end
  private_class_method :add_bias_entry, :bias_percent

  # The bias for a difficulty level from 0 to 100. Level 50 is plain random;
  # each level below it adds 2% dots and each level above it adds 2% 3x3
  # squares, so level 0 deals only dots and level 100 only 3x3 squares.
  def self.bias_for_level(level)
    unless level.is_a?(Integer) && level.between?(0, MAX_LEVEL)
      raise ArgumentError, "level must be an integer from 0 to #{MAX_LEVEL}, got #{level.inspect}"
    end

    return {EASY_TILE => (NEUTRAL_LEVEL - level) * 2}.freeze if level < NEUTRAL_LEVEL
    return {HARD_TILE => (level - NEUTRAL_LEVEL) * 2}.freeze if level > NEUTRAL_LEVEL

    {}.freeze
  end

  # ---------------------------------------------------------------------------
  # Playing
  # ---------------------------------------------------------------------------

  # One whole move: puts option `index` with its anchor on (row, col), scores
  # 1 point per square, empties full rows and columns, and deals 3 new tiles
  # once all are used. Returns a Move, or nil if the tile doesn't fit there.
  def play(index, row, col, deal: true, capture: false)
    tile = @options[index]
    return nil unless tile && fits?(tile, row, col)

    placed = place(tile, row, col)
    @options.delete_at(index)
    cells_before_clearing, tile_ids_before_clearing = capture_state if capture
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

  # 3 tiles, by default dealt with the board's bias. If none of them fit
  # anywhere, the first one is swapped for a small tile that does fit.
  #
  # The bias maps tile names to percentages. Each tile is dealt as a mix: with
  # {dot: 20}, 20% of tiles are dots and the other 80% are picked uniformly
  # from all 19 tiles (dots included), so about 24% of tiles are dots. Several
  # tiles may be biased as long as the total is at most 100. An empty bias
  # means plain random, drawn exactly as before so seeded games are unchanged.
  def generate_options(bias=@bias)
    bias = self.class.normalize_bias(bias) unless bias.equal?(@bias)
    tiles = Array.new(OPTIONS) { deal_tile(bias) }
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
    tile.offsets.map do |row_offset, col_offset, value|
      [row + row_offset, col + col_offset - tile.anchor, value]
    end
  end

  def fits?(tile, row, col)
    left = col - tile.anchor
    return false unless row.between?(0, ROWS - tile.height) && left.between?(0, COLS - tile.width)

    tile.row_masks.each_with_index.all? do |mask, row_offset|
      occupancy_mask(@cells[row + row_offset]).nobits?(mask << left)
    end
  end

  # The first [row, col] where the tile fits, or nil.
  def find_position(tile)
    occupied = occupancy_bitboard
    placement = tile.placements.find {|_row, _col, mask| occupied.nobits?(mask) }
    placement&.first(2)
  end

  def fits_anywhere?(tile)
    !find_position(tile).nil?
  end

  # Every [row, col] where the tile fits, top-left first.
  def positions_for(tile)
    occupied = occupancy_bitboard
    tile.placements.filter_map do |row, col, mask|
      [row, col] if occupied.nobits?(mask)
    end
  end

  def legal_placement_count(tiles, occupied_bits: occupancy_bitboard, exclude_index: nil)
    tiles.each_with_index.sum do |tile, index|
      next 0 if index == exclude_index

      tile.placements.count {|_row, _col, mask| occupied_bits.nobits?(mask) }
    end
  end

  def placement_result(tile, row, col, occupied_bits: occupancy_bitboard)
    placed = occupied_bits | tile.placement_mask(row, col)
    full_rows = 0
    clear_mask = 0
    ROWS.times do |index|
      row_mask = FULL_ROW_MASK << (index * COLS)
      next unless placed.allbits?(row_mask)

      full_rows += 1
      clear_mask |= row_mask
    end
    full_cols = 0
    FULL_COLUMN_MASKS.each do |column_mask|
      next unless placed.allbits?(column_mask)

      full_cols += 1
      clear_mask |= column_mask
    end
    [placed & ~clear_mask, full_rows, full_cols]
  end

  # Rows and columns that have no empty squares left.
  def full_lines
    rows = (0...ROWS).select {|row| @cells[row].none?(EMPTY) }
    cols = (0...COLS).select {|col| @cells.none? {|values| values[col] == EMPTY } }
    [rows, cols]
  end

  # ---------------------------------------------------------------------------
  # Measures used by the computer player (see lib/auto_player.rb)
  # ---------------------------------------------------------------------------

  # How many of the 8 squares around (row, col) are filled.
  def filled_neighbours(row, col)
    NEIGHBOUR_OFFSETS.count {|dr, dc| filled?(row + dr, col + dc) }
  end

  # 1 for touching the top or bottom edge, plus 1 for touching the left or right edge.
  def edges_touched(row, col)
    [row.zero? || row == ROWS - 1, col.zero? || col == COLS - 1].count(true)
  end

  # Counts filled cells adjacent to any square in the tile's footprint. Each
  # neighboring cell is counted once, and squares covered by the tile itself
  # are excluded.
  def footprint_neighbours(tile, row, col)
    footprint_contact_count(tile, row, col, include_walls: false)
  end

  # As above, with each distinct off-board neighbor counted as occupied. This
  # gives strategies that treat board edges as occupied a footprint-wide view.
  def footprint_contact(tile, row, col)
    footprint_contact_count(tile, row, col, include_walls: true)
  end

  # How many rows and columns would be full after placing the tile there.
  def lines_completed_by(tile, row, col)
    line_completion_scores(tile, [[row, col]]).first
  end

  # Keep this bit-mask loop inline because feature extraction calls it for every
  # legal action; extra dispatches make the O-hint path measurably slower.
  # rubocop:disable Metrics/AbcSize
  def line_completion_scores(tile, positions)
    occupied_rows = Array.new(ROWS) {|row| occupancy_mask(@cells[row]) }
    occupied_cols = Array.new(COLS, 0)
    occupied_rows.each_with_index do |mask, row|
      COLS.times {|col| occupied_cols[col] |= (1 << row) unless mask.nobits?(1 << col) }
    end

    positions.map do |row, col|
      left = col - tile.anchor
      complete_rows = tile.row_masks.each_with_index.count do |mask, row_offset|
        (occupied_rows[row + row_offset] | (mask << left)) == (1 << COLS) - 1
      end
      complete_cols = tile.col_masks.each_with_index.count do |mask, col_offset|
        c = left + col_offset
        (occupied_cols[c] | (mask << row)) == (1 << ROWS) - 1
      end
      complete_rows + complete_cols
    end
  end
  # rubocop:enable Metrics/AbcSize

  def neighbour_scores(positions)
    occupied = occupancy_bitboard
    positions.map do |row, col|
      bits = occupied & NEIGHBOUR_MASKS[row][col]
      count = 0
      until bits.zero?
        bits &= bits - 1
        count += 1
      end
      count
    end
  end

  def occupied_bits
    occupancy_bitboard
  end

  # ---------------------------------------------------------------------------
  # Saving
  # ---------------------------------------------------------------------------

  # The save stores the same compact snapshot and offer records as a trace.
  def to_save
    [BoardSnapshot::SAVE_HEADER, *BoardSnapshot.records(self)].join("\n")
  end

  # Builds a board from text made by #to_save, or returns nil if the text
  # doesn't look like a saved game.
  def self.from_save(text, random: Random.new)
    return BoardSnapshot.read_save(text, random: random) if text.start_with?("#{BoardSnapshot::SAVE_HEADER}\n")

    fields = parse_save(text)
    board_from_legacy_fields(fields, random)
  end

  def self.board_from_legacy_fields(fields, random)
    return nil unless valid_legacy_rows?(fields)
    return nil unless valid_legacy_ids?(fields[:tile_ids])

    Board1010.new(cells: fields[:rows], tile_ids: fields[:tile_ids], options: fields[:options],
                  score: fields[:score], random: random)
  end

  def self.valid_legacy_rows?(fields)
    rows = fields[:rows]
    !fields[:score].nil? && rows.size == ROWS && rows.all? {|values| values.size == COLS }
  end

  def self.valid_legacy_ids?(tile_ids)
    return true unless tile_ids
    return false unless tile_ids.size == ROWS

    tile_ids.all? do |values|
      values.size == COLS && values.all? {|id| id.between?(0, TILE_NAMES.size) }
    end
  end
  private_class_method :board_from_legacy_fields, :valid_legacy_rows?, :valid_legacy_ids?

  def self.parse_save(text)
    fields = {score: nil, options: [], rows: [], tile_ids: nil}
    text.each_line {|line| parse_save_line(fields, *line.strip.split("=", 2)) }
    fields
  end

  # A line without "=" (or an empty one) has no key or value, and is ignored.
  def self.parse_save_line(fields, key=nil, value=nil)
    case key
    when "score"   then parse_score(fields, value)
    when "options" then parse_options(fields, value)
    when "row"     then fields[:rows] << value.to_s.chars.map(&:to_i)
    when "type"    then parse_tile_ids(fields, value)
    end
  end

  def self.parse_score(fields, value)
    fields[:score] = Integer(value, exception: false)
  end

  def self.parse_options(fields, value)
    fields[:options] = value.to_s.split(",").filter_map {|name| Tile::BY_NAME[name.to_sym] }
  end

  def self.parse_tile_ids(fields, value)
    (fields[:tile_ids] ||= []) << value.to_s.chars.map {|id| id.to_i(36) }
  end
  private_class_method :parse_save, :parse_save_line, :parse_score, :parse_options, :parse_tile_ids

  protected

  # Fills the tile's squares and adds 1 point per square. Assumes it fits.
  # Returns [row, col, value] of each square filled.
  def place(tile, row, col)
    squares = cells_for(tile, row, col)
    tile_id = tile.id
    squares.each do |r, c, value|
      @cells[r][c] = value
      @tile_ids[r][c] = tile_id
    end
    @score += squares.size
    squares
  end

  private

  # One tile for #generate_options. An empty bias keeps the original single
  # `sample` call; a biased deal uses exactly one `rand`, whose roll first
  # lands in a biased tile's share and otherwise picks uniformly from the rest.
  def deal_tile(bias)
    return Tile::ALL.sample(random: @random) if bias.empty?

    roll = @random.rand * 100
    bias.each do |name, percent|
      return Tile.fetch(name) if roll < percent

      roll -= percent
    end
    uniform_tile(roll / (100 - bias.values.sum))
  end

  # The tile at `fraction` (0...1) of the way through all tiles.
  def uniform_tile(fraction)
    Tile::ALL[[(fraction * Tile::ALL.size).floor, Tile::ALL.size - 1].min]
  end

  def empty_grid
    Array.new(ROWS) { Array.new(COLS, EMPTY) }
  end

  def tile_id_grid(cells)
    cells.map {|values| values.map {|value| value == EMPTY ? EMPTY : value } }
  end

  def normalize_options(options)
    options.map {|tile| tile.is_a?(Tile) ? tile : Tile.fetch(tile) }
  end

  def capture_state
    [@cells.map(&:dup), @tile_ids.map(&:dup)]
  end

  # This single pass serves each candidate placement in learned feature
  # extraction. Keeping the neighbor traversal inline avoids hot-loop dispatch.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def footprint_contact_count(tile, row, col, include_walls:)
    own = {}
    tile.offsets.each do |row_offset, col_offset, _value|
      own[[row + row_offset, col + col_offset - tile.anchor]] = true
    end
    touching = {}
    own.each_key do |r, c|
      NEIGHBOUR_OFFSETS.each do |dr, dc|
        cell = [r + dr, c + dc]
        next if own.key?(cell) || touching.key?(cell)

        if inside?(*cell)
          touching[cell] = true if filled?(*cell)
        elsif include_walls
          touching[cell] = true
        end
      end
    end
    touching.size
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

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

  def occupancy_mask(values)
    mask = 0
    values.each_with_index {|value, col| mask |= (1 << col) unless value == EMPTY }
    mask
  end

  def occupancy_bitboard
    bits = 0
    @cells.each_with_index do |values, row|
      bits |= occupancy_mask(values) << (row * COLS)
    end
    bits
  end
end

# The initial board/offer records are shared by one-shot saves and replay
# traces. Saves stop after these records; traces append their event history.
module BoardSnapshot
  SAVE_HEADER = "1010-board-v1"

  def self.records(board)
    [state_record(board), offer_record(board.options)]
  end

  def self.state_record(board)
    "i#{board.score}|#{board.cells.flatten.join}|#{board.tile_ids.flatten.map {|id| id.to_s(36) }.join}"
  end

  def self.offer_record(tiles)
    "d#{tiles.map {|tile| tile.id.to_s(36) }.join}"
  end

  def self.decode_state(record, random: Random.new)
    match = record.match(/\Ai(\d+)\|([0-5]{100})\|([0-9a-j]{100})\z/)
    return nil unless match

    tile_ids = decode_grid(match[3])
    return nil if tile_ids.flatten.any? {|id| id > Tile::ALL.size }

    Board1010.new(score: Integer(match[1]), cells: decode_grid(match[2]), tile_ids: tile_ids, random: random)
  end

  def self.decode_offer(record)
    match = record.match(/\Ad([1-9a-j]{1,3})\z/)
    return nil unless match

    ids = match[1].chars.map {|id| id.to_i(36) }
    return nil if ids.any? {|id| id > Tile::ALL.size }

    ids.map {|id| Tile::ALL.fetch(id - 1) }
  end

  def self.read_save(text, random: Random.new)
    header, state, offer, extra = text.lines(chomp: true)
    return nil unless header == SAVE_HEADER && state && offer && !extra

    board = decode_state(state, random: random)
    options = decode_offer(offer)
    return nil unless board && options

    board.replace_options(options)
    board
  end

  def self.decode_grid(text)
    text.chars.each_slice(10).map {|row| row.map {|id| id.to_i(36) } }
  end
  private_class_method :decode_grid
end
