# frozen_string_literal: true

# Tracks auto-mode game timing without depending on Gosu.
class AutoRunTracker
  attr_reader :run_count, :completed_count, :unfinished_count, :max_score,
              :max_score_run, :last_duration_seconds

  def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0 })
    @clock = clock
    @run_count = @completed_count = @unfinished_count = 0
    @max_score = @max_score_run = nil
    @active_run = nil
    @first_started_at = @last_ended_at = nil
    @last_duration_seconds = nil
  end

  def active?
    !@active_run.nil?
  end

  def any_runs?
    @run_count.positive?
  end

  def start_run(at_ms: @clock.call)
    raise RuntimeError, "an auto run is already active" if active?

    @run_count += 1
    @first_started_at ||= Float(at_ms)
    @active_run = {number: @run_count, started_at: Float(at_ms)}
    @active_run[:number]
  end

  def finish_run(score:, status: :completed, at_ms: @clock.call)
    return nil unless active?
    raise ArgumentError, "status must be completed, unfinished, or stopped" unless %i[completed unfinished stopped].include?(status.to_sym)

    ended_at = Float(at_ms)
    duration = [ended_at - @active_run.fetch(:started_at), 0.0].max / 1000.0
    number = @active_run.fetch(:number)
    score = Integer(score)
    new_max = false
    if status.to_sym == :completed
      @completed_count += 1
      if @max_score.nil? || score > @max_score
        @max_score = score
        @max_score_run = number
        new_max = true
      end
    else
      @unfinished_count += 1
    end
    @last_duration_seconds = duration
    @last_ended_at = ended_at
    @active_run = nil
    suffix = new_max ? "  new max" : ""
    suffix += "  #{status}" unless status.to_sym == :completed
    "Run #{number}   score #{score}   time #{format('%.1f', duration)}s#{suffix}"
  end

  def summary(at_ms: nil)
    return nil unless any_runs?

    ended_at = @active_run ? Float(at_ms || @clock.call) : @last_ended_at
    total = [ended_at - @first_started_at, 0.0].max / 1000.0
    maximum = @max_score.nil? ? "none" : "#{@max_score} (run #{@max_score_run})"
    ["Runs: #{@completed_count} completed, #{@unfinished_count} unfinished   Max score: #{maximum}",
     format("Total time: %.1fs", total)].join("\n")
  end
end
