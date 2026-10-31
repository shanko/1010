# frozen_string_literal: true

# Fixed, non-overlapping root seeds for repeatable training and evaluation.
module LearningSeedSets
  DEFINITIONS = {
    baseline: 1..100,
    training: 1_000_000..1_099_999,
    tuning: 2_000_000..2_001_999,
    held_out: 3_000_000..3_001_999
  }.freeze

  def self.names
    DEFINITIONS.keys
  end

  def self.fetch(name)
    range = DEFINITIONS.fetch(name.to_sym) do
      raise ArgumentError, "unknown seed set #{name.inspect}; choose from #{names.join(', ')}"
    end
    range.to_a
  end
end
