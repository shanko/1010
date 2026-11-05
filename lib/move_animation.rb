# frozen_string_literal: true

# move_animation.rb: shows a move step by step, after the board has already changed.
#
# The original changed the board one square per frame and called sleep(0.25)
# between cleared lines, which froze the whole window. Here Board1010#play
# changes the board at once, and this class only says what each square should
# LOOK like at a given time, so the window keeps drawing and reading input.
require_relative "board"

class MoveAnimation
  PLACE_STEP_MS  = 16  # the tile's squares appear one per frame, like the original
  CLEAR_STEP_MS  = 250 # then one row and one column start fading every quarter second
  CLEAR_FADE_MS  = 700 # each emptied line takes this long to fade out

  # `move` is a Board1010::Move. `now` is the time in milliseconds (Gosu.milliseconds).
  def initialize(move, now, clear_step_ms: CLEAR_STEP_MS, fade_ms: CLEAR_FADE_MS)
    @cells_before_clearing = move.cells_before_clearing
    @tile_ids_before_clearing = move.tile_ids_before_clearing
    @appears_at = appear_times(move.placed, now)
    @fade_ms = fade_ms

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
    return @cells_before_clearing[row][col] if cleared_at && now < cleared_at + @fade_ms

    board_value
  end

  # The tile type whose color should be shown at this point in the animation.
  def tile_id_at(row, col, board_tile_id, now)
    position = [row, col]
    appears_at = @appears_at[position]
    return Board1010::EMPTY if appears_at && now < appears_at

    cleared_at = [@row_cleared_at[row], @col_cleared_at[col]].compact.min
    return @tile_ids_before_clearing[row][col] if cleared_at && now < cleared_at + @fade_ms

    board_tile_id
  end

  # How opaque (row, col) is at `now`: squares in a cleared line fade out over
  # @fade_ms once their line empties. Everything else is fully opaque.
  def alpha_at(row, col, now)
    cleared_at = [@row_cleared_at[row], @col_cleared_at[col]].compact.min
    return 1.0 unless cleared_at && now > cleared_at && now < cleared_at + @fade_ms

    [0.0, 1.0 - ((now - cleared_at).to_f / @fade_ms)].max
  end

  private

  # {[row, col] => time it appears}, one square per step.
  def appear_times(placed, start)
    placed.each_with_index.to_h {|(row, col, _value), step| [[row, col], start + (step * PLACE_STEP_MS)] }
  end

  # When each cleared row and column starts fading (one of each per step), and
  # when the last fade is over.
  def clear_times(move, start, step_ms)
    rows  = step_times(move.cleared_rows, start, step_ms)
    cols  = step_times(move.cleared_cols, start, step_ms)
    last  = [rows.each_value.max, cols.each_value.max].compact.max
    [rows, cols, last ? last + @fade_ms : start]
  end

  # {line => time it starts fading}, one line per step.
  def step_times(lines, start, step_ms)
    lines.each_with_index.to_h {|line, step| [line, start + (step * step_ms)] }
  end
end
