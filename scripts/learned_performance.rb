# frozen_string_literal: true

require_relative "../game_simulator"
require_relative "../game_1010"

def average_ms(iterations, &block)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  iterations.times(&block)
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000 / iterations
end

model = {
  "schema_version"  => LearnedPlayer::MODEL_SCHEMA_VERSION,
  "feature_version" => ActionFeatures::VERSION,
  "feature_names"   => ActionFeatures::NAMES,
  "weights"         => ActionFeatures::NAMES.to_h {|name| [name, 0.0] }
}
player = LearnedPlayer.new(model)
board = GameSimulator.initial_board(seed: 8_675_309)
puts "learned legal actions: #{player.legal_actions(board).size}"
puts "learned choose_move: %.2f ms (5 runs)" % average_ms(5) { player.choose_move(board) }
puts "learned O hint for first option: %.2f ms (5 runs)" % average_ms(5) {
  player.best_position(board, board.options.first)
}

window = GameWindow.allocate
window.instance_variable_set(:@board, board)
window.instance_variable_set(:@auto_player, player)
window.instance_variable_set(:@selected, 0)
puts "cached O hint frame: %.4f ms (1,000 frames)" % average_ms(1_000) { window.send(:hint_position) }
