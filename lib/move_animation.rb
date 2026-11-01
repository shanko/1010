# frozen_string_literal: true

# move_animation.rb: shows a move step by step, after the board has already changed.
#
# The original changed the board one square per frame and called sleep(0.25)
# between cleared lines, which froze the whole window. Here Board1010#play
# changes the board at once, and this class only says what each square should
# LOOK like at a given time, so the window keeps drawing and reading input.
require_relative "board"

class MoveAnimation
  PLACE_STEP_MS = 16  # the tile's squares appear one per frame, like the original
  CLEAR_STEP_MS = 250 # then one row and one column empty every quarter second

  # `move` is a Board1010::Move. `now` is the time in milliseconds (Gosu.milliseconds).
  def initialize(move, now, clear_step_ms: CLEAR_STEP_MS)
    @cells_before_clearing = move.cells_before_clearing
    @tile_ids_before_clearing = move.tile_ids_before_clearing
    @appears_at = appear_times(move.placed, now)

    clearing_starts = now + (move.placed.size * PLACE_STEP_MS)
    @row_cleared_at, @col_cleared_at, @ends_at = clear_times(move, clearing_starts, clear_step_ms)
  end

  def done?(now)
    now >= @ends_at
  end

  # The value to draw for (row, col) at time `now`, given its value on the board.
  def value_at(row, col, board_value, now)
    appears_at = @appears_at[[row, col]]
    return Board1010::EMPTY if appears_at && now < appears_at

    cleared_at = [@row_cleared_at[row], @col_cleared_at[col]].compact.min
    return @cells_before_clearing[row][col] if cleared_at && now < cleared_at

    board_value
  end

  # The tile type whose color should be shown at this point in the animation.
  def tile_id_at(row, col, board_tile_id, now)
    position = [row, col]
    appears_at = @appears_at[position]
    return Board1010::EMPTY if appears_at && now < appears_at

    cleared_at = [@row_cleared_at[row], @col_cleared_at[col]].compact.min
    return @tile_ids_before_clearing[row][col] if cleared_at && now < cleared_at

    board_tile_id
  end

  private

  # {[row, col] => time it appears}, one square per step.
  def appear_times(placed, start)
    placed.each_with_index.to_h {|(row, col, _value), step| [[row, col], start + (step * PLACE_STEP_MS)] }
  end

  # When each cleared row and column empties (one of each per step), and
  # when the last step is over.
  def clear_times(move, start, step_ms)
    rows  = step_times(move.cleared_rows, start, step_ms)
    cols  = step_times(move.cleared_cols, start, step_ms)
    steps = [rows.size, cols.size].max
    [rows, cols, start + (steps * step_ms)]
  end

  # {line => time it empties}, one line per step.
  def step_times(lines, start, step_ms)
    lines.each_with_index.to_h {|line, step| [line, start + (step * step_ms)] }
  end
end
