# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../terminal_game"
require_relative "../game_trace"

class TerminalGameTest < Minitest::Test
  def play(typed, board)
    output = StringIO.new
    events = []
    logger = Object.new
    logger.define_singleton_method(:move) {|*event| events << [:move, *event] }
    logger.define_singleton_method(:deal) {|tiles| events << [:deal, tiles] }
    logger.define_singleton_method(:finish) {|**event| events << [:end, event] }
    TerminalGame.new(input: StringIO.new(typed), output: output, board: board, game_log: logger).run
    @last_logged_moves = events
    output.string
  end

  def test_places_a_tile_and_stops_without_saving
    board = Board1010.new(options: [Board1010::TILES[:sq2], Board1010::TILES[:dot]])
    output = play("0, 0\n1\n-1, 0\nn\n", board)

    assert_equal 4, board.score
    assert_equal [[:move, :sq2, 0, 0, 0]], @last_logged_moves.select {|event| event.first == :move }
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
    logger = Object.new
    logger.define_singleton_method(:move) {|*| }
    logger.define_singleton_method(:deal) {|*| }
    logger.define_singleton_method(:finish) {|*| }
    game = TerminalGame.allocate
    game.define_singleton_method(:load_game) { nil }
    game.send(:initialize, input: StringIO.new("q\nn\n"), output: output, game_log: logger)

    assert_kind_of Integer, game.instance_variable_get(:@seed)
  end

  def test_terminal_game_trace_records_batches_and_replays_to_the_same_score
    Dir.mktmpdir do |directory|
      board = Board1010.new(options: Array.new(3, Board1010::TILES[:dot]), random: Random.new(31))
      logger = GameLog.new(seed: 31, board: board, mode: "terminal", directory: directory)
      input = "0, 0\n1\n0, 1\n1\n0, 2\n1\nq\nn\n"
      TerminalGame.new(input: StringIO.new(input), output: StringIO.new, board: board, game_log: logger).run

      trace = GameTrace.read(logger.path)
      replayed_board = GameTrace.replay(trace)

      assert_equal "terminal", trace.mode
      assert_equal 2, trace.deal_batches.size
      assert_equal board.cells, replayed_board.cells
      assert_equal board.score, replayed_board.score
    end
  end
end
