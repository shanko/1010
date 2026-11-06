# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require "tmpdir"
require "open3"
require "rbconfig"
require_relative "../lib/game_session"
require_relative "../lib/game_options"
require_relative "../lib/game_log"
require_relative "../lib/game_trace"
require_relative "gui_support"

class GameReplayTest < Minitest::Test
  def with_moves(text)
    Tempfile.create(["game", ".moves"]) do |file|
      file.write(text)
      file.flush
      yield file.path
    end
  end

  # This test reads as one ordered end-to-end trace setup and assertion sequence.
  # rubocop:disable Metrics/MethodLength
  def test_v2_trace_replays_initial_board_deals_moves_and_undo_exactly
    Dir.mktmpdir do |directory|
      board = Board1010.new(options: [Tile.fetch(:dot), Tile.fetch(:dot)], random: Random.new(51))
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
  # rubocop:enable Metrics/MethodLength

  def test_v2_trace_replays_an_undone_move_that_emptied_its_batch_and_its_new_deal
    Dir.mktmpdir do |directory|
      path, board = record_undo_across_a_deal(directory)
      trace = GameTrace.read(path)
      replayed_board = GameTrace.replay(trace)

      assert_equal 4, trace.deal_batches.size
      assert_equal board.cells, replayed_board.cells
      assert_equal board.options, replayed_board.options
    end
  end

  def test_session_playback_reaches_the_recorded_board_and_logs_a_replayable_trace
    Dir.mktmpdir do |directory|
      path, board = record_undo_across_a_deal(directory)
      session = GameSession.new(replay_delay: 0, log_directory: directory,
                                save_store: save_store(directory), clock: -> { 0 })
      session.start_trace_playback(GameTrace.read(path), mode: "replay")
      playback_log = session.game_log.path
      session.playback_tick(0) while session.playback

      assert_equal board.cells, session.board.cells
      assert_equal board.options, session.board.options
      assert_nil session.offer_replay
      assert_equal board.cells, GameTrace.replay(GameTrace.read(playback_log)).cells
    end
  end

  def test_session_replay_delay_applies_after_moves_and_undos
    Dir.mktmpdir do |directory|
      session = GameSession.new(replay_delay: 1.25, log_directory: directory,
                                save_store: save_store(directory), clock: -> { 0 })
      session.start_trace_playback(replay_trace, mode: "test")

      session.playback_tick(1_000)
      assert_equal 2_250, session.playback_next_at
      session.playback_tick(2_249)
      assert_equal 3, session.playback.size
      session.playback_tick(2_250)
      assert_equal 3_500, session.playback_next_at
      assert_equal 0, session.board.score
      session.playback_tick(3_500)
      assert_equal 4_750, session.playback_next_at
      assert_equal 1, session.board.score
      assert_equal :finished, session.playback_tick(4_750)
      assert_nil session.playback
    end
  end

  # Follow the transition through both immutable replay and live continuation logs.
  def test_live_moves_and_undo_after_playback_create_a_replayable_continuation
    Dir.mktmpdir do |directory|
      session = GameSession.new(strategy: :first_fit, replay_delay: 0, log_directory: directory,
                                save_store: save_store(directory), clock: -> { 0 })
      session.start_trace_playback(replay_trace, mode: "replay")
      replay_path = session.game_log.path
      session.playback_tick(0) while session.playback
      recorded = File.binread(replay_path)
      snapshot = session.board.to_save

      assert session.auto_move
      assert session.undo
      assert_equal snapshot, session.board.to_save
      assert session.auto_move
      session.finish

      continuation = GameTrace.read(session.game_log.path)
      assert_nil continuation.seed
      assert_equal "continuation", continuation.mode
      assert_equal snapshot, continuation.starting_board.to_save
      assert_equal session.board.to_save, GameTrace.replay(continuation).to_save
      assert_equal recorded, File.binread(replay_path)
    end
  end

  def test_undo_immediately_after_playback_starts_from_the_restored_snapshot
    Dir.mktmpdir do |directory|
      session = GameSession.new(strategy: :first_fit, replay_delay: 0, log_directory: directory,
                                save_store: save_store(directory), clock: -> { 0 })
      session.start_trace_playback(replay_trace, mode: "replay")
      session.playback_tick(0) while session.playback
      replay_path = session.game_log.path
      recorded = File.binread(replay_path)

      assert session.undo
      assert_equal 0, session.board.score
      refute session.undo
      assert session.auto_move
      session.finish

      trace = GameTrace.read(session.game_log.path)
      assert_equal 0, trace.starting_board.score
      assert_nil trace.seed
      assert_equal session.board.to_save, GameTrace.replay(trace).to_save
      assert_equal recorded, File.binread(replay_path)
    end
  end

  def test_v3_trace_rejects_incomplete_files
    with_moves("1010-moves-v3\ns1\nmode=test\ni0|#{'0' * 100}|#{'0' * 100}\nd1\n") do |path|
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
      board = Board1010.new(cells: cells, tile_ids: tile_ids, options: [Tile.fetch(:dot)], score: 17)
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

  def test_rejects_an_unversioned_old_format_moves_file
    with_moves("s12345\nm012\nm290\nu\n") do |path|
      error = assert_raises(ArgumentError) { GameTrace.read(path) }
      assert_match "not a v2, v3 or v4 1010 trace", error.message
    end
  end

  def test_reads_a_v2_trace_with_named_tile_offers
    with_moves("1010-moves-v2\ns1\nmode=test\ni0|#{'0' * 100}|#{'0' * 100}\nddot\nzstopped|0\n") do |path|
      trace = GameTrace.read(path)

      assert_equal [:dot], trace.starting_board.options.map(&:name)
      assert_equal ["dot"], trace.deal_batches.first
    end
  end

  def test_command_line_options_recognize_replay_file_alongside_auto_seed_and_delay
    options = GameOptions.parse(["auto", "sam", "--seed", "7", "--delay", "1.25", "logs/game.moves"])

    assert_equal({auto: true, strategy: "sam", seed: 7, replay_delay: 1.25, replay_file: "logs/game.moves"}, options)
  end

  def test_command_line_options_leave_non_moves_arguments_alone
    assert_equal({auto: true, strategy: "sam"}, GameOptions.parse(%w[auto sam]))
  end

  def test_command_line_options_accept_a_learned_model_path
    Tempfile.create(["learned", ".json"]) do |model|
      options = GameOptions.parse(["auto", "learned", "--model", model.path, "--seed", "42"])

      assert_equal true, options.fetch(:auto)
      assert_equal "learned", options.fetch(:strategy)
      assert_equal model.path, options.fetch(:model)
      assert_equal 42, options.fetch(:seed)
    end
  end

  def test_default_and_explicit_learned_use_the_bundled_model_outside_the_repository
    Dir.mktmpdir do |directory|
      Dir.chdir(directory) do
        [[], %w[auto], %w[auto learned]].each do |args|
          assert_equal AutoPlayer::DEFAULT_MODEL_PATH, GameOptions.parse(args).fetch(:model)
        end
      end
    end
  end

  def test_missing_explicit_model_is_rejected_instead_of_using_the_bundled_model
    Dir.mktmpdir do |directory|
      path = File.join(directory, "missing.json")
      error = assert_raises(ArgumentError) { GameOptions.parse(["auto", "--model", path]) }
      assert_includes error.message, path
    end
  end

  def test_command_line_delay_defaults_to_half_a_second
    assert_equal 0.5, GameSession::DEFAULT_REPLAY_DELAY_SECONDS
  end

  def test_rejects_invalid_or_negative_delay_values
    ["abc", "-0.1", "Infinity"].each do |value|
      error = assert_raises(ArgumentError) { GameOptions.parse(["--delay", value, "logs/game.moves"]) }
      assert_match "delay", error.message
    end
  end

  def test_rejects_delay_without_a_value
    error = assert_raises(ArgumentError) { GameOptions.parse(["--delay"]) }
    assert_match "requires seconds", error.message
  end

  def test_empty_color_accepts_mint_cream_and_grey_and_rejects_others
    assert_equal :mint, GameOptions.parse(["--empty-color", "mint"]).fetch(:empty_color)
    assert_equal :cream, GameOptions.parse(["--empty-color", "cream"]).fetch(:empty_color)
    assert_equal :grey, GameOptions.parse(["--empty-color", "gray"]).fetch(:empty_color)
    refute GameOptions.parse([]).key?(:empty_color)

    ["rose", nil].each do |value|
      error = assert_raises(ArgumentError) { GameOptions.parse(["--empty-color", value].compact) }
      assert_match "empty-color", error.message
    end
  end

  def test_invalid_game_command_line_has_plain_error_without_backtrace
    skip GuiSupport::SKIP_MESSAGE if GuiSupport.excluded?

    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "scripts/game_1010.rb", "--seed")

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
    refute_match(%r{scripts/benchmark\.rb:\d+:in}, stderr)
  end

  private

  def record_undo_across_a_deal(directory)
    board = Board1010.new(options: [Tile.fetch(:dot)], random: Random.new(9))
    logger = GameLog.new(seed: nil, board: board, mode: "test", directory: directory)
    play_first_fit = lambda do
      previous = board.copy
      tile = board.options.first
      row, col = board.find_position(tile)
      board.play(0, row, col)
      logger.move(tile.name, 0, row, col)
      logger.deal(board.options) if previous.options.size == 1
      previous
    end

    board = play_first_fit.call
    logger.undo
    4.times { play_first_fit.call }
    logger.finish(reason: "stopped", score: board.score)
    [logger.path, board]
  end

  def replay_trace
    board = Board1010.new(options: [Tile.fetch(:dot), Tile.fetch(:hl2)])
    GameTrace::Trace.new(seed: nil, mode: "test", starting_board: board,
                         deal_batches: [%w[dot hl2]],
                         events: [[:move, :hl2, 1, 2, 3], [:undo], [:move, :dot, 0, 4, 5], [:end, "stopped", 1]])
  end

  def save_store(directory)
    GameSession::SaveStore.new(path: File.join(directory, "player-save.txt"))
  end
end
