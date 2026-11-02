# frozen_string_literal: true

require_relative "game_options"
require_relative "game_session"

# Plays auto games without a window, animation or pauses. Each game is logged
# and uses the same seed stream as the window, so `--seed` repeats its games.
class HeadlessGame
  # A saved game belongs to the human player. Starting from one would also stop
  # `--seed` from repeating the same games, so headless play never reads it.
  class NoSaveStore
    def exist?
      false
    end
  end

  def self.main(argv, output: $stdout, errors: $stderr)
    options = GameOptions.parse(argv)
    new(**options.slice(:games, :strategy, :seed, :model), output: output).run
    0
  rescue ArgumentError, SystemCallError => e
    errors.puts "1010: #{e.message}"
    errors.puts GameOptions::USAGE
    2
  rescue Interrupt
    130
  end

  def initialize(games: 1, strategy: AutoPlayer::DEFAULT_STRATEGY, seed: nil, model: nil,
                 log_directory: GameLog::DIRECTORY, output: $stdout)
    @games = games
    @strategy = strategy
    @seed = seed
    @model = model
    @log_directory = log_directory
    @output = output
    @scores = []
  end

  def run
    started = monotonic_seconds
    session = GameSession.new(auto: true, strategy: @strategy, seed: @seed, model: @model,
                              save_store: NoSaveStore.new, log_directory: @log_directory)
    begin
      play_games(session)
      @scores
    ensure
      session.finish
      report_total(session, monotonic_seconds - started)
    end
  end

  private

  def play_games(session)
    @games.times do |index|
      session.new_game unless index.zero?
      play_to_game_over(session)
      @scores << session.board.score
      @output.puts "Game #{index + 1}: score #{session.board.score}, #{session.move_count} moves, " \
                   "seed #{session.seed}, log #{session.game_log.path}"
      @output.flush
    end
  end

  def play_to_game_over(session)
    until session.game_over
      raise "#{session.strategy} did not make a legal move (seed #{session.seed})" unless session.auto_move
    end
  end

  def report_total(session, seconds)
    return if @scores.empty?

    mean = @scores.sum.to_f / @scores.size
    @output.puts "#{@scores.size} of #{@games} games with #{session.strategy}: mean #{mean.round(2)}, " \
                 "min #{@scores.min}, max #{@scores.max}, #{seconds.round(2)} seconds"
  end

  def monotonic_seconds
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
