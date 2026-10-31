# frozen_string_literal: true

require "minitest/autorun"
require_relative "../offer_replay"

class OfferReplayTest < Minitest::Test
  def test_applies_moves_and_feeds_each_recorded_offer_batch
    board = Board1010.new
    replay = OfferReplay.new(board: board, offers: [%w[dot dot], %w[hl2 dot]])

    replay.apply({tile: "dot", option: 0, row: 0, col: 0})
    replay.apply({tile: "dot", option: 0, row: 0, col: 1})

    assert_equal %i[hl2 dot], replay.board.options.map(&:name)
    assert_equal 2, replay.finish!(expected_score: 2).score
  end

  def test_rejects_a_move_that_names_a_different_offered_tile
    replay = OfferReplay.new(board: Board1010.new, offers: [%w[dot]])

    error = assert_raises(ArgumentError) do
      replay.apply({tile: "hl2", option: 0, row: 0, col: 0})
    end
    assert_match "differs", error.message
  end

  def test_rejects_an_illegal_move
    board = Board1010.new(cells: Array.new(10) { Array.new(10, 1) }, options: [Tile.fetch(:dot)])
    replay = OfferReplay.new(board: board, offers: [%w[dot]])

    error = assert_raises(ArgumentError) { replay.apply({tile: "dot", option: 0, row: 0, col: 0}) }
    assert_match "not legal", error.message
  end

  def test_rejects_missing_or_unused_batches_and_a_wrong_final_score
    missing = OfferReplay.new(board: Board1010.new, offers: [%w[dot]])
    assert_raises(ArgumentError) { missing.apply({tile: "dot", option: 0, row: 0, col: 0}) }

    unused = OfferReplay.new(board: Board1010.new, offers: [%w[dot], %w[hl2], %w[dot]])
    unused.apply({tile: "dot", option: 0, row: 0, col: 0})
    assert_raises(ArgumentError) { unused.finish! }

    mismatch = OfferReplay.new(board: Board1010.new, offers: [%w[dot], %w[hl2]])
    mismatch.apply({tile: "dot", option: 0, row: 0, col: 0})
    assert_raises(ArgumentError) { mismatch.finish!(expected_score: 2) }
  end

  def test_undo_restores_the_board_and_the_next_move_takes_the_next_recorded_batch
    replay = OfferReplay.new(board: Board1010.new, offers: [%w[dot], %w[hl2], %w[vl2], %w[dot]])
    replay.apply({tile: "dot", option: 0, row: 0, col: 0})
    replay.undo

    assert_equal 0, replay.board.score
    assert_equal [:dot], replay.board.options.map(&:name)
    replay.apply({tile: "dot", option: 0, row: 0, col: 0})
    assert_equal [:vl2], replay.board.options.map(&:name)
    replay.apply({tile: "vl2", option: 0, row: 1, col: 0})
    assert_equal [:dot], replay.finish!(expected_score: 3).options.map(&:name)
  end

  def test_explicit_deal_events_are_checked_against_the_consumed_batch
    replay = OfferReplay.new(board: Board1010.new, offers: [%w[dot], %w[hl2]])
    replay.apply({tile: "dot", option: 0, row: 0, col: 0})

    assert_same replay.board, replay.feed_deal([Tile.fetch(:hl2)])
    assert_raises(ArgumentError) { replay.feed_deal([Tile.fetch(:dot)]) }
  end
end
