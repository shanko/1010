# frozen_string_literal: true

# game_1010.rb: the Gosu window for 1010! (drawing and input).
#
#   ruby game_1010.rb                     you play (continues a saved game if there is one)
#   ruby game_1010.rb auto                the computer plays, game after game
#   ruby game_1010.rb auto sam --seed 42  pick the computer's strategy, and repeat the same games
#
# The rules live in board.rb, the computer player in auto_player.rb and the
# move animation in move_animation.rb. This file only reads input, updates
# what is on screen and draws.
require "gosu"
require_relative "board"
require_relative "auto_player"
require_relative "move_animation"

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

  # By tile value (see Board1010::TILES).
  TILE_COLORS = {
    1 => Gosu::Color.argb(0xf8_1b_b8_8b), # green
    2 => Gosu::Color.argb(0xe2_ec_55_25), # orange
    3 => Gosu::Color::FUCHSIA,
    4 => Gosu::Color.argb(0xf5_77_2f_c0), # purple
    5 => Gosu::Color::BLUE
  }.freeze

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
  Recording = Struct.new(:seed, :events)

  def initialize(auto: false, strategy: AutoPlayer::DEFAULT_STRATEGY, seed: nil)
    super(WIDTH, HEIGHT, fullscreen: false)
    self.caption = "1010!"
    @score_font = Gosu::Font.new(30)
    @small_font = Gosu::Font.new(20)

    # Every game's seed comes from here, so `--seed` repeats a whole session.
    @seeds       = Random.new(seed || Random.new_seed)
    @auto_player = AutoPlayer.new(strategy, random: Random.new(@seeds.rand(2**32)))
    @auto        = auto
    @auto_runs   = 0
    @max_score   = 0
    @recording   = nil # the game being recorded
    @last_recording = nil
    @playback    = nil # events still to replay
    @message     = nil

    load_game unless @auto
    new_game unless @board
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
    start(board, seed: seed)
  end

  # Everything that is reset when a game starts (new, loaded or played back).
  def start(board, seed: nil)
    stop_recording
    @board          = board
    @seed           = seed  # nil for a loaded game, which can't be recorded
    @previous_board = nil   # for undo (one level, like the original)
    @selected       = nil   # index of the chosen option
    @dragging       = false
    @animation      = nil
    @started_at     = Gosu.milliseconds
    @ended_at       = nil
    refresh_game_over
  end

  # Call after every change to the board. (Checking every frame would mean
  # trying every tile on every square 60 times a second.)
  def refresh_game_over
    @game_over = @board.game_over?
    @ended_at  = @game_over ? (@ended_at || Gosu.milliseconds) : nil
  end

  # ---------------------------------------------------------------------------
  # Moves
  # ---------------------------------------------------------------------------

  # Plays option `index` with its anchor on (row, col), for the player, the
  # computer and playback alike. Does nothing if the tile doesn't fit there.
  def try_place(index, row, col)
    previous = @board.copy
    move = @board.play(index, row, col)
    return unless move

    @previous_board = previous
    @recording&.events&.push([:move, index, row, col])
    @selected  = nil
    clear_step = @auto ? MoveAnimation::PLACE_STEP_MS : MoveAnimation::CLEAR_STEP_MS
    @animation = MoveAnimation.new(move, Gosu.milliseconds, clear_step_ms: clear_step)
    refresh_game_over
  end

  def undo
    return show_message("Nothing to undo") unless @previous_board

    @board          = @previous_board
    @previous_board = nil
    @selected       = nil
    @animation      = nil
    @recording&.events&.push([:undo])
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
    now = Gosu.milliseconds
    expire_finished(now)
    return if @animation # let a move finish before the next automatic one

    if @playback
      play_back_next
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

    @auto_runs += 1
    if @board.score > @max_score
      @max_score = @board.score
      puts "Score = #{@max_score}"
    end
    self.caption = "1010!  Runs: #{@auto_runs}  Max Score: #{@max_score}"
    new_game
  end

  def toggle_auto
    @auto     = !@auto
    @selected = nil
    @dragging = false
    self.caption = "1010!"
  end

  # ---------------------------------------------------------------------------
  # Recording and playback
  # ---------------------------------------------------------------------------

  # R starts recording a new game; pressing R again stops.
  def toggle_recording
    return stop_recording if @recording

    new_game
    @recording = Recording.new(@seed, [])
    show_message("Recording a new game (R to stop)")
  end

  def stop_recording
    return unless @recording

    @last_recording = @recording
    @recording = nil
    show_message("Recording stopped (P to play it back)")
  end

  # P plays the last recording: the same tiles (from its seed) and the same moves.
  def start_playback
    stop_recording
    return show_message("Nothing recorded yet (R to record)") unless @last_recording

    recording = @last_recording
    new_game(seed: recording.seed)
    @auto     = false
    @playback = recording.events.dup
    self.caption = "1010! (playback)"
  end

  def play_back_next
    event = @playback.shift
    case event&.first
    when :move then try_place(*event.drop(1))
    when :undo then undo
    else
      @playback = nil
      self.caption = "1010!"
      show_message("Playback finished")
    end
  end

  # ---------------------------------------------------------------------------
  # Saving
  # ---------------------------------------------------------------------------

  def save_game
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
    save_game
    close
  end

  # Deletes the saved game too, so the next start is a new game.
  def quit_without_saving
    File.delete(Board1010::SAVE_FILE) if File.exist?(Board1010::SAVE_FILE)
    close
  rescue SystemCallError => e
    puts "Could not delete #{Board1010::SAVE_FILE}: #{e.message}"
    close
  end

  # Called when the window closes (ESC, Q or the window's close button).
  def close
    puts "Total time played = #{play_seconds} seconds"
    puts "Score = #{@board.score}"
    super
  end

  def play_seconds
    ((@ended_at || Gosu.milliseconds) - @started_at) / 1000
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
        draw_square(cell_x(col), cell_y(row), CELL_SIZE, cell_color(value))
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
    x = mouse_x - (Board1010.anchor(tile) * CELL_PITCH)
    draw_tile(tile, x, mouse_y, size: CELL_SIZE, gap: CELL_GAP, corner: CELL_CORNER, z: Z_DRAGGED)
  end

  # While O is held: the square where the computer would put the selected tile's anchor.
  def draw_hint
    return unless @selected && Gosu.button_down?(Gosu::KB_O)

    row, col = @auto_player.best_position(@board, @board.options[@selected])
    draw_square(cell_x(col), cell_y(row), CELL_SIZE, COLORS[:hint]) if row
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

  def cell_color(value)
    value == Board1010::EMPTY ? COLORS[:empty] : TILE_COLORS.fetch(value)
  end

  # Draws each filled square of the tile, with its top-left square at (x, y).
  # `color` overrides the tile's own colors (used for the selected option).
  def draw_tile(tile, x, y, size:, gap:, corner:, color: nil, z: Z_CELLS)
    tile.each_with_index do |values, row|
      values.each_with_index do |value, col|
        next if value == Board1010::EMPTY

        left = x + (col * (size + gap))
        top  = y + (row * (size + gap))
        draw_square(left, top, size, color || cell_color(value), corner: corner, z: z)
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

  # Reads `[auto] [strategy] [--seed N]` from the command line.
  def self.options_from(argv)
    args = argv.dup
    options = {}

    seed_at = args.index("--seed")
    if seed_at
      options[:seed] = Integer(args[seed_at + 1])
      args.slice!(seed_at, 2)
    end

    options[:auto]     = !args.delete("auto").nil?
    options[:strategy] = args.shift unless args.empty?
    options
  end
end

GameWindow.new(**GameWindow.options_from(ARGV)).show if __FILE__ == $PROGRAM_NAME
