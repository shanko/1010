# frozen_string_literal: true

require_relative "artifact_file"
require_relative "game_trace"

# Publishes complete searched trajectories only after exact-offer replay succeeds.
class GameTraceWriter
  def self.write(path, source:, offers:, sequence:, expected_score:)
    raise ArgumentError, "output must end in .moves" unless path.end_with?(".moves")

    replay = OfferReplay.new(board: source.starting_board.copy, offers: offers)
    lines = [GameTrace::HEADER, "s#{source.seed || '-'}", "mode=improved",
             "r#{GameRules::VERSION}", *BoardSnapshot.records(replay.board)]
    sequence.each {|move| append_move(lines, replay, move) }
    board = replay.finish!(expected_score: expected_score)
    raise ArgumentError, "search result does not end at Game Over" unless board.game_over?

    lines << "zgame_over|#{board.score}"
    publish(path, lines)
  end

  def self.publish(path, lines)
    ArtifactFile.write(path, "#{lines.join("\n")}\n") {|staged| GameTrace.replay(GameTrace.read(staged)) }
  end
  private_class_method :publish

  def self.append_move(lines, replay, move)
    exhausted = replay.board.options.size == 1
    replay.apply(move)
    lines << "m#{move.fetch(:tile)},#{move.fetch(:option)},#{move.fetch(:row)},#{move.fetch(:col)}"
    lines << BoardSnapshot.offer_record(replay.board.options) if exhausted
  end
  private_class_method :append_move
end
