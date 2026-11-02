#!/usr/bin/env ruby
# frozen_string_literal: true

# deep_improve.rb: improve a seeded Game Over trace beyond the fixed
# 100-rollout budget of `learn.rb improve` by splicing a recorded prefix onto
# a re-searched tail.
#
# Method: replay the first --prefix moves of the recorded game on the natural
# seeded dealer. A seed-consistent trace's deals are regenerated identically,
# so the board's RNG ends in exactly the right position for the dealer to
# deal every set after the splice. Those sets are not taken from the recorded
# game: when no tile of a set fits, the dealer swaps one for a small tile, and
# that swap belongs to the board it was dealt on, not to the searched one.
# ImprovementSearch then explores the tail with a real rollout budget —
# GameImprover caps rollouts at min(states, 100), which stops the beam near
# depth ~50 and cannot reach a ~200-move Game Over. Here the beam walks far
# enough that rollout completions can outscore the recorded ending. The
# prefix moves plus the searched tail are merged into one legal sequence and
# written with GameImprover's own trace writer, then verified by replay and
# against the seeded dealer.
#
# Usage:
#   bundle exec ruby scripts/deep_improve.rb logs/<game>.moves [options]
#     --prefix N      moves of the recorded game to keep (default: 0)
#     --states N      search state budget (default: 1,000,000)
#     --rollouts N    rollout budget (default: 4,000)
#     --per-step N    rollouts per beam level (default: 4)
#     --beam N        beam width (default: 8)
#     --time SECONDS  wall-clock safety cap (default: 1200)
#     --rollout NAME  rollout strategy (default: sam; learned is ~6x slower)
#     --model FILE    learned model for --rollout learned
#     --output FILE   improved trace (default: <game>.improved.moves)
#
#   DEBUG=1 bundle exec ruby scripts/deep_improve.rb ...  # replay diagnostics
#
# Found during the samples/manual_score_930.moves study: a late splice produced
# a 5,505-point trace, and repeated late splices reached 34,944 on the same
# seed. See scripts/iterate_improve.rb and samples/improved_score_34944.moves.

require "optparse"
require_relative "../lib/game_trace"
require_relative "../lib/lesson_analyzer"
require_relative "../lib/game_improver"
require_relative "../lib/improvement_search"
require_relative "../lib/learned_player"

# Replays a merged sequence the way GameImprover#write_improved_trace does and
# reports the first move that fails to play. Used only with DEBUG=1.
DEBUG_REPLAY = lambda do |trace, offers, sequence, prefix, candidate|
  board = trace.starting_board.copy
  board.replace_options(offers.first.map {|name| Tile.fetch(name) })
  offer_index = 0
  sequence.each_with_index do |move, i|
    exhausted = board.options.size == 1
    played = board.play(move.fetch(:option), move.fetch(:row), move.fetch(:col), deal: false)
    unless played
      source = i < prefix ? "prefix" : "tail(#{i - prefix + 1}/#{candidate.size})"
      warn "illegal move #{i + 1} (#{source}): #{move.inspect} " \
           "options=#{board.options.map(&:name).inspect} score=#{board.score}"
      exit 1
    end
    next unless exhausted

    offer_index += 1
    batch = offers[offer_index]
    abort "ran out of offers at move #{i + 1}" unless batch

    board.replace_options(batch.map {|name| Tile.fetch(name) })
  end
  warn "debug replay ok: score #{board.score}, game_over #{board.game_over?}"
end

options = {prefix: 0, states: 1_000_000, rollouts: 4_000, per_step: 4,
           beam: 8, time: 1_200.0, rollout: :sam, model: nil, output: nil}
begin
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: scripts/deep_improve.rb TRACE.moves [options]"
    opts.on("--prefix N", Integer) {|v| options[:prefix] = v }
    opts.on("--states N", Integer) {|v| options[:states] = v }
    opts.on("--rollouts N", Integer) {|v| options[:rollouts] = v }
    opts.on("--per-step N", Integer) {|v| options[:per_step] = v }
    opts.on("--beam N", Integer) {|v| options[:beam] = v }
    opts.on("--time SECONDS", Float) {|v| options[:time] = v }
    opts.on("--rollout NAME") {|v| options[:rollout] = v.to_sym }
    opts.on("--model FILE") {|v| options[:model] = v }
    opts.on("--output FILE") {|v| options[:output] = v }
  end
  parser.parse!
rescue OptionParser::ParseError => e
  warn "Invalid options: #{e.message}"
  exit 2
end
trace_path = ARGV.shift or abort "Usage: scripts/deep_improve.rb TRACE.moves [options]"
abort "unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?

trace = GameTrace.read(trace_path)
raise ArgumentError, "trace has no dealer seed" unless trace.seed

baseline = LessonAnalyzer.new.final_trajectory(trace)
offers = baseline[:offers].map {|batch| batch.map(&:to_sym) }
sequence = baseline[:sequence]
baseline_score = baseline[:board].score
puts "baseline: #{baseline_score} points, #{sequence.size} moves, " \
     "#{offers.size} recorded offer sets, seed #{trace.seed}"

# Replay the recorded prefix with deal_if_needed: seed consistency means the
# generated batches are the recorded ones, so the board RNG lands in the right
# position for the dealer to continue after the splice. A trace that left the
# dealer can only be spliced before that point.
board = Board1010.new(random: Random.new(Integer(trace.seed)))
board.deal_if_needed
prefix = options[:prefix].clamp(0, sequence.size)
offer_index = 0
sequence.first(prefix).each_with_index do |move, index|
  dealt = board.options[move.fetch(:option)]&.name == move.fetch(:tile)
  unless dealt && board.play(move.fetch(:option), move.fetch(:row), move.fetch(:col))
    reason = GameImprover.new.validate_seed(trace).fetch(:reason)
    abort "#{trace_path} left the seeded dealer by move #{index + 1} (#{reason}); use a smaller --prefix"
  end

  offer_index += 1 if board.options.size == Board1010::OPTIONS
end

# The live batch holds the unplayed remainder of a recorded batch. Tiles can
# be consumed from any position, so check a subsequence rather than a suffix.
current_batch = board.options.map(&:name)
unplayed = offers[offer_index].dup
in_batch = current_batch.all? do |tile|
  position = unplayed.index(tile)
  position && unplayed.delete_at(position)
end
raise "offer mismatch at prefix: #{current_batch.inspect} not in #{offers[offer_index].inspect}" unless in_batch

puts "prefix: #{prefix} moves, score #{board.score}, on offer set #{offer_index + 1}/#{offers.size}"

model = options[:model] || (options[:rollout] == :learned ? AutoPlayer::DEFAULT_MODEL_PATH : nil)
model &&= LearnedPlayer.load(model)
search = ImprovementSearch.search(
  seed: trace.seed, starting_board: board,
  baseline_score: baseline_score, baseline_sequence: [],
  fixed_offers: [current_batch], continue_after_fixed_offers: true,
  strategy: :sam, rollout_strategy: options[:rollout], rollout_model: model,
  beam_width: options[:beam], max_states: options[:states],
  max_rollouts: options[:rollouts], rollouts_per_step: options[:per_step],
  time_budget_seconds: options[:time]
)

puts "search: best #{search.best_score} (delta #{search.score_delta}), status #{search.status}, " \
     "states #{search.explored_states}, rollouts #{search.explored_rollouts}, " \
     "#{search.elapsed_seconds.round(1)}s"

if search.best_score > baseline_score && search.complete
  merged_sequence = sequence.first(prefix) + search.candidate_sequence
  # candidate_offers[0] is the partially consumed current batch; the full
  # recorded batch must be written so prefix moves can still draw from it.
  merged_offers = offers.first(offer_index + 1) + search.candidate_offers[1..]
  DEBUG_REPLAY.call(trace, merged_offers, merged_sequence, prefix, search.candidate_sequence) if ENV["DEBUG"]
  output = options[:output] || trace_path.sub(/\.moves\z/, ".improved.moves")
  GameImprover.new.send(:write_improved_trace, output, trace, merged_offers, merged_sequence)
  replayed = GameTrace.replay(GameTrace.read(output))
  raise "replay #{replayed.score} != search #{search.best_score}" unless replayed.score == search.best_score

  seed_check = GameImprover.new.validate_seed(GameTrace.read(output))
  raise "improved trace left the seeded dealer: #{seed_check[:reason]}" unless seed_check[:consistent]

  puts "wrote #{output}: #{replayed.score} points, #{merged_sequence.size} moves, " \
       "#{merged_offers.size} offer sets"
else
  puts "no complete improvement above #{baseline_score} found"
end
