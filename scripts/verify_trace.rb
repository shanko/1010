#!/usr/bin/env ruby
# frozen_string_literal: true

# verify_trace.rb: replay each .moves trace and check the replayed score
# against the declared final score, and that it ended at Game Over.
# Exits nonzero if any trace mismatches.
#
# Usage:
#   bundle exec ruby scripts/verify_trace.rb logs/*.moves

require_relative "../lib/game_trace"

failures = 0
ARGV.each do |path|
  trace = GameTrace.read(path)
  replayed = GameTrace.replay(trace)
  ok = replayed.score == trace.final_score && trace.final_reason == "game_over"
  failures += 1 unless ok
  puts "#{path}: #{replayed.score} pts (declared #{trace.final_score}, #{trace.final_reason}) #{ok ? 'OK' : 'MISMATCH'}"
end
exit(failures.zero? ? 0 : 1)
