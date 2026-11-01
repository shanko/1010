# frozen_string_literal: true

require_relative "board"
require_relative "offer_replay"

# Reads v2/v3 game traces without Gosu and replays them without random dealing.
class GameTrace
  HEADER = "1010-moves-v3"
  LEGACY_HEADER = "1010-moves-v2"
  Trace = Struct.new(:seed, :mode, :starting_board, :deal_batches, :events,
                     :final_reason, :final_score, keyword_init: true)

  def self.versioned_file?(path)
    File.open(path, "r") {|file| [HEADER, LEGACY_HEADER].include?(file.gets&.chomp) }
  end

  def self.read(path)
    lines = File.readlines(path, chomp: true)
    version = lines.shift
    raise ArgumentError, "#{path} is not a v2 or v3 1010 trace" unless [HEADER, LEGACY_HEADER].include?(version)

    compact = version == HEADER

    seed_line = lines.shift
    raise ArgumentError, "#{path} has an invalid seed header" unless seed_line&.match?(/\As(?:-|\d+)\z/)

    seed = Integer(seed_line[1..], exception: false)

    mode_line = lines.shift
    raise ArgumentError, "#{path} has an invalid mode header" unless mode_line&.match?(/\Amode=[a-z_]+\z/)

    mode = mode_line.delete_prefix("mode=")

    state_line = lines.shift
    board = state_line && BoardSnapshot.decode_state(state_line)
    raise ArgumentError, "#{path} has an invalid initial board snapshot" unless board

    deals = []
    events = []
    final_reason = nil
    final_score = nil

    lines.each_with_index do |line, index|
      raise ArgumentError, "#{path} contains data after its end record" if final_reason

      case line
      when /\Ad(.*)\z/
        tiles = compact ? BoardSnapshot.decode_offer(line) : decode_legacy_offer(line, path, index)
        raise ArgumentError, "#{path} has an invalid offer batch on line #{index + 5}" unless tiles

        names = tiles.map {|tile| tile.name.to_s }
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
        Tile.fetch(name)
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
    replay = OfferReplay.new(board: board, offers: trace.deal_batches)

    trace.events.each_with_index do |event, _index|
      case event.first
      when :deal
        replay.feed_deal(event[1])
      when :move
        replay.apply(event)
      when :undo
        replay.undo
        board = replay.board
      when :end
        reason, expected_score = event.drop(1)
        replay.finish!(expected_score: expected_score, require_all_offers: false)
        if reason == "game_over" && !board.game_over?
          raise ArgumentError, "trace ends as Game Over while a current tile still fits"
        end
      end
    end

    replay.board
  end

  def self.decode_legacy_offer(line, path, index)
    names = line.delete_prefix("d").split(",")
    names.map do |name|
      Tile.fetch(name)
    rescue ArgumentError
      raise ArgumentError, "#{path} has unknown tile #{name.inspect} on line #{index + 5}"
    end
  end
  private_class_method :decode_legacy_offer
end
