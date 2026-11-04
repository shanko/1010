# frozen_string_literal: true

require_relative "improvement_search"
require_relative "lesson_store"
require_relative "learning_model"

# Creates reproducible training-seed episodes and complete search corrections.
class LessonCollector
  Result = Struct.new(:episodes, :improvements_found, :complete_improvements,
                      :lessons_saved, keyword_init: true)
  Counts = Struct.new(:improvements_found, :complete_improvements, :lessons_saved, keyword_init: true)

  def collect(seeds:, strategy: :sam, model: nil, time_budget_seconds: 30.0, beam_width: 4,
              max_states: 2_000, max_rollouts: 8, rollouts_per_step: 2,
              store: LessonStore.new, clock: nil)
    model = LearningModel.resolve(strategy, model)
    seeds = LearningSeedSets.validate!(seeds, set: :training, purpose: "lesson collection")
    raise ArgumentError, "lesson collection seeds must be unique" unless seeds.uniq.size == seeds.size

    counts = Counts.new(improvements_found: 0, complete_improvements: 0, lessons_saved: 0)
    options = {strategy: strategy, model: model, time_budget_seconds: time_budget_seconds,
               beam_width: beam_width, max_states: max_states, max_rollouts: max_rollouts,
               rollouts_per_step: rollouts_per_step, store: store, clock: clock}
    seeds.each {|seed| collect_seed(seed, options, counts) }
    Result.new(episodes: seeds.size, improvements_found: counts.improvements_found,
               complete_improvements: counts.complete_improvements, lessons_saved: counts.lessons_saved)
  end

  private

  def collect_seed(seed, options, counts)
    actual = GameSimulator.run(seed: seed, strategy: options[:strategy], model: options[:model])
    search = search_episode(seed, options)
    record_improvement(seed, actual, search, options, counts)
  end

  def search_episode(seed, options)
    ImprovementSearch.search(seed: seed, strategy: options[:strategy],
                             time_budget_seconds: options[:time_budget_seconds],
                             beam_width: options[:beam_width], max_states: options[:max_states],
                             max_rollouts: options[:max_rollouts],
                             rollouts_per_step: options[:rollouts_per_step],
                             rollout_strategy: options[:strategy], baseline_model: options[:model],
                             clock: options[:clock])
  end

  def record_improvement(seed, actual, search, options, counts)
    return if search.status == "time_capped"
    return unless search.score_delta.positive?

    counts.improvements_found += 1
    return unless search.complete

    counts.complete_improvements += 1
    lesson = build_lesson(seed, actual, search, options)
    validate_lesson!(lesson, actual, search, seed)
    options[:store].save(lesson)
    counts.lessons_saved += 1
  end

  def build_lesson(seed, actual, result, options)
    initial = GameSimulator.initial_board(seed: seed)
    validate_initial_offers!(actual, result)
    {schema_version: LessonStore::SCHEMA_VERSION, versions: LessonStore.versions,
     source_episode: source_record(seed, options),
     initial_state: initial_record(initial, actual),
     offers: actual.offers, actual_offers: actual.offers, candidate_offers: result.candidate_offers,
     actual_sequence: actual.moves, actual_score: actual.score,
     candidate_sequence: result.candidate_sequence, candidate_score: result.best_score,
     improvement_delta: result.score_delta, search: search_record(result, options), outcome: "improved",
     provenance: [provenance_record(seed, actual, result, options)]}
  end

  def validate_initial_offers!(actual, result)
    return if result.candidate_offers.first == actual.offers.first

    raise ArgumentError, "search candidate starts with a different initial offer"
  end

  def source_record(seed, options)
    {path: "simulator:#{seed}:#{options[:strategy]}", sha256: nil,
     seed: seed, mode: "auto", final_reason: "game_over"}
  end

  def initial_record(initial, actual)
    {cells: initial.cells, tile_ids: initial.tile_ids,
     score: initial.score, options: actual.offers.first}
  end

  def search_record(result, options)
    search_options(options).merge(search_metrics(result),
                                  information_mode: result.information_mode, version: ImprovementSearch::VERSION,
                                  strategy: options[:strategy].to_sym).merge(LearningModel.provenance(options[:model]))
  end

  def search_options(options)
    {time_budget_seconds: Float(options[:time_budget_seconds]),
     beam_width: Integer(options[:beam_width]), max_states: Integer(options[:max_states]),
     max_rollouts: Integer(options[:max_rollouts]),
     rollouts_per_step: Integer(options[:rollouts_per_step])}
  end

  def search_metrics(result)
    {explored_states: result.explored_states, explored_rollouts: result.explored_rollouts,
     transpositions_pruned: result.transpositions_pruned, status: result.status,
     cap_reason: result.cap_reason, candidate_complete: result.complete}
  end

  def provenance_record(seed, actual, result, options)
    {path: "simulator:#{seed}:#{options[:strategy]}", seed: seed,
     actual_score: actual.score, candidate_score: result.best_score,
     improvement_delta: result.score_delta, search_status: result.status,
     candidate_complete: result.complete}.merge(LearningModel.provenance(options[:model]))
  end

  def validate_lesson!(lesson, actual, result, seed)
    actual_board = LessonStore.replay(lesson, "actual_sequence")
    candidate_board = LessonStore.replay(lesson, "candidate_sequence")
    valid = actual_board.score == actual.score && candidate_board.score == result.best_score &&
      actual_board.game_over? && candidate_board.game_over?
    raise ArgumentError, "collected lesson failed complete-game replay validation for seed #{seed}" unless valid
  end
end
