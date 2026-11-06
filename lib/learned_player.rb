# frozen_string_literal: true

require "json"
require_relative "board"
require_relative "learning_seed_sets"
require_relative "lesson_store"
require_relative "offer_replay"
require_relative "artifact_file"
require_relative "imitation_examples"

# Versioned, documented state/action features for legal placements.
module ActionFeatures
  VERSION = 2
  TILE_FEATURES = Board1010::TILE_NAMES.map {|name| "tile_#{name}" }.freeze
  neighbors_four = Array.new(100) do |index|
    row, col = index.divmod(10)
    [[row - 1, col], [row + 1, col], [row, col - 1], [row, col + 1]]
      .select {|r, c| r.between?(0, 9) && c.between?(0, 9) }
      .map {|r, c| (r * 10) + c }
  end
  NEIGHBORS_4 = neighbors_four.freeze
  neighbors_eight = Array.new(100) do |index|
    row, col = index.divmod(10)
    Board1010::NEIGHBOUR_OFFSETS.filter_map do |dr, dc|
      r = row + dr
      c = col + dc
      (r * 10) + c if r.between?(0, 9) && c.between?(0, 9)
    end
  end
  NEIGHBORS_8 = neighbors_eight.freeze
  BASE_FEATURES = %w[
    bias tile_area completed_rows completed_cols remaining_legal_placements
    largest_empty_region empty_region_count isolated_empty_cells
    filled_neighbours edge_cells occupied_fraction
  ].freeze
  NAMES = (BASE_FEATURES + TILE_FEATURES).freeze
  FEATURE_INDEX = NAMES.each_with_index.to_h.freeze
  BYTE_COUNTS = Array.new(256) {|value| value.digits(2).sum }.freeze
  LEFT_EDGE_MASK = (0...Board1010::ROWS).sum {|row| 1 << (row * Board1010::COLS) }
  RIGHT_EDGE_MASK = (0...Board1010::ROWS).sum {|row| 1 << ((row * Board1010::COLS) + Board1010::COLS - 1) }

  class FeatureVector < Array
    def initialize
      super(NAMES.size, 0.0)
    end

    def fetch(key, *defaults, &block)
      return super unless key.is_a?(String) || key.is_a?(Symbol)

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

  # Keep this schema-ordered feature assignment list together: it is the hot
  # extraction path and is easier to audit against BASE_FEATURES as one sequence.
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
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
    features[FEATURE_INDEX.fetch("filled_neighbours")] = board.footprint_neighbours(tile, row, col).to_f / 32.0
    features[FEATURE_INDEX.fetch("edge_cells")] = board.footprint_contact(tile, row, col).to_f / 32.0
    features[FEATURE_INDEX.fetch("occupied_fraction")] = occupied.to_f / 100.0
    features[FEATURE_INDEX.fetch("tile_#{tile_name}")] = 1.0
    features
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  # Empty regions use four-neighbor connectivity. Isolated cells use the
  # game's eight-neighbor geometry because diagonal gaps also affect fit.
  # Keep the bitboard traversal inline: it runs for every candidate action and
  # splitting its inner loops into methods measurably slows the O-hint path.
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
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
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

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
    _path, model = resolve(path)
    new(model)
  end

  # Return the concrete model and path together so selection never writes a
  # pointer to another pointer. Real paths also detect cycles through symlinks.
  def self.resolve(path, visited: [])
    path = File.realpath(path)
    raise ArgumentError, "selected checkpoint pointer cycle: #{path}" if visited.include?(path)

    model = JSON.parse(File.read(path))
    return [path, model] unless model["selected_checkpoint"]

    selected_path = File.expand_path(model.fetch("selected_checkpoint"), File.dirname(path))
    raise ArgumentError, "selected checkpoint does not exist: #{selected_path}" unless File.file?(selected_path)

    resolve(selected_path, visited: visited + [path])
  rescue JSON::ParserError => e
    raise ArgumentError, "invalid learned policy JSON: #{e.message}"
  end

  def initialize(model)
    model = JSON.parse(JSON.generate(model))
    validate_model!(model)
    @model = model
    @weights = read_weights(model)
    @weight_values = ActionFeatures::NAMES.map {|name| @weights.fetch(name) }
  end

  def validate_model!(model)
    unless model["schema_version"] == MODEL_SCHEMA_VERSION
      raise ArgumentError,
            "unsupported learned policy model schema"
    end

    validate_feature_version!(model)
    unless model["feature_names"] == ActionFeatures::NAMES
      raise ArgumentError,
            "model feature names do not match this code"
    end
    raise ArgumentError, "model weights are missing" unless model["weights"].is_a?(Hash)
  end

  def validate_feature_version!(model)
    return if model["feature_version"] == ActionFeatures::VERSION

    feature_version = model["feature_version"]
    message = ["model uses action feature version #{feature_version.inspect};",
               "this code requires version #{ActionFeatures::VERSION} (retrain the model)"].join(" ")
    raise ArgumentError, message
  end

  def read_weights(model)
    ActionFeatures::NAMES.to_h do |name|
      weight = Float(model["weights"].fetch(name, 0.0))
      raise ArgumentError, "model weights must be finite" unless weight.finite?

      [name, weight]
    end
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
    temperature = validated_temperature(temperature)

    actions = legal_actions(board)
    return nil if actions.empty?

    probabilities = action_probabilities(actions, temperature)
    selected_index = sample_index(probabilities, random)
    expected = expected_action_features(actions, probabilities)
    action, features = actions.fetch(selected_index)
    {action: action, log_probability: Math.log(probabilities.fetch(selected_index)),
     chosen_features: features, expected_features: expected, probabilities: probabilities}
  end

  def validated_temperature(value)
    temperature = Float(value)
    raise ArgumentError, "temperature must be finite and positive" unless temperature.finite? && temperature.positive?

    temperature
  end

  def action_probabilities(actions, temperature)
    scores = actions.map {|_action, features| score(features) / temperature }
    maximum = scores.max
    masses = scores.map {|value| Math.exp((value - maximum).clamp(-40.0, 0.0)) }
    total = masses.sum
    masses.map {|mass| mass / total }
  end

  def sample_index(probabilities, random)
    draw = random.rand
    probabilities.each_index.find do |index|
      draw -= probabilities[index]
      draw.negative?
    end || (probabilities.size - 1)
  end

  def expected_action_features(actions, probabilities)
    ActionFeatures::FeatureVector.new.tap do |expected|
      ActionFeatures::NAMES.each_index do |feature_index|
        expected[feature_index] = expected_feature_value(actions, probabilities, feature_index)
      end
    end
  end

  def expected_feature_value(actions, probabilities, feature_index)
    actions.each_with_index.sum do |(_action, features), index|
      probabilities[index] * features[feature_index]
    end
  end

  def update_policy_gradient!(chosen_features:, expected_features:, advantage:, learning_rate:,
                              temperature: 1.0)
    temperature = validated_temperature(temperature)

    scale = Float(advantage) * Float(learning_rate) / temperature
    raise ArgumentError, "policy update scale must be finite" unless scale.finite?

    update_weights(chosen_features, expected_features, scale)
    @weight_values = ActionFeatures::NAMES.map {|name| @weights.fetch(name) }
    @model["weights"] = @weights
  end

  def update_weights(chosen_features, expected_features, scale)
    ActionFeatures::NAMES.each_with_index do |name, index|
      @weights[name] += scale * (feature_at(chosen_features, name, index) -
                                 feature_at(expected_features, name, index))
    end
  end

  def feature_at(features, name, index)
    features.is_a?(Array) ? features[index] : features.fetch(name)
  end

  def best_position(board, tile, random: Random.new)
    option_index = board.options.index(tile)
    return nil unless option_index

    actions = board.positions_for(tile).map do |row, col|
      action = [option_index, row, col]
      [action, ActionFeatures.extract(board, *action)]
    end
    return nil if actions.empty?

    winners = best_actions(actions)
    winners.map {|_index, row, col| [row, col] }.sample(random: random)
  end

  def best_actions(actions)
    scored = actions.map {|action, features| [action, score(features)] }
    best_score = scored.map(&:last).max
    scored.select {|_action, value| value == best_score }.map(&:first)
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

  def train(directory:, seed_set: :training, random_seed: 1, epochs: 10, learning_rate: 0.1,
            allow_legacy_lessons: false)
    epochs, rate = validate_training_options(epochs, learning_rate)
    LearningSeedSets.validate_set!(seed_set, allowed: :training, purpose: "imitation training")
    excluded = Hash.new(0)
    ImitationExamples.open do |examples|
      collect_examples(directory, seed_set, excluded, allow_legacy_lessons, examples)
      if examples.empty?
        raise ArgumentError, "no eligible improved lessons found in #{directory} (seed set #{seed_set})"
      end

      train_examples(examples, random_seed: random_seed, epochs: epochs, rate: rate,
                      seed_set: seed_set, excluded: excluded, allow_legacy_lessons: allow_legacy_lessons)
    end
  end

  def train_examples(examples, random_seed:, epochs:, rate:, seed_set:, excluded:, allow_legacy_lessons:)
    random_seed = Integer(random_seed)
    weights, examples_seen = train_weights(examples, random_seed, epochs, rate)
    model = training_model(weights: weights, examples: examples, seed_set: seed_set,
                           random_seed: random_seed, epochs: epochs, rate: rate, seen: examples_seen)
    model["training"]["allow_legacy_lessons"] = true if allow_legacy_lessons
    Result.new(model: model, episodes_used: episode_count(examples),
               examples_seen: examples_seen, excluded: excluded)
  end

  def validate_training_options(epochs, learning_rate)
    epochs = Integer(epochs)
    rate = Float(learning_rate)
    raise ArgumentError, "epochs must be positive" unless epochs.positive?

    unless rate.finite? && rate.positive? && rate <= 1.0
      raise ArgumentError,
            "learning rate must be finite and between 0 and 1"
    end

    [epochs, rate]
  end

  def collect_examples(directory, seed_set, excluded, allow_legacy_lessons, examples)
    Dir.glob(File.join(directory, "*.json")).each do |path|
      examples_from_path(path, seed_set, excluded, allow_legacy_lessons).each {|example| examples << example }
    end
  end

  def examples_from_path(path, seed_set, excluded, allow_legacy_lessons)
    lesson = LessonStore.read(path, allow_legacy: allow_legacy_lessons)
    return [] unless eligible_seed?(lesson, seed_set, excluded)
    return reject_lesson(excluded, :low_confidence_or_no_improvement) unless complete_improvement?(lesson)

    validated_examples(lesson, excluded)
  end

  def eligible_seed?(lesson, seed_set, excluded)
    unless root_seed?(lesson)
      excluded[:unverified_root_seed] += 1
      return false
    end

    seed = lesson.dig("source_episode", "seed")
    return true if seed && LearningSeedSets.member?(seed, set: seed_set)

    excluded[seed && LearningSeedSets.member?(seed, set: :held_out) ? :held_out : :outside_seed_set] += 1
    false
  end

  def root_seed?(lesson)
    kind = lesson.dig("source_episode", "seed_kind")
    kind == "root" || (kind.nil? && lesson["schema_version"] == 1)
  end

  def reject_lesson(excluded, reason)
    excluded[reason] += 1
    []
  end

  def complete_improvement?(lesson)
    lesson["outcome"] == "improved" && lesson["improvement_delta"].to_i.positive? &&
      lesson.dig("search", "candidate_complete") == true && lesson.dig("search", "status") == "improved"
  end

  def validated_examples(lesson, excluded)
    return reject_lesson(excluded, :invalid_replay) unless valid_complete_replay?(lesson)

    examples_for(lesson)
  rescue ArgumentError, KeyError
    reject_lesson(excluded, :invalid_replay)
  end

  def valid_complete_replay?(lesson)
    actual = LessonStore.replay(lesson, "actual_sequence")
    candidate = LessonStore.replay(lesson, "candidate_sequence")
    replay_scores_match?(lesson, actual, candidate) && actual.game_over? && complete_board?(candidate)
  end

  def replay_scores_match?(lesson, actual, candidate)
    actual.score == lesson.fetch("actual_score") && candidate.score == lesson.fetch("candidate_score") &&
      candidate.score - actual.score == lesson.fetch("improvement_delta")
  end

  def complete_board?(board)
    board.game_over? && !board.options.empty?
  end

  def train_weights(examples, random_seed, epochs, rate)
    weights = ActionFeatures::NAMES.to_h {|name| [name, 0.0] }
    random = Random.new(random_seed)
    seen = 0
    epochs.times do
      examples.shuffle(random: random).each do |example|
        update(weights, example, rate)
        seen += 1
      end
    end
    [weights, seen]
  end

  def training_model(weights:, examples:, seed_set:, random_seed:, epochs:, rate:, seen:)
    {"schema_version" => LearnedPlayer::MODEL_SCHEMA_VERSION,
     "feature_version" => ActionFeatures::VERSION, "feature_names" => ActionFeatures::NAMES,
     "weights" => weights,
     "training" => {"seed_set" => seed_set.to_s, "random_seed" => random_seed,
                    "epochs" => epochs, "learning_rate" => rate,
                    "episodes_used" => episode_count(examples), "examples_seen" => seen}}
  end

  def episode_count(examples)
    examples.episode_count
  end

  def save(model, path)
    ArtifactFile.write(path, "#{JSON.pretty_generate(model)}\n")
    path
  end

  private

  def examples_for(lesson)
    board = lesson_initial_board(lesson)
    offers = lesson["candidate_offers"] || lesson.fetch("offers")
    replay = OfferReplay.new(board: board, offers: offers, strict_offers: false)
    confidence = [Math.log(1 + lesson.fetch("improvement_delta").to_f), 2.0].min
    episode = lesson.dig("source_episode", "seed")
    policy = LearnedPlayer.new(empty_model)
    lesson.fetch("candidate_sequence").map do |move|
      example_for_move(move, policy, replay, confidence, episode)
    end
  end

  def lesson_initial_board(lesson)
    initial = lesson.fetch("initial_state")
    Board1010.new(cells: initial.fetch("cells"), tile_ids: initial.fetch("tile_ids"),
                  score: initial.fetch("score"), options: initial.fetch("options").map {|name| Tile.fetch(name) })
  end

  def example_for_move(move, policy, replay, confidence, episode)
    legal = policy.legal_actions(replay.board)
    chosen = [Integer(move.fetch("option")), Integer(move.fetch("row")), Integer(move.fetch("col"))]
    match = legal.find {|action, _features| action == chosen }
    raise ArgumentError, "candidate contains an action outside the legal set" unless match

    replay.apply({tile: move.fetch("tile"), option: chosen[0], row: chosen[1], col: chosen[2]})
    {legal: legal, chosen: match.last, weight: confidence, episode: episode}
  end

  def empty_model
    {"schema_version"  => LearnedPlayer::MODEL_SCHEMA_VERSION,
     "feature_version" => ActionFeatures::VERSION,
     "feature_names"   => ActionFeatures::NAMES,
     "weights"         => ActionFeatures::NAMES.to_h {|name| [name, 0.0] }}
  end

  def update(weights, example, learning_rate)
    expected = expected_features(weights, example[:legal])
    chosen_features = example[:chosen]
    ActionFeatures::NAMES.each do |name|
      weights[name] += learning_rate * example[:weight] * (chosen_features.fetch(name) - expected.fetch(name))
    end
  end

  def expected_features(weights, legal)
    scored = legal.map {|_action, features| [features, dot(weights, features)] }
    maximum = scored.map(&:last).max
    masses = scored.map {|_features, value| Math.exp((value - maximum).clamp(-40.0, 0.0)) }
    total = masses.sum
    ActionFeatures::NAMES.to_h do |name|
      [name, expected_feature(name, scored, masses, total)]
    end
  end

  def expected_feature(name, scored, masses, total)
    scored.each_with_index.sum {|(features, _score), index| masses[index] * features.fetch(name) / total }
  end

  def dot(weights, features)
    ActionFeatures::NAMES.sum {|name| weights.fetch(name) * features.fetch(name) }
  end
end
