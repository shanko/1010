# frozen_string_literal: true

require_relative "board"

# Reads and replays v2 game traces without depending on Gosu or random dealing.
class GameTrace
  HEADER = "1010-moves-v2"
  Trace = Struct.new(:seed, :mode, :starting_board, :deal_batches, :events,
                     :final_reason, :final_score, keyword_init: true)

  def self.versioned_file?(path)
    File.open(path, "r") {|file| file.gets&.chomp == HEADER }
  end

  def self.read(path)
    lines = File.readlines(path, chomp: true)
    raise ArgumentError, "#{path} is not a v2 1010 trace" unless lines.shift == HEADER

    seed_line = lines.shift
    raise ArgumentError, "#{path} has an invalid seed header" unless seed_line&.match?(/\As(?:-|\d+)\z/)
    seed = Integer(seed_line[1..], exception: false)

    mode_line = lines.shift
    raise ArgumentError, "#{path} has an invalid mode header" unless mode_line&.match?(/\Amode=[a-z_]+\z/)
    mode = mode_line.delete_prefix("mode=")

    state_line = lines.shift
    match = state_line&.match(/\Ai(\d+)\|([0-5]{100})\|([0-9a-j]{100})\z/)
    raise ArgumentError, "#{path} has an invalid initial board snapshot" unless match

    score = Integer(match[1])
    cells = decode_grid(match[2], 10)
    tile_ids = decode_grid(match[3], 36)
    board = Board1010.new(cells: cells, tile_ids: tile_ids, score: score)
    deals = []
    events = []
    final_reason = nil
    final_score = nil

    lines.each_with_index do |line, index|
      raise ArgumentError, "#{path} contains data after its end record" if final_reason

      case line
      when /\Ad(.*)\z/
        names = Regexp.last_match(1).split(",")
        tiles = parse_tiles(names, path, index + 5)
        unless tiles.size.between?(1, Board1010::OPTIONS)
          raise ArgumentError, "#{path} has an invalid offer batch on line #{index + 5}"
        end
        deals << names
        if deals.size == 1
          board.replace_options(tiles)
        else
          events << [:deal, tiles]
        end
      when /\Am([a-z0-9]+),([0-2]),([0-9]),([0-9])\z/
        name, option, row, col = Regexp.last_match.captures
        raise ArgumentError, "#{path} contains an unknown tile #{name.inspect}" unless Board1010::TILES.key?(name.to_sym)
        events << [:move, name.to_sym, option.to_i, row.to_i, col.to_i]
      when "u"
        events << [:undo]
      when /\Az([a-z_]+)\|(\d+)\z/
        final_reason = Regexp.last_match(1)
        final_score = Integer(Regexp.last_match(2))
        events << [:end, final_reason, final_score]
      else
        raise ArgumentError, "#{path} has invalid record on line #{index + 5}: #{line.inspect}"
      end
    end

    raise ArgumentError, "#{path} is incomplete: missing the initial offer batch" if deals.empty?
    raise ArgumentError, "#{path} is incomplete: missing the end record" unless final_reason

    Trace.new(seed: seed, mode: mode, starting_board: board, deal_batches: deals,
              events: events, final_reason: final_reason, final_score: final_score)
  end

  def self.replay(trace)
    board = trace.starting_board.copy
    previous_board = nil

    trace.events.each_with_index do |event, index|
      case event.first
      when :deal
        board.replace_options(event[1])
      when :move
        _type, tile_name, option, row, col = event
        actual_tile = board.options[option]
        unless actual_tile && Board1010::TILES.key(actual_tile) == tile_name
          raise ArgumentError, "trace move #{index + 1} selects #{tile_name.inspect} but option #{option} differs"
        end

        previous_board = board.copy
        unless board.play(option, row, col, deal: false)
          raise ArgumentError, "trace move #{index + 1} is not legal on the recorded board"
        end
      when :undo
        raise ArgumentError, "trace undo #{index + 1} has no move to undo" unless previous_board

        board = previous_board
        previous_board = nil
      when :end
        reason, expected_score = event.drop(1)
        raise ArgumentError, "trace final score mismatch: expected #{expected_score}, replayed #{board.score}" unless board.score == expected_score
        if reason == "game_over" && !board.game_over?
          raise ArgumentError, "trace ends as Game Over while a current tile still fits"
        end
      end
    end

    board
  end

  def self.decode_grid(text, base)
    text.chars.each_slice(10).map {|row| row.map {|character| character.to_i(base) } }
  end
  private_class_method :decode_grid

  def self.parse_tiles(names, path, line)
    names.map do |name|
      tile = Board1010::TILES[name.to_sym]
      raise ArgumentError, "#{path} has unknown tile #{name.inspect} on line #{line}" unless tile

      tile
    end
  end
  private_class_method :parse_tiles
end
