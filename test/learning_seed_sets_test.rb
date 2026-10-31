# frozen_string_literal: true

require "minitest/autorun"
require_relative "../learning_seed_sets"

class LearningSeedSetsTest < Minitest::Test
  def test_sets_are_stable_and_non_overlapping
    sets = LearningSeedSets.names.to_h {|name| [name, LearningSeedSets.fetch(name)] }

    assert_equal (1..100).to_a, sets.fetch(:baseline)
    assert_equal 100_000, sets.fetch(:training).size
    assert_equal 2_000, sets.fetch(:tuning).size
    assert_equal 2_000, sets.fetch(:held_out).size
    assert_equal sets.values.flatten.size, sets.values.flatten.uniq.size
  end

  def test_rejects_unknown_set
    assert_raises(ArgumentError) { LearningSeedSets.fetch(:validation) }
  end
end
