# frozen_string_literal: true

# Uses recorded offer batches first, then continues with the board's seeded dealer.
class RecordedOfferSource
  Batch = Struct.new(:names, :origin, keyword_init: true)

  def initialize(recorded_offers:, continue_with_seeded_dealer:)
    @recorded_offers = recorded_offers.map {|batch| batch.map(&:to_sym) }
    @continue_with_seeded_dealer = continue_with_seeded_dealer
  end

  def next_batch(board, index)
    names = @recorded_offers[index]
    if names
      board.generate_options if @continue_with_seeded_dealer
      board.replace_options(names.map {|name| Tile.fetch(name) })
      Batch.new(names: names, origin: :recorded)
    elsif @continue_with_seeded_dealer
      names = board.generate_options.map(&:name)
      board.replace_options(names.map {|name| Tile.fetch(name) })
      Batch.new(names: names, origin: :seeded)
    end
  end
end
