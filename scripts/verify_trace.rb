#!/usr/bin/env ruby
# frozen_string_literal: true

# verify_trace.rb: replay each .moves trace and check the replayed score
# against the declared final score, and that it ended at Game Over. A trace
# with a seed must also deal only what that seed deals on each board.
# Exits nonzero if any trace mismatches.
#
# Usage:
#   bundle exec ruby scripts/verify_trace.rb logs/*.moves

require_relative "../lib/game_improver"
require_relative "../lib/game_trace"

failures = 0
ARGV.each do |path|
  trace = GameTrace.read(path)
  replayed = GameTrace.replay(trace)
  scored = replayed.score == trace.final_score && trace.final_reason == "game_over"
  seed_check = trace.seed ? GameImprover.new.validate_seed(trace) : {consistent: true}
  result = if !scored
             "MISMATCH"
           elsif seed_check[:consistent]
             "OK"
           else
             "DEALER MISMATCH: #{seed_check[:reason]}"
           end
  failures += 1 unless result == "OK"
  puts "#{path}: #{replayed.score} pts (declared #{trace.final_score}, #{trace.final_reason}) #{result}"
end
exit(failures.zero? ? 0 : 1)
