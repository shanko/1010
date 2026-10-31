# frozen_string_literal: true

require "minitest/autorun"
require_relative "../auto_run_tracker"

class AutoRunTrackerTest < Minitest::Test
  def setup
    @now = 0.0
    @tracker = AutoRunTracker.new(clock: -> { @now })
  end

  def test_run_duration_excludes_pause_but_total_includes_it
    @tracker.start_run
    @now = 12_400
    assert_match "time 12.4s  new max", @tracker.finish_run(score: 78)
    @now = 12_900 # 500 ms restart pause
    @tracker.start_run
    @now = 22_700
    assert_includes @tracker.finish_run(score: 66), "9.8s"

    assert_equal 2, @tracker.completed_count
    assert_equal 78, @tracker.max_score
    assert_equal 1, @tracker.max_score_run
    assert_equal "Runs: 2 completed, 0 unfinished   Max score: 78 (run 1)\nTotal time: 22.7s", @tracker.summary
  end

  def test_quit_reports_an_unfinished_run_without_counting_it_as_a_max
    @tracker.start_run
    @now = 4_250
    assert_match "unfinished", @tracker.finish_run(score: 500, status: :unfinished)

    assert_equal 0, @tracker.completed_count
    assert_equal 1, @tracker.unfinished_count
    assert_nil @tracker.max_score
    assert_match "Runs: 0 completed, 1 unfinished", @tracker.summary
  end

  def test_stopping_and_restarting_auto_mode_keeps_run_number_and_total_span
    @tracker.start_run
    @now = 3_000
    @tracker.finish_run(score: 10, status: :stopped)
    @now = 8_000
    assert_equal 2, @tracker.start_run
    @now = 10_000
    @tracker.finish_run(score: 20)

    assert_equal 2, @tracker.run_count
    assert_equal 1, @tracker.completed_count
    assert_equal 1, @tracker.unfinished_count
    assert_equal 2.0, @tracker.last_duration_seconds
    assert_match "Total time: 10.0s", @tracker.summary
  end

  def test_rejects_nested_runs_and_unknown_statuses
    @tracker.start_run
    assert_raises(RuntimeError) { @tracker.start_run }
    assert_raises(ArgumentError) { @tracker.finish_run(score: 0, status: :paused) }
  end
end
