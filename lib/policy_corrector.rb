# frozen_string_literal: true

require_relative "game_simulator"
require_relative "improvement_search"
require_relative "lesson_store"

# Runs the learned policy, samples states it actually visits, and asks the
# searcher for improved continuations from those exact states.
class PolicyCorrector
  Result = Struct.new(:episodes, :states_searched, :improvements_saved, :usable_lessons, keyword_init: true)
  Counts = Struct.new(:episodes, :states_searched, :improvements_saved, :usable_lessons, keyword_init: true)

  def correct(seeds:, model:, store: LessonStore.new, time_budget_seconds: 1.0,
              beam_width: 4, max_states: 2_000, max_rollouts: 1,
              rollouts_per_step: 2, decision_stride: 1, clock: nil)
    seeds = LearningSeedSets.validate!(seeds, set: :training, purpose: "policy correction")
    stride = Integer(decision_stride)
    raise ArgumentError, "decision_stride must be positive" unless stride.positive?

    counts = Counts.new(episodes: 0, states_searched: 0, improvements_saved: 0, usable_lessons: 0)
    options = {model: model, store: store, time_budget_seconds: time_budget_seconds,
               beam_width: beam_width, max_states: max_states, max_rollouts: max_rollouts,
               rollouts_per_step: rollouts_per_step, decision_stride: stride, clock: clock}
    seeds.each {|seed| correct_episode(seed, options, counts) }
    Result.new(episodes: counts.episodes, states_searched: counts.states_searched,
               improvements_saved: counts.improvements_saved, usable_lessons: counts.usable_lessons)
  end

  private

  def correct_episode(seed, options, counts)
    episode = GameSimulator.run(seed: seed, strategy: :learned, model: options[:model], capture_states: true)
    counts.episodes += 1
    episode.decision_states.each_with_index do |state, index|
      next unless (index % options[:decision_stride]).zero?

      correct_state(seed: seed, episode: episode, state: state, index: index,
                    options: options, counts: counts)
    end
  end

  def correct_state(seed:, episode:, state:, index:, options:, counts:)
    offers = fixed_offers_for(state, episode)
    continuation = episode.moves.drop(index)
    result = search_continuation(state, episode, continuation, offers, options)
    counts.states_searched += 1
    return if result.status == "time_capped" || !result.score_delta.positive?

    lesson = build_lesson(seed: seed, episode: episode, state: state, index: index,
                          continuation: continuation, offers: offers, result: result, options: options)
    save_improvement(lesson, episode, result, options, counts)
  end

  def save_improvement(lesson, episode, result, options, counts)
    validate_lesson!(lesson, episode, result)
    options[:store].save(lesson)
    counts.improvements_saved += 1
    counts.usable_lessons += 1 if result.complete
  end

  def search_continuation(state, episode, continuation, offers, options)
    ImprovementSearch.search(starting_board: state.fetch(:board), baseline_score: episode.score,
                             baseline_sequence: continuation, fixed_offers: offers,
                             time_budget_seconds: options[:time_budget_seconds],
                             beam_width: options[:beam_width], max_states: options[:max_states],
                             max_rollouts: options[:max_rollouts],
                             rollouts_per_step: options[:rollouts_per_step],
                             strategy: :learned, rollout_strategy: :learned,
                             baseline_model: options[:model], rollout_model: options[:model],
                             clock: options[:clock])
  end

  def build_lesson(seed:, episode:, state:, index:, continuation:, offers:, result:, options:)
    board = state.fetch(:board)
    path = "seed:#{seed}:decision:#{index}"
    {schema_version: LessonStore::SCHEMA_VERSION, versions: LessonStore.versions,
     source_episode: {path: path, sha256: nil, seed: seed, seed_kind: "root",
                      mode: "learned", decision_index: index, final_reason: "game_over"},
     initial_state: {cells: board.cells, tile_ids: board.tile_ids, score: board.score, options: offers.first},
     offers: offers, actual_sequence: continuation, actual_score: episode.score,
     candidate_sequence: result.candidate_sequence, candidate_score: result.best_score,
     improvement_delta: result.score_delta, search: search_record(result, options),
     outcome: "improved", provenance: [provenance_record(path, seed, index, episode, result)]}
  end

  def search_record(result, options)
    search_limits(options).merge(search_stats(result), information_mode: result.information_mode,
                                                      version: ImprovementSearch::VERSION, strategy: :learned)
  end

  def search_limits(options)
    {time_budget_seconds: Float(options[:time_budget_seconds]),
     beam_width: Integer(options[:beam_width]), max_states: Integer(options[:max_states]),
     max_rollouts: Integer(options[:max_rollouts]),
     rollouts_per_step: Integer(options[:rollouts_per_step])}
  end

  def search_stats(result)
    {explored_states: result.explored_states, explored_rollouts: result.explored_rollouts,
     transpositions_pruned: result.transpositions_pruned, status: result.status,
     cap_reason: result.cap_reason, candidate_complete: result.complete}
  end

  def provenance_record(path, seed, index, episode, result)
    {path: path, seed: seed, decision_index: index, actual_score: episode.score,
     candidate_score: result.best_score, improvement_delta: result.score_delta,
     search_status: result.status, candidate_complete: result.complete}
  end

  def validate_lesson!(lesson, episode, result)
    actual_board = LessonStore.replay(lesson, "actual_sequence")
    candidate_board = LessonStore.replay(lesson, "candidate_sequence")
    raise ArgumentError, "learned baseline sequence score failed validation" unless actual_board.score == episode.score
    raise ArgumentError, "corrected sequence score failed validation" unless candidate_board.score == result.best_score
  end

  def fixed_offers_for(state, episode)
    [state.fetch(:board).options.map(&:name)] + episode.offers.drop(state.fetch(:offer_index) + 1)
  end
end
