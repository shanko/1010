# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/game_session"
require_relative "../lib/headless_game"

class SeededSaveTest < Minitest::Test
  def with_saved_session(**options)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "player-save.txt")
      bytes = Board1010.new(options: [Tile.fetch(:dot)]).to_save
      File.write(path, bytes)
      session = GameSession.new(strategy: :sam, clock: -> { 0 }, log_directory: directory,
                                save_store: GameSession::SaveStore.new(path: path), **options)
      yield session, directory, path, bytes
    ensure
      session&.finish
    end
  end

  def completed_game(session)
    session.auto_move until session.game_over
    session.finish
    trace = GameTrace.read(session.game_log.path)
    [trace.seed, trace.final_score, session.move_count, trace.events]
  end

  def test_explicitly_seeded_auto_ignores_save_and_repeats_the_first_game
    with_saved_session(auto: true, seed: 42) do |actual, directory, path, bytes|
      expected = GameSession.new(auto: true, strategy: :sam, seed: 42, clock: -> { 0 },
                                 log_directory: directory,
                                 save_store: GameSession::SaveStore.new(path: File.join(directory, "absent")))
      assert_nil actual.initial_message
      refute_nil actual.seed
      assert_equal completed_game(expected), completed_game(actual)
      assert_equal bytes, File.read(path)
    ensure
      expected&.finish
    end
  end

  def test_human_and_unseeded_auto_modes_continue_the_save
    [{auto: false}, {auto: false, seed: 42}, {auto: true}].each do |options|
      with_saved_session(**options) do |session, _directory, path, bytes|
        assert_equal :loaded, session.initial_message
        assert_nil session.seed
        assert_equal [Tile.fetch(:dot)], session.board.options
        assert_equal bytes, File.read(path)
      end
    end
  end

  def test_switching_human_play_to_auto_preserves_the_loaded_board
    with_saved_session(seed: 42) do |session, _directory, path, bytes|
      board = session.board
      assert session.toggle_auto
      assert_same board, session.board
      assert_equal :loaded, session.initial_message
      assert_equal bytes, File.read(path)
    end
  end

  def test_headless_store_ignores_saves_with_or_without_a_seed
    [nil, 42].each do |seed|
      with_saved_session(auto: true, seed: seed) do |_session, directory, path, bytes|
        headless = GameSession.new(auto: true, strategy: :sam, seed: seed, clock: -> { 0 },
                                   log_directory: directory, save_store: HeadlessGame::NoSaveStore.new)
        assert_nil headless.initial_message
        refute_nil headless.seed
        assert_equal bytes, File.read(path)
        headless.finish
      end
    end
  end
end
