# board.rb
STDOUT.sync = true
class Board1010

  attr_accessor :rows, :cols, :arr, :score, :options, :val, :placed_pos

  MAX_ROWS    = 10
  MAX_COLS    = 10
  MAX_OPTIONS = 3
  GAME_FILE_NAME = (RUBY_ENGINE == 'mruby') ? "./1010game.str" : "./1010game.dat"

  DOT = [1]

  # Horizontal Lines
  HL = [[], [ 1], [2,  2], [3,  3, 3], [4,  4, 4, 4], [5,  5, 5, 5, 5]]

  # Vertical Lines
  VL = [[], [-1], [-1,-1], [-1,-1,-1], [-1,-1,-1,-1], [-1,-1,-1,-1,-1]]

  # Squares
  SQ = [
    [],[[1]],
    [[2,2],
     [2,2]],
    [[3,3,3],
     [3,3,3],
     [3,3,3]],
  ]

  # Bottom Left Corners
  BL = [
    [],[[1]],
    [[2,0],
     [2,2]],
    [[3,0,0],
     [3,0,0],
     [3,3,3]],
  ]

  # Top Left Corners
  TL = [
    [],[[1]],
    [[2,2],
     [0,2]],
    [[3,3,3],
     [0,0,3],
     [0,0,3]],
  ]

  # Bottom Right Corners
  BR = [
    [],[[1]],
    [[0,2],
     [2,2]],
    [[0,0,3],
     [0,0,3],
     [3,3,3]],
  ]

  # Top Right Corners
  TR = [
    [],[[1]],
    [[2,2],
     [2,0]],
    [[3,3,3],
     [3,0,0],
     [3,0,0]],
  ]

  ALL_TILES = [
      DOT,

      HL[2],
      HL[3],
      HL[4],
      HL[5],

      VL[2],
      VL[3],
      VL[4],
      VL[5],

      SQ[2],
      SQ[3],

      BL[2],
      BL[3],

      TL[2],
      TL[3],

      BR[2],
      BR[3],

      TR[2],
      TR[3],
  ]

  def initialize(rows=MAX_ROWS, columns=MAX_COLS)
    @rows    = rows
    @cols    = columns
    @arr     = nil
    @score   = 0
    @val     = 0
    @options = []
    @prev_options = @prev_score = @prev_arr = nil
  end

  def marshal_dump
    [@score, @arr, @options]
  end

  def marshal_load(array)
    @score, @arr, @options = array
  end

  def prev_arr
    @prev_arr
  end

  def to_s
     opt_str = ""
     @options.each do |opt|
       opt_str += opt.inject(''){|sum,c| sum + c.to_s}
       opt_str += ','
     end
    "@rows=#{@rows};@cols=#{@cols};@score=#{@score};@val=#{@val};@options=#{@options};@arr=#{@arr}"
  end

  def parse_load(data)
    bGame = Struct.new("Game",:rows,:cols,:score,:val,:options,:arr)
    game = bGame.new
    data.split(';').each do |element|
      key,val = element.split('=')
      case key
      when "@rows"
        game.rows = val.to_i
      when "@cols"
        game.cols = val.to_i
      when "@score"
        game.score = val.to_i
      when "@val"
        game.val = val.to_i
      when "@options"
        game.options = [[1],[1,1,1],[-1,-1,-1]]
      when "@arr"
        game.arr = Array.new(game.rows){Array.new(game.cols){@val}}
      end
    end
    game
  end

  def load_game
    game = nil
    if File.exist?(GAME_FILE_NAME)
      File.open(GAME_FILE_NAME,"rb") do |f|
        data = f.read
        if RUBY_ENGINE == 'mruby'
          game = parse_load(data)
        else
          game = Marshal::load(data)
        end
      end
    end
    game
  end

  def save
    print "Do you want to save the game to play it later? [y/n] "
    opt = gets.chomp.downcase
    if(opt == "y")
      File.open(GAME_FILE_NAME,"wb") do |f|
        if (RUBY_ENGINE == 'mruby')
          f.write(self.to_s)
        else
          f.write(Marshal::dump(self))
        end
      end
    end
    (opt == "y")
  end

  def init(val=nil)
    if val.class == Array
      @arr   = val
      @score = _filled_cells
    elsif val.class == Fixnum
      @val = val
      @arr = Array.new(@rows){Array.new(@cols){val}}
      @score = 0
      @options = []
    elsif (game = load_game)
      @rows    = Board1010::MAX_ROWS
      @cols    = Board1010::MAX_COLS
      @val     = 0
      @arr     = game.arr
      @score   = game.score
      @options = game.options
    else
      @arr = Array.new(@rows){Array.new(@cols){@val}}
    end

    start
  end

  def current_score
    @score
  end

  def restore_arr(prev_arr)
    @arr = Marshal.load(Marshal.dump(prev_arr))
  end

  def restore_options(prev_options)
    @options = Marshal.load(Marshal.dump(prev_options))
  end

  def cell=(triplet)
    i,j,val = triplet
    _set_cell(i,j,val)
  end

  def get_selected_option(i,j)
    puts "Select one option for position (#{i}, #{j}):"
    while true do
      print "option> "
      option = gets.chomp
      stop if option.to_s.downcase == "q"
      return option.to_i if [1,2,3].include?(option.to_i)
      puts "Invalid option #{option}. Should be one of [1,2,3]"
    end
  end


  def get_position
    print "Select Row, Col: "
    line = gets.chomp
    x,y  = line.split(',')
    stop if x.to_i < 0 || y.to_i < 0
    i,j  = x.to_i % Board1010::MAX_ROWS, y.to_i % Board1010::MAX_COLS
    [i,j]
  end

  def row_cleanup(i)
    @cols.times do |j|
      _set_cell(i,j,@val)
    end
  end

  def col_cleanup(j)
    @rows.times do |i|
      _set_cell(i,j,@val)
    end
  end

  def cleanup(dry_run=false)
    rows_to_clean = []
    @rows.times do |i|
      row_full = true
      @cols.times do |j|
        if _cell_empty?(i,j)
          row_full = false
          break
        end
      end
      rows_to_clean << i if row_full
    end

    cols_to_clean = []
    @cols.times do |j|
      col_full = true
      @rows.times do |i|
        if _cell_empty?(i,j)
          col_full = false
          break
        end
      end
      cols_to_clean << j if col_full
    end

    unless dry_run
      rows_to_clean.each {|i| row_cleanup(i)}
      cols_to_clean.each {|j| col_cleanup(j)}
    end

    [rows_to_clean, cols_to_clean]
  end

  def backtrack
    @placed_pos.each do |i,j,k|
      _set_cell(i,j,0)
    end
    @placed_pos = []
  end

  def place(tile,i,j,dry_run=false)
    score = 0
    @placed_pos = []
    tile.each_with_index do |cell,r|
      if (cell.class == Array)
        if r == 0
          cell.each do |ele|
            break if ele > 0
            j -= 1
          end
          return 0 if j < 0
        end
        cell.each_with_index do |ele, c|
          if ele > 0 && _cell_occupied?(i+r, j+c)
            backtrack unless dry_run
            return 0
          end
          if ele > 0
            unless dry_run
              _set_cell(i+r,j+c,ele)
            end
            @placed_pos << [i+r,j+c,ele]
            score += 1
          end
        end
      elsif cell > 0
        if _cell_occupied?(i, j+r)
          backtrack unless dry_run
          return 0
        end
        unless dry_run
          _set_cell(i,j+r,cell)
        end
        @placed_pos << [i,j+r,cell]
        score += 1
      elsif cell < 0
        if _cell_occupied?(i+r, j)
          backtrack unless dry_run
          return 0
        end
        unless dry_run
          _set_cell(i+r,j, cell)
        end
        @placed_pos << [i+r,j,cell]
        score += 1
      else
         raise "invalid tile #{tile}"
      end
    end

    @score += score unless dry_run
    score
  end

  def show_tile(tile)
    p tile
  end

  ## Improve this algorithm to find a better fit
  def find_fitting_tile
    # puts "*** Finding a fitting tile ***"
    tiny_tiles = [HL[2], VL[2], SQ[2], BL[2], TL[2], BR[2], TR[2], DOT]
    i,j,tile   = pos_exists?(tiny_tiles)
    tile
  end

  def generate_tiles(n=Board1010::MAX_OPTIONS)
    opt_tiles = []

    n.times do |i|
      r = rand(ALL_TILES.size)
      tile =  ALL_TILES[r]
      opt_tiles << tile
    end

    opt_tiles[0] = find_fitting_tile unless pos_exists?(opt_tiles)

    opt_tiles
  end


  def show_tiles(all)
    n = 1
    all.each do |tile|
      if tile
        print " #{n}> "
        show_tile(tile)
        n += 1
      end
    end
    n
  end

  def pos_exists?(tiles, debug=false)
    tiles.each do |tile|
      if debug
        puts "Checking if tile #{tile} can be placed:"
        show
      end
      @arr.each_with_index do |row,i|
        row.each_with_index do |col,j|
          score = (_cell_occupied?(i,j) ? 0 : place(tile,i,j,true))
          puts "score = #{score} at (#{i},#{j})" if debug
          return [i,j,tile] if score > 0
        end
      end
    end
    puts "...no can place" if debug
    return false
  end

  def play
    while (true) do
      all = (@options.size > 0 ? @options : generate_tiles)
      @options = all
      while (all.size > 0) do
        show
        puts "\n#{'=' * 20}\nCurrent score = #{current_score}\n#{'=' * 20}\n"
        show_tiles(all)
        ended unless pos_exists?(all)
        i,j = get_position
        if all.size > 1
          opt = get_selected_option(i,j)
        else
          opt = 1
        end
        tile = all[opt - 1]
        new_score = place(tile,i,j)
        if new_score < 1
          puts " Cannot place the tile #{tile} at (#{i}, #{j})"
        else
          all.delete_at(opt - 1)
          cleanup
        end
      end
    end
  end

  def start
    @start_time = Time.now
  end

  def ended
    puts "\n--- Game ended: no place for remaining tiles"
    _over
  end

  def stop
    puts "\n--- Game stopped: to be played later"
    save
    _over
  end

  def show
    puts ""
    print "   ";@cols.times{|j| print " #{j}"}
    puts
    @arr.each_with_index do |row,i|
      print " #{i}["
      row.each do |col|
        if col == 0
          print " ."
        else
          print " X"
        end
      end
      puts " ]"
    end
    puts ""
  end

  def find_starting_pos(tile)
    positions = []
    @arr.each_with_index do |row,i|
      row.each_with_index do |col,j|
        score = place(tile,i,j,true)
        positions << [i,j] if score > 0
      end
    end
    positions
  end

  def neighbours(i,j)
    count = 0

    count += 1 if i > 0 && j > 0 && @arr[i-1][j-1] != 0
    count += 1 if i > 0 && @arr[i-1][j  ] != 0
    count += 1 if i > 0 && j < 9 && @arr[i-1][j+1] != 0

    count += 1 if i < 9 && j > 0 && @arr[i+1][j-1] != 0
    count += 1 if i < 9 && @arr[i+1][j  ] != 0
    count += 1 if i < 9 && j < 9 && @arr[i+1][j+1] != 0

    count += 1 if j > 0 && @arr[i  ][j-1] != 0
    count += 1 if j < 9 && @arr[i  ][j+1] != 0

    count
  end

  def jc_neighbours(i,j)
    count = 0

    count += 1 if i > 0 && j > 0 && @arr[i-1][j-1] != 0
    count += 1 if i > 0 && @arr[i-1][j  ] != 0
    count += 1 if i > 0 && j < 9 && @arr[i-1][j+1] != 0

    count += 1 if i < 9 && j > 0 && @arr[i+1][j-1] != 0
    count += 1 if i < 9 && @arr[i+1][j  ] != 0
    count += 1 if i < 9 && j < 9 && @arr[i+1][j+1] != 0

    count += 1 if j > 0 && @arr[i  ][j-1] != 0
    count += 1 if j < 9 && @arr[i  ][j+1] != 0

    count += 1 if (i == 0) || (i == 9)
    count += 1 if (j == 0) || (j == 9)

    count
  end

  def sam_algo(positions)
  ## Suggested by Sam:
  ## Find the position which completely fills more rows and columns when the tile is placed
    return -1
  end

  def andy_algo(positions)
  ## Suggested by Andy:
  ## Find the position which results into minimum empty cells after placing the tile but before
  ## clearing the filled rows and columns
    return  -1
  end

  def jc_algo(positions)
  # Suggested by JC:
  # The best position is one which has most neighbors occupied.
  # But treat the edge cells as if their neighbors are always occupied.
    neighbour_count = []
    positions.each_with_index do |pos,k|
      neighbour_count[k] = jc_neighbours(*pos)
    end
    neighbour_count.index(neighbour_count.max)
  end

  def shanko_algo(positions)
  # The best position is one which has most neighbors occupied
  # In other words: least neighboring cells empty
    neighbour_count = []
    positions.each_with_index do |pos,k|
      neighbour_count[k] = neighbours(*pos)
    end
    neighbour_count.index(neighbour_count.max)
  end

  def first_fit(positions)
  # The best position is always the first position found
    return 0
  end

  def last_fit(positions)
  # The best position is always the last position found
    return -1
  end

  def best_starting_position(tile)
    positions = find_starting_pos(tile)
    # n = first_fit(positions)
    # n = last_fit(positions)
    # n = shanko_algo(positions)
    n = jc_algo(positions)
    # n = sam_algo(positions)
    # n = andy_algo(positions)
    positions[n || 0]
  end

private

  def _set_cell(i,j,val)
    if _cell_valid?(i,j)
      @arr[i][j] = val
    end
  end

  def _cell_valid?(i,j)
    @arr[i] && @arr[i][j]
  end

  def _cell_empty?(i,j)
    _cell_valid?(i,j) && @arr[i][j] == @val
  end

  def _cell_occupied?(i,j)
    not _cell_empty?(i,j)
  end

  def _over
    stop_time = Time.now
    puts "Total time elapsed = #{stop_time - @start_time} seconds"
    puts "Score = #{@score}"
    puts
    raise "Over!"
  end

  def _filled_cells
    count = 0
    @arr.each do |row|
       row.each do |col|
         count += 1 if col > 0
       end
    end
    count
  end

end

if __FILE__ == $0
  begin
    puts "Total tiles = #{Board1010::ALL_TILES.size}"
    b = Board1010.new
    b.init
    b.play
  rescue
    puts "> " + $!.to_s
  end
end

