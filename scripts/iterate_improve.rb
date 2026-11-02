#!/usr/bin/env ruby
# frozen_string_literal: true

# iterate_improve.rb: repeatedly re-roll the tail of the current best trace.
#
# ImprovementSearch is deterministic for a given splice point, so each round
# splices at a *different* late move — the fraction walks down by --step only
# after a failed round — to get a fresh dice roll against the same seeded
# dealer. A strictly better trace becomes the new base for the next round.
# Stops early after --patience consecutive failures.
#
# On the seed-4152104760 game, the same approach with six splices tried in
# parallel each round climbed 5,505 -> 34,944 in ten rounds, and the next two
# found nothing better. See samples/improved_score_34944.moves.
#
# Usage:
#   bundle exec ruby scripts/iterate_improve.rb START.moves [options]
#     --rounds N      max rounds (default: 5)
#     --fraction F    first splice fraction of the game length (default: 0.90)
#     --step F        fraction decrement per failed round (default: 0.04)
#     --patience N    stop after N consecutive non-improving rounds (default: 3)
#     --states N      deep_improve state budget (default: 1,200,000)
#     --rollouts N    deep_improve rollout budget (default: 4,000)
#     --per-step N    rollouts per beam level (default: 4)
#     --beam N        beam width (default: 8)
#     --time SECONDS  per-round wall-clock cap (default: 1200)
#     --outdir DIR    where round traces go (default: <start-dir>/iterate)

require "optparse"
require "fileutils"
require "rbconfig"
require_relative "../lib/game_trace"
require_relative "../lib/lesson_analyzer"

options = {rounds: 5, fraction: 0.90, step: 0.04, patience: 3, states: 1_200_000,
           rollouts: 4_000, per_step: 4, beam: 8, time: 1_200.0, outdir: nil}
begin
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: scripts/iterate_improve.rb START.moves [options]"
    opts.on("--rounds N", Integer) {|v| options[:rounds] = v }
    opts.on("--fraction F", Float, "First splice fraction (walks down by --step)") {|v| options[:fraction] = v }
    opts.on("--step F", Float, "Fraction decrement per failed round") {|v| options[:step] = v }
    opts.on("--patience N", Integer) {|v| options[:patience] = v }
    opts.on("--states N", Integer) {|v| options[:states] = v }
    opts.on("--rollouts N", Integer) {|v| options[:rollouts] = v }
    opts.on("--per-step N", Integer) {|v| options[:per_step] = v }
    opts.on("--beam N", Integer) {|v| options[:beam] = v }
    opts.on("--time SECONDS", Float) {|v| options[:time] = v }
    opts.on("--outdir DIR") {|v| options[:outdir] = v }
  end
  parser.parse!
rescue OptionParser::ParseError => e
  warn "Invalid options: #{e.message}"
  exit 2
end
current = ARGV.shift or abort "Usage: scripts/iterate_improve.rb START.moves [options]"
abort "unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?

options[:outdir] ||= File.join(File.dirname(current), "iterate")
FileUtils.mkdir_p(options[:outdir])
deep_improve = File.expand_path("deep_improve.rb", __dir__)

stale = 0
options[:rounds].times do |round|
  trace = GameTrace.read(current)
  moves = trace.events.count {|e| e.first == :move }
  fraction = (options[:fraction] - (options[:step] * stale)).clamp(0.5, 0.97)
  prefix = (moves * fraction).to_i
  output = File.join(options[:outdir], "round#{round + 1}-p#{prefix}.moves")
  cmd = [RbConfig.ruby, deep_improve, current, "--prefix", prefix, "--rollout", "sam",
         "--rollouts", options[:rollouts], "--per-step", options[:per_step],
         "--beam", options[:beam], "--states", options[:states],
         "--time", options[:time], "--output", output].map(&:to_s)
  puts "== round #{round + 1}: #{File.basename(current)} " \
       "(#{trace.final_score} pts, #{moves} moves), splice at #{prefix}"
  system(*cmd, exception: true)
  next unless File.exist?(output)

  improved = GameTrace.read(output).final_score
  if improved > trace.final_score
    puts "   -> new best: #{improved} (+#{improved - trace.final_score})"
    current = output
    stale = 0
  else
    stale += 1
    break if stale >= options[:patience]
  end
end
puts "== done: best #{GameTrace.read(current).final_score} pts at #{current}"
