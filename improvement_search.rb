# frozen_string_literal: true

require "time"
require_relative "game_simulator"

# Bounded, anytime beam search. State and rollout counts are the reproducible
# work budgets; elapsed time is only a safety cap.
class ImprovementSearch
  VERSION = 2
  PathNode = Struct.new(:parent, :action, keyword_init: true)
  OfferNode = Struct.new(:parent, :batch, :batch_count, keyword_init: true)
  Node = Struct.new(:board, :path, :offer_history, :next_offer_index, :depth,
                    :offer_exhausted, :rank_score, :rng_position, keyword_init: true)
  Result = Struct.new(:seed, :mode, :baseline_strategy, :baseline_score, :best_score,
                      :score_delta, :elapsed_seconds, :explored_states, :explored_rollouts,
                      :transpositions_pruned, :candidate_sequence, :baseline_sequence,
                      :candidate_offers, :complete, :status, :cap_reason, keyword_init: true)

  def self.search(**options)
    new.search(**options)
  end

  def search(seed: nil, strategy: AutoPlayer::DEFAULT_STRATEGY, starting_board: nil,
             baseline_score: nil, baseline_sequence: nil, fixed_offers: nil,
             time_budget_seconds: 30.0, beam_width: 4, max_states: 10_000,
             max_rollouts: 100, rollouts_per_step: 2,
             rollout_strategy: strategy, baseline_model: nil, rollout_model: baseline_model,
             clock: nil)
    budget = Float(time_budget_seconds)
    raise ArgumentError, "time budget must be finite and non-negative" unless budget.finite? && budget >= 0
    beam_width = Integer(beam_width)
    max_states = Integer(max_states)
    max_rollouts = Integer(max_rollouts)
    rollouts_per_step = Integer(rollouts_per_step)
    raise ArgumentError, "beam width must be positive" unless beam_width.positive?
    raise ArgumentError, "max states must be positive" unless max_states.positive?
    raise ArgumentError, "max rollouts must be positive" unless max_rollouts.positive?
    raise ArgumentError, "rollouts per step must be positive" unless rollouts_per_step.positive?

    @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    seed = Integer(seed) unless seed.nil?
    strategy = strategy.to_sym
    rollout_strategy = rollout_strategy.to_sym
    baseline_result = nil

    if starting_board
      raise ArgumentError, "baseline_score is required with starting_board" if baseline_score.nil?

      root_board = starting_board.copy
      baseline_score = Integer(baseline_score)
      baseline_sequence = normalize_sequence(baseline_sequence || [])
    else
      raise ArgumentError, "seed or starting_board is required" if seed.nil?

      baseline_result = GameSimulator.run(seed: seed, strategy: strategy, model: baseline_model)
      root_board = GameSimulator.initial_board(seed: seed)
      baseline_score = baseline_result.score
      baseline_sequence = sequence_from_result(baseline_result)
    end

    fixed_offers = baseline_result.offers if fixed_offers == :baseline && baseline_result
    raise ArgumentError, "fixed_offers: :baseline requires a seeded search" if fixed_offers == :baseline
    fixed_offers = normalize_offers(fixed_offers) if fixed_offers

    initial_names = root_board.options.map(&:name).freeze
    if fixed_offers && fixed_offers.first != initial_names
      raise ArgumentError, "first fixed offer must match the starting board's current options"
    end

    mode = fixed_offers ? :fixed_offers : :seeded
    root_history = OfferNode.new(parent: nil, batch: initial_names, batch_count: 1)
    root = Node.new(board: root_board, path: nil, offer_history: root_history,
                    next_offer_index: 1, depth: 0, offer_exhausted: false,
                    rank_score: cheap_rank(root_board), rng_position: fixed_offers ? 0 : Board1010::OPTIONS)
    best_score = baseline_score
    best_node = nil
    best_offers = baseline_result ? baseline_result.offers : [initial_names]
    best_complete = true # the baseline is a complete trajectory
    started_at = monotonic_time
    deadline = started_at + budget
    explored_states = 0
    explored_rollouts = 0
    transpositions_pruned = 0
    state_capped = false
    rollout_capped = false
    time_capped = false
    beam = [root]
    visited = {state_key(root, fixed_offers) => true}

    while !beam.empty?
      candidates = []
      beam.each do |node|
        each_legal_action(node.board) do |action|
          if monotonic_time >= deadline
            time_capped = true
            break
          end
          if explored_states >= max_states
            state_capped = true
            break
          end

          child = advance(node, action, fixed_offers)
          key = state_key(child, fixed_offers)
          if visited.key?(key)
            transpositions_pruned += 1
            next
          end
          visited[key] = true
          explored_states += 1

          if child.offer_exhausted
            if child.board.score > best_score
              best_score = child.board.score
              best_node = child
              best_complete = false
            end
            next
          end

          if child.board.game_over?
            if child.board.score > best_score || (child.board.score == best_score && !best_complete)
              best_score = child.board.score
              best_node = child
              best_complete = true
            end
            next
          end

          child.rank_score = cheap_rank(child.board)
          candidates << child
        end
        break if time_capped || state_capped
      end

      break if time_capped

      ranked = candidates.each_with_index.sort_by {|(node, index)| [-node.rank_score, index] }.map(&:first)
      remaining_rollouts = max_rollouts - explored_rollouts
      rollout_count = [rollouts_per_step, remaining_rollouts].min
      ranked.first(rollout_count).each do |child|
        if monotonic_time >= deadline
          time_capped = true
          break
        end

        explored_rollouts += 1
        rollout = rollout_from(child, fixed_offers: fixed_offers,
                                strategy: rollout_strategy, model: rollout_model,
                                seed: rollout_seed(seed, explored_rollouts), deadline: deadline)
        if rollout[:timed_out]
          time_capped = true
          break
        end

        child.rank_score = rollout[:score]
        next unless rollout[:score] > best_score ||
                    (rollout[:score] == best_score && rollout[:complete] && !best_complete)

        best_score = rollout[:score]
        best_node = rollout[:node]
        best_complete = rollout[:complete]
      end

      break if time_capped
      ranked = ranked.each_with_index.sort_by {|(node, index)| [-node.rank_score, index] }.map(&:first)
      rollout_capped = true if remaining_rollouts <= rollout_count && ranked.size > rollout_count
      break if rollout_capped || state_capped

      beam = ranked.first(beam_width)
    end

    elapsed = monotonic_time - started_at
    cap_reason = if time_capped
                   "time"
                 elsif state_capped
                   "states"
                 elsif rollout_capped
                   "rollouts"
                 end
    status = if time_capped
               "time_capped"
             elsif best_score > baseline_score
               "improved"
             elsif state_capped || rollout_capped
               "budget exhausted"
             else
               "no improvement found within budget"
             end

    Result.new(seed: seed, mode: mode, baseline_strategy: strategy,
               baseline_score: baseline_score, best_score: best_score,
               score_delta: best_score - baseline_score, elapsed_seconds: elapsed,
               explored_states: explored_states, explored_rollouts: explored_rollouts,
               transpositions_pruned: transpositions_pruned,
               candidate_sequence: best_node ? sequence_for(best_node.path) : baseline_sequence,
               baseline_sequence: baseline_sequence,
               candidate_offers: best_node ? offers_for(best_node.offer_history) : best_offers,
               complete: best_complete, status: status, cap_reason: cap_reason)
  end

  private

  def each_legal_action(board)
    board.options.each_with_index do |tile, option_index|
      board.positions_for(tile).each do |row, col|
        yield({tile: tile.name, option: option_index, row: row, col: col}.freeze)
      end
    end
  end

  def advance(node, action, fixed_offers)
    board = node.board.copy
    option_count = board.options.size
    move = board.play(action.fetch(:option), action.fetch(:row), action.fetch(:col), deal: fixed_offers.nil?)
    raise RuntimeError, "search generated an illegal move #{action.inspect}" unless move

    offer_history = node.offer_history
    next_offer_index = node.next_offer_index
    offer_exhausted = false
    rng_position = node.rng_position
    if option_count == 1
      if fixed_offers
        next_names = fixed_offers[next_offer_index]
        if next_names
          board.replace_options(next_names.map {|name| Tile.fetch(name) })
          offer_history = append_offer(offer_history, next_names)
          next_offer_index += 1
        else
          offer_exhausted = true
        end
      else
        offer_history = append_offer(offer_history, board.options.map(&:name))
        # Seeded branches consume the same number of tile samples per deal;
        # this logical cursor avoids marshaling Random's large internal state.
        rng_position += Board1010::OPTIONS
      end
    end

    Node.new(board: board, path: PathNode.new(parent: node.path, action: action),
             offer_history: offer_history, next_offer_index: next_offer_index,
             depth: node.depth + 1, offer_exhausted: offer_exhausted,
             rank_score: board.score, rng_position: rng_position)
  end

  def rollout_from(node, fixed_offers:, strategy:, model:, seed:, deadline:)
    player = AutoPlayer.new(strategy, random: Random.new(seed), model: model)
    current = node

    loop do
      return {node: current, score: current.board.score, complete: false, timed_out: true} if monotonic_time >= deadline
      return {node: current, score: current.board.score, complete: false} if current.offer_exhausted
      return {node: current, score: current.board.score, complete: true} if current.board.game_over?

      index, row, col = player.choose_move(current.board)
      action = {tile: current.board.options[index].name, option: index, row: row, col: col}.freeze
      current = advance(current, action, fixed_offers)
    end
  end

  def append_offer(history, batch)
    OfferNode.new(parent: history, batch: batch.dup.freeze, batch_count: history.batch_count + 1)
  end

  def sequence_for(path)
    sequence = []
    while path
      sequence << path.action
      path = path.parent
    end
    sequence.reverse
  end

  def offers_for(history)
    batches = []
    while history
      batches << history.batch
      history = history.parent
    end
    batches.reverse
  end

  def cheap_rank(board)
    board.score + (board.legal_placement_count(board.options) * 2.0)
  end

  def state_key(node, fixed_offers)
    options = node.board.options.map(&:name).join(",")
    # The cursor distinguishes future deal streams; fixed offers use their
    # current batch index instead. Tile colors do not affect legality or score.
    offer_position = fixed_offers ? node.next_offer_index : node.rng_position
    [node.board.occupied_bits, options, node.board.score, node.depth, offer_position]
  end

  def normalize_offers(offers)
    offers.map do |batch|
      names = batch.map(&:to_sym)
      names.each {|name| Tile.fetch(name) }
      names
    end
  end

  def sequence_from_result(result)
    result.moves.map {|move| {tile: move[:tile], option: move[:option], row: move[:row], col: move[:col]}.freeze }
  end

  def normalize_sequence(sequence)
    sequence.map do |move|
      {tile: move.fetch(:tile).to_sym, option: Integer(move.fetch(:option)),
       row: Integer(move.fetch(:row)), col: Integer(move.fetch(:col))}.freeze
    end
  end

  def rollout_seed(seed, rollout_number)
    ((seed || 0) ^ (rollout_number * 2_654_435_761)) % (2**32)
  end

  def monotonic_time
    @clock.call
  end
end
