# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../lib/learn_cli"
require_relative "../lib/game_log"
require_relative "../lib/offer_replay"
require_relative "../lib/game_session"

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength

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
      lesson_directory = File.join(directory, LessonStore::DIRECTORY)
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
      assert_equal 0, result.fetch("improvements_saved")
      assert_equal 0, result.fetch("usable_lessons")
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

  def test_improve_command_writes_a_deterministic_replayable_trace_and_cost_report
    Dir.mktmpdir do |directory|
      source_path = write_completed_trace(directory, seed: 1_000_000)
      output_path = File.join(directory, "improved.moves")
      report_path = File.join(directory, "improved.json")
      lesson_directory = File.join(directory, LessonStore::DIRECTORY)
      arguments = ["improve", "--states", "500", "--time", "30", "--output", output_path,
                   "--report", report_path, "--save-lesson", source_path]

      output = StringIO.new
      error = StringIO.new
      status = Dir.chdir(directory) { LearnCLI.run(arguments, out: output, err: error) }
      assert_equal 0, status, error.string
      assert_match "Improved:", output.string
      assert_match "Costliest moves:", output.string

      source = GameTrace.read(source_path)
      improved = GameTrace.read(output_path)
      replayed = GameTrace.replay(improved)
      report = JSON.parse(File.read(report_path))
      assert_operator replayed.score, :>, source.final_score
      assert_equal source.deal_batches, improved.deal_batches.first(source.deal_batches.size)
      assert_equal true, report.fetch("seed_consistent")
      assert_operator report.fetch("seeded_offer_sets_used"), :>, 0
      assert_equal source.events.count {|event| event.first == :move }, report.fetch("per_move_estimates").size
      costs = report.fetch("costliest_moves").map {|entry| entry.fetch("estimated_cost") }
      assert_operator costs.size, :>, 0
      assert_equal costs.sort.reverse, costs, "costliest moves are listed most expensive first"

      lesson = LessonStore.read(Dir[File.join(lesson_directory, "*.json")].fetch(0))
      assert_equal source.final_score, lesson.fetch("actual_score")
      assert_equal improved.final_score, lesson.fetch("candidate_score")
      assert_equal improved.final_score - source.final_score, lesson.fetch("improvement_delta")
      assert ImitationTrainer.new.complete_improvement?(lesson)
      assert ImitationTrainer.new.valid_complete_replay?(lesson)
      assert_equal "dealer", lesson.dig("source_episode", "seed_kind")
      assert_operator lesson.fetch("candidate_offers").size, :>, lesson.fetch("actual_offers").size

      trace_before = File.binread(output_path)
      report_before = File.binread(report_path)
      status = Dir.chdir(directory) { LearnCLI.run(arguments, out: StringIO.new, err: error) }
      assert_equal 0, status, error.string
      assert_equal trace_before, File.binread(output_path)
      assert_equal report_before, File.binread(report_path)
      assert_equal 1, Dir.glob(File.join(lesson_directory, "*.json")).size
    end
  end

  def test_improve_reports_seed_validation_failures_and_rejects_quit_traces
    Dir.mktmpdir do |directory|
      source_path = write_completed_trace(directory, seed: 1_000_000)
      lines = File.readlines(source_path)
      offer_index = lines.index {|line| line.start_with?("d") }
      offer_names = BoardSnapshot.decode_offer(lines[offer_index].strip).map(&:name)
      offer_names[0] = (Tile::NAMES - offer_names).first
      lines[offer_index] = "#{BoardSnapshot.offer_record(offer_names.map {|name| Tile.fetch(name) })}\n"
      File.write(source_path, lines.join)

      result = GameImprover.new.validate_seed(GameTrace.read(source_path))
      assert_equal false, result.fetch(:consistent)
      assert_match "initial offer differs", result.fetch(:reason)

      quit_path = File.join(directory, "quit.moves")
      File.write(quit_path, lines.join.sub(/zgame_over\|\d+/, "zquit|0"))
      error = assert_raises(ArgumentError) do
        GameImprover.new.improve(quit_path, states: 10, output_path: File.join(directory, "quit-improved.moves"))
      end
      assert_match "only Game Over traces can be improved", error.message
    end
  end

  def test_improve_uses_the_final_trajectory_after_an_undo_crossing_a_deal
    Dir.mktmpdir do |directory|
      source_path = write_undo_across_deal_trace(directory)
      source = GameTrace.read(source_path)
      baseline = LessonAnalyzer.new.final_trajectory(source)
      assert_equal source.deal_batches.size - 1, baseline.fetch(:offers).size

      output_path = File.join(directory, "undo-improved.moves")
      report_path = File.join(directory, "undo-report.json")
      result = GameImprover.new.improve(source_path, states: 25, time_budget_seconds: 15,
                                        output_path: output_path, report_path: report_path)
      improved = GameTrace.read(result.trace_path)
      replayed = GameTrace.replay(improved)
      report = JSON.parse(File.read(report_path))

      assert_operator replayed.score, :>=, source.final_score
      assert_equal baseline.fetch(:offers).map {|batch| batch.map(&:to_s) },
                   improved.deal_batches.first(baseline.fetch(:offers).size)
      assert_equal 0, report.fetch("seeded_offer_sets_used")
      assert_equal false, report.fetch("seed_consistent")
      assert_match "no seed", report.fetch("seed_consistency_reason")
    end
  end

  def test_seed_validation_restores_dealer_state_when_a_deal_is_undone
    Dir.mktmpdir do |directory|
      source_path = write_completed_trace(directory, seed: 1_000_000)
      lines = File.readlines(source_path)
      move_indexes = lines.each_index.select {|index| lines[index].match?(/\Am[a-z0-9]+,/) }
      deal_indexes = lines.each_index.select {|index| lines[index].start_with?("d") }
      last_move = lines.fetch(move_indexes.fetch(2))
      deal_line = lines.fetch(deal_indexes.fetch(1))
      lines.insert(deal_indexes.fetch(1) + 1, "u\n", last_move, deal_line)
      undone_path = File.join(directory, "undone.moves")
      File.write(undone_path, lines.join)
      trace = GameTrace.read(undone_path)
      baseline = LessonAnalyzer.new.final_trajectory(trace)

      assert_equal true, GameImprover.new.validate_seed(trace).fetch(:consistent)
      assert_equal trace.deal_batches.size - 1, baseline.fetch(:offers).size

      result = GameImprover.new.improve(undone_path, states: 100, time_budget_seconds: 30,
                                        output_path: File.join(directory, "undone-improved.moves"))
      assert_equal true, result.report.fetch(:seed_consistent)
      assert_operator GameTrace.replay(GameTrace.read(result.trace_path)).score, :>=, trace.final_score
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

  # Records a game the way auto mode does: GameSession deals from
  # Random.new(seed) and writes that board seed into the trace.
  def write_completed_trace(directory, seed: 11)
    session = GameSession.new(auto: true, strategy: :first_fit, seed: 0, log_directory: directory,
                              save_store: GameSession::SaveStore.new(path: File.join(directory, "save.txt")),
                              clock: -> { 0 })
    session.new_game(seed: seed)
    session.auto_move until session.game_over
    path = session.game_log.path
    session.finish
    path
  end

  def write_undo_across_deal_trace(directory)
    board = Board1010.new(options: [Tile.fetch(:dot)], random: Random.new(9))
    log = GameLog.new(seed: nil, board: board, mode: "test", directory: directory)
    player = AutoPlayer.new(:first_fit)

    previous = board.copy
    play_and_log(board, log, 0, 0, 0)
    log.deal(board.options)
    board = previous
    log.undo

    loop do
      break if board.game_over?

      option, row, col = player.choose_move(board)
      last_tile = board.options.size == 1
      play_and_log(board, log, option, row, col)
      log.deal(board.options) if last_tile
    end
    log.finish(reason: "game_over", score: board.score)
    log.path
  end

  def play_and_log(board, log, option, row, col)
    tile = board.options.fetch(option).name
    log.move(tile, option, row, col)
    raise "illegal test move" unless board.play(option, row, col)
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
