# frozen_string_literal: true

require "minitest/autorun"
require_relative "../improvement_search"

class ImprovementSearchTest < Minitest::Test
  def test_fixed_offer_search_matches_a_brute_force_oracle_and_preserves_source
    board = handcrafted_board
    before = [Marshal.dump(board.cells), Marshal.dump(board.options), Marshal.dump(board.random), board.score]
    baseline = [{tile: :dot, option: 0, row: 4, col: 4}]

    result = ImprovementSearch.search(starting_board: board, baseline_score: 1,
                                      baseline_sequence: baseline,
                                      fixed_offers: [[:dot, :sq2]],
                                      time_budget_seconds: 2.0, beam_width: 64,
                                      max_states: 5_000, rollout_strategy: :first_fit)

    assert_equal brute_force_score(board), result.best_score
    assert_equal 4, result.score_delta
    assert_equal "improved", result.status
    refute result.complete # the frozen offer sequence ends before actual Game Over
    assert_equal before, [Marshal.dump(board.cells), Marshal.dump(board.options), Marshal.dump(board.random), board.score]
    assert_equal result.best_score, replay_fixed(board, result.candidate_sequence, [[:dot, :sq2]])
  end

  def test_zero_budget_returns_baseline_as_best_so_far
    board = handcrafted_board
    baseline = [{tile: :dot, option: 0, row: 4, col: 4}]

    result = ImprovementSearch.search(starting_board: board, baseline_score: 1,
                                      baseline_sequence: baseline,
                                      fixed_offers: [[:dot, :sq2]],
                                      time_budget_seconds: 0, max_states: 10)

    assert_equal 1, result.best_score
    assert_equal baseline, result.candidate_sequence
    assert_equal "budget exhausted", result.status
    assert_equal 0, result.explored_states
  end

  def test_seeded_mode_returns_a_replayable_baseline_when_budget_is_zero
    result = ImprovementSearch.search(seed: 29, strategy: :jc,
                                      time_budget_seconds: 0, max_states: 10)
    baseline = GameSimulator.run(seed: 29, strategy: :jc)
    replayed = replay_seeded(29, result.candidate_sequence, baseline.offers)

    assert_equal baseline.score, result.best_score
    assert_equal baseline.score, replayed.score
    assert_equal "budget exhausted", result.status
  end

  def test_validates_bounds_and_start_state_requirements
    assert_raises(ArgumentError) { ImprovementSearch.search(seed: 1, time_budget_seconds: -1) }
    assert_raises(ArgumentError) { ImprovementSearch.search(starting_board: handcrafted_board) }
    assert_raises(ArgumentError) { ImprovementSearch.search(seed: 1, max_states: 0) }
  end

  private

  def handcrafted_board
    cells = Array.new(10) { Array.new(10, 9) }
    [[4, 4], [4, 5], [5, 4], [5, 5], [4, 0], [4, 9], [5, 0], [5, 9],
     [0, 4], [0, 5], [9, 4], [9, 5]].each {|row, col| cells[row][col] = Board1010::EMPTY }
    Board1010.new(cells: cells, options: [Board1010::TILES[:dot], Board1010::TILES[:sq2]], random: Random.new(7))
  end

  def brute_force_score(board)
    return board.score if board.options.empty? || board.game_over?

    actions = board.options.flat_map do |tile|
      board.positions_for(tile).map {|row, col| [tile.name, row, col] }
    end
    return board.score if actions.empty?

    actions.map do |name, row, col|
      child = board.copy
      option = child.options.index(Tile.fetch(name))
      child.play(option, row, col, deal: false)
      brute_force_score(child)
    end.max
  end

  def replay_fixed(board, sequence, offers)
    copy = board.copy
    offer_index = 1
    sequence.each do |move|
      exhausted = copy.options.size == 1
      assert copy.play(move.fetch(:option), move.fetch(:row), move.fetch(:col), deal: false), "illegal candidate move: #{move}"
      if exhausted && (batch = offers[offer_index])
        copy.replace_options(batch.map {|name| Tile.fetch(name) })
        offer_index += 1
      end
    end
    copy.score
  end

  def replay_seeded(seed, sequence, offers)
    board = GameSimulator.initial_board(seed: seed)
    offer_index = 1
    sequence.each do |move|
      exhausted = board.options.size == 1
      assert board.play(move.fetch(:option), move.fetch(:row), move.fetch(:col), deal: false), "illegal candidate move: #{move}"
      if exhausted
        batch = offers.fetch(offer_index)
        board.replace_options(batch.map {|name| Tile.fetch(name) })
        offer_index += 1
      end
    end
    board
  end
end
