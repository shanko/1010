# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../terminal_game"

class TerminalGameTest < Minitest::Test
  def play(typed, board)
    output = StringIO.new
    TerminalGame.new(input: StringIO.new(typed), output: output, board: board).run
    output.string
  end

  def test_places_a_tile_and_stops_without_saving
    board = Board1010.new(options: [Board1010::TILES[:sq2], Board1010::TILES[:dot]])
    output = play("0, 0\n1\n-1, 0\nn\n", board)

    assert_equal 4, board.score
    assert_includes output, "Score = 4"
    assert_includes output, "Game stopped"
  end

  def test_reports_a_tile_that_does_not_fit
    board = Board1010.new(options: [Board1010::TILES[:hl5], Board1010::TILES[:dot]])
    output = play("0, 9\n1\nq\n", board)

    assert_includes output, "Cannot place that tile at (0, 9)"
  end
end
