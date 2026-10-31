# frozen_string_literal: true

# terminal_game.rb: play 1010! in the terminal (previously `ruby board.rb`).
#
#   ruby terminal_game.rb
#
# Type a position as "row, col" (e.g. "3, 4"), then the tile number. A negative
# position, or "q" at either question, stops the game and offers to save it.
require_relative "board"
require_relative "game_log"

class TerminalGame
  def initialize(input: $stdin, output: $stdout, board: nil, game_log: nil)
    @input  = input
    @output = output
    @seed = nil
    @board = board || load_game
    unless @board
      @seed = Random.new_seed
      @board = Board1010.new(random: Random.new(@seed))
    end
    @board.deal_if_needed
    @game_log = game_log || GameLog.new(seed: @seed, board: @board, mode: "terminal")
  end

  def run
    started_at = Time.now
    loop do
      show
      if @board.game_over?
        say("\n--- Game ended: no place for remaining tiles")
        break
      end
      move = ask_move
      unless move
        offer_to_save
        break
      end
      index, row, col = move
      option_count = @board.options.size
      tile_name = @board.options[index].name
      if @board.play(index, row, col)
        @game_log.move(tile_name, index, row, col)
        @game_log.deal(@board.options) if option_count == 1
      else
        say(" Cannot place that tile at (#{row}, #{col})")
      end
    end
    say("Total time elapsed = #{(Time.now - started_at).round} seconds")
    say("Score = #{@board.score}")
    @game_log.finish(reason: @board.game_over? ? "game_over" : "stopped", score: @board.score)
  end

  private

  # [option index, row, col], or nil when the player wants to stop.
  def ask_move
    row, col = ask_position
    return nil unless row

    index = @board.options.size > 1 ? ask_option : 0
    return nil unless index

    [index, row, col]
  end

  # [row, col], or nil to stop.
  def ask_position
    answer = ask("Select Row, Col: ")
    return nil if answer.nil? || answer.strip.casecmp("q").zero?

    row, col = answer.split(",").map(&:to_i)
    return nil if row.to_i.negative? || col.to_i.negative?

    [row.to_i % Board1010::ROWS, col.to_i % Board1010::COLS]
  end

  # The index of the chosen option, or nil to stop.
  def ask_option
    loop do
      answer = ask("option> ")
      return nil if answer.nil? || answer.casecmp("q").zero?

      number = answer.to_i
      return number - 1 if number.between?(1, @board.options.size)

      say("Invalid option #{answer}. Should be one of #{(1..@board.options.size).to_a}")
    end
  end

  def show
    show_board
    say("\n#{'=' * 20}\nCurrent score = #{@board.score}\n#{'=' * 20}")
    @board.options.each_with_index {|tile, index| say(" #{index + 1}> #{tile.inspect}") }
  end

  # The board with column numbers on top: "." is empty, "X" is filled.
  def show_board
    say("\n    #{(0...Board1010::COLS).to_a.join(' ')}")
    @board.cells.each_with_index do |values, row|
      squares = values.map {|value| value == Board1010::EMPTY ? "." : "X" }
      say(" #{row} [ #{squares.join(' ')} ]")
    end
  end

  def offer_to_save
    say("\n--- Game stopped: to be played later")
    answer = ask("Do you want to save the game to play it later? [y/n] ")
    return unless answer&.casecmp("y")&.zero?

    File.write(Board1010::SAVE_FILE, @board.to_save)
    say("Saved to #{Board1010::SAVE_FILE}")
  end

  def load_game
    return nil unless File.exist?(Board1010::SAVE_FILE)

    Board1010.from_save(File.read(Board1010::SAVE_FILE))
  end

  # The line typed, without the newline, or nil at the end of the input.
  def ask(prompt)
    @output.print(prompt)
    @input.gets&.chomp
  end

  def say(text)
    @output.puts(text)
  end
end

TerminalGame.new.run if __FILE__ == $PROGRAM_NAME
