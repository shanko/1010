# frozen_string_literal: true

require "time"
require_relative "game_simulator"
require_relative "recorded_offer_source"

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
  AdvanceState = Struct.new(:board, :offer_history, :next_offer_index, :offer_exhausted,
                            :rng_position, keyword_init: true)
  SearchState = Struct.new(:seed, :strategy, :rollout_strategy, :rollout_model,
                           :baseline_score, :baseline_sequence, :fixed_offers, :offer_source,
                           :mode, :beam_width, :max_states, :max_rollouts, :rollouts_per_step,
                           :best_score, :best_node, :best_offers, :best_complete,
                           :started_at, :deadline, :explored_states, :explored_rollouts,
                           :transpositions_pruned, :state_capped, :rollout_capped, :time_capped,
                           :beam, :visited, keyword_init: true)

  def self.search(**options)
    new.search(**options)
  end

  def search(seed: nil, strategy: AutoPlayer::SEARCH_STRATEGY, starting_board: nil,
             baseline_score: nil, baseline_sequence: nil, fixed_offers: nil,
             continue_after_fixed_offers: false,
             time_budget_seconds: 30.0, beam_width: 4, max_states: 10_000,
             max_rollouts: 100, rollouts_per_step: 2,
             rollout_strategy: strategy, baseline_model: nil, rollout_model: baseline_model,
             clock: nil)
    require_search_models!(strategy, rollout_strategy, starting_board, baseline_model, rollout_model)
    state = initialize_search(seed: seed, strategy: strategy, starting_board: starting_board,
                              baseline_score: baseline_score, baseline_sequence: baseline_sequence,
                              fixed_offers: fixed_offers, continue_after_fixed_offers: continue_after_fixed_offers,
                              budget: time_budget_seconds, beam_width: beam_width, max_states: max_states,
                              max_rollouts: max_rollouts, rollouts_per_step: rollouts_per_step,
                              rollout_strategy: rollout_strategy, baseline_model: baseline_model,
                              rollout_model: rollout_model, clock: clock)
    run_search(state)
    result_for(state)
  end

  private

  def require_search_models!(strategy, rollout_strategy, starting_board, baseline_model, rollout_model)
    missing_baseline = !starting_board && strategy.to_sym == :learned && baseline_model.nil?
    missing_rollout = rollout_strategy.to_sym == :learned && rollout_model.nil?
    return unless missing_baseline || missing_rollout

    raise ArgumentError,
          "learned search requires explicit baseline_model:/rollout_model:; bundled defaults are for gameplay"
  end

  def initialize_search(seed:, strategy:, starting_board:, baseline_score:, baseline_sequence:,
                        fixed_offers:, continue_after_fixed_offers:, budget:, beam_width:,
                        max_states:, max_rollouts:, rollouts_per_step:, rollout_strategy:,
                        baseline_model:, rollout_model:, clock:)
    validate_limits!(budget, beam_width, max_states, max_rollouts, rollouts_per_step)
    @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    seed = Integer(seed) unless seed.nil?
    strategy = strategy.to_sym
    rollout_strategy = rollout_strategy.to_sym
    baseline = baseline_for_search(seed: seed, strategy: strategy, starting_board: starting_board,
                                   baseline_score: baseline_score, baseline_sequence: baseline_sequence,
                                   baseline_model: baseline_model)
    offers, offer_source = prepare_offers(fixed_offers, baseline, continue_after_fixed_offers)
    root, mode = build_root(baseline, offers, offer_source, continue_after_fixed_offers)
    started = monotonic_time
    state_for(root: root, baseline: baseline, offers: offers, offer_source: offer_source,
              mode: mode, seed: seed, strategy: strategy, rollout_strategy: rollout_strategy,
              rollout_model: rollout_model, beam_width: beam_width, max_states: max_states,
              max_rollouts: max_rollouts, rollouts_per_step: rollouts_per_step,
              started: started, budget: budget)
  end

  def validate_limits!(budget, beam_width, max_states, max_rollouts, rollouts_per_step)
    budget = Float(budget)
    raise ArgumentError, "time budget must be finite and non-negative" unless budget.finite? && budget >= 0

    limits = {"beam width" => beam_width, "max states" => max_states,
              "max rollouts" => max_rollouts, "rollouts per step" => rollouts_per_step}
    limits.each do |label, value|
      number = Integer(value)
      raise ArgumentError, "#{label} must be positive" unless number.positive?
    end
  end

  def baseline_for_search(seed:, strategy:, starting_board:, baseline_score:, baseline_sequence:, baseline_model:)
    if starting_board
      raise ArgumentError, "baseline_score is required with starting_board" if baseline_score.nil?

      {board: starting_board.copy, score: Integer(baseline_score),
       sequence: normalize_sequence(baseline_sequence || []), result: nil}
    else
      raise ArgumentError, "seed or starting_board is required" if seed.nil?

      result = GameSimulator.run(seed: seed, strategy: strategy, model: baseline_model)
      {board: GameSimulator.initial_board(seed: seed), score: result.score,
       sequence: sequence_from_result(result), result: result}
    end
  end

  def prepare_offers(fixed_offers, baseline, continue_after_fixed_offers)
    fixed_offers = baseline[:result].offers if fixed_offers == :baseline && baseline[:result]
    raise ArgumentError, "fixed_offers: :baseline requires a seeded search" if fixed_offers == :baseline

    fixed_offers = normalize_offers(fixed_offers) if fixed_offers
    source = fixed_offers && RecordedOfferSource.new(recorded_offers:             fixed_offers,
                                                     continue_with_seeded_dealer: continue_after_fixed_offers)
    [fixed_offers, source]
  end

  def build_root(baseline, fixed_offers, _offer_source, continue_after_fixed_offers)
    board = baseline[:board]
    initial_names = board.options.map(&:name).freeze
    if fixed_offers && fixed_offers.first != initial_names
      raise ArgumentError, "first fixed offer must match the starting board's current options"
    end

    mode = search_mode(fixed_offers, continue_after_fixed_offers)
    history = OfferNode.new(parent: nil, batch: initial_names, batch_count: 1)
    root = Node.new(board: board, path: nil, offer_history: history, next_offer_index: 1,
                    depth: 0, offer_exhausted: false, rank_score: cheap_rank(board),
                    rng_position: fixed_offers ? 0 : Board1010::OPTIONS)
    [root, mode]
  end

  def search_mode(fixed_offers, continue_after_fixed_offers)
    return :recorded_then_seeded if continue_after_fixed_offers
    return :fixed_offers if fixed_offers

    :seeded
  end

  def state_for(root:, baseline:, offers:, offer_source:, mode:, seed:, strategy:, rollout_strategy:,
                rollout_model:, beam_width:, max_states:, max_rollouts:, rollouts_per_step:, started:, budget:)
    state = SearchState.new(**state_attributes(root: root, baseline: baseline, offers: offers,
                                               offer_source: offer_source, mode: mode, seed: seed,
                                               strategy: strategy, rollout_strategy: rollout_strategy,
                                               rollout_model: rollout_model, beam_width: beam_width,
                                               max_states: max_states, max_rollouts: max_rollouts,
                                               rollouts_per_step: rollouts_per_step,
                                               started: started, budget: budget))
    state.visited[state_key(root, offers)] = true
    state
  end

  def state_attributes(root:, baseline:, offers:, offer_source:, mode:, seed:, strategy:,
                       rollout_strategy:, rollout_model:, beam_width:, max_states:,
                       max_rollouts:, rollouts_per_step:, started:, budget:)
    {seed: seed, strategy: strategy, rollout_strategy: rollout_strategy, rollout_model: rollout_model,
     baseline_score: baseline[:score], baseline_sequence: baseline[:sequence],
     fixed_offers: offers, offer_source: offer_source, mode: mode,
     beam_width: Integer(beam_width), max_states: Integer(max_states),
     max_rollouts: Integer(max_rollouts), rollouts_per_step: Integer(rollouts_per_step),
     best_score: baseline[:score], best_node: nil, best_offers: initial_best_offers(root, baseline, offers),
     best_complete: true, started_at: started, deadline: started + Float(budget),
     explored_states: 0, explored_rollouts: 0, transpositions_pruned: 0,
     state_capped: false, rollout_capped: false, time_capped: false, beam: [root], visited: {}}
  end

  def initial_best_offers(root, baseline, offers)
    baseline[:result] ? baseline[:result].offers : (offers || [root.offer_history.batch])
  end

  def run_search(state)
    until state.beam.empty?
      expand_beam(state)
      break if state.time_capped || state.state_capped || state.rollout_capped
    end
  end

  def expand_beam(state)
    candidates = beam_candidates(state)
    return if state.time_capped

    ranked = rank_candidates(candidates)
    rollout_candidates(state, ranked)
    return if state.time_capped

    ranked = rank_candidates(ranked)
    state.rollout_capped = rollout_limit_reached?(state, ranked)
    state.beam = ranked.first(state.beam_width) unless state.rollout_capped || state.state_capped
  end

  def beam_candidates(state)
    candidates = []
    state.beam.each do |node|
      each_legal_action(node.board) do |action|
        expand_action(node, action, state, candidates)
        break if state.time_capped || state.state_capped
      end
      break if state.time_capped || state.state_capped
    end
    candidates
  end

  def expand_action(node, action, state, candidates)
    return if search_limit_reached?(state)

    child = advance(node, action, state.fixed_offers, state.offer_source)
    return prune_transposition(child, state) if state.visited.key?(state_key(child, state.fixed_offers))

    state.visited[state_key(child, state.fixed_offers)] = true
    state.explored_states += 1
    add_child(child, state, candidates)
  end

  def search_limit_reached?(state)
    if monotonic_time >= state.deadline
      state.time_capped = true
    elsif state.explored_states >= state.max_states
      state.state_capped = true
    end
    state.time_capped || state.state_capped
  end

  def prune_transposition(_child, state)
    state.transpositions_pruned += 1
  end

  def add_child(child, state, candidates)
    if child.offer_exhausted
      consider_best(state, child, child.board.score, false)
    elsif child.board.game_over?
      consider_best(state, child, child.board.score, true)
    else
      child.rank_score = cheap_rank(child.board)
      candidates << child
    end
  end

  def consider_best(state, node, score, complete)
    improves = score > state.best_score || (score == state.best_score && complete && !state.best_complete)
    return unless improves

    state.best_score = score
    state.best_node = node
    state.best_complete = complete
  end

  def rank_candidates(candidates)
    candidates.each_with_index.sort_by {|node, index| [-node.rank_score, index] }.map(&:first)
  end

  def rollout_candidates(state, ranked)
    remaining = state.max_rollouts - state.explored_rollouts
    rollout_count = [state.rollouts_per_step, remaining].min
    ranked.first(rollout_count).each {|child| run_candidate_rollout(child, state) }
    state.rollout_capped = true if remaining <= rollout_count && ranked.size > rollout_count
  end

  def run_candidate_rollout(child, state)
    return if rollout_time_expired?(state)

    rollout = perform_rollout(child, state)
    if rollout[:timed_out]
      state.time_capped = true
      return
    end

    child.rank_score = rollout[:score]
    consider_best(state, rollout[:node], rollout[:score], rollout[:complete])
  end

  def rollout_time_expired?(state)
    return false if monotonic_time < state.deadline

    state.time_capped = true
  end

  def perform_rollout(child, state)
    state.explored_rollouts += 1
    rollout_from(child, fixed_offers: state.fixed_offers, offer_source: state.offer_source,
                 strategy: state.rollout_strategy, model: state.rollout_model,
                 seed: rollout_seed(state.seed, state.explored_rollouts), deadline: state.deadline)
  end

  def rollout_limit_reached?(state, ranked)
    remaining = state.max_rollouts - state.explored_rollouts
    rollout_count = [state.rollouts_per_step, remaining].min
    remaining <= rollout_count && ranked.size > rollout_count
  end

  def result_for(state)
    Result.new(**result_attributes(state))
  end

  def result_attributes(state)
    result_identity(state).merge(result_counts(state), result_candidates(state), result_status(state))
  end

  def result_identity(state)
    {seed: state.seed, mode: state.mode, baseline_strategy: state.strategy,
     baseline_score: state.baseline_score, best_score: state.best_score,
     score_delta: state.best_score - state.baseline_score,
     elapsed_seconds: monotonic_time - state.started_at}
  end

  def result_counts(state)
    {explored_states: state.explored_states, explored_rollouts: state.explored_rollouts,
     transpositions_pruned: state.transpositions_pruned}
  end

  def result_candidates(state)
    {candidate_sequence: best_sequence(state), baseline_sequence: state.baseline_sequence,
     candidate_offers: best_offers(state), complete: state.best_complete}
  end

  def result_status(state)
    {status: search_status(state), cap_reason: cap_reason(state)}
  end

  def best_sequence(state)
    state.best_node ? sequence_for(state.best_node.path) : state.baseline_sequence
  end

  def best_offers(state)
    state.best_node ? offers_for(state.best_node.offer_history) : state.best_offers
  end

  def cap_reason(state)
    return "time" if state.time_capped
    return "states" if state.state_capped

    "rollouts" if state.rollout_capped
  end

  def search_status(state)
    return "time_capped" if state.time_capped
    return "improved" if state.best_score > state.baseline_score
    return "budget exhausted" if state.state_capped || state.rollout_capped

    "no improvement found within budget"
  end

  def each_legal_action(board)
    board.options.each_with_index do |tile, option_index|
      board.positions_for(tile).each do |row, col|
        yield({tile: tile.name, option: option_index, row: row, col: col}.freeze)
      end
    end
  end

  def advance(node, action, fixed_offers, offer_source)
    board = node.board.copy
    option_count = board.options.size
    move = board.play(action.fetch(:option), action.fetch(:row), action.fetch(:col), deal: false)
    raise "search generated an illegal move #{action.inspect}" unless move

    state = AdvanceState.new(board: board, offer_history: node.offer_history,
                             next_offer_index: node.next_offer_index, offer_exhausted: false,
                             rng_position: node.rng_position)
    replenish_after_move(state, option_count, fixed_offers, offer_source)
    advanced_node(node, action, state)
  end

  def replenish_after_move(state, option_count, fixed_offers, offer_source)
    return unless option_count == 1

    fixed_offers ? replenish_recorded_offer(state, offer_source) : replenish_seeded_offer(state)
  end

  def replenish_recorded_offer(state, offer_source)
    batch = offer_source.next_batch(state.board, state.next_offer_index)
    unless batch
      state.offer_exhausted = true
      return
    end

    state.offer_history = append_offer(state.offer_history, batch.names)
    state.next_offer_index += 1
    state.rng_position += Board1010::OPTIONS if batch.origin == :seeded
  end

  def replenish_seeded_offer(state)
    names = state.board.generate_options.map(&:name)
    state.board.replace_options(names.map {|name| Tile.fetch(name) })
    state.offer_history = append_offer(state.offer_history, state.board.options.map(&:name))
    # Seeded branches consume the same samples per deal; this cursor avoids
    # marshaling Random's internal state.
    state.rng_position += Board1010::OPTIONS
  end

  def advanced_node(node, action, state)
    Node.new(board: state.board, path: PathNode.new(parent: node.path, action: action),
             offer_history: state.offer_history, next_offer_index: state.next_offer_index,
             depth: node.depth + 1, offer_exhausted: state.offer_exhausted,
             rank_score: state.board.score, rng_position: state.rng_position)
  end

  def rollout_from(node, fixed_offers:, offer_source:, strategy:, model:, seed:, deadline:)
    player = AutoPlayer.new(strategy, random: Random.new(seed), model: model)
    current = node

    loop do
      outcome = rollout_outcome(current, deadline)
      return outcome if outcome

      index, row, col = player.choose_move(current.board)
      action = {tile: current.board.options[index].name, option: index, row: row, col: col}.freeze
      current = advance(current, action, fixed_offers, offer_source)
    end
  end

  def rollout_outcome(node, deadline)
    return {node: node, score: node.board.score, complete: false, timed_out: true} if monotonic_time >= deadline
    return {node: node, score: node.board.score, complete: false} if node.offer_exhausted
    return {node: node, score: node.board.score, complete: true} if node.board.game_over?

    nil
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
