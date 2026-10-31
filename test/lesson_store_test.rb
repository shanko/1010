# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require "rbconfig"
require_relative "../lesson_analyzer"
require_relative "../game_log"

class LessonStoreTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/lesson-v1.json", __dir__)

  def test_fixture_loads_and_both_sequences_replay
    lesson = LessonStore.read(FIXTURE)

    actual = LessonStore.replay(lesson, "actual_sequence")
    candidate = LessonStore.replay(lesson, "candidate_sequence")

    assert_equal lesson.fetch("actual_score"), actual.score
    assert_equal lesson.fetch("candidate_score"), candidate.score
    assert_equal "no_improvement", lesson.fetch("outcome")
  end

  def test_analyzer_creates_replayable_lesson_without_modifying_source
    Dir.mktmpdir do |directory|
      path = write_completed_trace(directory)
      original = File.binread(path)
      lesson = LessonAnalyzer.new.analyze(path, time_budget_seconds: 0,
                                          strategy: :first_fit)

      assert_equal original, File.binread(path)
      assert_equal "no_improvement", lesson.fetch(:outcome)
      assert_equal lesson.fetch(:actual_score), LessonStore.replay(lesson, "actual_sequence").score
      assert_equal lesson.fetch(:candidate_score), LessonStore.replay(lesson, "candidate_sequence").score
    end
  end

  def test_store_deduplicates_identical_states_and_retains_new_provenance
    Dir.mktmpdir do |directory|
      lesson = LessonStore.read(FIXTURE).transform_keys(&:to_sym)
      store = LessonStore.new(directory: directory)
      first = store.save(lesson)
      duplicate = Marshal.load(Marshal.dump(lesson))
      duplicate[:provenance] = [{path: "second.moves", sha256: "second", seed: 8}]
      second = store.save(duplicate)
      saved = LessonStore.read(second.fetch(:path))

      refute first.fetch(:deduplicated)
      assert second.fetch(:deduplicated)
      assert_equal 2, saved.fetch("provenance").size
      assert_equal 1, Dir.glob(File.join(directory, "*.json")).size
    end
  end

  def test_cli_analyzes_trace_and_saves_a_lesson
    Dir.mktmpdir do |directory|
      path = write_completed_trace(directory)
      output_directory = File.join(directory, "lessons")
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "scripts/learn.rb", "analyze", path,
                                               "--budget", "0", "--strategy", "first_fit",
                                               "--output", output_directory)
      assert status.success?, stderr
      summary = JSON.parse(stdout)
      assert_equal "no_improvement", summary.fetch("outcome")
      assert File.file?(summary.fetch("lesson"))
    end
  end

  def test_analyzer_rejects_non_game_over_trace
    Dir.mktmpdir do |directory|
      board = Board1010.new(options: [Board1010::TILES[:dot]])
      log = GameLog.new(seed: 1, board: board, mode: "test", directory: directory)
      log.finish(reason: "stopped", score: 0)

      error = assert_raises(ArgumentError) { LessonAnalyzer.new.analyze(log.path) }
      assert_match "only Game Over episodes", error.message
    end
  end

  private

  def write_completed_trace(directory)
    episode = GameSimulator.run(seed: 11, strategy: :first_fit)
    board = GameSimulator.initial_board(seed: 11)
    log = GameLog.new(seed: 11, board: board, mode: "auto", directory: directory)
    next_offer = 1

    episode.moves.each do |move|
      batch_exhausted = board.options.size == 1
      log.move(move.fetch(:tile), move.fetch(:option), move.fetch(:row), move.fetch(:col))
      raise "unexpected illegal fixture move" unless board.play(move.fetch(:option), move.fetch(:row), move.fetch(:col), deal: false)
      if batch_exhausted
        names = episode.offers.fetch(next_offer)
        board.replace_options(names.map {|name| Board1010::TILES.fetch(name) })
        log.deal(board.options)
        next_offer += 1
      end
    end
    log.finish(reason: "game_over", score: board.score)
    log.path
  end
end
