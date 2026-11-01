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
    range_for(name).to_a
  end

  # Accepts either an inclusive range ("1..3") or a comma-separated list.
  def self.parse_list(value)
    text = String(value).strip
    text.include?("..") ? parse_range(text) : parse_comma_list(text)
  rescue ArgumentError, TypeError
    raise ArgumentError,
          "invalid seed list #{value.inspect}; use comma-separated integers or an inclusive START..END range"
  end

  def self.parse_range(text)
    match = /\A(-?\d+)\.\.(-?\d+)\z/.match(text)
    raise ArgumentError unless match

    first, last = match.captures.map {|part| Integer(part) }
    raise ArgumentError if last < first

    (first..last).to_a
  end

  def self.parse_comma_list(text)
    parts = text.split(",", -1)
    raise ArgumentError if parts.empty? || parts.any? {|part| part.strip.empty? }

    parts.map {|part| Integer(part.strip) }
  end

  # Returns normalized seeds or raises one consistent error for a set mismatch.
  def self.validate!(seeds, set:, purpose:)
    range = range_for(set)
    values = Array(seeds).map {|seed| Integer(seed) }
    invalid = values.reject {|seed| range.cover?(seed) }
    invalid = ["(empty list)"] if values.empty?
    unless invalid.empty?
      raise ArgumentError,
            "#{purpose} seeds must belong to the #{set} seed set (#{range}); invalid seeds: #{invalid.join(', ')}"
    end

    values
  rescue TypeError
    raise ArgumentError, "#{purpose} seeds must be integers in the #{set} seed set"
  end

  def self.member?(seed, set:)
    range_for(set).cover?(Integer(seed))
  rescue ArgumentError, TypeError
    false
  end

  def self.validate_set!(name, allowed:, purpose:)
    selected = name.to_sym
    range_for(selected)
    return selected if selected == allowed.to_sym

    raise ArgumentError, "#{purpose} must use the #{allowed} seed set; got #{selected}"
  end

  def self.range_for(name)
    DEFINITIONS.fetch(name.to_sym) do
      raise ArgumentError, "unknown seed set #{name.inspect}; choose from #{names.join(', ')}"
    end
  end
end
