# frozen_string_literal: true

# game_1010.rb: the Gosu window for 1010! (drawing and input).
#
#   ./1010                     you play (continues a saved game if there is one)
#   ./1010 auto                the computer plays, game after game
#   ./1010 auto sam --seed 42  pick the computer's strategy, and repeat the same games
#   ./1010 auto learned --model learning_data/checkpoints/selected.json
#   ./1010 --headless --games 10   the computer plays without a window
#
# The rules live in lib/board.rb, the computer player in lib/auto_player.rb,
# and the move animation in lib/move_animation.rb. This file only reads input,
# updates state and draws.

# Headless play must work on machines without Gosu, so it branches off first.
if __FILE__ == $PROGRAM_NAME && ARGV.include?("--headless")
  require_relative "../lib/headless_game"
  exit HeadlessGame.main(ARGV)
end

begin
  require "gosu"
rescue LoadError => e
  abort <<~MESSAGE
    The game window needs the gosu gem, which could not be loaded (#{e.message}).
    If this bundle skips the gui group, include it again with:
      bundle config unset --local without && bundle install
    (or unset BUNDLE_WITHOUT if it is set in the environment).
    See "Installation" in README.md for gosu's system libraries.
  MESSAGE
end
require_relative "../lib/board"
require_relative "../lib/auto_player"
require_relative "../lib/move_animation"
require_relative "../lib/game_session"
require_relative "../lib/game_options"

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
  AUTO_RESTART_MS = GameSession::AUTO_RESTART_MS # auto mode pause before starting another game
  BLINK_MS        = 250 # how fast the recording mark blinks
  REPLAY_DELAY_SECONDS = GameSession::DEFAULT_REPLAY_DELAY_SECONDS

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
  tile_colors = Board1010::TILE_NAMES.each_with_index.to_h do |name, index|
    [Tile.fetch(name).id, TILE_PALETTE[index]]
  end
  TILE_COLORS = tile_colors.freeze

  HELP_LINES = [
    "Drag a tile onto the board,",
    "or pick one (click or 1/2/3)",
    "and click a square.",
    "O (hold): show Sam placement hint",
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
    initialize_fonts

    @strategy = strategy.to_sym
    @session = GameSession.new(auto: auto, strategy: strategy, seed: seed, replay_file: replay_file,
                               replay_delay: replay_delay, model: model,
                               clock: -> { Gosu.milliseconds })
    @hint_player = AutoPlayer.new(:sam)
    @closing = false
    @message = nil
    case @session.initial_message
    when :loaded then show_message("Loaded the saved game (N: new game)")
    when :damaged then show_message("The save file is damaged")
    end
    self.caption = "1010!  Auto: #{@strategy}" if @session.auto
    self.caption = "1010! (playback)" if replay_file
  end

  def initialize_fonts
    @score_font = Gosu::Font.new(30)
    @small_font = Gosu::Font.new(20)
  end
  private :initialize_fonts

  def needs_cursor?
    true
  end

  # ---------------------------------------------------------------------------
  # Starting games
  # ---------------------------------------------------------------------------

  def new_game(seed: nil)
    seed ? @session.new_game(seed: seed) : @session.new_game
    @selected = nil
    @animation = nil
    flush_auto_run_line
  end

  # Everything that is reset when a game starts (new, loaded or played back).
  def start(board, seed: nil, mode: "window")
    @session.start(board, seed: seed, mode: mode)
    @selected = nil
    @dragging = false
    @animation = nil
    flush_auto_run_line
  end

  # Call after every change to the board. (Checking every frame would mean
  # trying every tile on every square 60 times a second.)
  def refresh_game_over
    @session.refresh_game_over
    flush_auto_run_line
  end

  # ---------------------------------------------------------------------------
  # Moves
  # ---------------------------------------------------------------------------

  # Plays option `index` with its anchor on (row, col), for the player, the
  # computer and playback alike. Does nothing if the tile doesn't fit there.
  # During playback the replayer checks the move and supplies the recorded
  # offers, and play_back_next logs the recorded deal.
  def try_place(index, row, col)
    move = @session.place(index, row, col)
    flush_auto_run_line
    unless move
      @selected = nil
      return
    end

    @selected  = nil
    clear_step = @session.auto ? MoveAnimation::PLACE_STEP_MS : MoveAnimation::CLEAR_STEP_MS
    @animation = MoveAnimation.new(move, Gosu.milliseconds, clear_step_ms: clear_step)
  end

  def undo
    return show_message("Nothing to undo") unless @session.undo

    @selected       = nil
    @animation      = nil
  end

  def auto_move
    move = @session.auto_move
    flush_auto_run_line
    animate_move(move) if move
  end

  def select_option(index)
    @selected = index if index < @session.board.options.size
  end

  # ---------------------------------------------------------------------------
  # The game loop
  # ---------------------------------------------------------------------------

  def update
    return if @closing

    now = Gosu.milliseconds
    expire_finished(now)
    return if @animation # let a move finish before the next automatic one

    result = @session.tick(now: now)
    flush_auto_run_line
    case result
    when Board1010::Move then animate_move(result)
    when :finished then finish_playback
    when :undo
      @selected = nil
      @animation = nil
    when :restarted then update_auto_caption
    end
  end

  def animate_move(move)
    clear_step = @session.auto ? MoveAnimation::PLACE_STEP_MS : MoveAnimation::CLEAR_STEP_MS
    @animation = MoveAnimation.new(move, Gosu.milliseconds, clear_step_ms: clear_step)
  end

  # Drops the move animation and the message once their time is up.
  def expire_finished(now)
    @animation = nil if @animation&.done?(now)
    @message   = nil if @message && now >= @message[:until]
  end

  def auto_step(now)
    result = @session.auto_step(now)
    animate_move(result) if result.is_a?(Board1010::Move)
    update_auto_caption
  end

  def toggle_auto
    @session.toggle_auto
    flush_auto_run_line
    @selected = nil
    @dragging = false
    @session.auto ? update_auto_caption : self.caption = "1010!"
  end

  def print_auto_run(line)
    return unless line

    puts line
    update_auto_caption
  end

  def start_auto_run
    @session.start_auto_run
  end

  def finish_auto_run(score:, status: :completed)
    line = @session.finish_auto_run(score: score, status: status)
    @session.take_auto_run_line
    print_auto_run(line)
  end

  def update_auto_caption
    tracker = @session.auto_run_tracker
    return unless tracker

    last_time = tracker.last_duration_seconds
    timing = last_time ? "  Last: #{'%.1fs' % last_time}" : ""
    self.caption = [
      "1010!  Auto: #{@strategy}",
      "Runs: #{tracker.completed_count}",
      "Max Score: #{tracker.max_score || 0}#{timing}"
    ].join("  ")
  end

  def flush_auto_run_line
    print_auto_run(@session.take_auto_run_line)
  end

  # ---------------------------------------------------------------------------
  # Recording and playback
  # ---------------------------------------------------------------------------

  # R starts recording a new game; pressing R again stops.
  def toggle_recording
    result = @session.toggle_recording
    @selected = nil
    @animation = nil
    show_message(result == :started ? "Recording a new game (R to stop)" : "Recording stopped (P to play it back)")
  end

  def stop_recording
    @session.stop_recording
  end

  # P replays the last game's durable trace instead of keeping duplicate events in memory.
  def start_playback
    result = @session.start_playback
    return show_message("Nothing recorded yet (R to record)") if result == :nothing_recorded

    @selected = nil
    @animation = nil
    self.caption = "1010! (playback)"
  end

  def start_trace_playback(trace, mode:)
    @session.start_trace_playback(trace, mode: mode)
    @selected = nil
    @animation = nil
  end

  def play_back_next(now=Gosu.milliseconds)
    result = @session.playback_tick(now)
    animate_move(result) if result.is_a?(Board1010::Move)
    finish_playback if result == :finished
    @session.refresh_game_over if result == :undo
  end

  # A move that empties its batch is followed by its deal record, which is
  # shown straight away rather than after the playback delay.
  def play_back_move(tile_name, index, row, col)
    @session.play_back_move(tile_name, index, row, col)
  end

  def play_back_deal(tiles)
    @session.play_back_deal(tiles)
  end

  # After playback the player continues from the replayed board.
  def finish_playback
    self.caption = "1010!"
    show_message("Playback finished")
  end

  # ---------------------------------------------------------------------------
  # Saving
  # ---------------------------------------------------------------------------

  def save_game
    result = @session.save_game
    case result
    when :disabled_auto then show_message("Saving is off in auto mode")
    when :disabled_playback then show_message("Saving is off during playback")
    when :saved then show_message("Game saved")
    else show_message("Could not save: #{result.last.message}")
    end
  end

  # Like the original, carry on with a saved game if there is one.
  def load_game
    result = @session.load_game
    show_message("The save file is damaged") if result == :damaged
    show_message("Loaded the saved game (N: new game)") if result == :loaded
  end

  def show_message(text)
    @message = {text: text, until: Gosu.milliseconds + MESSAGE_MS}
    nil
  end

  def save_and_quit
    result = @session.quit(save: true)
    puts "Could not save: #{result.last.message}" if result.is_a?(Array) && result.first == :failed
    close
  end

  def saving_disabled?
    @session.saving_disabled?
  end

  # Deletes the saved game too, so the next start is a new game.
  def quit_without_saving
    result = @session.quit(save: false)
    if result.is_a?(Array) && result.first == :failed
      puts "Could not delete #{Board1010::SAVE_FILE}: #{result.last.message}"
    end
    close
  end

  # Called when the window closes (ESC, Q or the window's close button).
  def close
    return if @closing

    @closing = true
    summary = @session.finish
    flush_auto_run_line
    puts summary
    super
  end

  # Since the window opened, like the original: in auto mode that covers every
  # game played, not just the one in progress.
  def play_seconds
    @session.play_seconds
  end

  # ---------------------------------------------------------------------------
  # Input
  # ---------------------------------------------------------------------------

  # Looks the key (or mouse button) up in KEY_ACTIONS, PLAYER_ACTIONS and OPTION_KEYS.
  def button_down(id)
    return send(KEY_ACTIONS[id]) if KEY_ACTIONS.key?(id)
    return if @session.auto || @session.playback

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
    return if @session.auto || @session.playback || @selected.nil?

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
    @session.board.options.each_with_index do |tile, index|
      puts "Option #{index + 1} #{tile.inspect} fits first at #{@session.board.find_position(tile).inspect}"
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
    [row, col] if @session.board.inside?(row, col)
  end

  # Where option 0, 1 or 2 is drawn and can be clicked. Used for both, so
  # clicks and drawing can't disagree.
  def option_rect(index)
    {x: OPTION_X, y: OPTION_TOP + (index * OPTION_HEIGHT), w: OPTION_W, h: OPTION_HEIGHT}
  end

  def option_under_mouse
    @session.board.options.each_index.find do |index|
      option_contains_mouse?(index)
    end
  end

  def option_contains_mouse?(index)
    rect = option_rect(index)
    mouse_x.between?(rect[:x], rect[:x] + rect[:w]) &&
      mouse_y.between?(rect[:y], rect[:y] + rect[:h])
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
    @session.board.cells.each_with_index do |values, row|
      values.each_with_index do |value, col|
        draw_board_cell(row, col, value, now)
      end
    end
  end

  def draw_board_cell(row, col, value, now)
    value = @animation.value_at(row, col, value, now) if @animation
    tile_id = board_tile_id(row, col, now)
    draw_square(cell_x(col), cell_y(row), CELL_SIZE, cell_color(value, tile_id))
  end

  def board_tile_id(row, col, now)
    tile_id = @session.board.tile_ids[row][col]
    @animation ? @animation.tile_id_at(row, col, tile_id, now) : tile_id
  end

  def draw_options
    @session.board.options.each_with_index do |tile, index|
      draw_option(tile, index)
    end
  end

  def draw_option(tile, index)
    rect = option_rect(index)
    draw_option_line(rect)
    color = COLORS[:selected] if index == @selected # the original turned the selected tile yellow
    draw_tile(tile, rect[:x], rect[:y], size: OPTION_CELL_SIZE, gap: OPTION_CELL_GAP,
                                        corner: OPTION_CORNER, color: color)
  end

  def draw_option_line(rect)
    line_y = rect[:y] - OPTION_LINE_ABOVE
    Gosu.draw_line(rect[:x], line_y, COLORS[:option_line],
                   rect[:x] + OPTION_LINE_LENGTH, line_y, COLORS[:option_line], Z_CELLS)
  end

  # While dragging, the tile follows the mouse with its anchor square at the pointer.
  def draw_dragged_tile
    return unless @dragging && @selected

    tile = @session.board.options[@selected]
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
    tile = @session.board.options[@selected]
    key = [@session.board.object_id, @session.board.score, @selected, tile]
    if @hint_cache_key != key
      @hint_cache_key = key
      @hint_cache_value = @hint_player.best_position(@session.board, tile)
    end
    @hint_cache_value
  end

  def draw_status
    score = "Score: #{@session.board.score}"
    score += "     Game Over!" if @session.game_over
    @score_font.draw_text(score, TEXT_X, SCORE_Y, Z_TEXT, 1, 1, COLORS[:text])

    if @session.game_over && !@session.auto
      @score_font.draw_text("N to start new game, ESC to Quit", TEXT_X, STATUS_Y, Z_TEXT, 1, 1, COLORS[:text])
    end
    @small_font.draw_text(@message[:text], TEXT_X, MESSAGE_Y, Z_TEXT, 1, 1, COLORS[:text]) if @message
  end

  # A blinking red triangle while a game is being recorded.
  def draw_recording_mark
    return unless @session.recording

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

  def cell_color(value, tile_id=nil)
    return COLORS[:empty] if value == Board1010::EMPTY

    TILE_COLORS.fetch(tile_id&.positive? ? tile_id : value)
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
    GameOptions.parse(argv)
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    window = GameWindow.new(**GameWindow.options_from(ARGV))
  rescue ArgumentError, SystemCallError => e
    warn "1010: #{e.message}"
    warn GameOptions::USAGE
    exit 2
  end
  window.show
end
