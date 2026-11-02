# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require "open3"
require "rbconfig"
require_relative "../lib/game_session"

class GameSessionTest < Minitest::Test
  def with_session(**options)
    Dir.mktmpdir do |directory|
      options[:log_directory] ||= directory
      options[:save_store] ||= GameSession::SaveStore.new(path: File.join(directory, "player-save.txt"))
      options[:clock] ||= -> { 0 }
      session = GameSession.new(**options)
      yield session, directory
    ensure
      session&.finish
    end
  end

  def test_game_session_loads_without_gosu
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I.", "-e",
      'require "./lib/game_session"; abort "Gosu loaded" if defined?(Gosu)'
    )

    assert status.success?, [stdout, stderr].join
  end

  def test_place_and_undo_update_session_board_and_score
    with_session do |session, _directory|
      board = Board1010.new(options: [Tile.fetch(:dot), Tile.fetch(:hl2)])
      session.start(board)

      move = session.place(0, 0, 0)

      assert_instance_of Board1010::Move, move
      assert_equal 1, session.board.score
      assert session.undo
      assert_equal 0, session.board.score
      refute session.undo
    end
  end

  def test_illegal_placement_does_not_change_board_or_create_undo_state
    with_session do |session, _directory|
      board = Board1010.new(options: [Tile.fetch(:dot)])
      board.cells[0][0] = 1
      session.start(board)

      assert_nil session.place(0, 0, 0)
      assert_equal 0, session.board.score
      refute session.undo
    end
  end

  def test_human_save_load_and_delete_use_the_injected_store
    Dir.mktmpdir do |directory|
      save_path = File.join(directory, "player-save.txt")
      store = GameSession::SaveStore.new(path: save_path)
      session = GameSession.new(log_directory: directory, save_store: store, clock: -> { 0 })
      session.start(Board1010.new(options: [Tile.fetch(:dot)]))

      assert_equal :saved, session.save_game
      assert_equal session.board.to_save, File.read(save_path)
      assert_equal :deleted, session.delete_save
      refute File.exist?(save_path)
      session.finish
    end
  end

  def test_auto_and_playback_modes_cannot_overwrite_or_delete_player_save
    Dir.mktmpdir do |directory|
      save_path = File.join(directory, "player-save.txt")
      File.write(save_path, "player save bytes\n")
      store = GameSession::SaveStore.new(path: save_path)
      auto = GameSession.new(auto: true, log_directory: directory, save_store: store, clock: -> { 0 })
      assert_equal :disabled_auto, auto.save_game
      assert_equal :disabled, auto.delete_save
      auto.finish

      playback = GameSession.new(log_directory: directory, save_store: store, clock: -> { 0 })
      playback.start_trace_playback(replay_trace, mode: "test")
      assert_equal :disabled_playback, playback.save_game
      assert_equal :disabled, playback.delete_save
      playback.finish
      assert_equal "player save bytes\n", File.read(save_path)
    end
  end

  def test_loading_a_valid_or_damaged_save_reports_the_result
    Dir.mktmpdir do |directory|
      save_path = File.join(directory, "player-save.txt")
      store = GameSession::SaveStore.new(path: save_path)
      File.write(save_path, Board1010.new(options: [Tile.fetch(:dot)]).to_save)
      loaded = GameSession.new(log_directory: directory, save_store: store, clock: -> { 0 })
      assert_equal :loaded, loaded.initial_message
      assert_equal [Tile.fetch(:dot)], loaded.board.options
      loaded.finish

      File.write(save_path, "damaged")
      damaged = GameSession.new(log_directory: directory, save_store: store, clock: -> { 0 })
      assert_equal :damaged, damaged.initial_message
      assert_instance_of Board1010, damaged.board
      damaged.finish
    end
  end

  def test_auto_run_timing_uses_the_injected_clock
    now = 1_000.0
    with_session(auto: true, clock: -> { now }) do |session, _directory|
      now += 12_400
      line = session.finish_auto_run(score: 78)

      assert_equal "Run 1   score 78   time 12.4s  new max", line
      assert_match "Total time: 12.4s", session.auto_run_tracker.summary
    end
  end

  def test_quit_command_applies_the_requested_save_policy_and_finishes
    Dir.mktmpdir do |directory|
      save_path = File.join(directory, "player-save.txt")
      store = GameSession::SaveStore.new(path: save_path)
      session = GameSession.new(log_directory: directory, save_store: store, clock: -> { 0 })

      assert_equal :saved, session.quit(save: true)
      assert File.file?(save_path)
      assert_match "Score =", session.finish
    end
  end

  def test_auto_toggle_and_tick_use_session_state
    with_session do |session, _directory|
      assert session.toggle_auto
      move = session.tick(now: 1_000)
      assert_instance_of Board1010::Move, move
      refute_nil session.previous_board
      refute session.toggle_auto
    end
  end

  def test_auto_stops_after_the_requested_games_and_leaves_the_last_board
    with_session(auto: true, strategy: :sam, seed: 42, games: 2) do |session, directory|
      now = play_until_finished(session)

      assert session.game_over
      assert_equal 2, session.auto_run_tracker.completed_count
      board = session.board
      assert_nil session.tick(now: now + 10_000_000)
      assert_same board, session.board
      assert_equal 2, Dir[File.join(directory, "*.moves")].size
    end
  end

  def test_auto_without_a_game_count_keeps_restarting
    with_session(auto: true, strategy: :sam, seed: 42) do |session, _directory|
      session.auto_move until session.game_over
      refute session.auto_games_finished?
      assert_equal :restarted, session.tick(now: 10_000_000)
    end
  end

  def test_abandoned_games_do_not_count_and_a_new_game_still_plays_after_the_limit
    with_session(auto: true, strategy: :sam, seed: 42, games: 1) do |session, _directory|
      session.auto_move
      session.new_game
      assert_equal 0, session.auto_run_tracker.completed_count
      refute session.auto_games_finished?

      play_until_finished(session)
      assert session.auto_games_finished?
      session.new_game
      refute session.game_over
      assert_instance_of Board1010::Move, session.tick(now: 0)
    end
  end

  private

  # The injected clock stays at 0, so `now` is what passes the restart pause.
  def play_until_finished(session)
    now = 0
    until session.auto_games_finished?
      session.tick(now: now)
      now += GameSession::AUTO_RESTART_MS
    end
    now
  end

  def replay_trace
    board = Board1010.new(options: [Tile.fetch(:dot), Tile.fetch(:hl2)])
    GameTrace::Trace.new(seed: nil, mode: "test", starting_board: board,
                         deal_batches: [%w[dot hl2]],
                         events: [[:move, :hl2, 1, 2, 3], [:undo], [:move, :dot, 0, 4, 5], [:end, "stopped", 1]])
  end
end
