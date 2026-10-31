# frozen_string_literal: true

require "time"
require_relative "game_simulator"

# Bounded, anytime beam search. It keeps the best complete (or fixed-offer
# horizon) trajectory found while ranking frontier states with fast rollouts.
class ImprovementSearch
  VERSION = 1
  Node = Struct.new(:board, :sequence, :offers, :next_offer_index, :depth,
                    :offer_exhausted, :rank_score, keyword_init: true)
  Result = Struct.new(:seed, :mode, :baseline_strategy, :baseline_score, :best_score,
                      :score_delta, :elapsed_seconds, :explored_states,
                      :transpositions_pruned, :candidate_sequence, :baseline_sequence,
                      :candidate_offers, :complete, :status, keyword_init: true)

  def self.search(**options)
    new.search(**options)
  end

  def search(seed: nil, strategy: AutoPlayer::DEFAULT_STRATEGY, starting_board: nil,
             baseline_score: nil, baseline_sequence: nil, fixed_offers: nil,
             time_budget_seconds: 1.0, beam_width: 4, max_states: 10_000,
             rollout_strategy: strategy, baseline_model: nil, rollout_model: baseline_model)
    budget = Float(time_budget_seconds)
    raise ArgumentError, "time budget must be finite and non-negative" unless budget.finite? && budget >= 0
    beam_width = Integer(beam_width)
    max_states = Integer(max_states)
    raise ArgumentError, "beam width must be positive" unless beam_width.positive?
    raise ArgumentError, "max states must be positive" unless max_states.positive?

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

    initial_names = root_board.options.map(&:name)
    if fixed_offers && fixed_offers.first != initial_names
      raise ArgumentError, "first fixed offer must match the starting board's current options"
    end

    mode = fixed_offers ? :fixed_offers : :seeded
    root = Node.new(board: root_board, sequence: [], offers: [initial_names],
                    next_offer_index: 1, depth: 0, offer_exhausted: false,
                    rank_score: root_board.score)
    best_score = baseline_score
    best_sequence = baseline_sequence
    best_offers = baseline_result ? baseline_result.offers : [initial_names]
    best_complete = true # the baseline is a complete trajectory
    started_at = monotonic_time
    deadline = started_at + budget
    explored_states = 0
    transpositions_pruned = 0
    budget_exhausted = false
    beam = [root]
    visited = {state_key(root, fixed_offers) => true}

    while !beam.empty?
      break if budget_exhausted

      candidates = []
      beam.each do |node|
        each_legal_action(node.board) do |action|
          if monotonic_time >= deadline || explored_states >= max_states
            budget_exhausted = true
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
              best_sequence = child.sequence
              best_offers = child.offers
              best_complete = false
            end
            next
          end

          if child.board.game_over?
            if child.board.score > best_score || (child.board.score == best_score && !best_complete)
              best_score = child.board.score
              best_sequence = child.sequence
              best_offers = child.offers
              best_complete = true
            end
            next
          end

          rollout = rollout_from(child, fixed_offers: fixed_offers,
                                  strategy: rollout_strategy,
                                  model: rollout_model,
                                  seed: rollout_seed(seed, explored_states),
                                  deadline: deadline)
          child.rank_score = rollout[:score]
          if rollout[:score] > best_score || (rollout[:score] == best_score && rollout[:complete] && !best_complete)
            best_score = rollout[:score]
            best_sequence = rollout[:sequence]
            best_offers = rollout[:offers]
            best_complete = rollout[:complete]
          end
          candidates << child unless rollout[:timed_out] || rollout[:offer_exhausted]
          budget_exhausted = true if rollout[:timed_out]
          break if budget_exhausted
        end
        break if budget_exhausted
      end

      beam = candidates.sort_by {|node| -node.rank_score }.uniq {|node| state_key(node, fixed_offers) }.first(beam_width)
    end

    elapsed = monotonic_time - started_at
    status = if best_score > baseline_score
               "improved"
             elsif budget_exhausted
               "budget exhausted"
             else
               "no improvement found within budget"
             end

    Result.new(seed: seed, mode: mode, baseline_strategy: strategy,
               baseline_score: baseline_score, best_score: best_score,
               score_delta: best_score - baseline_score, elapsed_seconds: elapsed,
               explored_states: explored_states, transpositions_pruned: transpositions_pruned,
               candidate_sequence: best_sequence, baseline_sequence: baseline_sequence,
               candidate_offers: best_offers, complete: best_complete, status: status)
  end

  private

  def each_legal_action(board)
    board.options.each_with_index do |tile, option_index|
      board.positions_for(tile).each do |row, col|
        yield({tile: tile.name, option: option_index, row: row, col: col})
      end
    end
  end

  def advance(node, action, fixed_offers)
    board = node.board.copy
    option_count = board.options.size
    deal = fixed_offers.nil?
    move = board.play(action.fetch(:option), action.fetch(:row), action.fetch(:col), deal: deal)
    raise RuntimeError, "search generated an illegal move #{action.inspect}" unless move

    offers = node.offers.dup
    next_offer_index = node.next_offer_index
    offer_exhausted = false
    if option_count == 1
      if fixed_offers
        next_names = fixed_offers[next_offer_index]
        if next_names
          board.replace_options(next_names.map {|name| Tile.fetch(name) })
          offers << next_names
          next_offer_index += 1
        else
          offer_exhausted = true
        end
      else
        offers << board.options.map(&:name)
      end
    end

    Node.new(board: board, sequence: node.sequence + [action], offers: offers,
             next_offer_index: next_offer_index, depth: node.depth + 1,
             offer_exhausted: offer_exhausted, rank_score: board.score)
  end

  def rollout_from(node, fixed_offers:, strategy:, model:, seed:, deadline:)
    current = Node.new(board: node.board.copy, sequence: node.sequence.dup,
                       offers: node.offers.dup, next_offer_index: node.next_offer_index,
                       depth: node.depth, offer_exhausted: node.offer_exhausted,
                       rank_score: node.rank_score)
    player = AutoPlayer.new(strategy, random: Random.new(seed), model: model)

    loop do
      return rollout_result(current, complete: false, timed_out: true) if monotonic_time >= deadline
      return rollout_result(current, complete: false, offer_exhausted: true) if current.offer_exhausted
      return rollout_result(current, complete: true) if current.board.game_over?

      index, row, col = player.choose_move(current.board)
      action = {tile: current.board.options[index].name, option: index, row: row, col: col}
      current = advance(current, action, fixed_offers)
    end
  end

  def rollout_result(node, complete:, timed_out: false, offer_exhausted: false)
    {score: node.board.score, sequence: node.sequence, offers: node.offers,
     complete: complete, timed_out: timed_out, offer_exhausted: offer_exhausted}
  end

  def state_key(node, fixed_offers)
    occupied = node.board.cells.flatten.map {|value| value == Board1010::EMPTY ? "0" : "1" }.join
    options = node.board.options.map(&:name).join(",")
    rng_state = fixed_offers ? "" : Marshal.dump(node.board.random)
    [occupied, options, node.board.score, node.depth, node.next_offer_index, rng_state]
  end

  def normalize_offers(offers)
    offers.map do |batch|
      names = batch.map(&:to_sym)
      names.each {|name| Tile.fetch(name) }
      names
    end
  end

  def sequence_from_result(result)
    result.moves.map {|move| {tile: move[:tile], option: move[:option], row: move[:row], col: move[:col]} }
  end

  def normalize_sequence(sequence)
    sequence.map do |move|
      {tile: move.fetch(:tile).to_sym, option: Integer(move.fetch(:option)),
       row: Integer(move.fetch(:row)), col: Integer(move.fetch(:col))}
    end
  end

  def rollout_seed(seed, state_number)
    ((seed || 0) ^ (state_number * 2_654_435_761)) % (2**32)
  end

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
