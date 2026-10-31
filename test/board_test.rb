# frozen_string_literal: true

require "minitest/autorun"
require_relative "../board"

class BoardTest < Minitest::Test
  TILES = Board1010::TILES

  def fill_row(board, row, except: [])
    Board1010::COLS.times {|col| board.cells[row][col] = 1 unless except.include?(col) }
  end

  # --- Tiles ------------------------------------------------------------------

  def test_there_are_19_tiles_and_8_small_ones
    assert_equal 19, Board1010::ALL_TILES.size
    assert_equal 8, Board1010::SMALL_TILES.compact.size
  end

  def test_anchor_is_the_first_filled_square_of_the_top_row
    assert_equal 0, TILES[:tl3].anchor
    assert_equal 1, TILES[:br2].anchor
    assert_equal 2, TILES[:br3].anchor
  end

  def test_tile_values_are_immutable_and_precompute_shape_metadata
    tile = Tile.fetch("br2")

    assert_equal :br2, tile.name
    assert_equal 3, tile.area
    assert_equal [[0, 1, 2], [1, 0, 2], [1, 1, 2]], tile.offsets
    assert tile.frozen?
    assert tile.rows.frozen?
    assert tile.rows.all?(&:frozen?)
    assert_raises(FrozenError) { tile.rows[0][0] = 9 }
    assert_same tile, Tile.fetch(:br2)
    assert_raises(ArgumentError) { Tile.fetch(:missing) }
  end

  # --- Placing ----------------------------------------------------------------

  def test_cells_for_shifts_the_tile_left_by_its_anchor
    board = Board1010.new
    assert_equal [[0, 5, 2], [1, 4, 2], [1, 5, 2]], board.cells_for(TILES[:br2], 0, 5)
  end

  def test_fits_checks_the_edges_and_other_tiles
    board = Board1010.new
    board.cells[5][5] = 1

    assert board.fits?(TILES[:hl3], 5, 6)
    refute board.fits?(TILES[:hl3], 5, 4), "would cover (5, 5)"
    refute board.fits?(TILES[:hl3], 0, 8), "runs off the right edge"
    refute board.fits?(TILES[:vl5], 7, 0), "runs off the bottom"
    refute board.fits?(TILES[:br2], 0, 0), "its anchor shifts it off the left edge"
  end

  def test_play_scores_one_point_per_square_and_uses_up_the_option
    board = Board1010.new(options: [TILES[:sq2], TILES[:dot]])
    move = board.play(0, 0, 0)

    assert_equal 4, board.score
    assert_equal [TILES[:dot]], board.options
    assert_equal [[0, 0, 2], [0, 1, 2], [1, 0, 2], [1, 1, 2]], move.placed
  end

  def test_placing_any_shape_records_its_distinct_tile_type_id
    ids = Board1010::ALL_TILES.map(&:id)
    assert_equal Board1010::TILES.size, ids.uniq.size

    Board1010::TILES.each do |name, tile|
      board = Board1010.new(options: [tile])
      row = 0
      col = tile.anchor
      board.play(0, row, col)
      filled_ids = board.tile_ids.flatten.reject(&:zero?).uniq
      assert_equal [tile.id], filled_ids, "#{name} cells retain their tile type"
    end
  end

  def test_play_returns_nil_and_changes_nothing_when_the_tile_does_not_fit
    board = Board1010.new(options: [TILES[:hl3]])

    assert_nil board.play(0, 0, 8)
    assert_equal 0, board.score
    assert_equal [TILES[:hl3]], board.options
  end

  # --- Clearing lines -----------------------------------------------------------

  def test_full_row_is_cleared
    board = Board1010.new(options: [TILES[:dot], TILES[:dot]])
    fill_row(board, 3, except: [9])
    move = board.play(0, 3, 9)

    assert_equal [3], move.cleared_rows
    assert_empty move.cleared_cols
    assert(board.cells[3].all? {|value| value == Board1010::EMPTY })
    assert_equal 1, move.cells_before_clearing[3][9], "the move remembers the row before it was cleared"
  end

  def test_row_and_column_are_cleared_together
    board = Board1010.new(options: [TILES[:dot], TILES[:dot]])
    fill_row(board, 0, except: [0])
    (1...Board1010::ROWS).each {|row| board.cells[row][0] = 1 }
    move = board.play(0, 0, 0)

    assert_equal [[0], [0]], [move.cleared_rows, move.cleared_cols]
    assert_equal [Board1010::EMPTY], board.cells.flatten.uniq
    assert_equal move.placed.size, board.score, "clearing lines adds no score"
  end

  def test_score_is_the_sum_of_placed_tile_areas_even_when_a_line_is_cleared
    board = Board1010.new(options: [TILES[:hl2], TILES[:dot]])
    fill_row(board, 0, except: [8, 9])
    starting_score = board.score
    placed_area = 0

    first_move = board.play(0, 0, 8)
    placed_area += first_move.placed.size
    second_move = board.play(0, 1, 1)
    placed_area += second_move.placed.size

    assert_equal [0], first_move.cleared_rows
    assert_empty first_move.cleared_cols
    assert_equal placed_area, board.score - starting_score
    assert_equal 3, placed_area
  end

  # --- Dealing and game over --------------------------------------------------------

  def test_deals_three_new_tiles_once_all_are_used
    board = Board1010.new(options: [TILES[:dot]])
    board.play(0, 0, 0)
    assert_equal 3, board.options.size
  end

  def test_the_same_seed_deals_the_same_tiles
    first  = Board1010.new(random: Random.new(42)).generate_options
    second = Board1010.new(random: Random.new(42)).generate_options
    assert_equal first, second
  end

  def test_a_small_tile_is_swapped_in_when_nothing_dealt_fits
    board = Board1010.new
    Board1010::ROWS.times {|row| fill_row(board, row) }
    board.cells[0][0] = board.cells[0][1] = Board1010::EMPTY # room for hl2 (or a dot)

    20.times do
      assert(board.generate_options.any? {|tile| board.fits_anywhere?(tile) })
    end
  end

  def test_game_over_when_no_option_fits
    board = Board1010.new(options: [TILES[:sq3]])
    Board1010::ROWS.times {|row| fill_row(board, row) }
    board.cells[0][0] = Board1010::EMPTY
    assert board.game_over?

    board.options << TILES[:dot]
    refute board.game_over?
  end

  # --- Positions and measures -------------------------------------------------------

  def test_find_position_and_positions_for
    board = Board1010.new
    assert_equal [0, 0], board.find_position(TILES[:sq3])
    assert_equal 64, board.positions_for(TILES[:sq3]).size # 8 x 8 places for a 3x3 square
  end

  def test_neighbours_and_edges
    board = Board1010.new
    board.cells[4][4] = board.cells[4][5] = board.cells[5][4] = 1

    assert_equal 3, board.filled_neighbours(5, 5)
    assert_equal 2, board.edges_touched(0, 0)
    assert_equal 1, board.edges_touched(0, 5)
    assert_equal 0, board.edges_touched(5, 5)
  end

  def test_lines_completed_by_does_not_change_the_board
    board = Board1010.new
    fill_row(board, 2, except: [8, 9])

    assert_equal 1, board.lines_completed_by(TILES[:hl2], 2, 8)
    assert_equal Board1010::EMPTY, board.cells[2][8]
    assert_equal 0, board.score
  end

  # --- Copying and saving -----------------------------------------------------------

  def test_copy_is_independent
    board = Board1010.new(options: [TILES[:dot]])
    copy  = board.copy
    board.play(0, 0, 0)

    assert_equal Board1010::EMPTY, copy.cells[0][0]
    assert_equal [TILES[:dot]], copy.options
    assert_equal 0, copy.score
  end

  def test_copy_has_an_independent_snapshot_of_the_random_state
    board = Board1010.new(random: Random.new(8675309))
    first_branch = board.copy
    second_branch = board.copy

    expected_first_draw = board.random.rand
    assert_equal expected_first_draw, first_branch.random.rand
    assert_equal expected_first_draw, second_branch.random.rand
    assert_equal board.random.rand, first_branch.random.rand
    refute_same board.random, first_branch.random
  end

  def test_save_and_load_round_trip
    board = Board1010.new(options: [TILES[:hl5], TILES[:dot]])
    board.play(1, 2, 3)
    copy = Board1010.from_save(board.to_save)

    assert_equal board.cells, copy.cells
    assert_equal board.tile_ids, copy.tile_ids
    assert_equal board.score, copy.score
    assert_equal board.options, copy.options
  end

  def test_a_damaged_save_is_rejected
    assert_nil Board1010.from_save("score=10\nrow=000")
    assert_nil Board1010.from_save("not a saved game")
  end

  def test_loads_a_legacy_save_without_tile_type_rows
    board = Board1010.new(options: [TILES[:dot]])
    board.play(0, 0, 0)
    old_format = board.to_save.lines.reject {|line| line.start_with?("type=") }.join

    loaded = Board1010.from_save(old_format)

    assert_equal board.cells, loaded.cells
    assert_equal 1, loaded.tile_ids[0][0]
  end
end
