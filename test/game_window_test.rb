# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "gui_support"
require_relative "../scripts/game_1010" unless GuiSupport.excluded?

class GameWindowTest < Minitest::Test
  def setup
    skip GuiSupport::SKIP_MESSAGE if GuiSupport.excluded?
  end

  def test_global_input_keys_map_only_to_session_commands
    actions = GameWindow::KEY_ACTIONS

    assert_equal :quit_without_saving, actions.fetch(Gosu::KB_ESCAPE)
    assert_equal :save_and_quit, actions.fetch(Gosu::KB_Q)
    assert_equal :toggle_auto, actions.fetch(Gosu::KB_A)
    assert_equal :new_game, actions.fetch(Gosu::KB_N)
    assert_equal :save_game, actions.fetch(Gosu::KB_S)
    assert_equal :toggle_recording, actions.fetch(Gosu::KB_R)
    assert_equal :start_playback, actions.fetch(Gosu::KB_P)
  end

  def test_window_accepts_every_auto_mode_option
    parameters = GameWindow.instance_method(:initialize).parameters

    assert_includes parameters, %i[key games]
  end

  def test_player_keys_and_option_keys_map_to_expected_actions
    assert_equal :auto_move, GameWindow::PLAYER_ACTIONS.fetch(Gosu::KB_E)
    assert_equal :undo, GameWindow::PLAYER_ACTIONS.fetch(Gosu::KB_U)
    assert_equal :start_drag, GameWindow::PLAYER_ACTIONS.fetch(Gosu::MS_LEFT)
    assert_equal({Gosu::KB_1 => 0, Gosu::KB_2 => 1, Gosu::KB_3 => 2}, GameWindow::OPTION_KEYS)
  end

  # Exercise input and drawing without constructing a native window.
  def test_auto_move_invalidates_drag_even_when_the_index_still_exists
    Dir.mktmpdir do |directory|
      session = GameSession.new(strategy: :first_fit, log_directory: directory,
                                save_store: GameSession::SaveStore.new(path: File.join(directory, "save")))
      window = GameWindow.allocate
      window.instance_variable_set(:@session, session)
      [0, 2].each do |selected|
        session.start(Board1010.new(options: %i[dot dot dot]))
        window.instance_variable_set(:@selected, selected)
        window.instance_variable_set(:@dragging, true)
        window.button_down(Gosu::KB_E)

        assert_equal 2, session.board.options.size
        assert_nil window.instance_variable_get(:@selected)
        refute window.instance_variable_get(:@dragging)
        assert_nil window.draw_dragged_tile
      end
    ensure
      session&.finish
    end
  end

  def test_drag_drawing_discards_a_missing_option
    window = GameWindow.allocate
    board = Board1010.new(options: [:dot])
    window.instance_variable_set(:@session, Struct.new(:board).new(board))
    window.instance_variable_set(:@selected, 2)
    window.instance_variable_set(:@dragging, true)
    window.draw_dragged_tile

    assert_nil window.instance_variable_get(:@selected)
    refute window.instance_variable_get(:@dragging)
  end
end
