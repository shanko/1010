# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/game_simulator"
require_relative "../lib/lesson_analyzer"

class VisibleBatchPlannerTest < Minitest::Test
  def test_snapshot_is_immutable_and_does_not_retain_a_board_or_dealer
    board = Board1010.new(options: [Tile.fetch(:dot)])
    position = VisiblePosition.from_board(board)
    board.cells[0][0] = 1
    board.options.clear

    assert_equal 0, position.occupied_bits
    assert_equal [Tile.fetch(:dot)], position.options
    assert position.frozen?
    assert position.options.frozen?
    %i[random seed copy generate_options].each {|method| refute_respond_to position, method }
    assert_raises(ArgumentError) { VisibleBatchPlanner.new.search(board) }
    assert_raises(ArgumentError) do
      VisiblePosition.new(occupied_bits: 0, options: [Tile.fetch(:dot)] * 4, score: 0)
    end
  end

  def test_live_adapter_never_reads_or_copies_hidden_state
    board = Board1010.new(options: [Tile.fetch(:hl5), Tile.fetch(:sq2), Tile.fetch(:dot)])
    %i[random seed copy generate_options play].each do |method|
      board.define_singleton_method(method) { raise "planner accessed #{method}" }
    end
    before = [board.occupied_bits, board.options.dup, board.score]
    move = AutoPlayer.new(:visible_batch).choose_move(board)

    assert board.fits?(board.options.fetch(move.first), *move.drop(1))
    assert_equal before, [board.occupied_bits, board.options, board.score]
  end

  def test_hidden_rng_and_player_rng_do_not_affect_the_decision_or_work
    boards = [1, 99].map do |seed|
      Board1010.new(options: [Tile.fetch(:hl3), Tile.fetch(:vl3), Tile.fetch(:sq2)], random: Random.new(seed))
    end
    results = boards.map {|board| VisibleBatchPlanner.new.search(VisiblePosition.from_board(board)) }
    assert_equal results.first.to_h, results.last.to_h
    assert_equal AutoPlayer.new(:visible_batch, random: Random.new(1)).choose_move(boards.first),
                 AutoPlayer.new(:visible_batch, random: Random.new(99)).choose_move(boards.last)
  end

  def test_batch_completion_stops_without_dealing_or_claiming_a_game_over
    board = Board1010.new(options: [Tile.fetch(:dot)])
    board.define_singleton_method(:generate_options) { raise "future tiles were requested" }
    position = VisiblePosition.from_board(board)
    result = VisibleBatchPlanner.new.search(position)
    leaf = position.after_move(*result.move)

    assert result.completed_batch
    assert leaf.batch_complete?
    assert_equal :visible_batch, result.information_mode
    assert_equal 1, leaf.score
    assert_equal [Tile.fetch(:dot)], board.options
  end

  def test_an_already_empty_batch_is_complete_and_has_no_move
    position = VisiblePosition.from_board(Board1010.new)
    result = VisibleBatchPlanner.new.search(position)

    assert result.completed_batch
    assert_nil result.move
    assert_equal 0, result.explored_states
  end

  def test_visible_transition_matches_simultaneous_row_and_column_clearing
    board = Board1010.new(options: [Tile.fetch(:dot), Tile.fetch(:sq2)])
    10.times do |index|
      board.cells[0][index] = 1 unless index.zero?
      board.cells[index][0] = 1 unless index.zero?
    end
    next_position = VisiblePosition.from_board(board).after_move(0, 0, 0)
    board.play(0, 0, 0, deal: false)

    assert_equal board.occupied_bits, next_position.occupied_bits
    assert_equal board.score, next_position.score
    assert_equal board.options, next_position.options
    assert_equal 0, next_position.occupied_bits
    assert_raises(ArgumentError) { next_position.after_move(0, -1, 0) }
  end

  def test_joint_planning_can_use_a_clear_to_make_the_other_visible_tile_fit
    cells = Array.new(10) { Array.new(10, 1) }
    10.times {|index| cells[index][index] = 0 }
    board = Board1010.new(cells: cells, options: [Tile.fetch(:sq2), Tile.fetch(:dot)])
    result = VisibleBatchPlanner.new.search(VisiblePosition.from_board(board))

    assert_equal 1, result.move.first
    assert result.completed_batch
  end

  def test_dead_end_and_work_cap_return_only_legal_current_moves
    full = Board1010.new(cells: Array.new(10) { Array.new(10, 1) }, options: [Tile.fetch(:sq3)])
    assert_nil VisibleBatchPlanner.new.choose_move(VisiblePosition.from_board(full))
    board = Board1010.new(options: [Tile.fetch(:dot), Tile.fetch(:sq2), Tile.fetch(:hl5)])
    result = VisibleBatchPlanner.new(max_states: 1).search(VisiblePosition.from_board(board))

    assert_equal 1, result.explored_states
    assert_equal "states", result.cap_reason
    refute result.completed_batch
    assert board.fits?(board.options.fetch(result.move.first), *result.move.drop(1))
    assert_raises(ArgumentError) { VisibleBatchPlanner.new(max_states: 0) }
  end

  def test_selected_tile_hint_still_considers_the_current_offer_but_places_that_tile_first
    board = Board1010.new(options: [Tile.fetch(:hl5), Tile.fetch(:sq2)])
    position = AutoPlayer.new(:visible_batch).best_position(board, board.options.last)

    assert board.fits?(board.options.last, *position)
    assert_nil AutoPlayer.new(:visible_batch).best_position(board, Tile.fetch(:dot))
  end

  def test_information_modes_distinguish_live_play_from_future_informed_teachers
    report = GameBenchmark.run(seeds: [1], strategies: [:first_fit])
    lesson = LessonAnalyzer.new.analyze("samples/manual_score_1184.moves", time_budget_seconds: 0)

    assert_equal :visible_batch, report.fetch(:information_mode)
    assert_equal :known_future, lesson.dig(:search, :information_mode)
  end

  def test_visible_strategy_repeats_complete_games_and_replays_to_the_same_final_board
    first = GameSimulator.run(seed: 2, strategy: :visible_batch)
    second = GameSimulator.run(seed: 2, strategy: :visible_batch)
    replayed = GameSimulator.replay(first)

    assert_equal first.moves, second.moves
    assert_equal first.offers, second.offers
    assert_equal first.score, replayed.score
    assert_equal first.final_board.cells, replayed.cells
    assert replayed.game_over?
  end
end
