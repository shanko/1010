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

  def test_bitboard_empty_space_features_match_the_previous_grid_flood_fill
    random = Random.new(812_991)
    30.times do
      board = Board1010.new
      board.cells.each do |row|
        row.map! { random.rand < 0.28 ? 1 : Board1010::EMPTY }
      end

      assert_equal reference_empty_space_features(board),
                   ActionFeatures.send(:empty_space_features, board)
    end
  end

  def test_incremental_action_features_match_board_copy_features
    board = GameSimulator.initial_board(seed: 86_753_099)
    board.options.each_with_index do |tile, option|
      board.positions_for(tile).first(5).each do |row, col|
        after = board.copy
        move = after.play(option, row, col, deal: false)
        next unless move

        largest, regions, isolated = reference_empty_space_features(after)
        legal = after.legal_placement_count(after.options)
        occupied = after.cells.flatten.count {|value| value != Board1010::EMPTY }
        expected = {
          "completed_rows" => move.cleared_rows.size.to_f,
          "completed_cols" => move.cleared_cols.size.to_f,
          "remaining_legal_placements" => legal.to_f / 100.0,
          "largest_empty_region" => largest.to_f / 100.0,
          "empty_region_count" => regions.to_f / 100.0,
          "isolated_empty_cells" => isolated.to_f / 100.0,
          "occupied_fraction" => occupied.to_f / 100.0
        }
        actual = ActionFeatures.extract(board, option, row, col)
        expected.each {|name, value| assert_equal value, actual.fetch(name), name }
      end
    end
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
      assert_equal strategies, report.fetch(:pairwise_score_deltas).keys
    end
  end

  def test_simulator_can_capture_learned_policy_states_for_search_corrections
    result = GameSimulator.run(seed: 46, strategy: :learned, model: empty_model, capture_states: true)

    assert_equal result.moves.size, result.decision_states.size
    result.decision_states.each_with_index do |state, index|
      assert state.fetch(:board).options.any?
      assert_operator state.fetch(:offer_index), :>=, 0
      assert_equal result.moves[index][:tile], state.fetch(:board).options[result.moves[index][:option]].name
    end
  end

  def test_policy_corrections_reject_non_training_seeds
    held_out_seed = LearningSeedSets.fetch(:held_out).first
    error = assert_raises(ArgumentError) do
      PolicyCorrector.new.correct(seeds: [held_out_seed], model: empty_model)
    end
    assert_match "training seeds", error.message
  end

  def test_stride_one_corrections_and_mid_batch_lesson_replay
    episode = GameSimulator.run(seed: 1_000_000, strategy: :learned, model: empty_model,
                                capture_states: true)
    corrector = PolicyCorrector.new
    state = episode.decision_states.fetch(1)
    offers = corrector.send(:fixed_offers_for, state, episode)
    board = state.fetch(:board)
    assert_equal 2, board.options.size, "decision 2 should be mid-batch"
    assert_equal board.options.map(&:name), offers.first

    lesson = {
      "initial_state" => {"cells" => board.cells, "tile_ids" => board.tile_ids,
                          "score" => board.score, "options" => offers.first},
      "offers" => offers,
      "actual_sequence" => episode.moves.drop(1),
      "actual_score" => episode.score,
      "candidate_sequence" => episode.moves.drop(1),
      "candidate_score" => episode.score
    }
    replayed = LessonStore.replay(lesson, "actual_sequence")
    candidate = LessonStore.replay(lesson, "candidate_sequence")
    assert_equal episode.score, replayed.score
    assert_equal episode.score, candidate.score

    Dir.mktmpdir do |directory|
      result = corrector.correct(seeds: [1_000_000], model: empty_model,
                                 store: LessonStore.new(directory: directory),
                                 time_budget_seconds: 0, max_states: 1, decision_stride: 1)
      assert_equal 1, result.episodes
      assert_operator result.states_searched, :>=, 3
    end
  end

  private

  def reference_empty_space_features(board)
    empty = board.cells.flatten.map {|value| value == Board1010::EMPTY }
    seen = Array.new(100, false)
    sizes = []
    100.times do |index|
      sizes << reference_region_size(empty, seen, index) if empty[index] && !seen[index]
    end
    [sizes.max || 0, sizes.size, reference_isolated_count(empty)]
  end

  def reference_isolated_count(empty)
    (0...100).count do |index|
      empty[index] && ActionFeatures::NEIGHBORS_8[index].none? {|neighbor| empty[neighbor] }
    end
  end

  # Breadth-first size of the empty region containing `start`, marking it seen.
  def reference_region_size(empty, seen, start)
    queue = [start]
    seen[start] = true
    cursor = 0
    while cursor < queue.size
      ActionFeatures::NEIGHBORS_4[queue[cursor]].each do |neighbor|
        next unless empty[neighbor] && !seen[neighbor]

        seen[neighbor] = true
        queue << neighbor
      end
      cursor += 1
    end
    queue.size
  end

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
