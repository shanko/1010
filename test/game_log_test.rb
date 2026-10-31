# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../game_log"
require_relative "../game_trace"

class GameLogTest < Minitest::Test
  def test_writes_compact_seed_move_and_undo_records
    Dir.mktmpdir do |directory|
      board = Board1010.new(options: [Board1010::TILES[:dot]])
      log = GameLog.new(seed: 42, board: board, mode: "test", directory: directory)
      log.move(:dot, 0, 9, 0)
      log.undo
      log.finish(reason: "stopped", score: 0)

      contents = File.read(log.path)
      assert contents.start_with?("#{GameLog::VERSION_HEADER}\ns42\nmode=test\ni0|")
      assert_includes contents, "ddot\nmdot,0,9,0\nu\nzstopped|0\n"
      assert_equal ".moves", File.extname(log.path)
    end
  end

  def test_records_missing_seed_as_dash
    Dir.mktmpdir do |directory|
      board = Board1010.new(options: [Board1010::TILES[:dot]])
      log = GameLog.new(board: board, mode: "test", directory: directory)
      log.finish(reason: "stopped", score: 0)

      assert_includes File.read(log.path), "\ns-\n"
    end
  end

  def test_each_game_gets_a_distinct_file
    Dir.mktmpdir do |directory|
      board = Board1010.new(options: [Board1010::TILES[:dot], Board1010::TILES[:dot]])
      first = GameLog.new(seed: 1, board: board, mode: "test", directory: directory)
      second = GameLog.new(seed: 2, board: board, mode: "test", directory: directory)
      first.move(:dot, 0, 0, 0)
      second.move(:dot, 1, 1, 1)
      first.finish(reason: "stopped", score: 1)
      second.finish(reason: "stopped", score: 1)

      refute_equal first.path, second.path
      assert_includes File.read(first.path), "s1\n"
      assert_includes File.read(first.path), "mdot,0,0,0\n"
      assert_includes File.read(second.path), "s2\n"
      assert_includes File.read(second.path), "mdot,1,1,1\n"
    end
  end
end
