# frozen_string_literal: true

require "minitest/autorun"
require_relative "../game_simulator"

class GameSimulatorTest < Minitest::Test
  def test_same_seed_and_strategy_produce_identical_complete_episodes
    first = GameSimulator.run(seed: 42, strategy: :jc)
    second = GameSimulator.run(seed: 42, strategy: :jc)

    assert_equal first.summary, second.summary
    assert_equal first.moves, second.moves
    assert_equal first.offers, second.offers
    assert first.final_board.game_over?
  end

  def test_episode_score_equals_sum_of_placed_tile_areas
    result = GameSimulator.run(seed: 17, strategy: :sam)
    area = result.moves.sum {|move| Tile.fetch(move[:tile]).area }

    assert_equal area, result.score
    assert_equal result.moves.size, result.placed_tiles
    assert_equal result.offers.size, result.option_batches
    assert_operator result.cleared_lines, :>=, 0
  end

  def test_captured_auto_episode_replays_to_the_same_board_and_score
    result = GameSimulator.run(seed: 33, strategy: :jc)

    replayed_board = GameSimulator.replay(result)

    assert_equal result.final_board.cells, replayed_board.cells
    assert_equal result.final_board.options, replayed_board.options
    assert_equal result.score, replayed_board.score
    assert replayed_board.game_over?
  end

  def test_all_existing_strategies_can_run_headlessly
    AutoPlayer::STRATEGIES.each do |strategy|
      result = GameSimulator.run(seed: 3, strategy: strategy)
      assert result.final_board.game_over?, strategy.to_s
    end
  end

  def test_rejects_unknown_strategy
    assert_raises(ArgumentError) { GameSimulator.run(seed: 1, strategy: :unknown) }
  end
end
