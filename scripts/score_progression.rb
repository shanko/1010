#!/usr/bin/env ruby
# frozen_string_literal: true

# score_progression.rb: print the running score every STEP moves along a
# trace's committed (post-undo) sequence, plus how much is still needed to
# beat its final score. Handy for choosing deep_improve.rb --prefix points.
#
# Usage:
#   bundle exec ruby scripts/score_progression.rb logs/<game>.moves [STEP]

require_relative "../lib/game_trace"
require_relative "../lib/lesson_analyzer"

path = ARGV.shift or abort "Usage: scripts/score_progression.rb TRACE.moves [STEP]"
step = Integer(ARGV.shift || 20)

trace = GameTrace.read(path)
baseline = LessonAnalyzer.new.final_trajectory(trace)
final = baseline[:board].score
board = Board1010.new(random: Random.new(Integer(trace.seed)))
board.deal_if_needed
baseline[:sequence].each_with_index do |move, i|
  board.play(move[:option], move[:row], move[:col])
  next unless ((i + 1) % step).zero? || i + 1 == baseline[:sequence].size

  puts "move #{i + 1}: score #{board.score} (need +#{final + 1 - board.score} to beat #{final})"
end
