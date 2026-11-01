# frozen_string_literal: true

# The command coordinates trace validation, bounded search and report output.
# rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength, Metrics/CyclomaticComplexity
# rubocop:disable Metrics/PerceivedComplexity, Metrics/ParameterLists

require "json"
require "fileutils"
require_relative "game_trace"
require_relative "game_log"
require_relative "lesson_analyzer"
require_relative "lesson_store"
require_relative "improvement_search"

# Improves a finished trace while preserving its recorded offers and dealer seed.
class GameImprover
  Result = Struct.new(:trace_path, :report_path, :lesson_path, :report, keyword_init: true)
  DEFAULT_STATES = 50_000

  def improve(path, states: DEFAULT_STATES, time_budget_seconds: 86_400,
              beam_width: 4, output_path: nil, report_path: nil, save_lesson: false,
              lesson_directory: LessonStore::DIRECTORY)
    trace = GameTrace.read(path)
    unless trace.final_reason == "game_over"
      raise ArgumentError, "#{path} ended with #{trace.final_reason.inspect}; only Game Over traces can be improved"
    end

    baseline = LessonAnalyzer.new.final_trajectory(trace)
    seed_check = validate_seed(trace)
    start_board = starting_board(trace, baseline[:offers].first)
    search = ImprovementSearch.search(
      seed: trace.seed, starting_board: start_board, baseline_score: baseline[:board].score,
      baseline_sequence: baseline[:sequence], fixed_offers: baseline[:offers],
      continue_after_fixed_offers: !trace.seed.nil?, strategy: :sam, rollout_strategy: :sam,
      beam_width: beam_width, max_states: states, max_rollouts: [Integer(states), 100].min,
      rollouts_per_step: 2, time_budget_seconds: time_budget_seconds
    )
    keep_complete_baseline(search, baseline) unless search.complete
    output_path ||= improved_path(path)
    if File.expand_path(output_path) == File.expand_path(path)
      raise ArgumentError,
            "improved trace path must differ from the source"
    end

    report_path ||= output_path.sub(/\.moves\z/, ".report.json")
    write_improved_trace(output_path, trace, search.candidate_offers, search.candidate_sequence)
    output_trace = GameTrace.read(output_path)
    replayed = GameTrace.replay(output_trace)
    raise ArgumentError, "improved trace score does not match search result" unless replayed.score == search.best_score

    output_seed_check = validate_seed(output_trace)
    report = build_report(path, output_path, trace, output_trace, baseline, search,
                          seed_check, output_seed_check, states)
    write_report(report_path, report)
    lesson_path = if save_lesson
                    unless output_trace.final_reason == "game_over"
                      raise ArgumentError, "cannot save a lesson when recorded offers run out before Game Over"
                    end

                    lesson = LessonAnalyzer.new.analyze(output_path, time_budget_seconds: 0,
                                                         beam_width: beam_width, max_states: 1,
                                                         max_rollouts: 1)
                    LessonStore.new(directory: lesson_directory).save(lesson).fetch(:path)
                  end
    Result.new(trace_path: output_path, report_path: report_path, lesson_path: lesson_path, report: report)
  end

  def validate_seed(trace)
    return {consistent: false, reason: "trace has no seed; improvement is limited to recorded offers"} unless trace.seed

    initial = GameSimulator.initial_board(seed: trace.seed)
    expected_first = initial.options.map(&:name)
    actual_first = trace.deal_batches.first.map(&:to_sym)
    unless expected_first == actual_first
      return {consistent: false,
              reason:     "initial offer differs from the seeded dealer"}
    end

    replay_board = Board1010.new(cells: trace.starting_board.cells.map(&:dup),
                                 tile_ids: trace.starting_board.tile_ids.map(&:dup),
                                 score: trace.starting_board.score, random: initial.random)
    replay_board.replace_options(trace.deal_batches.first.map {|name| Tile.fetch(name) })
    replay = OfferReplay.new(board: replay_board, offers: trace.deal_batches)
    deal_index = 1
    trace.events.each do |event|
      case event.first
      when :deal
        dealer = replay.board
        expected = dealer.generate_options.map(&:name)
        actual = event[1].map(&:name)
        unless expected == actual
          return {consistent: false, reason: "recorded offer set #{deal_index + 1} differs from the seeded dealer"}
        end

        replay.feed_deal(event[1])
        deal_index += 1
      when :move
        replay.apply(event)
      when :undo
        replay.undo
      end
    end
    {consistent: true, reason: nil}
  rescue ArgumentError => e
    {consistent: false, reason: e.message}
  end

  private

  def keep_complete_baseline(search, baseline)
    search.best_score = baseline[:board].score
    search.score_delta = 0
    search.candidate_sequence = baseline[:sequence]
    search.candidate_offers = baseline[:offers]
    search.complete = true
    search.status = "no complete improvement within recorded offers"
  end

  def starting_board(trace, first_offer)
    random = trace.seed ? GameSimulator.initial_board(seed: trace.seed).random : Random.new(0)
    Board1010.new(cells: trace.starting_board.cells.map(&:dup),
                  tile_ids: trace.starting_board.tile_ids.map(&:dup),
                  score: trace.starting_board.score,
                  options: first_offer.map {|name| Tile.fetch(name) }, random: random)
  end

  def improved_path(path)
    return path.sub(/\.moves\z/, ".improved.moves") if path.end_with?(".moves")

    "#{path}.improved.moves"
  end

  def write_improved_trace(path, source, offers, sequence)
    raise ArgumentError, "output must end in .moves" unless path.end_with?(".moves")

    FileUtils.mkdir_p(File.dirname(path))
    board = source.starting_board.copy
    board.replace_options(offers.first.map {|name| Tile.fetch(name) })
    lines = [GameLog::VERSION_HEADER, "s#{source.seed || '-'}", "mode=improved",
             *BoardSnapshot.records(board)]
    offer_index = 0
    ending_reason = "game_over"
    sequence.each do |move|
      batch_exhausted = board.options.size == 1
      lines << "m#{move.fetch(:tile)},#{move.fetch(:option)},#{move.fetch(:row)},#{move.fetch(:col)}"
      played = board.play(move.fetch(:option), move.fetch(:row), move.fetch(:col), deal: false)
      raise ArgumentError, "search returned an illegal improved move" unless played
      next unless batch_exhausted

      offer_index += 1
      batch = offers[offer_index]
      unless batch
        ending_reason = "offers_exhausted"
        break
      end
      board.replace_options(batch.map {|name| Tile.fetch(name) })
      lines << BoardSnapshot.offer_record(batch.map {|name| Tile.fetch(name) })
    end
    unless board.game_over? || ending_reason == "offers_exhausted"
      raise ArgumentError, "search result does not end at Game Over"
    end

    lines << "z#{ending_reason}|#{board.score}"
    File.write(path, "#{lines.join("\n")}\n")
  end

  def build_report(source_path, output_path, source, output, baseline, search,
                   input_seed, output_seed, states_limit)
    source_moves = baseline[:sequence]
    improved_moves = search.candidate_sequence
    first_difference = source_moves.zip(improved_moves).index {|original, improved| original != improved }
    recorded_sets = [output.deal_batches.size, baseline[:offers].size].min
    move_costs, move_cost_rollouts = estimate_move_costs(source, baseline, rollout_budget: states_limit)
    costliest_moves = move_costs.select {|item| item[:estimated_cost]&.positive? }
    costliest_moves.sort_by! {|item| [-item.fetch(:estimated_cost), item.fetch(:move)] }
    {
      schema_version:                 1,
      source:                         File.expand_path(source_path),
      improved_trace:                 File.expand_path(output_path),
      seed:                           source.seed,
      source_logged_offer_sets:       source.deal_batches.size,
      original:                       {score: baseline[:board].score, moves: source_moves.size,
                 offer_sets: baseline[:offers].size},
      improved:                       {score: output.final_score, moves: improved_moves.size,
                 offer_sets: output.deal_batches.size},
      recorded_offer_sets_used:       recorded_sets,
      seeded_offer_sets_used:         [output.deal_batches.size - baseline[:offers].size, 0].max,
      first_change:                   first_difference && {move:     first_difference + 1,
                                                           original: source_moves[first_difference],
                                                           improved: improved_moves[first_difference]},
      costliest_moves:                costliest_moves.first(10),
      per_move_estimates:             move_costs,
      search:                         {states_explored: search.explored_states, states_limit: Integer(states_limit),
               rollouts: search.explored_rollouts, move_cost_rollouts: move_cost_rollouts,
               status: search.status,
               score_delta: search.score_delta},
      seed_consistent:                output_seed[:consistent],
      seed_consistency_reason:        output_seed[:reason],
      source_seed_consistent:         input_seed[:consistent],
      source_seed_consistency_reason: input_seed[:reason]
    }
  end

  def estimate_move_costs(trace, baseline, rollout_budget:)
    return [[], 0] if baseline[:sequence].empty?

    board = starting_board(trace, baseline[:offers].first)
    offer_index = 0
    player = AutoPlayer.new(:sam, random: Random.new(0))
    pair_budget = Integer(rollout_budget) / 2
    stride = [(baseline[:sequence].size.to_f / [pair_budget, 1].max).ceil, 1].max
    pairs_used = rollout_count = 0
    estimates = baseline[:sequence].each_with_index.map do |move, index|
      state = board.copy
      state_offer_index = offer_index
      alternative = best_alternative(state, move)
      estimate_now = alternative && pairs_used < pair_budget && (index % stride).zero?
      if estimate_now
        original_score = rollout_score(state, move, state_offer_index, baseline[:offers], trace.seed, player)
        alternative_score = rollout_score(state, alternative, state_offer_index, baseline[:offers], trace.seed, player)
        pairs_used += 1
        rollout_count += 2
      else
        original_score = alternative_score = nil
      end
      entry = {move: index + 1, tile: move.fetch(:tile).to_s,
               original: {row: move.fetch(:row), col: move.fetch(:col)},
               better: alternative && {row: alternative.fetch(:row), col: alternative.fetch(:col)},
               original_estimated_score: original_score,
               alternative_estimated_score: alternative_score,
               estimated_cost: if alternative
                                 alternative_score && (alternative_score - original_score)
                               else
                                 0
                               end}

      last_tile = board.options.size == 1
      board.play(move.fetch(:option), move.fetch(:row), move.fetch(:col), deal: false)
      if last_tile
        offer_index += 1
        load_offer(board, baseline[:offers], offer_index, trace.seed)
      end
      entry
    end
    [estimates, rollout_count]
  end

  def best_alternative(board, move)
    tile = Tile.fetch(move.fetch(:tile))
    option = board.options.index(tile)
    return unless option

    positions = board.positions_for(tile).reject do |row, col|
      row == move.fetch(:row) && col == move.fetch(:col)
    end
    alternatives = positions.map do |row, col|
      after = board.copy
      result = after.play(option, row, col, deal: false, capture: false)
      action = {tile: tile.name, option: option, row: row, col: col}
      [after.legal_placement_count(after.options) + ((result.cleared_rows.size + result.cleared_cols.size) * 20),
       action]
    end
    alternatives.max_by {|rank, action| [rank, -action.fetch(:row), -action.fetch(:col)] }&.last
  end

  def rollout_score(state, first_move, offer_index, offers, seed, player)
    board = state.copy
    offer_index = apply_estimated_move(board, first_move, offers, offer_index, seed)
    until board.game_over?
      option, row, col = player.choose_move(board)
      move = {tile: board.options[option].name, option: option, row: row, col: col}
      offer_index = apply_estimated_move(board, move, offers, offer_index, seed)
    end
    board.score
  end

  def apply_estimated_move(board, move, offers, offer_index, seed)
    last_tile = board.options.size == 1
    board.play(move.fetch(:option), move.fetch(:row), move.fetch(:col), deal: false)
    return offer_index unless last_tile

    next_index = offer_index + 1
    load_offer(board, offers, next_index, seed)
    next_index
  end

  def load_offer(board, offers, index, seed)
    if index < offers.size
      board.generate_options if seed
      board.replace_options(offers[index].map {|name| Tile.fetch(name) })
    elsif seed
      board.replace_options(board.generate_options)
    end
  end

  def write_report(path, report)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.pretty_generate(report)}\n")
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength, Metrics/CyclomaticComplexity
# rubocop:enable Metrics/PerceivedComplexity, Metrics/ParameterLists
