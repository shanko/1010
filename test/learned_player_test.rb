# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../learned_player"
require_relative "../auto_player"
require_relative "../game_simulator"
require_relative "../policy_corrector"

class LearnedPlayerTest < Minitest::Test
  def test_feature_schema_is_stable_and_features_cover_documented_state_and_action_data
    board = Board1010.new(options: [Board1010::TILES[:dot], Board1010::TILES[:dot]])
    before = [Marshal.dump(board.cells), Marshal.dump(board.options), Marshal.dump(board.random)]

    features = ActionFeatures.extract(board, 0, 0, 0)

    assert_equal ActionFeatures::NAMES, features.keys
    assert_equal 1.0, features.fetch("tile_dot")
    assert_equal 0.0, features.fetch("tile_sq2")
    assert_equal 0.04, features.fetch("tile_area")
    assert_equal 0.0, features.fetch("completed_rows")
    assert_equal 0.0, features.fetch("completed_cols")
    assert_in_delta 0.99, features.fetch("remaining_legal_placements"), 0.000_001
    assert_equal before, [Marshal.dump(board.cells), Marshal.dump(board.options), Marshal.dump(board.random)]
    assert features.fetch("remaining_legal_placements").positive?
    assert_in_delta 0.99, features.fetch("largest_empty_region"), 0.000_001
    assert_equal 0.01, features.fetch("empty_region_count")
    assert_equal 0.0, features.fetch("isolated_empty_cells")
    assert_equal 0.0, features.fetch("filled_neighbours")
    assert_equal 1.0, features.fetch("edge_cells")
    assert_equal 0.01, features.fetch("occupied_fraction")
    assert_equal 1.0, ActionFeatures::TILE_FEATURES.sum {|name| features.fetch(name) }
    assert features.values.all?(&:finite?)
  end

  def test_completed_row_and_column_features_count_the_lines_cleared
    cells = Array.new(10) { Array.new(10, 9) }
    [[0, 0], [0, 4], [1, 1], [2, 2], [3, 3], [4, 5], [5, 6], [6, 7], [7, 8], [8, 9], [9, 4]].each do |row, col|
      cells[row][col] = Board1010::EMPTY
    end
    board = Board1010.new(cells: cells, options: [Board1010::TILES[:dot]])

    features = ActionFeatures.extract(board, 0, 9, 4)

    assert_equal 1.0, features.fetch("completed_rows")
    assert_equal 0.0, features.fetch("completed_cols")
  end

  def test_learned_strategy_requires_and_uses_a_versioned_model
    assert_raises(ArgumentError) { AutoPlayer.new(:learned) }
    model = empty_model
    model["weights"]["tile_sq2"] = 10.0
    model["weights"]["tile_dot"] = -10.0
    board = Board1010.new(options: [Board1010::TILES[:dot], Board1010::TILES[:sq2]])

    assert_equal 1, AutoPlayer.new(:learned, model: model, random: Random.new(5)).choose_move(board).first
  end

  def test_imitation_training_is_deterministic_and_model_round_trips
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "lesson.json"), JSON.pretty_generate(improved_lesson))
      trainer = ImitationTrainer.new
      first = trainer.train(directory: directory, random_seed: 29, epochs: 4)
      second = trainer.train(directory: directory, random_seed: 29, epochs: 4)
      model_path = File.join(directory, "model.json")
      trainer.save(first.model, model_path)
      loaded = LearnedPlayer.load(model_path)

      assert_equal first.model, second.model
      assert_equal 1, first.episodes_used
      assert_operator first.examples_seen, :>, 0
      assert_equal first.model, loaded.model
      result = GameSimulator.run(seed: 44, strategy: :learned, model: model_path)
      assert result.final_board.game_over?
      assert_operator result.score, :>, 0
    end
  end

  def test_training_excludes_held_out_seed_lessons
    Dir.mktmpdir do |directory|
      lesson = improved_lesson
      lesson["source_episode"]["seed"] = LearningSeedSets.fetch(:held_out).first
      File.write(File.join(directory, "held-out.json"), JSON.pretty_generate(lesson))

      error = assert_raises(ArgumentError) { ImitationTrainer.new.train(directory: directory) }
      assert_match "no eligible improved lessons", error.message
    end
  end

  def test_benchmark_accepts_a_model_for_learned_policy_and_reports_uncertainty
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "lesson.json"), JSON.pretty_generate(improved_lesson))
      model = ImitationTrainer.new.train(directory: directory, epochs: 1).model
      held_out = LearningSeedSets.fetch(:held_out).first(2)
      strategies = %i[first_fit last_fit random_fit shanko jc sam learned]
      report = GameBenchmark.run(seeds: held_out, strategies: strategies, models: {learned: model})

      assert_equal held_out, report.fetch(:seeds)
      strategies.each do |strategy|
        results = report.fetch(:strategies).fetch(strategy)
        assert_equal 2, results.fetch(:per_seed).size
        interval = results.fetch(:metrics).fetch(:score).fetch(:mean_ci_95)
        assert_operator interval.fetch(:lower), :<=, interval.fetch(:upper)
      end
    end
  end

  def test_simulator_can_capture_learned_policy_states_for_search_corrections
    result = GameSimulator.run(seed: 46, strategy: :learned, model: empty_model, capture_states: true)

    assert_equal result.moves.size, result.decision_states.size
    result.decision_states.each_with_index do |state, index|
      assert state.fetch(:board).options.any?
      assert_operator state.fetch(:offer_index), :>=, 0
      assert_equal result.moves[index][:tile], Board1010::TILES.key(state.fetch(:board).options[result.moves[index][:option]])
    end
  end

  def test_policy_corrections_reject_non_training_seeds
    held_out_seed = LearningSeedSets.fetch(:held_out).first
    error = assert_raises(ArgumentError) do
      PolicyCorrector.new.correct(seeds: [held_out_seed], model: empty_model)
    end
    assert_match "training seeds", error.message
  end

  private

  def empty_model
    {"schema_version" => LearnedPlayer::MODEL_SCHEMA_VERSION,
     "feature_version" => ActionFeatures::VERSION,
     "feature_names" => ActionFeatures::NAMES,
     "weights" => ActionFeatures::NAMES.to_h {|name| [name, 0.0] }}
  end

  def improved_lesson
    cells = Array.new(10) { Array.new(10, 9) }
    holes = [[0, 0], [1, 2], [2, 6], [3, 8], [4, 0], [4, 4], [4, 5], [5, 4], [5, 5],
             [6, 1], [7, 3], [8, 7], [9, 9]]
    holes.each {|row, col| cells[row][col] = Board1010::EMPTY }
    tile_ids = Array.new(10) { Array.new(10, 0) }
    offers = [%w[dot sq2 sq3]]
    initial = {cells: cells, tile_ids: tile_ids, score: 0, options: offers.first}
    actual = [{tile: "dot", option: 0, row: 4, col: 4}]
    candidate = [{tile: "dot", option: 0, row: 4, col: 0},
                 {tile: "sq2", option: 0, row: 4, col: 4}]
    {"schema_version" => 1,
     "source_episode" => {"path" => "train.moves", "sha256" => "example", "seed" => 1_000_000},
     "initial_state" => initial, "offers" => offers,
     "actual_sequence" => actual, "actual_score" => 1,
     "candidate_sequence" => candidate, "candidate_score" => 5,
     "improvement_delta" => 4, "outcome" => "improved",
     "search" => {"status" => "improved", "candidate_complete" => true},
     "provenance" => []}
  end
end
