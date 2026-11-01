# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../learn_cli"
require_relative "../game_log"

class LearnCLITest < Minitest::Test
  def test_shared_seed_lists_accept_ranges_and_comma_lists
    assert_equal [1_000_000, 1_000_001], LearningSeedSets.parse_list("1000000..1000001")
    assert_equal [2_000_000, 2_000_002], LearningSeedSets.parse_list("2000000,2000002")
  end

  def test_seed_set_violations_use_one_message_format
    errors = %i[training tuning held_out].map do |set|
      seed = LearningSeedSets.fetch(set == :training ? :held_out : :training).first
      error = assert_raises(ArgumentError) do
        LearningSeedSets.validate!([seed], set: set, purpose: "sample task")
      end
      error.message
    end

    errors.each do |message|
      assert_match(/sample task seeds must belong to the (training|tuning|held_out) seed set .*; invalid seeds:/,
                   message)
    end
  end

  def test_analyze_command_success_path_runs_in_process
    Dir.mktmpdir do |directory|
      trace = write_completed_trace(directory)
      summary = run_success("analyze", "--budget", "0", "--strategy", "first_fit",
                            "--output", File.join(directory, "lessons"), trace)

      assert_equal "no_improvement", summary.fetch("outcome")
      assert File.file?(summary.fetch("lesson"))
    end
  end

  def test_collect_and_imitation_training_commands_success_paths_run_in_process
    Dir.mktmpdir do |directory|
      lesson_directory = File.join(directory, "lessons")
      collected = run_success("collect-training", "--seeds", "1000000..1000000",
                              "--budget", "5", "--max-states", "500", "--max-rollouts", "8",
                              "--output", lesson_directory)
      assert_equal 1, collected.fetch("episodes")
      assert_equal 1, collected.fetch("lessons_saved")

      model_path = File.join(directory, "imitation.json")
      trained = run_success("train-imitation", "--lessons", lesson_directory,
                            "--seed", "5", "--epochs", "1", "--output", model_path)
      assert_equal 1, trained.fetch("episodes_used")
      assert File.file?(model_path)
    end
  end

  def test_correct_command_accepts_a_seed_range_and_runs_in_process
    Dir.mktmpdir do |directory|
      model_path = write_empty_model(directory)
      result = run_success("correct", "--model", model_path, "--seeds", "1000000..1000000",
                           "--budget", "0", "--max-rollouts", "1", "--stride", "100000",
                           "--output", File.join(directory, "corrections"))

      assert_equal 1, result.fetch("episodes")
      assert_equal 1, result.fetch("states_searched")
    end
  end

  def test_train_rl_and_select_commands_success_paths_run_in_process
    Dir.mktmpdir do |directory|
      model_path = write_empty_model(directory)
      checkpoint_directory = File.join(directory, "checkpoints")
      trained = run_success("train-rl", "--model", model_path, "--episodes", "1",
                            "--seeds", "1000000..1000000", "--tuning-seeds", "2000000..2000000",
                            "--checkpoint-interval", "1", "--checkpoints", checkpoint_directory)
      assert_equal 1, trained.fetch("episodes").size
      assert File.file?(trained.fetch("best_checkpoint"))

      selected = run_success("select", "--checkpoint", trained.fetch("best_checkpoint"),
                             "--tuning-seeds", "2000000..2000000")
      assert File.file?(selected.fetch("selected_pointer"))
    end
  end

  def test_seed_set_errors_are_reported_without_a_parser_crash
    Dir.mktmpdir do |directory|
      model_path = write_empty_model(directory)
      out = StringIO.new
      err = StringIO.new
      status = LearnCLI.run(["correct", "--model", model_path, "--seeds", "3000000..3000001"],
                            out: out, err: err)

      assert_equal 1, status
      assert_match "policy correction seeds must belong to the training seed set", err.string
      assert_match "invalid seeds: 3000000, 3000001", err.string
    end
  end

  private

  def run_success(*arguments)
    output = StringIO.new
    error = StringIO.new
    status = LearnCLI.run(arguments, out: output, err: error)
    assert_equal 0, status, error.string
    JSON.parse(output.string)
  end

  def write_empty_model(directory)
    model = {"schema_version"  => LearnedPlayer::MODEL_SCHEMA_VERSION,
             "feature_version" => ActionFeatures::VERSION,
             "feature_names"   => ActionFeatures::NAMES,
             "weights"         => ActionFeatures::NAMES.to_h {|name| [name, 0.0] }}
    path = File.join(directory, "model.json")
    File.write(path, JSON.generate(model))
    path
  end

  def write_completed_trace(directory)
    episode = GameSimulator.run(seed: 11, strategy: :first_fit)
    board = GameSimulator.initial_board(seed: 11)
    log = GameLog.new(seed: 11, board: board, mode: "auto", directory: directory)
    next_offer = 1
    episode.moves.each do |move|
      batch_exhausted = board.options.size == 1
      log.move(move.fetch(:tile), move.fetch(:option), move.fetch(:row), move.fetch(:col))
      raise "unexpected illegal fixture move" unless board.play(move.fetch(:option), move.fetch(:row),
                                                                move.fetch(:col), deal: false)

      next unless batch_exhausted

      names = episode.offers.fetch(next_offer)
      board.replace_options(names.map {|name| Tile.fetch(name) })
      log.deal(board.options)
      next_offer += 1
    end
    log.finish(reason: "game_over", score: board.score)
    log.path
  end
end
