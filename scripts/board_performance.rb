# frozen_string_literal: true

require_relative "../game_simulator"

def average_seconds(iterations)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  iterations.times { yield }
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / iterations
end

board = Board1010.new
tile = Tile.fetch(:sq3)
position_seconds = average_seconds(100) { board.positions_for(tile) }
sam_seconds = average_seconds(10) { GameSimulator.run(seed: 8_675_309, strategy: :sam) }

puts format("positions_for(sq3): %.1f µs/call (100 calls)", position_seconds * 1_000_000)
puts format("sam full game: %.1f ms/game (10 games, seed 8675309)", sam_seconds * 1_000)
