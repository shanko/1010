# frozen_string_literal: true

require_relative "board"
require_relative "offer_replay"

# Reads v2/v3 game traces without Gosu and replays them without random dealing.
class GameTrace
  HEADER = "1010-moves-v3"
  LEGACY_HEADER = "1010-moves-v2"
  Trace = Struct.new(:seed, :mode, :starting_board, :deal_batches, :events,
                     :final_reason, :final_score, keyword_init: true)
  ParseState = Struct.new(:seed, :mode, :board, :deals, :events, :final_reason, :final_score,
                          keyword_init: true)

  def self.versioned_file?(path)
    File.open(path, "r") {|file| [HEADER, LEGACY_HEADER].include?(file.gets&.chomp) }
  end

  def self.read(path)
    lines = File.readlines(path, chomp: true)
    compact = validate_version!(path, lines.shift)
    state = read_headers(path, lines)
    parse_records(path, lines, state, compact)
    validate_complete!(path, state)
    Trace.new(seed: state.seed, mode: state.mode, starting_board: state.board,
              deal_batches: state.deals, events: state.events,
              final_reason: state.final_reason, final_score: state.final_score)
  end

  def self.validate_version!(path, version)
    raise ArgumentError, "#{path} is not a v2 or v3 1010 trace" unless [HEADER, LEGACY_HEADER].include?(version)

    version == HEADER
  end
  private_class_method :validate_version!

  def self.read_headers(path, lines)
    seed = parse_seed_header(path, lines.shift)
    mode = parse_mode_header(path, lines.shift)
    board = parse_board_header(path, lines.shift)
    ParseState.new(seed: seed, mode: mode, board: board, deals: [], events: [])
  end
  private_class_method :read_headers

  def self.parse_seed_header(path, line)
    raise ArgumentError, "#{path} has an invalid seed header" unless line&.match?(/\As(?:-|\d+)\z/)

    Integer(line[1..], exception: false)
  end
  private_class_method :parse_seed_header

  def self.parse_mode_header(path, line)
    raise ArgumentError, "#{path} has an invalid mode header" unless line&.match?(/\Amode=[a-z_]+\z/)

    line.delete_prefix("mode=")
  end
  private_class_method :parse_mode_header

  def self.parse_board_header(path, line)
    board = line && BoardSnapshot.decode_state(line)
    raise ArgumentError, "#{path} has an invalid initial board snapshot" unless board

    board
  end
  private_class_method :parse_board_header

  def self.parse_records(path, lines, state, compact)
    lines.each_with_index {|line, index| parse_record(path, line, index, state, compact) }
  end
  private_class_method :parse_records

  def self.parse_record(path, line, index, state, compact)
    raise ArgumentError, "#{path} contains data after its end record" if state.final_reason

    case line
    when /\Ad(.*)\z/ then parse_deal_record(path, line, index, state, compact)
    when /\Am([a-z0-9]+),([0-2]),([0-9]),([0-9])\z/ then parse_move_record(line, state)
    when "u" then state.events << [:undo]
    when /\Az([a-z_]+)\|(\d+)\z/ then parse_end_record(line, state)
    else raise ArgumentError, "#{path} has invalid record on line #{index + 5}: #{line.inspect}"
    end
  end
  private_class_method :parse_record

  def self.parse_deal_record(path, line, index, state, compact)
    tiles = compact ? BoardSnapshot.decode_offer(line) : decode_legacy_offer(line, path, index)
    raise ArgumentError, "#{path} has an invalid offer batch on line #{index + 5}" unless valid_offer?(tiles)

    state.deals << tiles.map {|tile| tile.name.to_s }
    add_deal_event(state, tiles)
  end
  private_class_method :parse_deal_record

  def self.valid_offer?(tiles)
    tiles&.size&.between?(1, Board1010::OPTIONS)
  end
  private_class_method :valid_offer?

  def self.add_deal_event(state, tiles)
    if state.deals.size == 1
      state.board.replace_options(tiles)
    else
      state.events << [:deal, tiles]
    end
  end
  private_class_method :add_deal_event

  def self.parse_move_record(line, state)
    name, option, row, col = /\Am([a-z0-9]+),([0-2]),([0-9]),([0-9])\z/.match(line).captures
    Tile.fetch(name)
    state.events << [:move, name.to_sym, option.to_i, row.to_i, col.to_i]
  end
  private_class_method :parse_move_record

  def self.parse_end_record(line, state)
    match = /\Az([a-z_]+)\|(\d+)\z/.match(line)
    state.final_reason = match[1]
    state.final_score = Integer(match[2])
    state.events << [:end, state.final_reason, state.final_score]
  end
  private_class_method :parse_end_record

  def self.validate_complete!(path, state)
    raise ArgumentError, "#{path} is incomplete: missing the initial offer batch" if state.deals.empty?
    raise ArgumentError, "#{path} is incomplete: missing the end record" unless state.final_reason
  end
  private_class_method :validate_complete!

  def self.replay(trace)
    board = trace.starting_board.copy
    replay = OfferReplay.new(board: board, offers: trace.deal_batches)

    trace.events.each {|event| replay_event(event, replay) }

    replay.board
  end

  def self.replay_event(event, replay)
    case event.first
    when :deal then replay.feed_deal(event[1])
    when :move then replay.apply(event)
    when :undo then replay.undo
    when :end then replay_end(event, replay)
    end
  end
  private_class_method :replay_event

  def self.replay_end(event, replay)
    reason, expected_score = event.drop(1)
    replay.finish!(expected_score: expected_score, require_all_offers: false)
    return unless reason == "game_over" && !replay.board.game_over?

    raise ArgumentError, "trace ends as Game Over while a current tile still fits"
  end
  private_class_method :replay_end

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
