# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require "rbconfig"
require_relative "../lib/lesson_analyzer"
require_relative "../lib/game_log"
require_relative "../lib/offer_replay"

class LessonStoreTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/lesson-search-v3.json", __dir__)

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
                                                strategy:            :first_fit)

      assert_equal original, File.binread(path)
      assert_equal "no_improvement", lesson.fetch(:outcome)
      assert_equal lesson.fetch(:actual_score), LessonStore.replay(lesson, "actual_sequence").score
      assert_equal lesson.fetch(:candidate_score), LessonStore.replay(lesson, "candidate_sequence").score
    end
  end

  def test_analyzer_lesson_is_byte_identical_with_a_slower_clock
    Dir.mktmpdir do |directory|
      path = write_completed_trace(directory)
      analyzer = LessonAnalyzer.new
      fast_clock = ticking_clock(0.0001)
      slow_clock = ticking_clock(0.01)
      options = {time_budget_seconds: 1_000, beam_width: 4, max_states: 60,
                 max_rollouts: 4, strategy: :first_fit}

      fast_lesson = analyzer.analyze(path, **options, clock: fast_clock)
      slow_lesson = analyzer.analyze(path, **options, clock: slow_clock)

      assert_equal JSON.generate(fast_lesson), JSON.generate(slow_lesson)
      assert_equal 4, fast_lesson.dig(:search, :max_rollouts)
      assert_equal fast_lesson.dig(:search, :explored_rollouts), slow_lesson.dig(:search, :explored_rollouts)
      refute fast_lesson.fetch(:search).key?(:elapsed_seconds)
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

  # Both insertion orders must converge on the stronger, replayable lesson.
  # rubocop:disable Metrics/MethodLength
  def test_reanalysis_keeps_the_strongest_result_and_deduplicates_provenance
    [false, true].each do |reverse|
      Dir.mktmpdir do |directory|
        store = LessonStore.new(directory: directory)
        strong = improved_lesson
        weak = Marshal.load(Marshal.dump(strong))
        weak[:candidate_sequence] = weak[:actual_sequence]
        weak[:candidate_score] = weak[:actual_score]
        weak[:improvement_delta] = 0
        weak[:outcome] = "no_improvement"
        weak[:search][:status] = "no improvement found within budget"
        lessons = reverse ? [strong, weak] : [weak, strong]
        lessons.each {|lesson| store.save(lesson) }
        result = store.save(strong)
        saved = LessonStore.read(result.fetch(:path))

        assert result.fetch(:deduplicated)
        assert_equal 5, saved.fetch("candidate_score")
        assert_equal 4, saved.fetch("improvement_delta")
        assert_equal "improved", saved.dig("search", "status")
        assert_equal 1, saved.fetch("provenance").size
        assert_equal 5, LessonStore.replay(saved, "candidate_sequence").score
        assert_equal 1, Dir[File.join(directory, "*.json")].size
      end
    end
  end

  def test_complete_and_partial_analyses_are_preserved_separately
    Dir.mktmpdir do |directory|
      store = LessonStore.new(directory: directory)
      complete = improved_lesson
      partial = Marshal.load(Marshal.dump(complete))
      partial[:candidate_sequence] = [{tile: "sq2", option: 1, row: 4, col: 4}]
      partial[:candidate_score] = 4
      partial[:improvement_delta] = 3
      partial[:search][:candidate_complete] = false
      paths = [store.save(complete), store.save(partial)].map {|result| result.fetch(:path) }

      assert_equal 2, paths.uniq.size
      assert_equal([true, false], paths.map {|path| LessonStore.read(path).dig("search", "candidate_complete") })
      assert_equal([5, 4], paths.map {|path| LessonStore.read(path).fetch("candidate_score") })
    end
  end

  def test_old_search_version_cannot_absorb_a_current_analysis
    Dir.mktmpdir do |directory|
      store = LessonStore.new(directory: directory)
      lesson = improved_lesson
      old = Marshal.load(Marshal.dump(lesson))
      old[:search][:version] = ImprovementSearch::VERSION - 1
      payload = JSON.parse(JSON.generate(old))
      payload["state_fingerprint"] = store.send(:identity_for, old)
      old_path = File.join(directory, "old.json")
      File.write(old_path, JSON.generate(payload))
      before = File.binread(old_path)

      result = store.save(lesson)
      refute result.fetch(:deduplicated)
      refute_equal old_path, result.fetch(:path)
      assert_equal before, File.binread(old_path)
    end
  end
  # rubocop:enable Metrics/MethodLength

  def test_analyzer_rejects_non_game_over_trace
    Dir.mktmpdir do |directory|
      board = Board1010.new(options: [Tile.fetch(:dot)])
      log = GameLog.new(seed: 1, board: board, mode: "test", directory: directory)
      log.finish(reason: "stopped", score: 0)

      error = assert_raises(ArgumentError) { LessonAnalyzer.new.analyze(log.path) }
      assert_match "only Game Over episodes", error.message
    end
  end

  private

  # One stranded dot versus a dot outside the only available 2x2 pocket.
  def improved_lesson
    cells = Array.new(10) { Array.new(10, 1) }
    holes = [[0, 0], [1, 2], [2, 6], [3, 8], [4, 0], [4, 4], [4, 5], [5, 4], [5, 5],
             [6, 1], [7, 3], [8, 7], [9, 9]]
    holes.each {|row, col| cells[row][col] = 0 }
    offers = [%w[dot sq2 sq3]]
    {schema_version: LessonStore::SCHEMA_VERSION, versions: LessonStore.versions,
     source_episode: {seed: 1_000_000, seed_kind: "root"},
     initial_state: {cells: cells, tile_ids: cells, score: 0, options: offers.first}, offers: offers,
     actual_sequence: [{tile: "dot", option: 0, row: 4, col: 4}], actual_score: 1,
     candidate_sequence: [{tile: "dot", option: 0, row: 4, col: 0}, {tile: "sq2", option: 0, row: 4, col: 4}],
     candidate_score: 5, improvement_delta: 4, outcome: "improved",
     search: {version: ImprovementSearch::VERSION, status: "improved", candidate_complete: true},
     provenance: [{path: "example", seed: 1_000_000}]}
  end

  def write_completed_trace(directory)
    episode = GameSimulator.run(seed: 11, strategy: :first_fit)
    board = GameSimulator.initial_board(seed: 11)
    log = GameLog.new(seed: 11, board: board, mode: "auto", directory: directory)
    replay = OfferReplay.new(board: board, offers: episode.offers)

    episode.moves.each do |move|
      batch_exhausted = replay.board.options.size == 1
      log.move(move.fetch(:tile), move.fetch(:option), move.fetch(:row), move.fetch(:col))
      replay.apply(move)
      log.deal(replay.board.options) if batch_exhausted
    end
    board = replay.finish!(expected_score: episode.score)
    log.finish(reason: "game_over", score: board.score)
    log.path
  end

  def ticking_clock(increment)
    time = 0.0
    -> { time += increment }
  end
end
