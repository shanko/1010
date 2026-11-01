# frozen_string_literal: true

require_relative "improvement_search"
require_relative "lesson_store"

# Creates reproducible training-seed episodes and complete search corrections.
class LessonCollector
  Result = Struct.new(:episodes, :improvements_found, :complete_improvements,
                      :lessons_saved, keyword_init: true)

  def collect(seeds:, strategy: :sam, time_budget_seconds: 30.0, beam_width: 4,
              max_states: 2_000, max_rollouts: 8, rollouts_per_step: 2,
              store: LessonStore.new, clock: nil)
    seeds = LearningSeedSets.validate!(seeds, set: :training, purpose: "lesson collection")
    raise ArgumentError, "lesson collection seeds must be unique" unless seeds.uniq.size == seeds.size

    improvements_found = complete_improvements = lessons_saved = 0
    seeds.each do |seed|
      actual = GameSimulator.run(seed: seed, strategy: strategy)
      result = ImprovementSearch.search(seed: seed, strategy: strategy,
                                        time_budget_seconds: time_budget_seconds,
                                        beam_width: beam_width, max_states: max_states,
                                        max_rollouts: max_rollouts, rollouts_per_step: rollouts_per_step,
                                        rollout_strategy: strategy, clock: clock)
      next if result.status == "time_capped"
      next unless result.score_delta.positive?

      improvements_found += 1
      next unless result.complete

      complete_improvements += 1
      initial_board = GameSimulator.initial_board(seed: seed)
      actual_offers = actual.offers
      candidate_offers = result.candidate_offers
      raise ArgumentError, "search candidate starts with a different initial offer" unless
        candidate_offers.first == actual_offers.first

      lesson = {
        schema_version: LessonStore::SCHEMA_VERSION,
        source_episode: {path: "simulator:#{seed}:#{strategy}", sha256: nil,
                         seed: seed, mode: "auto", final_reason: "game_over"},
        initial_state: {cells: initial_board.cells, tile_ids: initial_board.tile_ids,
                        score: initial_board.score, options: actual_offers.first},
        offers: actual_offers, actual_offers: actual_offers,
        candidate_offers: candidate_offers,
        actual_sequence: actual.moves, actual_score: actual.score,
        candidate_sequence: result.candidate_sequence,
        candidate_score: result.best_score, improvement_delta: result.score_delta,
        search: {version: ImprovementSearch::VERSION, strategy: strategy.to_sym,
                 time_budget_seconds: Float(time_budget_seconds),
                 beam_width: Integer(beam_width), max_states: Integer(max_states),
                 max_rollouts: Integer(max_rollouts), rollouts_per_step: Integer(rollouts_per_step),
                 explored_states: result.explored_states, explored_rollouts: result.explored_rollouts,
                 transpositions_pruned: result.transpositions_pruned, status: result.status,
                 cap_reason: result.cap_reason,
                 candidate_complete: result.complete},
        outcome: "improved",
        provenance: [{path: "simulator:#{seed}:#{strategy}", seed: seed,
                      actual_score: actual.score, candidate_score: result.best_score,
                      improvement_delta: result.score_delta, search_status: result.status,
                      candidate_complete: result.complete}]
      }

      actual_board = LessonStore.replay(lesson, "actual_sequence")
      candidate_board = LessonStore.replay(lesson, "candidate_sequence")
      unless actual_board.score == actual.score && candidate_board.score == result.best_score &&
             actual_board.game_over? && candidate_board.game_over?
        raise ArgumentError, "collected lesson failed complete-game replay validation for seed #{seed}"
      end
      store.save(lesson)
      lessons_saved += 1
    end

    Result.new(episodes: seeds.size, improvements_found: improvements_found,
               complete_improvements: complete_improvements, lessons_saved: lessons_saved)
  end
end
