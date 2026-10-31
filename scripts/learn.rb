#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "fileutils"
require_relative "../lesson_analyzer"
require_relative "../learned_player"
require_relative "../policy_corrector"

def usage
  warn "Usage: bundle exec ruby scripts/learn.rb COMMAND [options]"
  warn "Commands: analyze GAME.moves, train-imitation, correct"
  warn "Analyze options:"
  warn "  --budget SECONDS    search time after baseline preparation (default: 1.0)"
  warn "  --beam-width N      beam width (default: 4)"
  warn "  --max-states N      maximum expanded states (default: 10000)"
  warn "  --strategy NAME     rollout strategy (default: #{AutoPlayer::DEFAULT_STRATEGY})"
  warn "  --output DIR        lesson directory (default: learning_data)"
end

command = ARGV.shift
unless %w[analyze train-imitation correct].include?(command)
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
else
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
end
