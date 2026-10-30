# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../game_1010"

class GameReplayTest < Minitest::Test
  def with_moves(text)
    Tempfile.create(["game", ".moves"]) do |file|
      file.write(text)
      file.flush
      yield file.path
    end
  end

  def test_reads_move_and_undo_records_and_seed
    with_moves("s12345\nm012\nm290\nu\n") do |path|
      assert_equal [12_345, [[:move, 0, 1, 2], [:move, 2, 9, 0], [:undo]]], GameWindow.read_moves(path)
    end
  end

  def test_rejects_a_file_without_the_expected_header
    with_moves("m012\n") do |path|
      error = assert_raises(ArgumentError) { GameWindow.read_moves(path) }
      assert_match "not a supported .moves file", error.message
    end
  end

  def test_rejects_a_file_without_a_replayable_seed
    with_moves("s-\nm012\n") do |path|
      error = assert_raises(ArgumentError) { GameWindow.read_moves(path) }
      assert_match "no replayable seed", error.message
    end
  end

  def test_rejects_malformed_move_records
    with_moves("s42\nm912\n") do |path|
      error = assert_raises(ArgumentError) { GameWindow.read_moves(path) }
      assert_match "invalid move record", error.message
    end
  end

  def test_command_line_options_recognize_replay_file_alongside_auto_seed_and_delay
    options = GameWindow.options_from(["auto", "sam", "--seed", "7", "--delay", "1.25", "logs/game.moves"])

    assert_equal({auto: true, strategy: "sam", seed: 7, replay_delay: 1.25, replay_file: "logs/game.moves"}, options)
  end

  def test_command_line_options_leave_non_moves_arguments_alone
    assert_equal({auto: true, strategy: "sam"}, GameWindow.options_from(["auto", "sam"]))
  end

  def test_command_line_delay_defaults_to_half_a_second
    assert_equal 0.5, GameWindow::REPLAY_DELAY_SECONDS
  end

  def test_rejects_invalid_or_negative_delay_values
    ["abc", "-0.1", "Infinity"].each do |value|
      error = assert_raises(ArgumentError) { GameWindow.options_from(["--delay", value, "logs/game.moves"]) }
      assert_match "delay", error.message
    end
  end

  def test_rejects_delay_without_a_value
    error = assert_raises(ArgumentError) { GameWindow.options_from(["--delay"]) }
    assert_match "requires seconds", error.message
  end

  def test_replays_moves_and_undoes_with_a_quarter_second_gap
    window = GameWindow.allocate
    window.instance_variable_set(:@playback, [[:move, 1, 2, 3], [:undo], [:move, 0, 4, 5]])
    window.instance_variable_set(:@replay_delay_ms, 1_250)
    moves = []
    undos = 0

    window.define_singleton_method(:try_place) {|*args| moves << args }
    window.define_singleton_method(:undo) { undos += 1 }
    window.define_singleton_method(:caption=) {|_text| }
    window.define_singleton_method(:show_message) {|_text| }

    window.play_back_next(1_000)
    assert_equal [[1, 2, 3]], moves
    assert_equal 2_250, window.instance_variable_get(:@playback_next_at)

    window.play_back_next(2_249)
    assert_equal 0, undos
    assert_equal 2, window.instance_variable_get(:@playback).size

    window.play_back_next(2_250)
    assert_equal 1, undos
    assert_equal 3_500, window.instance_variable_get(:@playback_next_at)

    window.play_back_next(3_500)
    assert_equal [[1, 2, 3], [0, 4, 5]], moves
    assert_equal 4_750, window.instance_variable_get(:@playback_next_at)

    window.play_back_next(4_750)
    assert_nil window.instance_variable_get(:@playback)
  end

  def test_failed_placement_clears_selection_highlight
    board = Board1010.new(options: [Board1010::TILES[:dot]])
    board.cells[0][0] = 1
    window = GameWindow.allocate
    window.instance_variable_set(:@board, board)
    window.instance_variable_set(:@selected, 0)

    window.try_place(0, 0, 0)

    assert_nil window.instance_variable_get(:@selected)
  end

  def test_each_tile_value_has_a_distinct_non_black_non_white_color
    window = GameWindow.allocate
    colors = GameWindow::TILE_COLORS.values

    assert_equal Board1010::TILES.size, colors.map(&:to_i).uniq.size
    refute_includes colors.map(&:to_i), Gosu::Color::BLACK.to_i
    refute_includes colors.map(&:to_i), Gosu::Color::WHITE.to_i
    Board1010::TILES.each do |name, tile|
      tile_id = Board1010::TILE_IDS.fetch(tile)
      value = tile.flatten.find {|cell| cell != Board1010::EMPTY }
      assert_equal GameWindow::TILE_COLORS.fetch(tile_id), window.cell_color(value, tile_id), name.to_s
    end
  end
end
