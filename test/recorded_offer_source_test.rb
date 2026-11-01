# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/recorded_offer_source"
require_relative "../lib/game_simulator"

class RecordedOfferSourceTest < Minitest::Test
  def test_recorded_batches_handoff_to_the_seeded_dealer_at_the_matching_rng_position
    seed = 77
    board = GameSimulator.initial_board(seed: seed)
    initial = board.options.map(&:name)
    recorded = [initial, %i[dot hl2 vl2]]
    source = RecordedOfferSource.new(recorded_offers: recorded, continue_with_seeded_dealer: true)

    recorded_batch = source.next_batch(board, 1)
    seeded_batch = source.next_batch(board, 2)
    expected = GameSimulator.initial_board(seed: seed)
    expected.generate_options
    expected_batch = expected.generate_options.map(&:name)

    assert_equal :recorded, recorded_batch.origin
    assert_equal recorded.fetch(1), recorded_batch.names
    assert_equal :seeded, seeded_batch.origin
    assert_equal expected_batch, seeded_batch.names
  end

  def test_source_without_a_seed_stops_after_the_recorded_batches
    board = Board1010.new(options: %i[dot hl2 vl2])
    source = RecordedOfferSource.new(recorded_offers:             [%i[dot hl2 vl2]],
                                     continue_with_seeded_dealer: false)

    assert_equal %i[dot hl2 vl2], source.next_batch(board, 0).names
    assert_nil source.next_batch(board, 1)
  end
end
