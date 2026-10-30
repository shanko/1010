# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../game_log"

class GameLogTest < Minitest::Test
  def test_writes_compact_seed_move_and_undo_records
    Dir.mktmpdir do |directory|
      log = GameLog.new(seed: 42, directory: directory)
      log.move(2, 9, 0)
      log.undo
      log.close

      assert_equal "s42\nm290\nu\n", File.read(log.path)
      assert_equal ".moves", File.extname(log.path)
    end
  end

  def test_records_missing_seed_as_dash
    Dir.mktmpdir do |directory|
      log = GameLog.new(directory: directory)
      log.close

      assert_equal "s-\n", File.read(log.path)
    end
  end

  def test_each_game_gets_a_distinct_file
    Dir.mktmpdir do |directory|
      first = GameLog.new(seed: 1, directory: directory)
      second = GameLog.new(seed: 2, directory: directory)
      first.move(0, 0, 0)
      second.move(1, 1, 1)
      first.close
      second.close

      refute_equal first.path, second.path
      assert_equal "s1\nm000\n", File.read(first.path)
      assert_equal "s2\nm111\n", File.read(second.path)
    end
  end
end
