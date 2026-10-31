# frozen_string_literal: true

require "digest"
require_relative "game_trace"
require_relative "improvement_search"
require_relative "lesson_store"

# Converts a replayable completed trace into a search lesson.
class LessonAnalyzer
  def analyze(path, time_budget_seconds: 1.0, beam_width: 4, max_states: 10_000,
              strategy: AutoPlayer::DEFAULT_STRATEGY)
    raise ArgumentError, "#{path} is not a versioned replayable .moves trace" unless GameTrace.versioned_file?(path)

    source_digest = Digest::SHA256.file(path).hexdigest
    trace = GameTrace.read(path)
    raise ArgumentError, "#{path} ended with #{trace.final_reason.inspect}; only Game Over episodes can be analyzed" unless trace.final_reason == "game_over"

    baseline = extract_final_trajectory(trace)
    raise ArgumentError, "#{path} is missing a replayable initial offer" if baseline[:offers].empty?

    starting_board = trace.starting_board.copy
    starting_board.replace_options(LessonStore.tiles_for(baseline[:offers].first))
    result = ImprovementSearch.search(starting_board: starting_board,
                                      baseline_score: baseline[:board].score,
                                      baseline_sequence: baseline[:sequence],
                                      fixed_offers: baseline[:offers],
                                      time_budget_seconds: time_budget_seconds,
                                      beam_width: beam_width, max_states: max_states,
                                      strategy: strategy, rollout_strategy: strategy)

    record = {
      schema_version: LessonStore::SCHEMA_VERSION,
      source_episode: {path: File.expand_path(path), sha256: source_digest,
                       seed: trace.seed, mode: trace.mode, final_reason: trace.final_reason},
      initial_state: {cells: trace.starting_board.cells, tile_ids: trace.starting_board.tile_ids,
                      score: trace.starting_board.score, options: baseline[:offers].first},
      offers: baseline[:offers],
      actual_sequence: baseline[:sequence], actual_score: baseline[:board].score,
      candidate_sequence: result.candidate_sequence, candidate_score: result.best_score,
      improvement_delta: result.score_delta,
      search: {strategy: strategy.to_sym, time_budget_seconds: Float(time_budget_seconds),
               beam_width: Integer(beam_width), max_states: Integer(max_states),
               elapsed_seconds: result.elapsed_seconds, explored_states: result.explored_states,
               transpositions_pruned: result.transpositions_pruned, status: result.status,
               candidate_complete: result.complete},
      outcome: result.score_delta.positive? ? "improved" : "no_improvement",
      provenance: [{path: File.expand_path(path), sha256: source_digest, seed: trace.seed,
                    actual_score: baseline[:board].score, candidate_score: result.best_score,
                    improvement_delta: result.score_delta, search_status: result.status,
                    candidate_complete: result.complete}]
    }

    actual_board = LessonStore.replay(record.transform_keys(&:to_s), "actual_sequence")
    candidate_board = LessonStore.replay(record.transform_keys(&:to_s), "candidate_sequence")
    raise ArgumentError, "actual sequence score does not match the completed trace" unless actual_board.score == trace.final_score
    raise ArgumentError, "candidate score does not match its replay" unless candidate_board.score == result.best_score
    raise ArgumentError, "source trace changed during analysis" unless Digest::SHA256.file(path).hexdigest == source_digest

    record
  end

  private

  # Undo events remove the corresponding action and any offer batch that was
  # introduced after it, leaving the exact final committed trajectory.
  def extract_final_trajectory(trace)
    board = trace.starting_board.copy
    sequence = []
    offers = [trace.deal_batches.first]
    board.replace_options(LessonStore.tiles_for(offers.first))
    undo_stack = []

    trace.events.each do |event|
      case event.first
      when :deal
        names = event[1].map {|tile| Board1010::TILES.key(tile) }
        offers << names
        board.replace_options(event[1])
      when :move
        _type, tile_name, option, row, col = event
        undo_stack << [board.copy, sequence.dup, offers.dup]
        actual = board.options[option]
        unless actual && Board1010::TILES.key(actual) == tile_name
          raise ArgumentError, "trace move selects #{tile_name.inspect} but option #{option} differs"
        end
        raise ArgumentError, "trace contains an illegal move" unless board.play(option, row, col, deal: false)

        sequence << {tile: tile_name, option: option, row: row, col: col}
      when :undo
        snapshot = undo_stack.pop || raise(ArgumentError, "trace undo has no corresponding move")
        board, sequence, offers = snapshot
      end
    end

    unless board.score == trace.final_score && board.game_over?
      raise ArgumentError, "trace does not replay to its declared Game Over state"
    end
    {board: board, sequence: sequence, offers: offers}
  end
end
