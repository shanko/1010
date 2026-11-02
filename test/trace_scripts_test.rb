# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../lib/game_improver"
require_relative "../lib/game_session"

class TraceScriptsTest < Minitest::Test
  DEEP_IMPROVE = File.expand_path("../scripts/deep_improve.rb", __dir__)
  VERIFY_TRACE = File.expand_path("../scripts/verify_trace.rb", __dir__)
  SEED = 2

  def test_an_improved_trace_is_a_game_its_seed_deals
    Dir.mktmpdir do |directory|
      source = write_game(directory)
      output = File.join(directory, "improved.moves")
      stdout, stderr, status = run_script(DEEP_IMPROVE, source, "--prefix", "0", "--states", "3000",
                                          "--rollouts", "40", "--output", output)

      assert status.success?, stderr
      assert_match "wrote", stdout
      improved = GameTrace.read(output)
      assert_operator improved.final_score, :>, GameTrace.read(source).final_score
      assert_equal({consistent: true, reason: nil}, GameImprover.new.validate_seed(improved))
    end
  end

  def test_splicing_past_where_a_trace_left_the_dealer_is_a_plain_error
    Dir.mktmpdir do |directory|
      source = write_game(directory, trace_seed: SEED + 1)

      _stdout, stderr, status = run_script(DEEP_IMPROVE, source, "--prefix", "5", "--states", "10",
                                           "--rollouts", "1", "--output", File.join(directory, "out.moves"))

      refute status.success?
      assert_match "left the seeded dealer", stderr
      assert_match "initial offer differs", stderr
      refute_match(/deep_improve\.rb:\d+:in/, stderr)
      refute_path_exists File.join(directory, "out.moves")
    end
  end

  def test_verify_trace_accepts_a_game_the_seed_deals
    Dir.mktmpdir do |directory|
      stdout, _stderr, status = run_script(VERIFY_TRACE, write_game(directory))

      assert status.success?
      assert_match(/\bOK$/, stdout)
    end
  end

  def test_verify_trace_rejects_deals_the_seed_does_not_produce
    Dir.mktmpdir do |directory|
      stdout, _stderr, status = run_script(VERIFY_TRACE, write_game(directory, trace_seed: SEED + 1))

      refute status.success?
      assert_match "DEALER MISMATCH", stdout
      assert_match "initial offer differs", stdout
    end
  end

  private

  def run_script(script, *arguments)
    Open3.capture3(RbConfig.ruby, script, *arguments)
  end

  # Writes the game's trace, optionally declaring a seed that did not deal it.
  def write_game(directory, trace_seed: SEED)
    session = GameSession.new(auto: true, strategy: :first_fit, seed: 0, log_directory: directory,
                              save_store: GameSession::SaveStore.new(path: File.join(directory, "save.txt")),
                              clock: -> { 0 })
    session.new_game(seed: SEED)
    session.auto_move until session.game_over
    path = session.game_log.path
    session.finish
    File.write(path, File.read(path).sub(/^s#{SEED}$/, "s#{trace_seed}"))
    path
  end
end
