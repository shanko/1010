# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/game_1010"

class GameWindowTest < Minitest::Test
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

  def test_player_keys_and_option_keys_map_to_expected_actions
    assert_equal :auto_move, GameWindow::PLAYER_ACTIONS.fetch(Gosu::KB_E)
    assert_equal :undo, GameWindow::PLAYER_ACTIONS.fetch(Gosu::KB_U)
    assert_equal :start_drag, GameWindow::PLAYER_ACTIONS.fetch(Gosu::MS_LEFT)
    assert_equal({Gosu::KB_1 => 0, Gosu::KB_2 => 1, Gosu::KB_3 => 2}, GameWindow::OPTION_KEYS)
  end
end
