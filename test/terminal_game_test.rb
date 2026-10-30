# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../terminal_game"

class TerminalGameTest < Minitest::Test
  def play(typed, board)
    output = StringIO.new
    events = []
    logger = Object.new
    logger.define_singleton_method(:move) {|*event| events << event }
    logger.define_singleton_method(:close) {}
    TerminalGame.new(input: StringIO.new(typed), output: output, board: board, game_log: logger).run
    @last_logged_moves = events
    output.string
  end

  def test_places_a_tile_and_stops_without_saving
    board = Board1010.new(options: [Board1010::TILES[:sq2], Board1010::TILES[:dot]])
    output = play("0, 0\n1\n-1, 0\nn\n", board)

    assert_equal 4, board.score
    assert_equal [[0, 0, 0]], @last_logged_moves
    assert_includes output, "Score = 4"
    assert_includes output, "Game stopped"
  end

  def test_reports_a_tile_that_does_not_fit
    board = Board1010.new(options: [Board1010::TILES[:hl5], Board1010::TILES[:dot]])
    output = play("0, 9\n1\nq\n", board)

    assert_includes output, "Cannot place that tile at (0, 9)"
  end

  def test_fresh_game_seed_is_written_to_its_logger
    output = StringIO.new
    logged_seed = nil
    logger = Object.new
    logger.define_singleton_method(:close) {}
    game = TerminalGame.allocate
    game.define_singleton_method(:load_game) { nil }

    logger.define_singleton_method(:seed=) {|seed| logged_seed = seed }
    game.send(:initialize, input: StringIO.new("q\nn\n"), output: output, game_log: logger)

    assert_kind_of Integer, game.instance_variable_get(:@seed)
    assert_equal game.instance_variable_get(:@seed), logged_seed
  end
end
