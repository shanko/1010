# game_1010.rb
require "gosu"
require "./board"

class GameWindow < Gosu::Window
  attr_reader :clicked_x, :clicked_y

  COLORS = {
    maroon: Gosu::Color.new(*[222, 217, 17,  152]),
    purple: Gosu::Color.new(*[245, 119, 47,  192]),
    brown:  Gosu::Color.new(*[226, 236, 85, 37]),
    grey:   Gosu::Color.new(*[62,  121, 218, 109]),
    pink:   Gosu::Color.new(*[193, 254, 9,   124]),
    bleau:  Gosu::Color.new(*[250, 5,   145, 245]),
    green:  Gosu::Color.new(*[248, 27,  184, 139])
  }.freeze

  FONT_COLOR = Gosu::Color::RED
  LINE_COLOR = Gosu::Color::BLUE

  def initialize(auto=false)
    @width  = 480
    @height = 480
    super(@width, @height, {fullscreen: false})
    self.caption = "1010!"

    @score_font = Gosu::Font.new(30)
    @help_font  = Gosu::Font.new(20)

    @board           = Board1010.new # Dependency injection?
    @selected_option = 0
    @selected_row    = @selected_col = -1
    @clicked_x       = @clicked_y    = -1

    ## These should be even so that div by 2 is proper int
    @gap  = 2
    @size = 32
    @option_cell_size = 20

    @recording = []
    @placed_positions = []
    @rows_to_clean = []
    @cols_to_clean = []
    @ended = @undo = @show_pos = @record = @playback = @help = @drag = false

    @auto  = auto
    @auto_count = @max_score = @count = 0
  end

  def needs_cursor?
    true
  end

  def draw_score
    @score_font.draw("Score: #{@board.score}", 20, 360, 1, 1.0, 1.0, FONT_COLOR)
  end

  def draw_help
    return unless @help
    x = 340
    y = 340
    @help_font.draw("ESC: abort",       x, y, 1, 1.0, 1.0, FONT_COLOR)
    @help_font.draw("A: auto",          x, y + 20, 1, 1.0, 1.0, FONT_COLOR)
    @help_font.draw("N: new game",      x, y + 40, 1, 1.0, 1.0, FONT_COLOR)
    @help_font.draw("O: show position", x, y + 60, 1, 1.0, 1.0, FONT_COLOR)
    @help_font.draw("Q: save and quit", x, y + 80, 1, 1.0, 1.0, FONT_COLOR)
    @help_font.draw("S: save",          x, y + 100, 1, 1.0, 1.0, FONT_COLOR)
    @help_font.draw("U: undo",          x, y + 120, 1, 1.0, 1.0, FONT_COLOR)
  end

  def draw_background
    draw_rect(0, 0, 0, @width + 5, @height + 5, Gosu::Color::WHITE)
    boarder = 10 * (@size + @gap) + 1
    draw_rect(boarder, 0, 0, 5, boarder + 5, Gosu::Color::GRAY)
    draw_rect(0, boarder, 0, boarder,   5, Gosu::Color::GRAY)
  end

  def cell_color(value=0)
    color = case value
            when 0
              COLORS[:grey]
            when -1
              COLORS[:bleau]
            when -2
              COLORS[:maroon]
            when 1
              COLORS[:green]
            when 2
              COLORS[:brown]
            when 3
              Gosu::Color::FUCHSIA
            when 4
              COLORS[:purple]
            else
              Gosu::Color::BLUE
    end

    # puts "Cell color of #{value} = #{color}"
    color
  end

  def draw_cell(i, j, value)
    x = @gap + (j * (@size + @gap))
    y = @gap + (i * (@size + @gap))
    z = 1

    draw_sqr(x, y, z, @size, cell_color(value), 4)
  end

  def dragged_xy
    [@drag_x, @drag_y]
  end

  def clicked_xy
    x = @clicked_x
    y = @clicked_y # these are from the latest click
    @clicked_x = @clicked_y = -1 # so immediately reset the co-ordinates
    [x, y]
  end

  def get_screen_position
    x, y = clicked_xy
    i = -1
    j = -1

    Board1010::MAX_COLS.times do |jj|
      if (x >= @gap + (@size + @gap) * jj) && (x < @gap + (@size + @gap) * (jj + 1))
        j = jj
        break
      end
    end

    Board1010::MAX_ROWS.times do |ii|
      if (y >= @gap + (@size + @gap) * ii) && (y < @gap + (@size + @gap) * (ii + 1))
        i = ii
        break
      end
    end

    [i, j]
  end

  def get_selected_option
    x, y = clicked_xy
    opt  = 0
    gap  = @gap  / 2
    size = @size / 2
    (1..Board1010::MAX_OPTIONS).each do |i|
      y1 = (@option_cell_size * i) + ((i - 1) * (size + gap) * 5)
      y2 = (@option_cell_size * (i + 1)) + (i * (size + gap) * 5)
      if (x > 360) && (y1 < y) && (y < y2)
        opt = i
        break
      end
    end

    opt
  end

  def draw_option_tile(tile, pos, selected=false)
    return unless (1..Board1010::MAX_OPTIONS).cover?(pos)

    gap  = @gap  / 2
    size = @size / 2

    x = 360
    y = (@option_cell_size * pos) + ((pos - 1) * (size + gap) * 5)

    gap, size = _draw_option_tile(tile, x, y, selected && Gosu::Color::YELLOW, gap, size)

    draw_line(360, ((@option_cell_size / 2) * pos) + ((pos - 1) * (size + gap) * 5), LINE_COLOR,
              460, ((@option_cell_size / 2) * pos) + ((pos - 1) * (size + gap) * 5), LINE_COLOR, 1)
  end

  def draw_sqr(x, y, z, length, color=Gosu::Color::WHITE, corner=0)
    draw_rect(x, y, z, length, length, color)
    draw_corners(x, y, length, length, Gosu::Color::WHITE, corner)
  end

  def draw_corners(x, y, width, height, color=nil, size=0)
    return if size.zero?
    color ||= Gosu::Color::WHITE

    z = 1

    # Top Left
    x1 = x
    y1 = y
    c1 = color
    x2 = x1 + size
    y2 = y1
    c2 = color
    x3 = x1
    y3 = y1 + size
    c3 = color
    draw_triangle(x1, y1, c1, x2, y2, c2, x3, y3, c3, z, :default)

    # Top Right
    x1 = x + width
    y1 = y
    c1 = color
    x2 = x1 - size
    y2 = y1
    c2 = color
    x3 = x1
    y3 = y1 + size
    c3 = color
    draw_triangle(x1, y1, c1, x2, y2, c2, x3, y3, c3, z, :default)

    # Bot Left
    x1 = x
    y1 = y + height
    c1 = color
    x2 = x1
    y2 = y1 - size
    c2 = color
    x3 = x1 + size
    y3 = y1
    c3 = color
    draw_triangle(x1, y1, c1, x2, y2, c2, x3, y3, c3, z, :default)

    # Bot Right
    x1 = x + width
    y1 = y + height
    c1 = color
    x2 = x1 - size
    y2 = y1
    c2 = color
    x3 = x1
    y3 = y1 - size
    c3 = color
    draw_triangle(x1, y1, c1, x2, y2, c2, x3, y3, c3, z, :default)
  end

  def draw_rect(x, y, z, width, height, color=Gosu::Color::WHITE)
    c1 = c2 = c3 = c4 = color
    x1 = x
    y1 = y
    x2 = x1 + width
    y2 = y1
    x3 = x1
    y3 = y1 + height
    x4 = x2
    y4 = y3
    Gosu.draw_quad(x1, y1, c1, x2, y2, c2, x3, y3, c3, x4, y4, c4, z, :default)
  end

  def corrected_x(tile, x)
    new_x = x
    cell  = tile.first
    cell.each do |val|
      if val.zero?
        new_x -= (@size + @gap)
      else
        break
      end
    end
    new_x
  end

  def draw_dragged_tile
    return unless @drag

    x, y = dragged_xy
    if @selected_option > 0
      tile = @option_tiles[@selected_option - 1]
      x    = corrected_x(tile, x)
      _draw_option_tile(tile, x, y)
    end
  end

  def draw_open_pos
    return unless @show_pos

    tile      = @option_tiles[@selected_option - 1]
    bpos      = @board.best_starting_position(tile)
    positions = (bpos ? [bpos] : [])
    positions.each do |pos|
      i, j = pos
      draw_cell(i, j, -2)
    end
  end

  def draw_options
    n = 1
    @option_tiles.each_with_index do |tile, i|
      if tile
        draw_option_tile(tile, (i + 1), @selected_option == (i + 1))
        n += 1
      end
    end
    n
  end

  def draw_board
    @board.arr.each_with_index do |row, i|
      row.each_with_index do |val, j|
        draw_cell(i, j, val)
      end
    end
  end

  def place_selected_tile
    if @placed_positions.empty?
      if @rows_to_clean.empty? && @cols_to_clean.empty?
        @rows_to_clean, @cols_to_clean = @board.cleanup(true)
      else
        unless @rows_to_clean.empty?
          i = @rows_to_clean.shift
          Board1010::MAX_ROWS.times {|j| @board.cell = [i, j, 0] }
        end

        unless @cols_to_clean.empty?
          j = @cols_to_clean.shift
          Board1010::MAX_COLS.times {|i| @board.cell = [i, j, 0] }
        end

        sleep(0.25) unless @auto
      end
    else
      i, j, val = @placed_positions.shift
      @board.cell = [i, j, val]
      return
    end

    return unless (@selected_option > 0) && (@selected_row >= 0) && (@selected_col >= 0)

    unless @undo
      @prev_score   = @board.score
      @prev_arr     = Marshal.load(Marshal.dump(@board.arr))
      @prev_option_tiles = Marshal.load(Marshal.dump(@option_tiles))
    end
    tile = @option_tiles[@selected_option - 1]
    new_score = @board.place(tile, @selected_row, @selected_col, true)
    if new_score > 0
      @board.score += new_score
      @placed_positions = @board.placed_pos
      @option_tiles.delete_at(@selected_option - 1)
    end

    @selected_option = 0
    @selected_row = @selected_col = -1
  end

  def draw_status
    @count += 1
    if @ended
      @score_font.draw("Score: #{@board.score}     Game Over!", 20, 360, 1, 1.0, 1.0, FONT_COLOR)
      if @auto
        @auto_count += 1
        if @board.score > @max_score
          puts "Score = #{@board.score}"
          @max_score  = @board.score
        end
        restart
      else
        @score_font.draw("N to start new game, ESC to Quit", 20, 390, 1, 1.0, 1.0, FONT_COLOR)
      end
    end

    return unless @record

    if @count.even?
      x1 = 20
      y1 = 400
      x2 = 40
      y2 = 400
      x3 = 30
      y3 = 410
    else
      x1 = 20
      y1 = 400
      x2 = 40
      y2 = 400
      x3 = 30
      y3 = 390
    end

    z = 1
    c1 = c2 = c3 = Gosu::Color::RED
    draw_triangle(x1, y1, c1, x2, y2, c2, x3, y3, c3, z, :default)
  end

  def draw
    draw_background
    draw_board
    draw_score
    draw_help
    draw_options
    draw_dragged_tile
    draw_open_pos
    draw_status
  end

  def update
    if @drag
      @drag_x = mouse_x
      @drag_y = mouse_y
      return
    end

    if @playback && !@recording.empty?
      puts "playing back"
      @selected_row, @selected_col, @selected_option, @option_tiles = @recording.shift
      return
    end

    if @undo
      @board.score = @prev_score
      @board.restore_arr(@prev_arr)
      @option_tiles = @prev_option_tiles

      @undo = false
    else
      @option_tiles = @board.options
      @option_tiles = @board.generate_tiles if @option_tiles.empty?
      @ended = !@board.pos_exists?(@option_tiles)
    end

    if @auto
      @selected_option = rand(@option_tiles.size) + 1
      tile = @option_tiles[@selected_option - 1]
      position = @board.best_starting_position(tile)
      @selected_row, @selected_col = position if position
    else
      if @record
        @recording << [@selected_row, @selected_col, @selected_option, @option_tiles]
      end
    end

    place_selected_tile

    @board.restore_options(@option_tiles)
  end

  def start
    @start_time = Time.now
    @auto ? @board.init(0) : @board.init
    @ended = false
    show
  end

  def stop
    stop_time = Time.now
    puts "Total time played = #{(stop_time - @start_time).to_i} seconds"
    puts "Score = #{@board.score}"
    close
  end

  def restart
    @board.init(0)
    self.caption = "1010!  Runs: #{@auto_count}  Max Score: #{@max_score}" if @auto
    @ended = false
  end

  def button_up(id)
    case id
    when Gosu::MsLeft
      @drag = false
      @clicked_x = mouse_x
      @clicked_y = mouse_y
      @selected_row, @selected_col = get_screen_position if @selected_row < 0 || @selected_col < 0

    when Gosu::MsRight
      # do nothing
    when Gosu::KbO
      @show_pos = false
    when Gosu::KbH
      @help = false
    end
  end

  def button_down(id)
    case id
    when Gosu::KbEscape
      stop
    when Gosu::KbA
      @auto = !@auto
    when Gosu::KbB
      # about
    when Gosu::KbC
      # cheat
      @board.pos_exists?(@option_tiles, true)
    when Gosu::KbH
      @help = true
    when Gosu::KbN
      # new
      restart
    when Gosu::KbO
      @show_pos = true
    when Gosu::KbP
      self.caption = "1010! (playback)"
      @playback = true
      restart
    when Gosu::KbQ
      @board.stop
    when Gosu::KbR
      @record = true
      self.caption = "1010! (recording)"
    when Gosu::KbS
      @board.save
    when Gosu::KbU
      @undo = true
    when Gosu::Kb1
      @selected_option = 1
    when Gosu::Kb2
      @selected_option = 2
    when Gosu::Kb3
      @selected_option = 3
    when Gosu::MsRight
      # do nothing
    when Gosu::MsLeft
      @drag      = true
      @clicked_x = mouse_x
      @clicked_y = mouse_y
      @selected_option = get_selected_option if @selected_option.zero?
    else
      puts "Button down pressed with id = #{id}"
    end
  end

  private

  def _draw_option_tile(tile, x, y, color=nil, gap=nil, size=nil)
    gap  ||= @gap
    size ||= @size
    tile.each_with_index do |cell, i|
      cell.each_with_index do |ele, j|
        next unless ele > 0
        new_x = x + (size + gap) * j
        new_y = y + (size + gap) * i
        color ||= cell_color(ele)
        draw_sqr(new_x, new_y, 1, size, color, 2)
      end
    end
    [gap, size]
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    win = GameWindow.new(ARGV[0])
    win.start
    #  rescue Exception => e
    if RUBY_ENGINE == "mruby"
      raise e
    else
      puts "> " + $ERROR_INFO.to_s
    end
  end
end
