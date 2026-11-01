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

  def test_parses_ranges_and_lists_and_standardizes_bad_input
    assert_equal [1, 2, 3], LearningSeedSets.parse_list("1..3")
    assert_equal [1, 3, 5], LearningSeedSets.parse_list("1,3,5")
    error = assert_raises(ArgumentError) { LearningSeedSets.parse_list("1..x") }
    assert_match "invalid seed list", error.message
  end

  def test_validation_uses_a_consistent_seed_set_error
    error = assert_raises(ArgumentError) do
      LearningSeedSets.validate!([3_000_000], set: :training, purpose: "example")
    end
    assert_match "example seeds must belong to the training seed set", error.message
    assert_match "invalid seeds: 3000000", error.message
  end
end
