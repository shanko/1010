#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "fileutils"
require_relative "../lesson_analyzer"
require_relative "../learned_player"
require_relative "../policy_corrector"
require_relative "../reinforcement_trainer"
require_relative "../lesson_collector"

def usage
  warn "Usage: bundle exec ruby scripts/learn.rb COMMAND [options]"
  warn "Commands: analyze GAME.moves, train-imitation, collect-training, correct, train-rl, select"
  warn "Analyze options:"
  warn "  --budget SECONDS    search time after baseline preparation (default: 1.0)"
  warn "  --beam-width N      beam width (default: 4)"
  warn "  --max-states N      maximum expanded states (default: 10000)"
  warn "  --strategy NAME     rollout strategy (default: #{AutoPlayer::DEFAULT_STRATEGY})"
  warn "  --output DIR        lesson directory (default: learning_data)"
end

command = ARGV.shift
unless %w[analyze train-imitation collect-training correct train-rl select].include?(command)
  usage
  exit 2
end

if command == "analyze"
  options = {budget: 1.0, beam_width: 4, max_states: 10_000,
             strategy: AutoPlayer::DEFAULT_STRATEGY, output: LessonStore::DIRECTORY}
  parser = OptionParser.new do |opts|
    opts.on("--budget SECONDS", Float) {|value| options[:budget] = value }
    opts.on("--beam-width N", Integer) {|value| options[:beam_width] = value }
    opts.on("--max-states N", Integer) {|value| options[:max_states] = value }
    opts.on("--strategy NAME") {|value| options[:strategy] = value.to_sym }
    opts.on("--output DIR") {|value| options[:output] = value }
  end
  begin
    parser.parse!(ARGV)
  rescue OptionParser::ParseError => error
    warn "Invalid options: #{error.message}"
    usage
    exit 2
  end
  path = ARGV.shift
  unless path && ARGV.empty?
    usage
    exit 2
  end

  begin
    lesson = LessonAnalyzer.new.analyze(path, time_budget_seconds: options[:budget],
                                        beam_width: options[:beam_width], max_states: options[:max_states],
                                        strategy: options[:strategy])
    saved = LessonStore.new(directory: options[:output]).save(lesson)
    divergence = lesson.fetch(:actual_sequence).zip(lesson.fetch(:candidate_sequence)).index do |actual, candidate|
      actual != candidate
    end
    unless divergence
      actual_length = lesson.fetch(:actual_sequence).size
      candidate_length = lesson.fetch(:candidate_sequence).size
      divergence = [actual_length, candidate_length].min if actual_length != candidate_length
    end
    divergence += 1 if divergence
    puts JSON.pretty_generate({outcome: lesson.fetch(:outcome), actual_score: lesson.fetch(:actual_score),
                               candidate_score: lesson.fetch(:candidate_score),
                               improvement_delta: lesson.fetch(:improvement_delta),
                               first_action_divergence: divergence,
                               search_status: lesson.fetch(:search).fetch(:status),
                               lesson: File.expand_path(saved.fetch(:path)),
                               deduplicated: saved.fetch(:deduplicated)})
  rescue ArgumentError, IOError, SystemCallError => error
    warn "Analysis failed: #{error.message}"
    exit 1
  end
elsif command == "train-imitation"
  options = {lessons: LessonStore::DIRECTORY, output: File.join(LessonStore::DIRECTORY, "models", "imitation-v1.json"),
             seed_set: :training, seed: 1, epochs: 10, learning_rate: 0.1}
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: bundle exec ruby scripts/learn.rb train-imitation [options]"
    opts.on("--lessons DIR") {|value| options[:lessons] = value }
    opts.on("--output FILE") {|value| options[:output] = value }
    opts.on("--seed-set NAME", LearningSeedSets.names.map(&:to_s).join(", ")) {|value| options[:seed_set] = value.to_sym }
    opts.on("--seed N", Integer) {|value| options[:seed] = value }
    opts.on("--epochs N", Integer) {|value| options[:epochs] = value }
    opts.on("--learning-rate RATE", Float) {|value| options[:learning_rate] = value }
  end
  begin
    parser.parse!(ARGV)
  rescue OptionParser::ParseError => error
    warn "Invalid options: #{error.message}"
    warn parser
    exit 2
  end
  unless ARGV.empty?
    warn parser
    exit 2
  end

  begin
    trained = ImitationTrainer.new.train(directory: options[:lessons], seed_set: options[:seed_set],
                                         random_seed: options[:seed], epochs: options[:epochs],
                                         learning_rate: options[:learning_rate])
    FileUtils.mkdir_p(File.dirname(options[:output]))
    ImitationTrainer.new.save(trained.model, options[:output])
    puts JSON.pretty_generate({model: File.expand_path(options[:output]),
                               episodes_used: trained.episodes_used,
                               examples_seen: trained.examples_seen,
                               excluded: trained.excluded.transform_keys(&:to_s)})
  rescue ArgumentError, IOError, SystemCallError => error
    warn "Training failed: #{error.message}"
    exit 1
  end
elsif command == "collect-training"
  options = {strategy: :sam, budget: 0.5, beam_width: 4, max_states: 2_000,
             output: LessonStore::DIRECTORY}
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: bundle exec ruby scripts/learn.rb collect-training --seeds LIST [options]"
    opts.on("--seeds LIST", "Comma-separated training seeds or inclusive range (start..end)") do |value|
      if value.include?("..")
        first, last = value.split("..", 2).map {|seed| Integer(seed) }
        raise OptionParser::InvalidArgument, "range end must be >= start" if last < first
        options[:seeds] = (first..last).to_a
      else
        options[:seeds] = value.split(",").map {|seed| Integer(seed) }
      end
    end
    opts.on("--strategy NAME") {|value| options[:strategy] = value.to_sym }
    opts.on("--budget SECONDS", Float) {|value| options[:budget] = value }
    opts.on("--beam-width N", Integer) {|value| options[:beam_width] = value }
    opts.on("--max-states N", Integer) {|value| options[:max_states] = value }
    opts.on("--output DIR") {|value| options[:output] = value }
  end
  begin
    parser.parse!(ARGV)
  rescue OptionParser::ParseError => error
    warn "Invalid options: #{error.message}"
    warn parser
    exit 2
  end
  unless ARGV.empty? && options[:seeds]
    warn parser
    exit 2
  end

  begin
    result = LessonCollector.new.collect(seeds: options[:seeds], strategy: options[:strategy],
                                          time_budget_seconds: options[:budget],
                                          beam_width: options[:beam_width], max_states: options[:max_states],
                                          store: LessonStore.new(directory: options[:output]))
    puts JSON.pretty_generate({episodes: result.episodes,
                               improvements_found: result.improvements_found,
                               complete_improvements: result.complete_improvements,
                               lessons_saved: result.lessons_saved})
  rescue ArgumentError, IOError, SystemCallError => error
    warn "Training lesson collection failed: #{error.message}"
    exit 1
  end
elsif command == "correct"
  options = {budget: 0.1, beam_width: 4, max_states: 2_000, stride: 1,
             output: LessonStore::DIRECTORY}
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: bundle exec ruby scripts/learn.rb correct --model MODEL --seeds LIST [options]"
    opts.on("--model FILE") {|value| options[:model] = value }
    opts.on("--seeds LIST", "Comma-separated training seeds") {|value| options[:seeds] = value.split(",").map {|seed| Integer(seed) } }
    opts.on("--budget SECONDS", Float) {|value| options[:budget] = value }
    opts.on("--beam-width N", Integer) {|value| options[:beam_width] = value }
    opts.on("--max-states N", Integer) {|value| options[:max_states] = value }
    opts.on("--stride N", Integer) {|value| options[:stride] = value }
    opts.on("--output DIR") {|value| options[:output] = value }
  end
  begin
    parser.parse!(ARGV)
  rescue OptionParser::ParseError => error
    warn "Invalid options: #{error.message}"
    warn parser
    exit 2
  end
  unless ARGV.empty? && options[:model] && options[:seeds]
    warn parser
    exit 2
  end

  begin
    held_out = LearningSeedSets::DEFINITIONS.fetch(:held_out)
    unless options[:seeds].all? {|seed| LearningSeedSets::DEFINITIONS.fetch(:training).cover?(seed) && !held_out.cover?(seed) }
      raise ArgumentError, "correction seeds must come from the training set; held-out/tuning seeds are not allowed"
    end
    model = LearnedPlayer.load(options[:model])
    result = PolicyCorrector.new.correct(seeds: options[:seeds], model: model,
                                          store: LessonStore.new(directory: options[:output]),
                                          time_budget_seconds: options[:budget],
                                          beam_width: options[:beam_width], max_states: options[:max_states],
                                          decision_stride: options[:stride])
    puts JSON.pretty_generate({episodes: result.episodes, states_searched: result.states_searched,
                               improvements_saved: result.improvements_saved})
  rescue ArgumentError, IOError, SystemCallError => error
    warn "Correction search failed: #{error.message}"
    exit 1
  end
elsif command == "select"
  options = {tuning_seeds: LearningSeedSets.fetch(:tuning).first(20)}
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: bundle exec ruby scripts/learn.rb select --checkpoint FILE [options]"
    opts.on("--checkpoint FILE", "Checkpoint to evaluate on tuning seeds") {|value| options[:checkpoint] = value }
    opts.on("--tuning-seeds LIST", "Comma-separated tuning seeds; defaults to first 20") do |value|
      options[:tuning_seeds] = value.split(",").map {|seed| Integer(seed) }
    end
    opts.on("--output FILE", "Selected pointer (default: sibling selected.json)") {|value| options[:output] = value }
  end
  begin
    parser.parse!(ARGV)
  rescue OptionParser::ParseError => error
    warn "Invalid options: #{error.message}"
    warn parser
    exit 2
  end
  unless ARGV.empty? && options[:checkpoint]
    warn parser
    exit 2
  end

  begin
    tuning = options[:tuning_seeds]
    unless !tuning.empty? && tuning.all? {|seed| LearningSeedSets::DEFINITIONS.fetch(:tuning).cover?(seed) }
      raise ArgumentError, "checkpoint selection must use tuning seeds"
    end
    checkpoint = File.expand_path(options[:checkpoint])
    model = LearnedPlayer.load(checkpoint).model
    report = GameBenchmark.run(seeds: tuning, strategies: [:learned], models: {learned: model})
    metrics = report.fetch(:strategies).fetch(:learned).fetch(:metrics).fetch(:score)
    evaluation = {"seeds" => tuning, "mean_score" => metrics.fetch(:mean),
                  "score_summary" => metrics,
                  "per_seed" => report.fetch(:strategies).fetch(:learned).fetch(:per_seed)}
    pointer = File.expand_path(options[:output] || File.join(File.dirname(checkpoint), "selected.json"))
    raise ArgumentError, "selected pointer must be beside the checkpoint" unless File.dirname(pointer) == File.dirname(checkpoint)

    result = RLCheckpointStore.new(directory: File.dirname(pointer)).select(checkpoint,
                                                                           tuning_evaluation: evaluation)
    puts JSON.pretty_generate({checkpoint: checkpoint, selected_pointer: File.expand_path(result),
                               tuning_evaluation: evaluation})
  rescue ArgumentError, IOError, SystemCallError => error
    warn "Checkpoint selection failed: #{error.message}"
    exit 1
  end
else
  options = {episodes: 1, random_seed: 1, learning_rate: 0.01, temperature: 1.0,
             baseline_decay: 0.9, checkpoint_interval: 1,
             checkpoints: File.join(LessonStore::DIRECTORY, "checkpoints")}
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: bundle exec ruby scripts/learn.rb train-rl --model MODEL [options]"
    opts.on("--model FILE", "Initial imitation model") {|value| options[:model] = value }
    opts.on("--resume FILE", "Resume from an RL checkpoint or selected.json pointer") {|value| options[:resume] = value }
    opts.on("--episodes N", Integer) {|value| options[:episodes] = value }
    opts.on("--seeds LIST", "Comma-separated training seeds; default starts at the next training seed") do |value|
      options[:seeds] = value.split(",").map {|seed| Integer(seed) }
    end
    opts.on("--tuning-seeds LIST", "Comma-separated tuning seeds; defaults to first 20 tuning seeds") do |value|
      options[:tuning_seeds] = value.split(",").map {|seed| Integer(seed) }
    end
    opts.on("--seed N", Integer, "Policy exploration RNG seed") {|value| options[:random_seed] = value }
    opts.on("--learning-rate RATE", Float) {|value| options[:learning_rate] = value }
    opts.on("--temperature VALUE", Float) {|value| options[:temperature] = value }
    opts.on("--baseline-decay VALUE", Float) {|value| options[:baseline_decay] = value }
    opts.on("--checkpoint-interval N", Integer) {|value| options[:checkpoint_interval] = value }
    opts.on("--checkpoints DIR") {|value| options[:checkpoints] = value }
  end
  begin
    parser.parse!(ARGV)
  rescue OptionParser::ParseError => error
    warn "Invalid options: #{error.message}"
    warn parser
    exit 2
  end
  unless ARGV.empty? && (options[:model] || options[:resume])
    warn parser
    exit 2
  end

  begin
    trainer = ReinforcementTrainer.new
    result = trainer.train(initial_model: options[:model] || options[:resume],
                           resume: options[:resume], episode_count: options[:episodes],
                           random_seed: options[:random_seed], learning_rate: options[:learning_rate],
                           temperature: options[:temperature], baseline_decay: options[:baseline_decay],
                           seeds: options[:seeds], tuning_seeds: options[:tuning_seeds] || LearningSeedSets.fetch(:tuning).first(20),
                           checkpoint_interval: options[:checkpoint_interval],
                           checkpoint_store: RLCheckpointStore.new(directory: options[:checkpoints]))
    puts JSON.pretty_generate({episodes: result.episodes, global_step: result.global_step,
                               best_checkpoint: File.expand_path(result.best_checkpoint),
                               selected_pointer: File.expand_path(result.selected_pointer),
                               selection_changed: result.selection_changed,
                               previous_selected_checkpoint: result.previous_selected_checkpoint && File.expand_path(result.previous_selected_checkpoint),
                               best_tuning_evaluation: result.best_tuning_evaluation,
                               checkpoints: result.checkpoints.map do |checkpoint|
                                 {path: File.expand_path(checkpoint.fetch(:path)),
                                  mean_score: checkpoint.fetch(:evaluation).fetch("mean_score")}
                               end})
  rescue ArgumentError, IOError, SystemCallError => error
    warn "RL training failed: #{error.message}"
    exit 1
  end
end
