# frozen_string_literal: true

require "json"
require "optparse"
require "open3"
require "digest"
require "time"
require_relative "../game_simulator"
require_relative "../learning_seed_sets"

options = {strategies: AutoPlayer::STRATEGIES, max_moves: 100_000, models: {}}
parser = OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/benchmark.rb (--seeds 1..100 | --seed-set baseline) --output baseline.json"
  parser.on("--seeds LIST", "Comma-separated seeds or an inclusive range, e.g. 1,2,3 or 1..100") do |value|
    raise OptionParser::InvalidArgument, "use either --seeds or --seed-set" if options[:seed_set]

    options[:seeds] = if value.include?("..")
                        first, last = value.split("..", 2).map {|part| Integer(part) }
                        raise OptionParser::InvalidArgument, "range end must be >= start" if last < first
                        (first..last).to_a
                      else
                        value.split(",").map {|part| Integer(part) }
                      end
  end
  parser.on("--seed-set NAME", LearningSeedSets.names.map(&:to_s).join(", "), "Use a predefined disjoint seed set") do |value|
    raise OptionParser::InvalidArgument, "use either --seeds or --seed-set" if options[:seeds]

    options[:seed_set] = value.to_sym
    options[:seeds] = LearningSeedSets.fetch(value)
  end
  parser.on("--strategies LIST", "Comma-separated strategy names; defaults to all current strategies") do |value|
    options[:strategies] = value.split(",").map(&:to_sym)
  end
  parser.on("--output PATH", "Write the JSON report to PATH (required)") {|value| options[:output] = value }
  parser.on("--max-moves COUNT", Integer, "Safety limit per simulated episode") {|value| options[:max_moves] = value }
  parser.on("--model PATH", "Learned policy model (required when learned strategy is selected)") do |value|
    options[:models][:learned] = value
  end
end

begin
parser.parse!(ARGV)

raise OptionParser::MissingArgument, "--seeds is required" unless options[:seeds]
raise OptionParser::MissingArgument, "--output is required" unless options[:output]
raise OptionParser::InvalidArgument, "--max-moves must be positive" unless options[:max_moves].positive?
if options[:strategies].include?(:learned)
  missing = AutoPlayer::STRATEGIES - options[:strategies]
  raise OptionParser::InvalidArgument, "learned comparison must include all heuristic baselines: #{missing.join(', ')}" unless missing.empty?
end

report = GameBenchmark.run(seeds: options[:seeds], strategies: options[:strategies],
                           max_moves: options[:max_moves], models: options[:models])
if options[:strategies].include?(:learned)
  best_heuristic = AutoPlayer::STRATEGIES.max_by do |strategy|
    report.fetch(:strategies).fetch(strategy).fetch(:metrics).fetch(:score).fetch(:mean)
  end
  report[:strongest_heuristic] = best_heuristic
  report[:learned_vs_strongest_heuristic] = report.fetch(:pairwise_score_deltas)
                                                      .fetch(:learned).fetch(best_heuristic)
  report[:learned_model_path] = File.expand_path(options[:models].fetch(:learned))
  report[:learned_model_sha256] = Digest::SHA256.file(options[:models].fetch(:learned)).hexdigest
end
revision, = Open3.capture2("git", "rev-parse", "HEAD")
dirty = !Open3.capture2("git", "status", "--porcelain").first.empty?
report[:source_revision] = revision.strip
report[:working_tree_dirty] = dirty
report[:seed_set] = options[:seed_set] if options[:seed_set]
source_files = %w[board.rb auto_player.rb learned_player.rb game_simulator.rb learning_seed_sets.rb scripts/benchmark.rb]
source_digest_input = source_files.map do |path|
  absolute_path = File.expand_path("../#{path}", __dir__)
  "#{path}\0#{File.binread(absolute_path)}"
end.join("\0")
report[:source_files] = source_files
report[:source_code_sha256] = Digest::SHA256.hexdigest(source_digest_input)

File.write(options[:output], JSON.pretty_generate(report) + "\n")
puts "Wrote #{options[:output]} for #{options[:seeds].size} seeds and #{options[:strategies].size} strategies."
rescue OptionParser::ParseError, ArgumentError, IOError, SystemCallError => error
  warn "Benchmark failed: #{error.message}"
  warn parser
  exit 2
end
