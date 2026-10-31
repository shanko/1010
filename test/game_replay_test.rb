# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require "tmpdir"
require "open3"
require "rbconfig"
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

  def test_v2_trace_replays_initial_board_deals_moves_and_undo_exactly
    Dir.mktmpdir do |directory|
      board = Board1010.new(options: [Board1010::TILES[:dot], Board1010::TILES[:dot]], random: Random.new(51))
      logger = GameLog.new(seed: 51, board: board, mode: "test", directory: directory)

      tile_name = board.options[0].name
      board.play(0, 0, 0)
      logger.move(tile_name, 0, 0, 0)

      previous_board = board.copy
      tile_name = board.options[0].name
      board.play(0, 0, 1)
      logger.move(tile_name, 0, 0, 1)
      logger.deal(board.options)

      board = previous_board
      logger.undo
      logger.finish(reason: "stopped", score: board.score)

      trace = GameTrace.read(logger.path)
      replayed_board = GameTrace.replay(trace)

      assert_equal 51, trace.seed
      assert_equal "test", trace.mode
      assert_equal 2, trace.deal_batches.size
      assert_equal board.cells, replayed_board.cells
      assert_equal board.tile_ids, replayed_board.tile_ids
      assert_equal board.options, replayed_board.options
      assert_equal board.score, replayed_board.score
    end
  end

  def test_v2_trace_rejects_incomplete_files
    with_moves("#{GameTrace::HEADER}\ns1\nmode=test\ni0|#{'0' * 100}|#{'0' * 100}\nddot\n") do |path|
      error = assert_raises(ArgumentError) { GameTrace.read(path) }
      assert_match "missing the end record", error.message
    end
  end

  def test_v2_trace_replays_a_seedless_nonempty_starting_board
    Dir.mktmpdir do |directory|
      cells = Array.new(Board1010::ROWS) { Array.new(Board1010::COLS, Board1010::EMPTY) }
      tile_ids = Array.new(Board1010::ROWS) { Array.new(Board1010::COLS, Board1010::EMPTY) }
      cells[4][6] = 2
      tile_ids[4][6] = Tile.fetch(:hl2).id
      board = Board1010.new(cells: cells, tile_ids: tile_ids, options: [Board1010::TILES[:dot]], score: 17)
      logger = GameLog.new(board: board, mode: "terminal", directory: directory)
      logger.finish(reason: "stopped", score: board.score)

      trace = GameTrace.read(logger.path)
      replayed_board = GameTrace.replay(trace)

      assert_nil trace.seed
      assert_equal board.cells, replayed_board.cells
      assert_equal board.tile_ids, replayed_board.tile_ids
      assert_equal board.options, replayed_board.options
      assert_equal board.score, replayed_board.score
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

  def test_command_line_options_accept_a_learned_model_path
    Tempfile.create(["learned", ".json"]) do |model|
      options = GameWindow.options_from(["auto", "learned", "--model", model.path, "--seed", "42"])

      assert_equal true, options.fetch(:auto)
      assert_equal "learned", options.fetch(:strategy)
      assert_equal model.path, options.fetch(:model)
      assert_equal 42, options.fetch(:seed)
    end
  end

  def test_learned_mode_without_a_model_reports_the_selected_model_location
    error = assert_raises(ArgumentError) { GameWindow.options_from(["auto", "learned"]) }
    assert_match "selected model", error.message
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

  def test_update_returns_without_touching_gosu_after_window_close
    window = GameWindow.allocate
    window.instance_variable_set(:@closing, true)

    assert_nil window.update
  end

  def test_save_keys_preserve_player_save_in_auto_and_playback_modes
    [{auto: true, playback: false, label: "auto mode", message: "Saving is off in auto mode"},
     {auto: false, playback: true, label: "playback", message: "Saving is off during playback"}].each do |mode|
      [Gosu::KB_S, Gosu::KB_Q, Gosu::KB_ESCAPE].each do |key|
        Dir.mktmpdir do |directory|
          Dir.chdir(directory) do
            original = "player save bytes\n"
            File.write(Board1010::SAVE_FILE, original)
            window = save_test_window(auto: mode.fetch(:auto), playback: mode.fetch(:playback))

            window.button_down(key)

            assert_equal original, File.binread(Board1010::SAVE_FILE), "#{mode.fetch(:label)} key #{key}"
            if key == Gosu::KB_S
              assert_equal mode.fetch(:message), window.instance_variable_get(:@test_message)
            else
              assert window.instance_variable_get(:@test_closed), "#{mode.fetch(:label)} key #{key} should close"
            end
          end
        end
      end
    end
  end

  def test_save_keys_keep_human_mode_behavior
    [Gosu::KB_S, Gosu::KB_Q, Gosu::KB_ESCAPE].each do |key|
      Dir.mktmpdir do |directory|
        Dir.chdir(directory) do
          File.write(Board1010::SAVE_FILE, "player save bytes\n")
          window = save_test_window(auto: false, playback: false)

          window.button_down(key)

          if key == Gosu::KB_ESCAPE
            refute File.exist?(Board1010::SAVE_FILE)
          else
            assert_equal window.instance_variable_get(:@board).to_save,
                         File.read(Board1010::SAVE_FILE)
            assert_equal "Game saved", window.instance_variable_get(:@test_message)
            assert_equal(key == Gosu::KB_Q, window.instance_variable_get(:@test_closed) || false)
          end
        end
      end
    end
  end

  def test_auto_run_window_helpers_use_one_injected_clock
    now = 1_000.0
    window = GameWindow.allocate
    window.instance_variable_set(:@auto_run_tracker, AutoRunTracker.new(clock: -> { now }))
    window.define_singleton_method(:print_auto_run) {|line| line }

    window.send(:start_auto_run)
    now += 12_400
    line = window.send(:finish_auto_run, score: 78)

    assert_equal "Run 1   score 78   time 12.4s  new max", line
    assert_match "Total time: 12.4s", window.instance_variable_get(:@auto_run_tracker).summary
  end

  def test_invalid_game_command_line_has_plain_error_without_backtrace
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "game_1010.rb", "--seed")

    refute status.success?
    assert_match "--seed requires an integer", stderr
    assert_match "Usage:", stderr
    refute_match(/game_1010\.rb:\d+:in/, stderr)
  end

  def test_invalid_benchmark_arguments_have_plain_error_without_backtrace
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "scripts/benchmark.rb")

    refute status.success?
    assert_match "Benchmark failed:", stderr
    assert_match "Usage:", stderr
    refute_match(/scripts\/benchmark\.rb:\d+:in/, stderr)
  end

  def test_each_tile_value_has_a_distinct_non_black_non_white_color
    window = GameWindow.allocate
    colors = GameWindow::TILE_COLORS.values

    assert_equal Board1010::TILES.size, colors.map(&:to_i).uniq.size
    refute_includes colors.map(&:to_i), Gosu::Color::BLACK.to_i
    refute_includes colors.map(&:to_i), Gosu::Color::WHITE.to_i
    Board1010::TILES.each do |name, tile|
      tile_id = tile.id
      value = tile.rows.flatten.find {|cell| cell != Board1010::EMPTY }
      assert_equal GameWindow::TILE_COLORS.fetch(tile_id), window.cell_color(value, tile_id), name.to_s
    end
  end

  private

  def save_test_window(auto:, playback:)
    window = GameWindow.allocate
    window.instance_variable_set(:@auto, auto)
    window.instance_variable_set(:@playback, playback ? [[:move]] : nil)
    window.instance_variable_set(:@board, Board1010.new(options: [Board1010::TILES[:dot]]))
    window.define_singleton_method(:close) { @test_closed = true }
    window.define_singleton_method(:show_message) {|message| @test_message = message }
    window
  end
end
