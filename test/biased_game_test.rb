# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require_relative "../lib/game_session"
require_relative "../lib/game_options"
require_relative "../lib/game_improver"
require_relative "../lib/headless_game"

# Biased dealing outside the board: text form, saves, game logs, sessions,
# the command line and seeded improvement.
class BiasedGameTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/game_1010.rb", __dir__)

  def session(directory, **options)
    GameSession.new(strategy: :first_fit, clock: -> { 0 }, log_directory: directory,
                    save_store: GameSession::SaveStore.new(path: File.join(directory, "save.txt")), **options)
  end

  def play_out(session)
    session.auto_move until session.game_over
    path = session.game_log.path
    session.finish
    path
  end

  # --- Text form --------------------------------------------------------------

  def test_bias_text_round_trips_and_accepts_any_case
    assert_equal "dot=20,sq3=12.5", Board1010.bias_to_text({"DOT" => 20, "sq3" => 12.5})
    assert_equal({dot: 20, sq3: 12.5}, Board1010.bias_from_text("DOT=20, sq3=12.5"))
    assert_equal({}, Board1010.bias_from_text(""))
    assert_equal "", Board1010.bias_to_text({})
  end

  def test_bad_bias_text_is_rejected
    ["dot", "dot=", "=20", "dot=20=1", "dot=x", "dot=20,", "dot=20,DOT=5", "dot=60,sq3=50", "nope=1",
     "dot=Infinity", "dot=1e3"].each do |text|
      assert_raises(ArgumentError, text) { Board1010.bias_from_text(text) }
    end
  end

  def test_only_integer_and_float_percentages_are_accepted
    assert_raises(ArgumentError) { Board1010.normalize_bias({dot: Rational(1, 3)}) }
  end

  # --- Saves ------------------------------------------------------------------

  def test_unbiased_saves_are_unchanged_and_biased_saves_keep_their_bias
    plain = Board1010.new(random: Random.new(5)).tap(&:deal_if_needed)
    refute_includes plain.to_save, "|b"

    biased = Board1010.new(random: Random.new(5), bias: {sq3: 30, dot: 10}).tap(&:deal_if_needed)
    assert_includes biased.to_save.lines[1], "|bsq3=30,dot=10"

    loaded = Board1010.from_save(biased.to_save)
    assert_equal({sq3: 30, dot: 10}, loaded.bias)
    assert_equal biased.options, loaded.options
    assert_equal({}, Board1010.from_save(plain.to_save).bias)
  end

  def test_a_damaged_bias_makes_the_save_unreadable
    save = Board1010.new(bias: {dot: 20}).tap(&:deal_if_needed).to_save
    ["|bdot=120", "|bnope=5", "|b", "|bdot=0"].each do |damage|
      assert_nil Board1010.from_save(save.sub("|bdot=20", damage)), damage
    end
  end

  # --- Sessions and game logs -------------------------------------------------

  def test_a_session_bias_is_dealt_logged_and_replayed
    Dir.mktmpdir do |directory|
      game = session(directory, auto: true, seed: 3, bias: {sq3: 100})
      assert_equal({sq3: 100}, game.board.bias)
      assert_equal %i[sq3 sq3 sq3], game.board.options.map(&:name)
      score = game.board.score
      path = play_out(game)

      trace = GameTrace.read(path)
      assert_equal({sq3: 100}, trace.starting_board.bias)
      assert_includes trace.deal_batches.flatten.map(&:to_s).tally.max_by(&:last), "sq3"
      assert_operator GameTrace.replay(trace).score, :>=, score
    end
  end

  def test_unbiased_sessions_write_the_same_logs_as_before
    Dir.mktmpdir do |directory|
      path = play_out(session(directory, auto: true, seed: 3))
      refute_includes File.read(path), "|b"
    end
  end

  def test_a_loaded_save_keeps_its_own_bias_and_new_games_use_the_sessions
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "save.txt"), Board1010.new(bias: {dot: 40}).tap(&:deal_if_needed).to_save)
      game = session(directory, bias: {sq3: 100})

      assert_equal :loaded, game.initial_message
      assert_equal({dot: 40}, game.board.bias)
      game.new_game
      assert_equal({sq3: 100}, game.board.bias)
      game.finish
    end
  end

  def test_a_replayed_biased_game_continues_with_its_bias
    Dir.mktmpdir do |directory|
      path = play_out(session(directory, auto: true, seed: 4, bias: {hl2: 50}))
      replay = session(directory, replay_file: path, replay_delay: 0)

      assert_equal({hl2: 50}, replay.board.bias)
      replay.finish
    end
  end

  # --- Command line -----------------------------------------------------------

  def test_level_and_bias_options_become_a_bias
    assert_equal({dot: 60}, GameOptions.parse(%w[--level 20]).fetch(:bias))
    assert_equal({}, GameOptions.parse(%w[auto --level 50]).fetch(:bias))
    assert_equal({sq3: 100}, GameOptions.parse(%w[--headless --level 100]).fetch(:bias))
    assert_equal({dot: 20, sq3: 10}, GameOptions.parse(%w[auto --bias dot=20,SQ3=10 --seed 1]).fetch(:bias))
    refute GameOptions.parse(%w[auto]).key?(:bias)
  end

  def test_bad_level_and_bias_options_are_rejected
    {%w[--level] => "--level", %w[--level 101] => "level", %w[--level x] => "--level",
     %w[--level 2.5] => "--level", %w[--bias] => "--bias", %w[--bias dot] => "bias",
     %w[--level 10 --bias dot=5] => "not both", %w[--level 10 a.moves] => "replaying"}.each do |args, message|
      error = assert_raises(ArgumentError, args.join(" ")) { GameOptions.parse(args) }
      assert_includes error.message, message
    end
  end

  # Only hard levels here: a game of nothing but dots can never end.
  def test_headless_games_use_the_level
    Dir.mktmpdir do |directory|
      output = StringIO.new
      HeadlessGame.new(strategy: :first_fit, seed: 8, bias: Board1010.bias_for_level(100),
                       log_directory: directory, output: output).run
      trace = GameTrace.read(Dir[File.join(directory, "*.moves")].first)

      assert_equal({sq3: 100}, trace.starting_board.bias)
      assert_includes trace.deal_batches.first.map(&:to_s), "sq3"
    end
  end

  def test_command_line_headless_level_writes_a_biased_log
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "gosu.rb"), "abort 'gosu was loaded'\n")
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", directory, SCRIPT, "--headless", "first_fit",
                                              "--level", "90", "--seed", "7", chdir: directory)

      assert status.success?, stderr
      assert_match(/^Game 1: score \d+/, stdout)
      log = Dir[File.join(directory, "logs", "*.moves")].first
      assert_equal({sq3: 80}, GameTrace.read(log).starting_board.bias)
    end
  end

  # --- Seeded improvement -----------------------------------------------------

  def test_seed_validation_rebuilds_the_biased_dealer
    Dir.mktmpdir do |directory|
      game = session(directory, auto: true, seed: 0, bias: {sq3: 40})
      game.new_game(seed: 1_000_000)
      trace = GameTrace.read(play_out(game))

      assert_equal true, GameImprover.new.validate_seed(trace).fetch(:consistent)
    end
  end
end
