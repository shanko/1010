# frozen_string_literal: true

require "minitest/autorun"
require_relative "../auto_player"

class AutoPlayerTest < Minitest::Test
  TILES = Board1010::TILES

  def test_jc_prefers_a_corner_on_an_empty_board
    assert_equal [0, 0], AutoPlayer.new(:jc).best_position(Board1010.new, TILES[:dot])
  end

  def test_jc_prefers_a_crowded_spot
    board = Board1010.new
    [[4, 4], [4, 5], [4, 6], [5, 4], [5, 6]].each {|row, col| board.cells[row][col] = 1 }
    assert_equal [5, 5], AutoPlayer.new(:jc).best_position(board, TILES[:dot])
  end

  def test_first_fit_and_last_fit
    board = Board1010.new
    assert_equal [0, 0], AutoPlayer.new(:first_fit).best_position(board, TILES[:sq2])
    assert_equal [8, 8], AutoPlayer.new(:last_fit).best_position(board, TILES[:sq2])
  end

  def test_sam_completes_a_line_when_it_can
    board = Board1010.new
    Board1010::COLS.times {|col| board.cells[9][col] = 1 unless col == 3 }
    assert_equal [9, 3], AutoPlayer.new(:sam).best_position(board, TILES[:dot])
  end

  def test_no_position_when_the_tile_fits_nowhere
    board = Board1010.new
    board.cells.each {|values| values.fill(1) }
    assert_nil AutoPlayer.new.best_position(board, TILES[:dot])
  end

  def test_unknown_strategy_is_rejected_with_the_choices
    error = assert_raises(ArgumentError) { AutoPlayer.new(:best) }
    assert_includes error.message, "jc"
  end

  def test_choose_move_only_picks_a_tile_that_fits
    board = Board1010.new(options: [TILES[:sq3], TILES[:dot]])
    Board1010::ROWS.times {|row| board.cells[row].fill(1) }
    board.cells[0][0] = Board1010::EMPTY

    assert_equal [1, 0, 0], AutoPlayer.new.choose_move(board)
  end

  def test_every_strategy_plays_whole_games
    AutoPlayer::STRATEGIES.each do |strategy|
      player = AutoPlayer.new(strategy, random: Random.new(1))
      board  = Board1010.new(random: Random.new(1))
      board.deal_if_needed
      board.play(*player.choose_move(board)) until board.game_over?

      assert_operator board.score, :>, 0, strategy
    end
  end

  def test_the_same_seeds_repeat_the_same_game
    scores = Array.new(2) do
      player = AutoPlayer.new(:jc, random: Random.new(7))
      board  = Board1010.new(random: Random.new(7))
      board.deal_if_needed
      board.play(*player.choose_move(board)) until board.game_over?
      board.score
    end
    assert_equal scores.first, scores.last
  end
end
