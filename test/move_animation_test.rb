# frozen_string_literal: true

require "minitest/autorun"
require_relative "../move_animation"

class MoveAnimationTest < Minitest::Test
  EMPTY = Board1010::EMPTY

  # A dot that completes row 0 (cleared) at (0, 9), played at time 1000.
  def setup
    @board = Board1010.new(options: [Board1010::TILES[:hl2], Board1010::TILES[:dot]])
    Board1010::COLS.times {|col| @board.cells[0][col] = 1 unless col >= 8 }
    move = @board.play(0, 0, 8) # hl2 fills (0, 8) and (0, 9)
    @animation = MoveAnimation.new(move, 1000)
  end

  def test_placed_squares_appear_one_per_step
    step = MoveAnimation::PLACE_STEP_MS
    assert_equal 2, value(0, 8, 1000), "the first square shows at once"
    assert_equal EMPTY, value(0, 9, 1000), "the second square isn't there yet"
    assert_equal 2, value(0, 9, 1000 + step)
  end

  def test_a_cleared_row_shows_its_old_squares_until_it_empties
    cleared_at = 1000 + (2 * MoveAnimation::PLACE_STEP_MS)
    assert_equal 1, value(0, 0, cleared_at - 1)
    assert_equal EMPTY, value(0, 0, cleared_at)
  end

  def test_squares_away_from_the_move_show_the_board
    assert_equal EMPTY, value(5, 5, 1000)
  end

  def test_done_after_the_last_line_empties
    ends_at = 1000 + (2 * MoveAnimation::PLACE_STEP_MS) + MoveAnimation::CLEAR_STEP_MS
    refute @animation.done?(ends_at - 1)
    assert @animation.done?(ends_at)
  end

  private

  def value(row, col, now)
    @animation.value_at(row, col, @board.cells[row][col], now)
  end
end
