# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/move_animation"

class MoveAnimationTest < Minitest::Test
  EMPTY = Board1010::EMPTY

  # A dot that completes row 0 (cleared) at (0, 9), played at time 1000.
  def setup
    @board = Board1010.new(options: [Tile.fetch(:hl2), Tile.fetch(:dot)])
    Board1010::COLS.times {|col| @board.cells[0][col] = 1 unless col >= 8 }
    move = @board.play(0, 0, 8, capture: true) # hl2 fills (0, 8) and (0, 9)
    @animation = MoveAnimation.new(move, 1000)
  end

  def test_placed_squares_appear_one_per_step
    step = MoveAnimation::PLACE_STEP_MS
    assert_equal 2, value(0, 8, 1000), "the first square shows at once"
    assert_equal EMPTY, value(0, 9, 1000), "the second square isn't there yet"
    assert_equal 2, value(0, 9, 1000 + step)
  end

  def test_a_cleared_row_shows_its_old_squares_while_it_fades
    cleared_at = 1000 + (2 * MoveAnimation::PLACE_STEP_MS)
    fade = MoveAnimation::CLEAR_FADE_MS
    assert_equal 1, value(0, 0, cleared_at + fade - 1)
    assert_equal EMPTY, value(0, 0, cleared_at + fade)
  end

  def test_cleared_squares_fade_out_over_the_fade_time
    cleared_at = 1000 + (2 * MoveAnimation::PLACE_STEP_MS)
    fade = MoveAnimation::CLEAR_FADE_MS
    assert_equal 1.0, @animation.alpha_at(0, 0, cleared_at)
    mid_fade = @animation.alpha_at(0, 0, cleared_at + (fade / 2))
    assert mid_fade.positive? && mid_fade < 1, "mid-fade should be translucent, got #{mid_fade}"
    assert_equal 1.0, @animation.alpha_at(0, 0, cleared_at + fade)
    assert_equal 1.0, @animation.alpha_at(5, 5, cleared_at + 1), "uncleared squares never fade"
  end

  def test_squares_away_from_the_move_show_the_board
    assert_equal EMPTY, value(5, 5, 1000)
  end

  def test_placed_cells_use_the_placed_tile_type_color_identity
    tile_id = Tile.fetch(:hl2).id

    assert_equal tile_id, @animation.tile_id_at(0, 8, @board.tile_ids[0][8], 1000)
    assert_equal EMPTY, @animation.tile_id_at(0, 9, @board.tile_ids[0][9], 1000)
    assert_equal tile_id, @animation.tile_id_at(0, 9, @board.tile_ids[0][9], 1000 + MoveAnimation::PLACE_STEP_MS)
  end

  def test_done_after_the_last_line_fades_out
    ends_at = 1000 + (2 * MoveAnimation::PLACE_STEP_MS) + MoveAnimation::CLEAR_FADE_MS
    refute @animation.done?(ends_at - 1)
    assert @animation.done?(ends_at)
  end

  private

  def value(row, col, now)
    @animation.value_at(row, col, @board.cells[row][col], now)
  end
end
