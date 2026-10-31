# frozen_string_literal: true

require_relative "game_simulator"
require_relative "improvement_search"
require_relative "lesson_store"

# Runs the learned policy, samples states it actually visits, and asks the
# searcher for improved continuations from those exact states.
class PolicyCorrector
  Result = Struct.new(:episodes, :states_searched, :improvements_saved, keyword_init: true)

  def correct(seeds:, model:, store: LessonStore.new, time_budget_seconds: 0.1,
              beam_width: 4, max_states: 2_000, decision_stride: 1)
    seeds = seeds.map {|seed| Integer(seed) }
    stride = Integer(decision_stride)
    raise ArgumentError, "provide at least one correction seed" if seeds.empty?
    raise ArgumentError, "decision_stride must be positive" unless stride.positive?
    training_range = LearningSeedSets::DEFINITIONS.fetch(:training)
    unless seeds.all? {|seed| training_range.cover?(seed) }
      raise ArgumentError, "policy corrections must use training seeds; tuning and held-out seeds are not allowed"
    end
    episodes = states_searched = improvements_saved = 0

    seeds.each do |seed|
      episode = GameSimulator.run(seed: seed, strategy: :learned, model: model, capture_states: true)
      episodes += 1
      episode.decision_states.each_with_index do |state, index|
        next unless (index % stride).zero?

        # A captured decision can be halfway through a three-tile offer. The
        # board holds only the remaining tiles, so make that the first fixed
        # offer and append the later batches from the episode history.
        offers = fixed_offers_for(state, episode)
        continuation = episode.moves.drop(index)
        result = ImprovementSearch.search(starting_board: state.fetch(:board),
                                          baseline_score: episode.score,
                                          baseline_sequence: continuation,
                                          fixed_offers: offers,
                                          time_budget_seconds: time_budget_seconds,
                                          beam_width: beam_width, max_states: max_states,
                                          strategy: :learned, rollout_strategy: :learned,
                                          baseline_model: model, rollout_model: model)
        states_searched += 1
        next unless result.score_delta.positive?

        board = state.fetch(:board)
        source = {path: "seed:#{seed}:decision:#{index}", seed: seed, decision_index: index}
        lesson = {
          schema_version: LessonStore::SCHEMA_VERSION,
          source_episode: {path: source[:path], sha256: nil, seed: seed,
                           mode: "learned", decision_index: index, final_reason: "game_over"},
          initial_state: {cells: board.cells, tile_ids: board.tile_ids, score: board.score,
                          options: offers.first},
          offers: offers,
          actual_sequence: continuation, actual_score: episode.score,
          candidate_sequence: result.candidate_sequence, candidate_score: result.best_score,
          improvement_delta: result.score_delta,
          search: {strategy: :learned, time_budget_seconds: Float(time_budget_seconds),
                   beam_width: Integer(beam_width), max_states: Integer(max_states),
                   elapsed_seconds: result.elapsed_seconds, explored_states: result.explored_states,
                   transpositions_pruned: result.transpositions_pruned, status: result.status,
                   candidate_complete: result.complete},
          outcome: "improved",
          provenance: [{path: source[:path], seed: seed, decision_index: index,
                        actual_score: episode.score, candidate_score: result.best_score,
                        improvement_delta: result.score_delta, search_status: result.status,
                        candidate_complete: result.complete}]
        }
        actual_board = LessonStore.replay(lesson, "actual_sequence")
        candidate_board = LessonStore.replay(lesson, "candidate_sequence")
        raise ArgumentError, "learned baseline sequence score failed validation" unless actual_board.score == episode.score
        raise ArgumentError, "corrected sequence score failed validation" unless candidate_board.score == result.best_score

        store.save(lesson)
        improvements_saved += 1
      end
    end

    Result.new(episodes: episodes, states_searched: states_searched,
               improvements_saved: improvements_saved)
  end

  private

  def fixed_offers_for(state, episode)
    [state.fetch(:board).options.map(&:name)] +
      episode.offers.drop(state.fetch(:offer_index) + 1)
  end
end
