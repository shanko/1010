# frozen_string_literal: true

require "digest"
require_relative "game_trace"
require_relative "improvement_search"
require_relative "lesson_store"
require_relative "offer_replay"

# Converts a replayable completed trace into a search lesson.
class LessonAnalyzer
  def analyze(path, time_budget_seconds: 30.0, beam_width: 4, max_states: 10_000,
              max_rollouts: 8, rollouts_per_step: 2,
              strategy: AutoPlayer::DEFAULT_STRATEGY, clock: nil)
    source_digest, trace, baseline = read_source(path)
    options = {time_budget_seconds: time_budget_seconds, beam_width: beam_width,
               max_states: max_states, max_rollouts: max_rollouts,
               rollouts_per_step: rollouts_per_step, strategy: strategy,
               rollout_strategy: strategy, clock: clock}
    result = search(trace, baseline, options)
    record = build_record(path, source_digest, trace, baseline, result, options)
    validate_record!(path, record, trace, result)
    verify_source_unchanged!(path, source_digest)
    record
  end

  def final_trajectory(trace)
    extract_final_trajectory(trace)
  end

  private

  def read_source(path)
    raise ArgumentError, "#{path} is not a versioned replayable .moves trace" unless GameTrace.versioned_file?(path)

    source_digest = Digest::SHA256.file(path).hexdigest
    trace = GameTrace.read(path)
    unless trace.final_reason == "game_over"
      message = ["#{path} ended with #{trace.final_reason.inspect};", "only Game Over episodes can be analyzed"].join(" ")
      raise ArgumentError, message
    end
    baseline = extract_final_trajectory(trace)
    raise ArgumentError, "#{path} is missing a replayable initial offer" if baseline[:offers].empty?

    [source_digest, trace, baseline]
  end

  def search(trace, baseline, options)
    starting_board = trace.starting_board.copy
    starting_board.replace_options(baseline[:offers].first.map {|name| Tile.fetch(name) })
    ImprovementSearch.search(starting_board: starting_board,
                             baseline_score: baseline[:board].score,
                             baseline_sequence: baseline[:sequence], fixed_offers: baseline[:offers],
                             **options)
  end

  def build_record(path, source_digest, trace, baseline, result, options)
    record_header(path, source_digest, trace, baseline).merge(
      trajectory_record(baseline, result),
      search: search_record(result, options),
      outcome: result.score_delta.positive? ? "improved" : "no_improvement",
      provenance: [provenance_record(path, source_digest, trace, baseline, result)]
    )
  end

  def record_header(path, source_digest, trace, baseline)
    {schema_version: LessonStore::SCHEMA_VERSION,
     source_episode: {path: File.expand_path(path), sha256: source_digest,
                      seed: trace.seed, mode: trace.mode, final_reason: trace.final_reason},
     initial_state: {cells: trace.starting_board.cells, tile_ids: trace.starting_board.tile_ids,
                     score: trace.starting_board.score, options: baseline[:offers].first}}
  end

  def trajectory_record(baseline, result)
    {offers: baseline[:offers], actual_sequence: baseline[:sequence], actual_score: baseline[:board].score,
     candidate_sequence: result.candidate_sequence, candidate_score: result.best_score,
     improvement_delta: result.score_delta}
  end

  def search_record(result, options)
    search_limits(options).merge(search_result(result), version: ImprovementSearch::VERSION,
                                strategy: options.fetch(:strategy).to_sym)
  end

  def search_limits(options)
    {time_budget_seconds: Float(options.fetch(:time_budget_seconds)),
     beam_width: Integer(options.fetch(:beam_width)), max_states: Integer(options.fetch(:max_states)),
     max_rollouts: Integer(options.fetch(:max_rollouts)),
     rollouts_per_step: Integer(options.fetch(:rollouts_per_step))}
  end

  def search_result(result)
    {explored_states: result.explored_states, explored_rollouts: result.explored_rollouts,
     transpositions_pruned: result.transpositions_pruned, status: result.status,
     cap_reason: result.cap_reason, candidate_complete: result.complete}
  end

  def provenance_record(path, source_digest, trace, baseline, result)
    {path: File.expand_path(path), sha256: source_digest, seed: trace.seed,
     actual_score: baseline[:board].score, candidate_score: result.best_score,
     improvement_delta: result.score_delta, search_status: result.status,
     candidate_complete: result.complete}
  end

  def validate_record!(path, record, trace, result)
    actual_board = LessonStore.replay(record.transform_keys(&:to_s), "actual_sequence")
    candidate_board = LessonStore.replay(record.transform_keys(&:to_s), "candidate_sequence")
    unless actual_board.score == trace.final_score
      raise ArgumentError,
            "actual sequence score does not match the completed trace"
    end
    raise ArgumentError, "candidate score does not match its replay" unless candidate_board.score == result.best_score
  end

  def verify_source_unchanged!(path, source_digest)
    unless Digest::SHA256.file(path).hexdigest == source_digest
      raise ArgumentError,
            "source trace changed during analysis"
    end
  end

  # Undo events remove the corresponding action and any offer batch that was
  # introduced after it, leaving the exact final committed trajectory.
  def extract_final_trajectory(trace)
    board = trace.starting_board.copy
    sequence = []
    offers = [trace.deal_batches.first]
    replay = OfferReplay.new(board: board, offers: trace.deal_batches)
    undo_stack = []

    trace.events.each {|event| replay_trajectory_event(event, replay, undo_stack, sequence, offers) }

    board = replay.board
    unless board.score == trace.final_score && board.game_over?
      raise ArgumentError, "trace does not replay to its declared Game Over state"
    end

    {board: board, sequence: sequence, offers: offers}
  end

  def replay_trajectory_event(event, replay, undo_stack, sequence, offers)
    case event.first
      when :deal
        replay_deal_event(event[1], replay, offers)
      when :move
        replay_move_event(event, replay, undo_stack, sequence, offers)
      when :undo
        replay_undo_event(replay, undo_stack, sequence, offers)
    end
  end

  def replay_deal_event(tiles, replay, offers)
    replay.feed_deal(tiles)
    offers << tiles.map(&:name)
  end

  def replay_move_event(event, replay, undo_stack, sequence, offers)
    undo_stack << [sequence.dup, offers.dup]
    replay.apply(event)
    _type, tile_name, option, row, col = event
    sequence << {tile: tile_name, option: option, row: row, col: col}
  end

  def replay_undo_event(replay, undo_stack, sequence, offers)
    snapshot = undo_stack.pop || raise(ArgumentError, "trace undo has no corresponding move")
    replay.undo
    sequence.replace(snapshot[0])
    offers.replace(snapshot[1])
  end
end
