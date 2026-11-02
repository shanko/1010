# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require_relative "../lib/game_simulator"
require_relative "../lib/headless_game"

class HeadlessGameTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/game_1010.rb", __dir__)

  def play(directory, **options)
    output = StringIO.new
    scores = HeadlessGame.new(strategy: :sam, seed: 42, log_directory: directory, output: output, **options).run
    [scores, output.string]
  end

  def test_each_logged_game_replays_to_its_reported_score
    Dir.mktmpdir do |directory|
      scores, output = play(directory, games: 3)

      assert_equal 3, scores.size
      logs = Dir[File.join(directory, "*.moves")]
      assert_equal 3, logs.size
      replayed = logs.map do |path|
        assert_includes File.read(path), "zgame_over|"
        GameTrace.replay(GameTrace.read(path)).score
      end
      assert_equal scores.sort, replayed.sort
      assert_match(/^Game 3: score #{scores.last}, \d+ moves, seed \d+, log /, output)
      mean = (scores.sum / 3.0).round(2)
      assert_match(/^3 of 3 games with sam: mean #{mean}, min #{scores.min}, max #{scores.max}/, output)
    end
  end

  def test_a_seed_repeats_its_games_and_the_first_matches_the_simulator
    Dir.mktmpdir do |first|
      Dir.mktmpdir do |second|
        scores, = play(first, games: 2)
        assert_equal scores, play(second, games: 2).first
        assert_equal GameSimulator.run(seed: 42, strategy: :sam).score, scores.first
      end
    end
  end

  def test_uses_the_learned_default_when_no_strategy_is_given
    Dir.mktmpdir do |directory|
      output = StringIO.new
      scores = HeadlessGame.new(seed: 42, log_directory: directory, output: output).run
      simulated = GameSimulator.run(seed: 42, strategy: :learned, model: AutoPlayer::DEFAULT_MODEL_PATH)
      assert_equal simulated.score, scores.first
      assert_includes output.string, "with learned"
    end
  end

  def test_neither_reads_nor_changes_the_players_saved_game
    Dir.mktmpdir do |directory|
      Dir.chdir(directory) do
        expected, = play(File.join(directory, "without-save"))
        saved = Board1010.new(random: Random.new(1)).tap(&:deal_if_needed).to_save
        File.write(Board1010::SAVE_FILE, saved)

        assert_equal expected, play(File.join(directory, "with-save")).first
        assert_equal saved, File.read(Board1010::SAVE_FILE)
      end
    end
  end

  def test_options_imply_auto_and_default_to_no_game_count
    assert_equal({headless: true, auto: true, strategy: "sam"}, GameOptions.parse(%w[--headless sam]))
    assert_equal 5, GameOptions.parse(%w[auto --headless --games 5 --seed 1 sam]).fetch(:games)
    refute GameOptions.parse(%w[auto sam]).key?(:headless)
  end

  def test_games_also_works_with_the_window_auto_mode
    assert_equal({auto: true, games: 10}, GameOptions.parse(%w[auto --games 10]).slice(:auto, :games))
    refute GameOptions.parse(%w[auto --games 10]).key?(:headless)
  end

  def test_rejects_options_that_do_not_apply
    {%w[--games 2 sam] => "requires auto", %w[--games 2] => "requires auto", %w[auto --games] => "--games",
     %w[auto --games 0] => "--games", %w[auto --games x] => "--games", %w[auto --games 2 a.moves] => "replaying",
     %w[--headless --games] => "--games", %w[--headless --delay 1] => "--delay",
     %w[--headless a.moves] => ".moves"}.each do |args, message|
      error = assert_raises(ArgumentError, args.join(" ")) { GameOptions.parse(args) }
      assert_includes error.message, message
    end
  end

  # A gosu.rb that aborts proves the command line path never loads the real one.
  def test_command_line_plays_without_loading_gosu
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "gosu.rb"), "abort 'gosu was loaded'\n")
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", directory, SCRIPT, "--headless", "sam",
                                              "--games", "2", "--seed", "7", chdir: directory)

      assert status.success?, stderr
      assert_match(/^Game 2: score \d+/, stdout)
      assert_equal 2, Dir[File.join(directory, "logs", "*.moves")].size
    end
  end

  def test_invalid_command_line_has_plain_error_without_backtrace
    Dir.mktmpdir do |directory|
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, "--headless", "nonsense", chdir: directory)

      assert_equal 2, status.exitstatus
      assert_match "unknown strategy", stderr
      assert_match "Usage:", stderr
      refute_match(/\.rb:\d+:in/, stderr)
    end
  end
end
