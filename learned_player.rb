# frozen_string_literal: true

require "json"
require_relative "board"
require_relative "learning_seed_sets"
require_relative "lesson_store"

# Versioned, documented state/action features for legal placements.
module ActionFeatures
  VERSION = 1
  TILE_FEATURES = Board1010::TILE_NAMES.map {|name| "tile_#{name}" }.freeze
  NEIGHBORS_4 = Array.new(100) do |index|
    row, col = index.divmod(10)
    [[row - 1, col], [row + 1, col], [row, col - 1], [row, col + 1]]
      .select {|r, c| r.between?(0, 9) && c.between?(0, 9) }
      .map {|r, c| r * 10 + c }
  end.freeze
  NEIGHBORS_8 = Array.new(100) do |index|
    row, col = index.divmod(10)
    Board1010::NEIGHBOUR_OFFSETS.filter_map do |dr, dc|
      r = row + dr
      c = col + dc
      r * 10 + c if r.between?(0, 9) && c.between?(0, 9)
    end
  end.freeze
  BASE_FEATURES = %w[
    bias tile_area completed_rows completed_cols remaining_legal_placements
    largest_empty_region empty_region_count isolated_empty_cells
    filled_neighbours edge_cells occupied_fraction
  ].freeze
  NAMES = (BASE_FEATURES + TILE_FEATURES).freeze
  FEATURE_INDEX = NAMES.each_with_index.to_h.freeze
  BYTE_COUNTS = Array.new(256) {|value| value.digits(2).sum }.freeze
  LEFT_EDGE_MASK = (0...Board1010::ROWS).sum {|row| 1 << (row * Board1010::COLS) }
  RIGHT_EDGE_MASK = (0...Board1010::ROWS).sum {|row| 1 << (row * Board1010::COLS + Board1010::COLS - 1) }

  class FeatureVector < Array
    def initialize
      super(NAMES.size, 0.0)
    end

    def fetch(key, *defaults, &block)
      return super(key, *defaults, &block) unless key.is_a?(String) || key.is_a?(Symbol)

      index = NAMES.index(key.to_s)
      return super(index, *defaults, &block) if index

      raise KeyError, "key not found: #{key.inspect}" if defaults.empty? && !block
      block ? block.call(key) : defaults.first
    end

    def keys
      NAMES
    end

    def values
      self
    end
  end

  def self.extract(board, option_index, row, col)
    tile = board.options.fetch(option_index)
    raise ArgumentError, "feature action is not legal" unless board.fits?(tile, row, col)

    occupied_before = board.occupied_bits
    occupied_after, completed_rows, completed_cols = board.placement_result(
      tile, row, col, occupied_bits: occupied_before
    )
    largest_region, region_count, isolated = empty_space_features(occupied_after)
    legal_placements = board.legal_placement_count(board.options, occupied_bits: occupied_after,
                                                   exclude_index: option_index)
    occupied = bit_count(occupied_after)
    tile_name = tile.name
    features = FeatureVector.new
    features[FEATURE_INDEX.fetch("bias")] = 1.0
    features[FEATURE_INDEX.fetch("tile_area")] = tile.area.to_f / 25.0
    features[FEATURE_INDEX.fetch("completed_rows")] = completed_rows.to_f
    features[FEATURE_INDEX.fetch("completed_cols")] = completed_cols.to_f
    features[FEATURE_INDEX.fetch("remaining_legal_placements")] = legal_placements.to_f / 100.0
    features[FEATURE_INDEX.fetch("largest_empty_region")] = largest_region.to_f / 100.0
    features[FEATURE_INDEX.fetch("empty_region_count")] = region_count.to_f / 100.0
    features[FEATURE_INDEX.fetch("isolated_empty_cells")] = isolated.to_f / 100.0
    features[FEATURE_INDEX.fetch("filled_neighbours")] = board.filled_neighbours(row, col).to_f / 8.0
    features[FEATURE_INDEX.fetch("edge_cells")] = board.edges_touched(row, col).to_f / 2.0
    features[FEATURE_INDEX.fetch("occupied_fraction")] = occupied.to_f / 100.0
    features[FEATURE_INDEX.fetch("tile_#{tile_name}")] = 1.0
    features
  end

  # Empty regions use four-neighbor connectivity. Isolated cells use the
  # game's eight-neighbor geometry because diagonal gaps also affect fit.
  def self.empty_space_features(board_or_bits)
    occupied = board_or_bits.is_a?(Board1010) ? board_or_bits.occupied_bits : board_or_bits
    empty = Board1010::FULL_BOARD_MASK ^ occupied
    remaining = empty
    largest = 0
    regions = 0
    left_edge = LEFT_EDGE_MASK
    right_edge = RIGHT_EDGE_MASK
    until remaining.zero?
      regions += 1
      region = remaining & -remaining
      frontier = region
      until frontier.zero?
        expanded = ((frontier & ~left_edge) >> 1) | ((frontier & ~right_edge) << 1) |
                   (frontier >> Board1010::COLS) | (frontier << Board1010::COLS)
        frontier = expanded & remaining & ~region
        region |= frontier
      end
      size = bit_count(region)
      largest = size if size > largest
      remaining &= ~region
    end

    neighbors = ((empty & ~left_edge) >> 1) | ((empty & ~right_edge) << 1) |
                (empty >> Board1010::COLS) | (empty << Board1010::COLS) |
                ((empty & ~left_edge) >> (Board1010::COLS + 1)) |
                ((empty & ~right_edge) >> (Board1010::COLS - 1)) |
                ((empty & ~left_edge) << (Board1010::COLS - 1)) |
                ((empty & ~right_edge) << (Board1010::COLS + 1))
    [largest, regions, bit_count(empty & ~neighbors)]
  end
  private_class_method :empty_space_features

  def self.bit_count(bits)
    bits.digits(256).sum {|byte| BYTE_COUNTS[byte] }
  end
  private_class_method :bit_count
end

# Linear action scorer. The model file contains only versioned metadata and
# feature weights, so it can be loaded without third-party ML libraries.
class LearnedPlayer
  MODEL_SCHEMA_VERSION = 1

  attr_reader :model, :weights

  def self.load(path)
    model = JSON.parse(File.read(path))
    if model["selected_checkpoint"]
      selected_path = File.join(File.dirname(path), model.fetch("selected_checkpoint"))
      raise ArgumentError, "selected checkpoint does not exist: #{selected_path}" unless File.file?(selected_path)

      model = JSON.parse(File.read(selected_path))
    end
    new(model)
  rescue JSON::ParserError => error
    raise ArgumentError, "invalid learned policy JSON: #{error.message}"
  end

  def initialize(model)
    model = JSON.parse(JSON.generate(model))
    raise ArgumentError, "unsupported learned policy model schema" unless model["schema_version"] == MODEL_SCHEMA_VERSION
    raise ArgumentError, "unsupported action feature version" unless model["feature_version"] == ActionFeatures::VERSION
    raise ArgumentError, "model feature names do not match this code" unless model["feature_names"] == ActionFeatures::NAMES
    raise ArgumentError, "model weights are missing" unless model["weights"].is_a?(Hash)

    @model = model
    @weights = ActionFeatures::NAMES.to_h do |name|
      weight = Float(model["weights"].fetch(name, 0.0))
      raise ArgumentError, "model weights must be finite" unless weight.finite?

      [name, weight]
    end
    @weight_values = ActionFeatures::NAMES.map {|name| @weights.fetch(name) }
  end

  def score(features)
    features.each_index.sum {|index| @weight_values[index] * features[index] }
  end

  # Returns the highest-ranked [option index, row, col], using seeded random
  # tie-breaking to avoid a permanent top-left bias.
  def choose_move(board, random: Random.new)
    actions = legal_actions(board)
    return nil if actions.empty?

    scored = actions.map {|action, features| [action, score(features)] }
    best_score = scored.map(&:last).max
    tied = scored.select {|_action, value| value == best_score }.map(&:first)
    tied.sample(random: random)
  end

  # Draws a stochastic action for policy-gradient training and returns the
  # sufficient statistics for grad(log pi): chosen features minus expectation.
  def sample_action(board, random:, temperature: 1.0)
    temperature = Float(temperature)
    raise ArgumentError, "temperature must be finite and positive" unless temperature.finite? && temperature.positive?
    actions = legal_actions(board)
    return nil if actions.empty?

    scores = actions.map {|_action, features| score(features) / temperature }
    maximum = scores.max
    masses = scores.map {|value| Math.exp([[value - maximum, -40.0].max, 0.0].min) }
    total = masses.sum
    probabilities = masses.map {|mass| mass / total }
    draw = random.rand
    selected_index = probabilities.each_index.find do |index|
      draw -= probabilities[index]
      draw.negative?
    end || probabilities.size - 1
    expected = ActionFeatures::FeatureVector.new
    ActionFeatures::NAMES.each_index do |feature_index|
      expected[feature_index] = actions.each_with_index.sum do |(_action, features), index|
        probabilities[index] * features[feature_index]
      end
    end
    action, features = actions.fetch(selected_index)
    {action: action, log_probability: Math.log(probabilities.fetch(selected_index)),
     chosen_features: features, expected_features: expected, probabilities: probabilities}
  end

  def update_policy_gradient!(chosen_features:, expected_features:, advantage:, learning_rate:,
                              temperature: 1.0)
    temperature = Float(temperature)
    raise ArgumentError, "temperature must be finite and positive" unless temperature.finite? && temperature.positive?

    scale = Float(advantage) * Float(learning_rate) / temperature
    raise ArgumentError, "policy update scale must be finite" unless scale.finite?

    ActionFeatures::NAMES.each_with_index do |name, index|
      chosen = chosen_features.is_a?(Array) ? chosen_features[index] : chosen_features.fetch(name)
      expected = expected_features.is_a?(Array) ? expected_features[index] : expected_features.fetch(name)
      @weights[name] += scale * (chosen - expected)
    end
    @weight_values = ActionFeatures::NAMES.map {|name| @weights.fetch(name) }
    @model["weights"] = @weights
  end

  def best_position(board, tile, random: Random.new)
    option_index = board.options.index(tile)
    return nil unless option_index

    actions = board.positions_for(tile).map do |row, col|
      action = [option_index, row, col]
      [action, ActionFeatures.extract(board, *action)]
    end
    return nil if actions.empty?

    scored = actions.map {|action, features| [action, score(features)] }
    best_score = scored.map(&:last).max
    scored.select {|_action, value| value == best_score }.map(&:first).map {|_index, row, col| [row, col] }.sample(random: random)
  end

  def legal_actions(board)
    board.options.each_index.flat_map do |index|
      board.positions_for(board.options[index]).map do |row, col|
        action = [index, row, col]
        [action, ActionFeatures.extract(board, *action)]
      end
    end
  end
end

# Deterministic softmax imitation trainer over validated, improved lessons.
class ImitationTrainer
  Result = Struct.new(:model, :episodes_used, :examples_seen, :excluded, keyword_init: true)

  def train(directory:, seed_set: :training, random_seed: 1, epochs: 10, learning_rate: 0.1)
    epochs = Integer(epochs)
    rate = Float(learning_rate)
    raise ArgumentError, "epochs must be positive" unless epochs.positive?
    raise ArgumentError, "learning rate must be finite and between 0 and 1" unless rate.finite? && rate.positive? && rate <= 1.0
    raise ArgumentError, "imitation training must use the training seed set" unless seed_set.to_sym == :training

    allowed_range = LearningSeedSets::DEFINITIONS.fetch(seed_set.to_sym) do
      raise ArgumentError, "unknown training seed set #{seed_set.inspect}"
    end
    examples = []
    excluded = Hash.new(0)
    lesson_paths = Dir.glob(File.join(directory, "*.json")).sort
    lesson_paths.each do |path|
      lesson = LessonStore.read(path)
      seed = lesson.dig("source_episode", "seed")
      if seed && LearningSeedSets::DEFINITIONS.fetch(:held_out).cover?(Integer(seed))
        excluded[:held_out] += 1
        next
      end
      unless seed && allowed_range.cover?(Integer(seed))
        excluded[:outside_seed_set] += 1
        next
      end
      unless lesson["outcome"] == "improved" && lesson["improvement_delta"].to_i.positive? &&
             lesson.dig("search", "candidate_complete") == true && lesson.dig("search", "status") == "improved"
        excluded[:low_confidence_or_no_improvement] += 1
        next
      end

      begin
        actual = LessonStore.replay(lesson, "actual_sequence")
        candidate = LessonStore.replay(lesson, "candidate_sequence")
        unless actual.score == lesson.fetch("actual_score") && candidate.score == lesson.fetch("candidate_score") &&
               candidate.score - actual.score == lesson.fetch("improvement_delta") &&
               actual.game_over? && candidate.game_over? && !candidate.options.empty?
          excluded[:invalid_replay] += 1
          next
        end
        examples.concat(examples_for(lesson))
      rescue ArgumentError, KeyError
        excluded[:invalid_replay] += 1
      end
    end
    raise ArgumentError, "no eligible improved lessons found in #{directory} (seed set #{seed_set})" if examples.empty?

    weights = ActionFeatures::NAMES.to_h {|name| [name, 0.0] }
    random = Random.new(Integer(random_seed))
    examples_seen = 0
    epochs.times do
      examples.shuffle(random: random).each do |example|
        update(weights, example, rate)
        examples_seen += 1
      end
    end
    model = {"schema_version" => LearnedPlayer::MODEL_SCHEMA_VERSION,
             "feature_version" => ActionFeatures::VERSION,
             "feature_names" => ActionFeatures::NAMES,
             "weights" => weights,
             "training" => {"seed_set" => seed_set.to_s, "random_seed" => Integer(random_seed),
                            "epochs" => epochs, "learning_rate" => rate,
                            "episodes_used" => examples.map {|example| example[:episode] }.uniq.size,
                            "examples_seen" => examples_seen}}
    Result.new(model: model, episodes_used: examples.map {|example| example[:episode] }.uniq.size,
               examples_seen: examples_seen, excluded: excluded)
  end

  def save(model, path)
    File.write(path, JSON.pretty_generate(model) + "\n")
    path
  end

  private

  def examples_for(lesson)
    initial = lesson.fetch("initial_state")
    board = Board1010.new(cells: initial.fetch("cells"), tile_ids: initial.fetch("tile_ids"),
                          score: initial.fetch("score"),
                          options: initial.fetch("options").map {|name| Tile.fetch(name) })
    offers = lesson["candidate_offers"] || lesson.fetch("offers")
    next_offer = 1
    confidence = [Math.log(1 + lesson.fetch("improvement_delta").to_f), 2.0].min
    episode = lesson.dig("source_episode", "seed")
    policy = LearnedPlayer.new(empty_model)
    lesson.fetch("candidate_sequence").map do |move|
      legal = policy.legal_actions(board)
      chosen = [Integer(move.fetch("option")), Integer(move.fetch("row")), Integer(move.fetch("col"))]
      match = legal.find {|action, _features| action == chosen }
      raise ArgumentError, "candidate contains an action outside the legal set" unless match

      batch_exhausted = board.options.size == 1
      board.play(chosen[0], chosen[1], chosen[2], deal: false)
      if batch_exhausted && (batch = offers[next_offer])
        board.replace_options(batch.map {|name| Tile.fetch(name) })
        next_offer += 1
      end
      {legal: legal, chosen: match.last, weight: confidence, episode: episode}
    end
  end

  def empty_model
    {"schema_version" => LearnedPlayer::MODEL_SCHEMA_VERSION,
     "feature_version" => ActionFeatures::VERSION,
     "feature_names" => ActionFeatures::NAMES,
     "weights" => ActionFeatures::NAMES.to_h {|name| [name, 0.0] }}
  end

  def update(weights, example, learning_rate)
    scored = example[:legal].map {|_action, features| [features, dot(weights, features)] }
    maximum = scored.map(&:last).max
    probabilities = scored.map {|_features, value| Math.exp([[value - maximum, -40.0].max, 0.0].min) }
    normalizer = probabilities.sum
    chosen_features = example[:chosen]
    expected = ActionFeatures::NAMES.to_h do |name|
      value = scored.each_with_index.sum {|(features, _score), index| probabilities[index] * features.fetch(name) / normalizer }
      [name, value]
    end
    ActionFeatures::NAMES.each do |name|
      weights[name] += learning_rate * example[:weight] * (chosen_features.fetch(name) - expected.fetch(name))
    end
  end

  def dot(weights, features)
    ActionFeatures::NAMES.sum {|name| weights.fetch(name) * features.fetch(name) }
  end
end
