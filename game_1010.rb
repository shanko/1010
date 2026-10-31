# frozen_string_literal: true

# game_1010.rb: the Gosu window for 1010! (drawing and input).
#
#   ruby game_1010.rb                     you play (continues a saved game if there is one)
#   ruby game_1010.rb auto                the computer plays, game after game
#   ruby game_1010.rb auto sam --seed 42  pick the computer's strategy, and repeat the same games
#   ruby game_1010.rb auto learned --model learning_data/checkpoints/selected.json
#
# The rules live in board.rb, the computer player in auto_player.rb and the
# move animation in move_animation.rb. This file only reads input, updates
# what is on screen and draws.
require "gosu"
require_relative "board"
require_relative "auto_player"
require_relative "move_animation"
require_relative "game_log"
require_relative "game_trace"
require_relative "auto_run_tracker"

class GameWindow < Gosu::Window
  # --- Layout (pixels) --------------------------------------------------------

  WIDTH  = 480
  HEIGHT = 480

  CELL_SIZE    = 32
  CELL_GAP     = 2
  CELL_PITCH   = CELL_SIZE + CELL_GAP                # from one square to the next
  CELL_CORNER  = 4                                   # size of the clipped corners
  BOARD_PIXELS = (Board1010::COLS * CELL_PITCH) + 1  # 341
  BORDER       = 5                                   # the gray edge right of and below the board

  OPTION_X           = 360 # the 3 tiles to choose from, stacked on the right
  OPTION_W           = 120
  OPTION_TOP         = 20
  OPTION_HEIGHT      = 105
  OPTION_CELL_SIZE   = 16
  OPTION_CELL_GAP    = 1
  OPTION_CORNER      = 2
  OPTION_LINE_ABOVE  = 10  # the blue line above each option
  OPTION_LINE_LENGTH = 100

  TEXT_X           = 20
  SCORE_Y          = 360
  STATUS_Y         = 390
  MESSAGE_Y        = 425
  RECORDING_MARK_Y = 455
  HELP_X           = 330
  HELP_Y           = 270
  HELP_LINE_HEIGHT = 18

  Z_BACKGROUND = 0
  Z_CELLS      = 1
  Z_DRAGGED    = 2
  Z_TEXT       = 3
  Z_HELP       = 4

  # --- Timing (milliseconds) --------------------------------------------------

  MESSAGE_MS      = 2000 # how long messages like "Game saved" stay up
  AUTO_RESTART_MS = 500  # how long auto mode shows "Game Over!" before the next game
  BLINK_MS        = 250  # how fast the recording mark blinks
  REPLAY_DELAY_SECONDS = 0.5

  # --- Colors -----------------------------------------------------------------

  # Gosu::Color.argb takes 0xAARRGGBB: alpha (opacity) first, then red, green, blue.
  COLORS = {
    background:    Gosu::Color::WHITE,
    border:        Gosu::Color::GRAY,
    empty:         Gosu::Color.argb(0x3e_79_da_6d), # pale green
    selected:      Gosu::Color::YELLOW,
    hint:          Gosu::Color.argb(0xde_d9_11_98), # magenta
    text:          Gosu::Color::RED,
    option_line:   Gosu::Color::BLUE,
    help_backdrop: Gosu::Color.argb(0xf0_ff_ff_ff)  # almost opaque white
  }.freeze

  # One opaque color for each of the 19 tile shapes, in Board1010::TILE_NAMES order.
  TILE_PALETTE = [
    Gosu::Color.argb(0xff_20_9b_77), # dot: emerald
    Gosu::Color.argb(0xff_ff_9f_1c), # hl2: orange
    Gosu::Color.argb(0xff_83_38_ec), # hl3: purple
    Gosu::Color.argb(0xff_3a_86_ff), # hl4: blue
    Gosu::Color.argb(0xff_e6_39_46), # hl5: red
    Gosu::Color.argb(0xff_00_b4_d8), # vl2: cyan
    Gosu::Color.argb(0xff_9c_66_44), # vl3: brown
    Gosu::Color.argb(0xff_70_e0_00), # vl4: lime
    Gosu::Color.argb(0xff_ff_be_0b), # vl5: amber
    Gosu::Color.argb(0xff_43_61_ee), # sq2: indigo
    Gosu::Color.argb(0xff_b5_17_9e), # sq3: fuchsia
    Gosu::Color.argb(0xff_fb_56_07), # bl2: vermilion
    Gosu::Color.argb(0xff_57_75_90), # bl3: slate blue
    Gosu::Color.argb(0xff_a7_c9_57), # tl2: yellow green
    Gosu::Color.argb(0xff_2e_c4_b6), # tl3: turquoise
    Gosu::Color.argb(0xff_d8_11_59), # br2: crimson
    Gosu::Color.argb(0xff_4c_c9_f0), # br3: sky blue
    Gosu::Color.argb(0xff_8a_c9_26), # tr2: leaf green
    Gosu::Color.argb(0xff_c7_7d_ff)  # tr3: lilac
  ].freeze
  TILE_COLORS = Board1010::TILE_NAMES.each_with_index.to_h do |name, index|
    [Tile.fetch(name).id, TILE_PALETTE[index]]
  end.freeze

  HELP_LINES = [
    "Drag a tile onto the board,",
    "or pick one (click or 1/2/3)",
    "and click a square.",
    "O (hold): show best position",
    "U: undo       N: new game",
    "A: auto play  E: one auto move",
    "S: save       Q: save and quit",
    "R: record     P: play recording",
    "C: print positions (terminal)",
    "ESC: quit, delete the save"
  ].freeze

  # Keys that work at any time, and the method each one calls.
  KEY_ACTIONS = {
    Gosu::KB_ESCAPE => :quit_without_saving,
    Gosu::KB_Q      => :save_and_quit,
    Gosu::KB_A      => :toggle_auto,
    Gosu::KB_N      => :new_game,
    Gosu::KB_S      => :save_game,
    Gosu::KB_R      => :toggle_recording,
    Gosu::KB_P      => :start_playback,
    Gosu::KB_C      => :print_positions
  }.freeze

  # Keys and clicks that make moves, ignored while the computer or a playback is playing.
  PLAYER_ACTIONS = {
    Gosu::KB_E    => :auto_move, # let the computer make one move
    Gosu::KB_U    => :undo,
    Gosu::MS_LEFT => :start_drag
  }.freeze

  OPTION_KEYS = {Gosu::KB_1 => 0, Gosu::KB_2 => 1, Gosu::KB_3 => 2}.freeze

  # A recorded game: the seed that deals its tiles, and the moves and undos made.
  def initialize(auto: false, strategy: AutoPlayer::DEFAULT_STRATEGY, seed: nil, replay_file: nil,
                 replay_delay: REPLAY_DELAY_SECONDS, model: nil)
    super(WIDTH, HEIGHT, fullscreen: false)
    self.caption = "1010!"
    @score_font = Gosu::Font.new(30)
    @small_font = Gosu::Font.new(20)

    # Every game's seed comes from here, so `--seed` repeats a whole session.
    @seeds       = Random.new(seed || Random.new_seed)
    @strategy = strategy.to_sym
    @auto_player = AutoPlayer.new(strategy, random: Random.new(@seeds.rand(2**32)), model: model)
    @auto        = auto
    @auto_run_tracker = AutoRunTracker.new(clock: -> { Gosu.milliseconds })
    @closing = false
    @auto_runs   = 0
    @max_score   = 0
    @recording   = false # visual marker; GameLog records every game to disk
    @last_recording_path = nil
    @offer_replay = nil
    @playback    = nil # events still to replay
    @replay_delay_ms = (Float(replay_delay) * 1000).round
    raise ArgumentError, "replay delay must be a finite non-negative number" unless
      @replay_delay_ms >= 0 && Float(replay_delay).finite?
    @message     = nil
    @opened_at   = Gosu.milliseconds # for the time played, over every game in this window
    self.caption = "1010!  Auto: #{@strategy}" if @auto

    if replay_file
      @auto = false
      start_trace_playback(GameTrace.read(replay_file), mode: "replay")
    else
      load_game unless @auto
      new_game unless @board
    end
  end

  def needs_cursor?
    true
  end

  # ---------------------------------------------------------------------------
  # Starting games
  # ---------------------------------------------------------------------------

  def new_game(seed: @seeds.rand(2**32))
    board = Board1010.new(random: Random.new(seed))
    board.deal_if_needed
    start(board, seed: seed, mode: @auto ? "auto" : "window")
  end

  # Everything that is reset when a game starts (new, loaded or played back).
  def start(board, seed: nil, mode: "window")
    if @auto_run_tracker&.active?
      finish_auto_run(score: @board.score, status: :stopped)
    end
    stop_recording
    if @game_log && @board
      @game_log.finish(reason: @game_over ? "game_over" : "new_game", score: @board.score)
      @last_recording_path = @game_log.path
    end
    @game_log = GameLog.new(seed: seed, board: board, mode: mode)
    @board          = board
    @seed           = seed  # nil for a loaded game, which can't be recorded
    @previous_board = nil   # for undo (one level, like the original)
    @selected       = nil   # index of the chosen option
    @dragging       = false
    @animation      = nil
    @playback_next_at = nil
    @playback = nil
    @offer_replay = nil
    @ended_at       = nil
    @game_over = false
    start_auto_run if @auto && @auto_run_tracker && !@auto_run_tracker.active?
    refresh_game_over
  end

  # Call after every change to the board. (Checking every frame would mean
  # trying every tile on every square 60 times a second.)
  def refresh_game_over
    was_game_over = @game_over
    @game_over = @board.game_over?
    @ended_at  = @game_over ? (@ended_at || Gosu.milliseconds) : nil
    if @auto && @game_over && !was_game_over && @auto_run_tracker&.active?
      finish_auto_run(score: @board.score)
    end
  end

  # ---------------------------------------------------------------------------
  # Moves
  # ---------------------------------------------------------------------------

  # Plays option `index` with its anchor on (row, col), for the player, the
  # computer and playback alike. Does nothing if the tile doesn't fit there.
  # During playback the replayer checks the move and supplies the recorded
  # offers, and play_back_next logs the recorded deal.
  def try_place(index, row, col)
    previous = @board.copy
    tile_name = previous.options[index].name
    move = if @offer_replay
             @offer_replay.apply({tile: tile_name, option: index, row: row, col: col}, capture: true)
           else
             @board.play(index, row, col, capture: true)
           end
    unless move
      @selected = nil
      return
    end

    @previous_board = previous
    @game_log.move(tile_name, index, row, col)
    @game_log.deal(@board.options) if !@offer_replay && previous.options.size == 1
    @selected  = nil
    clear_step = @auto ? MoveAnimation::PLACE_STEP_MS : MoveAnimation::CLEAR_STEP_MS
    @animation = MoveAnimation.new(move, Gosu.milliseconds, clear_step_ms: clear_step)
    refresh_game_over
  end

  def undo
    return show_message("Nothing to undo") unless @previous_board

    @board          = @offer_replay ? @offer_replay.undo : @previous_board
    @previous_board = nil
    @selected       = nil
    @animation      = nil
    @game_log.undo
    refresh_game_over
  end

  def auto_move
    move = @auto_player.choose_move(@board)
    try_place(*move) if move
  end

  def select_option(index)
    @selected = index if index < @board.options.size
  end

  # ---------------------------------------------------------------------------
  # The game loop
  # ---------------------------------------------------------------------------

  def update
    return if @closing

    now = Gosu.milliseconds
    expire_finished(now)
    return if @animation # let a move finish before the next automatic one

    if @playback
      play_back_next(now)
    elsif @auto
      auto_step(now)
    end
  end

  # Drops the move animation and the message once their time is up.
  def expire_finished(now)
    @animation = nil if @animation&.done?(now)
    @message   = nil if @message && now >= @message[:until]
  end

  def auto_step(now)
    return auto_move unless @game_over
    return if now < @ended_at + AUTO_RESTART_MS

    @auto_runs = @auto_run_tracker.run_count
    @max_score = @auto_run_tracker.max_score || 0
    update_auto_caption
    new_game
  end

  def toggle_auto
    if @auto
      finish_auto_run(score: @board.score, status: :stopped) if @auto_run_tracker.active?
      @auto = false
    else
      @auto = true
      start_auto_run unless @game_over
    end
    @selected = nil
    @dragging = false
    @auto ? update_auto_caption : self.caption = "1010!"
  end

  def print_auto_run(line)
    return unless line

    puts line
    update_auto_caption
  end

  def start_auto_run
    @auto_run_tracker.start_run
  end

  def finish_auto_run(score:, status: :completed)
    print_auto_run(@auto_run_tracker.finish_run(score: score, status: status))
  end

  def update_auto_caption
    return unless @auto_run_tracker

    last_time = @auto_run_tracker.last_duration_seconds
    timing = last_time ? "  Last: #{format('%.1fs', last_time)}" : ""
    self.caption = "1010!  Auto: #{@strategy}  Runs: #{@auto_run_tracker.completed_count}  Max Score: #{@auto_run_tracker.max_score || 0}#{timing}"
  end

  # ---------------------------------------------------------------------------
  # Recording and playback
  # ---------------------------------------------------------------------------

  # R starts recording a new game; pressing R again stops.
  def toggle_recording
    return stop_recording if @recording

    new_game
    @recording = true
    show_message("Recording a new game (R to stop)")
  end

  def stop_recording
    return unless @recording

    @last_recording_path = @game_log.path if @game_log
    @recording = false
    show_message("Recording stopped (P to play it back)")
  end

  # P replays the last game's durable trace instead of keeping duplicate events in memory.
  def start_playback
    stop_recording
    path = @last_recording_path || @game_log&.path
    return show_message("Nothing recorded yet (R to record)") unless path

    # The trace can only be read once it has its end record.
    @game_log.finish(reason: @game_over ? "game_over" : "stopped", score: @board.score) if @game_log&.path == path

    start_trace_playback(GameTrace.read(path), mode: "playback")
    @auto = false
    self.caption = "1010! (playback)"
  end

  def start_trace_playback(trace, mode:)
    start(trace.starting_board.copy, seed: trace.seed, mode: mode)
    @playback = trace.events
    @offer_replay = OfferReplay.new(board: @board, offers: trace.deal_batches)
  end

  def play_back_next(now = Gosu.milliseconds)
    return if @playback_next_at && now < @playback_next_at

    event = @playback.shift
    case event&.first
    when :move
      _type, tile_name, index, row, col = event
      play_back_move(tile_name, index, row, col)
      @playback_next_at = now + @replay_delay_ms
    when :deal
      play_back_deal(event[1])
    when :undo
      undo
      @playback_next_at = now + @replay_delay_ms
    when :end
      _type, reason, score = event
      @offer_replay.finish!(expected_score: score, require_all_offers: false)
      @game_log.finish(reason: reason, score: score)
      finish_playback
    else
      finish_playback
    end
  end

  # A move that empties its batch is followed by its deal record, which is
  # shown straight away rather than after the playback delay.
  def play_back_move(tile_name, index, row, col)
    offered = @board.options[index]&.name
    unless offered == tile_name
      raise ArgumentError, "replay expected #{tile_name.inspect} at option #{index}, found #{offered.inspect}"
    end

    try_place(index, row, col)
    play_back_deal(@playback.shift[1]) if @playback.first&.first == :deal
  end

  def play_back_deal(tiles)
    @offer_replay.feed_deal(tiles)
    @game_log.deal(tiles)
    refresh_game_over
  end

  # After playback the player continues from the replayed board.
  def finish_playback
    @playback = nil
    @offer_replay = nil
    self.caption = "1010!"
    show_message("Playback finished")
  end

  # ---------------------------------------------------------------------------
  # Saving
  # ---------------------------------------------------------------------------

  def save_game
    if saving_disabled?
      show_message(@auto ? "Saving is off in auto mode" : "Saving is off during playback")
      return
    end

    File.write(Board1010::SAVE_FILE, @board.to_save)
    show_message("Game saved")
  rescue SystemCallError => e
    show_message("Could not save: #{e.message}")
  end

  # Like the original, carry on with a saved game if there is one.
  def load_game
    return unless File.exist?(Board1010::SAVE_FILE)

    board = Board1010.from_save(File.read(Board1010::SAVE_FILE))
    return show_message("The save file is damaged") unless board

    board.deal_if_needed
    start(board)
    show_message("Loaded the saved game (N: new game)")
  end

  def show_message(text)
    @message = {text: text, until: Gosu.milliseconds + MESSAGE_MS}
    nil
  end

  def save_and_quit
    save_game unless saving_disabled?
    close
  end

  def saving_disabled?
    @auto || @playback
  end

  # Deletes the saved game too, so the next start is a new game.
  def quit_without_saving
    File.delete(Board1010::SAVE_FILE) if !saving_disabled? && File.exist?(Board1010::SAVE_FILE)
    close
  rescue SystemCallError => e
    puts "Could not delete #{Board1010::SAVE_FILE}: #{e.message}"
    close
  end

  # Called when the window closes (ESC, Q or the window's close button).
  def close
    return if @closing

    @closing = true
    if @auto_run_tracker&.active?
      finish_auto_run(score: @board.score, status: :unfinished)
    end
    @game_log&.finish(reason: @game_over ? "game_over" : "quit", score: @board.score)
    if @auto_run_tracker&.any_runs?
      puts @auto_run_tracker.summary
    else
      puts "Total time played = #{play_seconds} seconds"
      puts "Score = #{@board.score}"
    end
    super
  end

  # Since the window opened, like the original: in auto mode that covers every
  # game played, not just the one in progress.
  def play_seconds
    (Gosu.milliseconds - @opened_at) / 1000
  end

  # ---------------------------------------------------------------------------
  # Input
  # ---------------------------------------------------------------------------

  # Looks the key (or mouse button) up in KEY_ACTIONS, PLAYER_ACTIONS and OPTION_KEYS.
  def button_down(id)
    return send(KEY_ACTIONS[id]) if KEY_ACTIONS.key?(id)
    return if @auto || @playback

    if PLAYER_ACTIONS.key?(id)
      send(PLAYER_ACTIONS[id])
    elsif OPTION_KEYS.key?(id)
      select_option(OPTION_KEYS[id])
    end
  end

  # Two ways to place a tile, as before: drag it onto the board, or click it
  # (or press 1/2/3) and then click a square. Either way the tile is placed
  # when the mouse button is RELEASED over the board.
  def button_up(id)
    return unless id == Gosu::MS_LEFT

    @dragging = false
    return if @auto || @playback || @selected.nil?

    row, col = cell_under_mouse
    try_place(@selected, row, col) if row
  end

  def start_drag
    index = option_under_mouse
    return unless index

    @selected = index
    @dragging = true
  end

  # C: prints the first position where each option fits (for debugging).
  def print_positions
    @board.options.each_with_index do |tile, index|
      puts "Option #{index + 1} #{tile.inspect} fits first at #{@board.find_position(tile).inspect}"
    end
  end

  # ---------------------------------------------------------------------------
  # Screen geometry
  # ---------------------------------------------------------------------------

  def cell_x(col)
    CELL_GAP + (col * CELL_PITCH)
  end

  def cell_y(row)
    CELL_GAP + (row * CELL_PITCH)
  end

  # [row, col] of the board square under the mouse, or nil.
  def cell_under_mouse
    row = ((mouse_y - CELL_GAP) / CELL_PITCH).floor
    col = ((mouse_x - CELL_GAP) / CELL_PITCH).floor
    [row, col] if @board.inside?(row, col)
  end

  # Where option 0, 1 or 2 is drawn and can be clicked. Used for both, so
  # clicks and drawing can't disagree.
  def option_rect(index)
    {x: OPTION_X, y: OPTION_TOP + (index * OPTION_HEIGHT), w: OPTION_W, h: OPTION_HEIGHT}
  end

  def option_under_mouse
    @board.options.each_index.find do |index|
      rect = option_rect(index)
      mouse_x.between?(rect[:x], rect[:x] + rect[:w]) && mouse_y.between?(rect[:y], rect[:y] + rect[:h])
    end
  end

  # ---------------------------------------------------------------------------
  # Drawing (only draws: never changes the game)
  # ---------------------------------------------------------------------------

  def draw
    draw_background
    draw_board
    draw_options
    draw_dragged_tile
    draw_hint
    draw_status
    draw_recording_mark
    draw_help
  end

  def draw_background
    Gosu.draw_rect(0, 0, WIDTH, HEIGHT, COLORS[:background], Z_BACKGROUND)
    Gosu.draw_rect(BOARD_PIXELS, 0, BORDER, BOARD_PIXELS + BORDER, COLORS[:border], Z_BACKGROUND)
    Gosu.draw_rect(0, BOARD_PIXELS, BOARD_PIXELS, BORDER, COLORS[:border], Z_BACKGROUND)
  end

  def draw_board
    now = Gosu.milliseconds
    @board.cells.each_with_index do |values, row|
      values.each_with_index do |value, col|
        value = @animation.value_at(row, col, value, now) if @animation
        tile_id = @animation ? @animation.tile_id_at(row, col, @board.tile_ids[row][col], now) : @board.tile_ids[row][col]
        draw_square(cell_x(col), cell_y(row), CELL_SIZE, cell_color(value, tile_id))
      end
    end
  end

  def draw_options
    @board.options.each_with_index do |tile, index|
      rect   = option_rect(index)
      line_y = rect[:y] - OPTION_LINE_ABOVE
      Gosu.draw_line(rect[:x], line_y, COLORS[:option_line],
                     rect[:x] + OPTION_LINE_LENGTH, line_y, COLORS[:option_line], Z_CELLS)

      color = COLORS[:selected] if index == @selected # the original turned the selected tile yellow
      draw_tile(tile, rect[:x], rect[:y], size: OPTION_CELL_SIZE, gap: OPTION_CELL_GAP,
                                          corner: OPTION_CORNER, color: color)
    end
  end

  # While dragging, the tile follows the mouse with its anchor square at the pointer.
  def draw_dragged_tile
    return unless @dragging && @selected

    tile = @board.options[@selected]
    x = mouse_x - (tile.anchor * CELL_PITCH)
    draw_tile(tile, x, mouse_y, size: CELL_SIZE, gap: CELL_GAP, corner: CELL_CORNER, z: Z_DRAGGED)
  end

  # While O is held: the square where the computer would put the selected tile's anchor.
  def draw_hint
    return unless @selected && Gosu.button_down?(Gosu::KB_O)

    row, col = hint_position
    draw_square(cell_x(col), cell_y(row), CELL_SIZE, COLORS[:hint]) if row
  end

  def hint_position
    tile = @board.options[@selected]
    key = [@board.object_id, @board.score, @selected, tile]
    if @hint_cache_key != key
      @hint_cache_key = key
      @hint_cache_value = @auto_player.best_position(@board, tile)
    end
    @hint_cache_value
  end

  def draw_status
    score = "Score: #{@board.score}"
    score += "     Game Over!" if @game_over
    @score_font.draw_text(score, TEXT_X, SCORE_Y, Z_TEXT, 1, 1, COLORS[:text])

    if @game_over && !@auto
      @score_font.draw_text("N to start new game, ESC to Quit", TEXT_X, STATUS_Y, Z_TEXT, 1, 1, COLORS[:text])
    end
    @small_font.draw_text(@message[:text], TEXT_X, MESSAGE_Y, Z_TEXT, 1, 1, COLORS[:text]) if @message
  end

  # A blinking red triangle while a game is being recorded.
  def draw_recording_mark
    return unless @recording

    tip   = (Gosu.milliseconds / BLINK_MS).even? ? 10 : -10
    color = Gosu::Color::RED
    x     = TEXT_X
    y     = RECORDING_MARK_Y
    Gosu.draw_triangle(x, y, color, x + 20, y, color, x + 10, y + tip, color, Z_TEXT)
  end

  # While H is held.
  def draw_help
    return unless Gosu.button_down?(Gosu::KB_H)

    height = (HELP_LINES.size * HELP_LINE_HEIGHT) + 10
    Gosu.draw_rect(HELP_X - 5, HELP_Y - 5, WIDTH - HELP_X + 5, height, COLORS[:help_backdrop], Z_HELP)
    HELP_LINES.each_with_index do |line, index|
      @small_font.draw_text(line, HELP_X, HELP_Y + (index * HELP_LINE_HEIGHT), Z_HELP, 0.8, 0.8, COLORS[:text])
    end
  end

  # ---------------------------------------------------------------------------
  # Drawing helpers
  # ---------------------------------------------------------------------------

  def cell_color(value, tile_id = nil)
    return COLORS[:empty] if value == Board1010::EMPTY

    TILE_COLORS.fetch(tile_id && tile_id.positive? ? tile_id : value)
  end

  # Draws each filled square of the tile, with its top-left square at (x, y).
  # `color` overrides the tile's own colors (used for the selected option).
  def draw_tile(tile, x, y, size:, gap:, corner:, color: nil, z: Z_CELLS)
    tile_id = tile.id
    tile.rows.each_with_index do |values, row|
      values.each_with_index do |value, col|
        next if value == Board1010::EMPTY

        left = x + (col * (size + gap))
        top  = y + (row * (size + gap))
        draw_square(left, top, size, color || cell_color(value, tile_id), corner: corner, z: z)
      end
    end
  end

  # A square with clipped corners: a filled square, then a triangle in the
  # background color over each corner.
  def draw_square(x, y, size, color, corner: CELL_CORNER, z: Z_CELLS)
    Gosu.draw_rect(x, y, size, size, color, z)

    background = COLORS[:background]
    [[x, y, 1, 1], [x + size, y, -1, 1], [x, y + size, 1, -1], [x + size, y + size, -1, -1]].each do |cx, cy, dx, dy|
      Gosu.draw_triangle(cx, cy, background, cx + (dx * corner), cy, background, cx, cy + (dy * corner), background, z)
    end
  end

  # Reads `[auto] [strategy] [--seed N] [--model PATH]` from the command line.
  def self.options_from(argv)
    args = argv.dup
    options = {}

    seed_at = args.index("--seed")
    if seed_at
      raise ArgumentError, "--seed requires an integer" unless args[seed_at + 1]

      options[:seed] = Integer(args[seed_at + 1])
      args.slice!(seed_at, 2)
    end

    delay_at = args.index("--delay")
    if delay_at
      value = args[delay_at + 1]
      raise ArgumentError, "--delay requires seconds (for example: --delay 1.5)" unless value

      begin
        options[:replay_delay] = Float(value)
      rescue ArgumentError
        raise ArgumentError, "invalid --delay value #{value.inspect}; use seconds, for example --delay 1.5"
      end
      unless options[:replay_delay].finite? && options[:replay_delay] >= 0
        raise ArgumentError, "--delay must be a finite non-negative number of seconds"
      end
      args.slice!(delay_at, 2)
    end

    model_at = args.index("--model")
    if model_at
      value = args[model_at + 1]
      raise ArgumentError, "--model requires a model JSON path" unless value

      options[:model] = value
      args.slice!(model_at, 2)
    end

    replay_at = args.index {|arg| arg.end_with?(".moves") }
    options[:replay_file] = args.delete_at(replay_at) if replay_at

    options[:auto]     = !args.delete("auto").nil?
    options[:strategy] = args.shift unless args.empty?
    strategy_name = (options[:strategy] || AutoPlayer::DEFAULT_STRATEGY).to_sym
    if strategy_name == :learned
      options[:model] ||= File.join("learning_data", "checkpoints", "selected.json")
      unless File.file?(options[:model])
        raise ArgumentError, "learned strategy needs --model PATH or a selected model at #{options[:model]}"
      end
    end
    raise ArgumentError, "unexpected command line arguments: #{args.join(' ')}" unless args.empty?
    options
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    window = GameWindow.new(**GameWindow.options_from(ARGV))
  rescue ArgumentError, SystemCallError => error
    warn "1010: #{error.message}"
    warn "Usage: ruby game_1010.rb [auto [strategy]] [--seed N] [--model PATH] [--delay SECONDS] [GAME.moves]"
    exit 2
  end
  window.show
end
