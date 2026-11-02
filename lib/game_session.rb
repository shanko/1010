# frozen_string_literal: true

require_relative "board"
require_relative "auto_player"
require_relative "game_log"
require_relative "game_trace"
require_relative "auto_run_tracker"

# The rules and durable state for one or more games. This class has no Gosu
# dependency; a window or terminal front end supplies time and presentation.
class GameSession
  AUTO_RESTART_MS = 500
  DEFAULT_REPLAY_DELAY_SECONDS = 0.5

  class SaveStore
    def initialize(path: Board1010::SAVE_FILE)
      @path = path
    end

    def exist?
      File.exist?(@path)
    end

    def read
      File.read(@path)
    end

    def write(value)
      File.write(@path, value)
    end

    def delete
      File.delete(@path)
    end
  end

  attr_reader :board, :previous_board, :auto, :game_over, :ended_at,
              :game_log, :recording, :last_recording_path, :offer_replay,
              :playback, :playback_next_at, :auto_player, :auto_run_tracker,
              :seed, :strategy, :replay_delay_ms, :last_move, :initial_message, :move_count

  def initialize(auto: false, strategy: AutoPlayer::DEFAULT_STRATEGY, seed: nil,
                 replay_file: nil, replay_delay: DEFAULT_REPLAY_DELAY_SECONDS, model: nil, games: nil,
                 clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0 },
                 save_store: SaveStore.new, log_directory: GameLog::DIRECTORY,
                 logger_factory: ->(**options) { GameLog.new(**options) })
    @games = games
    initialize_dependencies(clock, save_store, log_directory, logger_factory)
    initialize_policy(auto, strategy, seed, model)
    initialize_state(replay_delay)
    initialize_game(replay_file)
  end

  def initialize_dependencies(clock, save_store, log_directory, logger_factory)
    @clock = clock
    @save_store = save_store
    @logger_factory = logger_factory
    @log_directory = log_directory
  end

  def initialize_policy(auto, strategy, seed, model)
    @seeds = Random.new(seed || Random.new_seed)
    @strategy = strategy.to_sym
    @auto_player = AutoPlayer.new(@strategy, random: Random.new(@seeds.rand(2**32)), model: model)
    @auto = auto
    @auto_run_tracker = AutoRunTracker.new(clock: @clock)
  end

  def initialize_state(replay_delay)
    @recording = false
    @last_recording_path = nil
    @offer_replay = nil
    @playback = nil
    @replay_delay_ms = (Float(replay_delay) * 1000).round
    valid_delay = Float(replay_delay).finite? && @replay_delay_ms >= 0
    raise ArgumentError, "replay delay must be a finite non-negative number" unless valid_delay

    @started_at = @clock.call
  end

  def initialize_game(replay_file)
    if replay_file
      @auto = false
      start_trace_playback(GameTrace.read(replay_file), mode: "replay")
    else
      result = load_game
      @initial_message = result if %i[loaded damaged].include?(result)
      new_game unless @board
    end
  end

  def new_game(seed: @seeds.rand(2**32))
    board = Board1010.new(random: Random.new(seed))
    board.deal_if_needed
    start(board, seed: seed, mode: @auto ? "auto" : "window")
  end

  def start(board, seed: nil, mode: "window")
    finish_current_game
    @game_log = @logger_factory.call(seed: seed, board: board, mode: mode, directory: @log_directory)
    reset_board_state(board, seed)
    start_auto_run if @auto && !@auto_run_tracker.active?
    refresh_game_over
  end

  def finish_current_game
    finish_auto_run(score: @board.score, status: :stopped) if @auto_run_tracker.active?
    stop_recording
    return unless @game_log && @board

    @game_log.finish(reason: @game_over ? "game_over" : "new_game", score: @board.score)
    @last_recording_path = @game_log.path
  end

  def reset_board_state(board, seed)
    @board = board
    @seed = seed
    @previous_board = nil
    @last_move = nil
    @move_count = 0
    @playback_next_at = nil
    @playback = nil
    @offer_replay = nil
    @ended_at = nil
    @game_over = false
  end

  def refresh_game_over(now: @clock.call)
    was_game_over = @game_over
    @game_over = @board.game_over?
    @ended_at = @game_over ? (@ended_at || now) : nil
    finish_auto_run(score: @board.score) if @auto && @game_over && !was_game_over && @auto_run_tracker.active?
    @game_over
  end

  def place(index, row, col)
    @last_move = nil
    tile = @board.options[index]
    return nil unless tile && @board.fits?(tile, row, col)

    previous = @board.copy
    move = apply_placement(tile, index, row, col)
    return nil unless move

    @previous_board = previous
    @move_count += 1
    record_placement(previous, tile, index, row, col)
    @last_move = move
    refresh_game_over
    move
  end

  def apply_placement(tile, index, row, col)
    if @offer_replay
      @offer_replay.apply({tile: tile.name, option: index, row: row, col: col}, capture: true)
    else
      @board.play(index, row, col, capture: true)
    end
  end

  def record_placement(previous, tile, index, row, col)
    @game_log.move(tile.name, index, row, col)
    @game_log.deal(@board.options) if !@offer_replay && previous.options.size == 1
  end

  def undo
    return false unless @previous_board

    @board = @offer_replay ? @offer_replay.undo : @previous_board
    @previous_board = nil
    @move_count -= 1
    @last_move = nil
    @game_log.undo
    refresh_game_over
    true
  end

  def auto_move
    move = @auto_player.choose_move(@board)
    move && place(*move)
  end

  def tick(now: @clock.call)
    return playback_tick(now) if @playback
    return auto_step(now) if @auto

    nil
  end

  def auto_step(now)
    return auto_move unless @game_over
    return if auto_games_finished? || now < @ended_at + AUTO_RESTART_MS

    new_game
    :restarted
  end

  # True once auto mode has completed the requested number of games. Games
  # abandoned with N or by turning auto off do not count.
  def auto_games_finished?
    !@games.nil? && @auto_run_tracker.completed_count >= @games
  end

  def toggle_auto
    if @auto
      finish_auto_run(score: @board.score, status: :stopped) if @auto_run_tracker.active?
      @auto = false
    else
      @auto = true
      start_auto_run unless @game_over
    end
    @auto
  end

  def start_auto_run
    @auto_run_tracker.start_run
  end

  def finish_auto_run(score:, status: :completed)
    line = @auto_run_tracker.finish_run(score: score, status: status)
    @pending_run_line = line if line
    line
  end

  def take_auto_run_line
    line = @pending_run_line
    @pending_run_line = nil
    line
  end

  def toggle_recording
    return stop_recording if @recording

    new_game
    @recording = true
    :started
  end

  def stop_recording
    return unless @recording

    @last_recording_path = @game_log.path if @game_log
    @recording = false
    :stopped
  end

  def start_playback
    stop_recording
    path = @last_recording_path || @game_log&.path
    return :nothing_recorded unless path

    @game_log.finish(reason: @game_over ? "game_over" : "stopped", score: @board.score) if @game_log&.path == path
    start_trace_playback(GameTrace.read(path), mode: "playback")
    @auto = false
    :started
  end

  def start_trace_playback(trace, mode:)
    start(trace.starting_board.copy, seed: trace.seed, mode: mode)
    @playback = trace.events.dup
    @offer_replay = OfferReplay.new(board: @board, offers: trace.deal_batches)
    :started
  end

  def playback_tick(now=@clock.call)
    return if @playback_next_at && now < @playback_next_at

    event = @playback.shift
    process_playback_event(event, now)
  end

  def process_playback_event(event, now)
    case event&.first
    when :move then playback_move(event, now)
    when :deal then playback_deal(event)
    when :undo then playback_undo(now)
    when :end then finish_trace_playback(event)
    else
      clear_playback
    end
  end

  def playback_move(event, now)
    _type, tile_name, index, row, col = event
    play_back_move(tile_name, index, row, col)
    @playback_next_at = now + @replay_delay_ms
    @last_move
  end

  def playback_deal(event)
    play_back_deal(event[1])
    :deal
  end

  def playback_undo(now)
    undo
    @playback_next_at = now + @replay_delay_ms
    :undo
  end

  def finish_trace_playback(event)
    _type, reason, score = event
    @offer_replay.finish!(expected_score: score, require_all_offers: false)
    @game_log.finish(reason: reason, score: score)
    clear_playback
  end

  def clear_playback
    @playback = nil
    @offer_replay = nil
    :finished
  end

  def play_back_move(tile_name, index, row, col)
    offered = @board.options[index]&.name
    unless offered == tile_name
      raise ArgumentError, "replay expected #{tile_name.inspect} at option #{index}, found #{offered.inspect}"
    end

    move = place(index, row, col)
    raise ArgumentError, "replay move is not legal" unless move

    play_back_deal(@playback.shift[1]) if @playback.first&.first == :deal
    move
  end

  def play_back_deal(tiles)
    @offer_replay.feed_deal(tiles)
    @game_log.deal(tiles)
    refresh_game_over
  end

  def save_game
    return :disabled_auto if @auto
    return :disabled_playback if @playback

    @save_store.write(@board.to_save)
    :saved
  rescue SystemCallError => e
    [:failed, e]
  end

  def load_game
    return :missing unless @save_store.exist?

    board = Board1010.from_save(@save_store.read)
    return :damaged unless board

    board.deal_if_needed
    start(board)
    :loaded
  end

  def saving_disabled?
    @auto || @playback
  end

  def delete_save
    return :disabled if saving_disabled?
    return :missing unless @save_store.exist?

    @save_store.delete
    :deleted
  rescue SystemCallError => e
    [:failed, e]
  end

  def quit(save:)
    result = save ? save_game : delete_save
    finish
    result
  end

  def finish(status: nil)
    return @summary if @finished

    finish_auto_run(score: @board.score, status: status || :unfinished) if @auto_run_tracker.active?
    @game_log&.finish(reason: @game_over ? "game_over" : "quit", score: @board.score)
    @summary = if @auto_run_tracker.any_runs?
                 @auto_run_tracker.summary
               else
                 "Total time played = #{play_seconds} seconds\nTotal moves = #{@move_count}\nScore = #{@board.score}"
               end
    @finished = true
    @summary
  end

  def play_seconds(now: @clock.call)
    (now - @started_at) / 1000
  end
end
