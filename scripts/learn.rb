#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../lesson_analyzer"

def usage
  warn "Usage: bundle exec ruby scripts/learn.rb analyze GAME.moves [options]"
  warn "  --budget SECONDS    search time after baseline preparation (default: 1.0)"
  warn "  --beam-width N      beam width (default: 4)"
  warn "  --max-states N      maximum expanded states (default: 10000)"
  warn "  --strategy NAME     rollout strategy (default: #{AutoPlayer::DEFAULT_STRATEGY})"
  warn "  --output DIR        lesson directory (default: learning_data)"
end

command = ARGV.shift
unless command == "analyze"
  usage
  exit 2
end

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
