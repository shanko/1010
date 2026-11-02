#!/usr/bin/env ruby
# frozen_string_literal: true

# eval_seed.rb: play complete games on a trace's dealer seed (the `s` record)
# with chosen strategies. The dealer stream depends only on the seed, so every
# policy faces the exact offers the logged game dealt — a quick way to compare
# strategies against a recorded human or searched game on identical tiles.
#
# Usage:
#   bundle exec ruby scripts/eval_seed.rb SEED|TRACE.moves [strategy ...]
#   bundle exec ruby scripts/eval_seed.rb logs/<game>.moves learned codex_sam sam

require_relative "../lib/board"
require_relative "../lib/auto_player"
require_relative "../lib/game_trace"

source = ARGV.shift or abort "Usage: scripts/eval_seed.rb SEED|TRACE.moves [strategy ...]"
seed = source.end_with?(".moves") ? GameTrace.read(source).seed : Integer(source)
strategies = ARGV.empty? ? %i[learned codex_sam sam] : ARGV.map(&:to_sym)

strategies.each do |strategy|
  board = Board1010.new(random: Random.new(Integer(seed)))
  board.deal_if_needed
  first_offer = board.options.map(&:name)
  player = AutoPlayer.new(strategy, random: Random.new(0))
  moves = 0
  until board.game_over?
    index, row, col = player.choose_move(board)
    raise "#{strategy}: no legal move but game_over? is false" unless index

    board.play(index, row, col)
    moves += 1
  end
  puts "#{strategy}: score #{board.score} in #{moves} moves (first offer #{first_offer.inspect})"
end
