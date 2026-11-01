# frozen_string_literal: true

# Each command owns its complete option surface and delegates domain work to the
# existing service objects.
# rubocop:disable Metrics/AbcSize, Metrics/MethodLength

require "json"
require "optparse"
require "fileutils"
require_relative "lesson_analyzer"
require_relative "learned_player"
require_relative "policy_corrector"
require_relative "reinforcement_trainer"
require_relative "lesson_collector"
require_relative "game_improver"

# In-process command implementations for scripts/learn.rb.
module LearnCLI
  class Command
    attr_reader :parser

    def call(argv, out: $stdout, err: $stderr)
      options = parse(argv.dup)
      execute(options, out: out, err: err)
      0
    rescue OptionParser::ParseError => e
      err.puts "Invalid options: #{e.message}"
      err.puts parser if parser
      2
    rescue ArgumentError, IOError, SystemCallError => e
      err.puts "#{failure_label}: #{e.message}"
      1
    end

    def parse(_argv)
      raise NotImplementedError
    end

    def execute(_options, out:, **)
      raise NotImplementedError
    end

    private

    def parse_options(argv, options, banner:)
      @parser = OptionParser.new do |opts|
        opts.banner = banner
        define_options(opts, options)
      end
      @parser.parse!(argv)
      raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      options
    end

    def define_options(_opts, _options)
      raise NotImplementedError
    end

    def json(out, value)
      out.puts JSON.pretty_generate(value)
    end

    def failure_label
      self.class::FAILURE_LABEL
    end
  end

  class Analyze < Command
    FAILURE_LABEL = "Analysis failed"

    def parse(argv)
      options = {budget: 30.0, beam_width: 4, max_states: 10_000, max_rollouts: 8,
                 strategy: AutoPlayer::DEFAULT_STRATEGY, output: LessonStore::DIRECTORY}
      @parser = OptionParser.new do |opts|
        opts.banner = "Usage: scripts/learn.rb analyze GAME.moves [options]"
        define_options(opts, options)
      end
      @parser.parse!(argv)
      @trace_path = argv.shift
      raise OptionParser::MissingArgument, "GAME.moves" unless @trace_path
      raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      options
    end

    def execute(options, out:, **)
      lesson = LessonAnalyzer.new.analyze(@trace_path, time_budget_seconds: options[:budget],
                                          beam_width: options[:beam_width], max_states: options[:max_states],
                                          max_rollouts: options[:max_rollouts],
                                          rollouts_per_step: options.fetch(:rollouts_per_step, 2),
                                          strategy: options[:strategy])
      saved = LessonStore.new(directory: options[:output]).save(lesson)
      divergence = lesson.fetch(:actual_sequence).zip(lesson.fetch(:candidate_sequence)).index do |actual, candidate|
        actual != candidate
      end
      unless divergence
        actual_length = lesson.fetch(:actual_sequence).size
        candidate_length = lesson.fetch(:candidate_sequence).size
        divergence = [actual_length, candidate_length].min if actual_length != candidate_length
      end
      divergence += 1 if divergence
      json(out, {outcome: lesson.fetch(:outcome), actual_score: lesson.fetch(:actual_score),
                 candidate_score: lesson.fetch(:candidate_score), improvement_delta: lesson.fetch(:improvement_delta),
                 first_action_divergence: divergence, search_status: lesson.fetch(:search).fetch(:status),
                 lesson: File.expand_path(saved.fetch(:path)), deduplicated: saved.fetch(:deduplicated)})
    end

    private

    def define_options(opts, options)
      opts.on("--budget SECONDS", Float) {|value| options[:budget] = value }
      opts.on("--beam-width N", Integer) {|value| options[:beam_width] = value }
      opts.on("--max-states N", Integer) {|value| options[:max_states] = value }
      opts.on("--max-rollouts N", Integer) {|value| options[:max_rollouts] = value }
      opts.on("--rollouts-per-step N", Integer) {|value| options[:rollouts_per_step] = value }
      opts.on("--strategy NAME") {|value| options[:strategy] = value.to_sym }
      opts.on("--output DIR") {|value| options[:output] = value }
    end
  end

  class TrainImitation < Command
    FAILURE_LABEL = "Training failed"

    def parse(argv)
      options = {lessons: LessonStore::DIRECTORY,
                 output: File.join(LessonStore::DIRECTORY, "models", "imitation-v1.json"),
                 seed_set: :training, seed: 1, epochs: 10, learning_rate: 0.1}
      parse_options(argv, options, banner: "Usage: scripts/learn.rb train-imitation [options]")
    end

    def execute(options, out:, **)
      LearningSeedSets.validate_set!(options[:seed_set], allowed: :training, purpose: "imitation training")
      trained = ImitationTrainer.new.train(directory: options[:lessons], seed_set: options[:seed_set],
                                           random_seed: options[:seed], epochs: options[:epochs],
                                           learning_rate: options[:learning_rate])
      FileUtils.mkdir_p(File.dirname(options[:output]))
      ImitationTrainer.new.save(trained.model, options[:output])
      json(out, {model: File.expand_path(options[:output]), episodes_used: trained.episodes_used,
                 examples_seen: trained.examples_seen, excluded: trained.excluded.transform_keys(&:to_s)})
    end

    private

    def define_options(opts, options)
      opts.on("--lessons DIR") {|value| options[:lessons] = value }
      opts.on("--output FILE") {|value| options[:output] = value }
      opts.on("--seed-set NAME", LearningSeedSets.names.map(&:to_s).join(", ")) {|value|
        options[:seed_set] = value.to_sym
      }
      opts.on("--seed N", Integer) {|value| options[:seed] = value }
      opts.on("--epochs N", Integer) {|value| options[:epochs] = value }
      opts.on("--learning-rate RATE", Float) {|value| options[:learning_rate] = value }
    end
  end

  class CollectTraining < Command
    FAILURE_LABEL = "Training lesson collection failed"

    def parse(argv)
      options = {strategy: :sam, budget: 30.0, beam_width: 4, max_states: 2_000,
                 max_rollouts: 8, output: LessonStore::DIRECTORY}
      parser = build_parser(options)
      parser.parse!(argv)
      raise OptionParser::MissingArgument, "--seeds LIST" unless options[:seeds]
      raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      options
    end

    def execute(options, out:, **)
      seeds = LearningSeedSets.validate!(options[:seeds], set: :training, purpose: "lesson collection")
      result = LessonCollector.new.collect(seeds: seeds, strategy: options[:strategy],
                                           time_budget_seconds: options[:budget],
                                           beam_width: options[:beam_width], max_states: options[:max_states],
                                           max_rollouts: options[:max_rollouts],
                                           rollouts_per_step: options.fetch(:rollouts_per_step, 2),
                                           store: LessonStore.new(directory: options[:output]))
      json(out, {episodes: result.episodes, improvements_found: result.improvements_found,
                 complete_improvements: result.complete_improvements, lessons_saved: result.lessons_saved})
    end

    private

    def build_parser(options)
      @parser = OptionParser.new do |opts|
        opts.banner = "Usage: scripts/learn.rb collect-training --seeds LIST [options]"
        opts.on("--seeds LIST", "Comma-separated integers or inclusive START..END range") do |value|
          options[:seeds] = LearningSeedSets.parse_list(value)
        end
        opts.on("--strategy NAME") {|value| options[:strategy] = value.to_sym }
        opts.on("--budget SECONDS", Float) {|value| options[:budget] = value }
        opts.on("--beam-width N", Integer) {|value| options[:beam_width] = value }
        opts.on("--max-states N", Integer) {|value| options[:max_states] = value }
        opts.on("--max-rollouts N", Integer) {|value| options[:max_rollouts] = value }
        opts.on("--rollouts-per-step N", Integer) {|value| options[:rollouts_per_step] = value }
        opts.on("--output DIR") {|value| options[:output] = value }
      end
    end
  end

  class Correct < Command
    FAILURE_LABEL = "Correction search failed"

    def parse(argv)
      options = {budget: 1.0, beam_width: 4, max_states: 2_000, max_rollouts: 1, stride: 1,
                 output: LessonStore::DIRECTORY}
      @parser = OptionParser.new do |opts|
        opts.banner = "Usage: scripts/learn.rb correct --model MODEL --seeds LIST [options]"
        opts.on("--model FILE") {|value| options[:model] = value }
        opts.on("--seeds LIST", "Comma-separated integers or inclusive START..END range") do |value|
          options[:seeds] = LearningSeedSets.parse_list(value)
        end
        opts.on("--budget SECONDS", Float) {|value| options[:budget] = value }
        opts.on("--beam-width N", Integer) {|value| options[:beam_width] = value }
        opts.on("--max-states N", Integer) {|value| options[:max_states] = value }
        opts.on("--max-rollouts N", Integer) {|value| options[:max_rollouts] = value }
        opts.on("--rollouts-per-step N", Integer) {|value| options[:rollouts_per_step] = value }
        opts.on("--stride N", Integer) {|value| options[:stride] = value }
        opts.on("--output DIR") {|value| options[:output] = value }
      end
      @parser.parse!(argv)
      raise OptionParser::MissingArgument, "--model FILE" unless options[:model]
      raise OptionParser::MissingArgument, "--seeds LIST" unless options[:seeds]
      raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      options
    end

    def execute(options, out:, **)
      seeds = LearningSeedSets.validate!(options[:seeds], set: :training, purpose: "policy correction")
      model = LearnedPlayer.load(options[:model])
      result = PolicyCorrector.new.correct(seeds: seeds, model: model,
                                           store: LessonStore.new(directory: options[:output]),
                                           time_budget_seconds: options[:budget],
                                           beam_width: options[:beam_width], max_states: options[:max_states],
                                           max_rollouts: options[:max_rollouts],
                                           rollouts_per_step: options.fetch(:rollouts_per_step, 2),
                                           decision_stride: options[:stride])
      json(out, {episodes: result.episodes, states_searched: result.states_searched,
                 improvements_saved: result.improvements_saved, usable_lessons: result.usable_lessons})
    end
  end

  class Select < Command
    FAILURE_LABEL = "Checkpoint selection failed"

    def parse(argv)
      options = {tuning_seeds: LearningSeedSets.fetch(:tuning).first(20)}
      @parser = OptionParser.new do |opts|
        opts.banner = "Usage: scripts/learn.rb select --checkpoint FILE [options]"
        opts.on("--checkpoint FILE", "Checkpoint to evaluate on tuning seeds") {|value| options[:checkpoint] = value }
        opts.on("--tuning-seeds LIST", "Comma-separated integers or inclusive START..END range") do |value|
          options[:tuning_seeds] = LearningSeedSets.parse_list(value)
        end
        opts.on("--output FILE", "Selected pointer (default: sibling selected.json)") {|value|
          options[:output] = value
        }
      end
      @parser.parse!(argv)
      raise OptionParser::MissingArgument, "--checkpoint FILE" unless options[:checkpoint]
      raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      options
    end

    def execute(options, out:, **)
      tuning = LearningSeedSets.validate!(options[:tuning_seeds], set: :tuning, purpose: "checkpoint selection")
      checkpoint = File.expand_path(options[:checkpoint])
      model = LearnedPlayer.load(checkpoint).model
      report = GameBenchmark.run(seeds: tuning, strategies: [:learned], models: {learned: model})
      metrics = report.fetch(:strategies).fetch(:learned).fetch(:metrics).fetch(:score)
      evaluation = {"seeds" => tuning, "mean_score" => metrics.fetch(:mean),
                    "score_summary" => metrics,
                    "per_seed" => report.fetch(:strategies).fetch(:learned).fetch(:per_seed)}
      pointer = File.expand_path(options[:output] || File.join(File.dirname(checkpoint), "selected.json"))
      unless File.dirname(pointer) == File.dirname(checkpoint)
        raise ArgumentError,
              "selected pointer must be beside the checkpoint"
      end

      result = RLCheckpointStore.new(directory: File.dirname(pointer)).select(checkpoint,
                                                                              tuning_evaluation: evaluation)
      json(out, {checkpoint: checkpoint, selected_pointer: File.expand_path(result),
                 tuning_evaluation: evaluation})
    end
  end

  class TrainRL < Command
    FAILURE_LABEL = "RL training failed"

    def parse(argv)
      options = {episodes: 1, random_seed: 1, learning_rate: 0.01, temperature: 1.0,
                 baseline_decay: 0.9,
                 checkpoint_interval: ReinforcementTrainer::DEFAULT_CHECKPOINT_INTERVAL,
                 checkpoints: File.join(LessonStore::DIRECTORY, "checkpoints")}
      @parser = OptionParser.new do |opts|
        opts.banner = "Usage: scripts/learn.rb train-rl --model MODEL [options]"
        opts.on("--model FILE", "Initial imitation model") {|value| options[:model] = value }
        opts.on("--resume FILE", "Resume from an RL checkpoint or selected.json pointer") {|value|
          options[:resume] = value
        }
        opts.on("--episodes N", Integer) {|value| options[:episodes] = value }
        opts.on("--seeds LIST", "Comma-separated integers or inclusive START..END range") do |value|
          options[:seeds] = LearningSeedSets.parse_list(value)
        end
        opts.on("--tuning-seeds LIST", "Comma-separated integers or inclusive START..END range") do |value|
          options[:tuning_seeds] = LearningSeedSets.parse_list(value)
        end
        opts.on("--seed N", Integer, "Policy exploration RNG seed") {|value| options[:random_seed] = value }
        opts.on("--learning-rate RATE", Float) {|value| options[:learning_rate] = value }
        opts.on("--temperature VALUE", Float) {|value| options[:temperature] = value }
        opts.on("--baseline-decay VALUE", Float) {|value| options[:baseline_decay] = value }
        opts.on("--checkpoint-interval N", Integer) {|value| options[:checkpoint_interval] = value }
        opts.on("--checkpoints DIR") {|value| options[:checkpoints] = value }
      end
      @parser.parse!(argv)
      raise OptionParser::MissingArgument, "--model MODEL or --resume FILE" unless options[:model] || options[:resume]
      raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      options
    end

    def execute(options, out:, **)
      seeds = options[:seeds] && LearningSeedSets.validate!(options[:seeds], set: :training, purpose: "RL training")
      tuning_seeds = LearningSeedSets.validate!(options[:tuning_seeds] || LearningSeedSets.fetch(:tuning).first(20),
                                                set: :tuning, purpose: "RL tuning")
      result = ReinforcementTrainer.new.train(initial_model: options[:model] || options[:resume],
                                              resume: options[:resume], episode_count: options[:episodes],
                                              random_seed: options[:random_seed],
                                              learning_rate: options[:learning_rate],
                                              temperature: options[:temperature],
                                              baseline_decay: options[:baseline_decay],
                                              seeds: seeds, tuning_seeds: tuning_seeds,
                                              checkpoint_interval: options[:checkpoint_interval],
                                              checkpoint_store: RLCheckpointStore.new(directory: options[:checkpoints]))
      json(out, {episodes: result.episodes, global_step: result.global_step,
                 best_checkpoint: File.expand_path(result.best_checkpoint),
                 selected_pointer: File.expand_path(result.selected_pointer),
                 selection_changed: result.selection_changed,
                 previous_selected_checkpoint: expanded_path(result.previous_selected_checkpoint),
                 best_tuning_evaluation: result.best_tuning_evaluation,
                 checkpoints: result.checkpoints.map do |checkpoint|
                   {path:       File.expand_path(checkpoint.fetch(:path)),
                    mean_score: checkpoint.fetch(:evaluation).fetch("mean_score")}
                 end})
    end

    private

    def expanded_path(path)
      File.expand_path(path) if path
    end
  end

  class Improve < Command
    FAILURE_LABEL = "Game improvement failed"

    def parse(argv)
      options = {states: GameImprover::DEFAULT_STATES, time: 86_400.0, beam_width: 4}
      @parser = OptionParser.new do |opts|
        opts.banner = "Usage: scripts/learn.rb improve GAME.moves [options]"
        opts.on("--states N", Integer, "Maximum search states (default: #{options[:states]})") do |value|
          options[:states] = value
        end
        opts.on("--time SECONDS", Float, "Optional wall-clock safety cap") {|value| options[:time] = value }
        opts.on("--beam-width N", Integer) {|value| options[:beam_width] = value }
        opts.on("--output FILE", "Improved trace (default: GAME.improved.moves)") {|value| options[:output] = value }
        opts.on("--report FILE", "JSON report (default: sibling .report.json)") {|value| options[:report] = value }
        opts.on("--save-lesson", "Also save a lesson from the improved trace") { options[:save_lesson] = true }
      end
      @parser.parse!(argv)
      @trace_path = argv.shift
      raise OptionParser::MissingArgument, "GAME.moves" unless @trace_path
      raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      options
    end

    def execute(options, out:, **)
      result = GameImprover.new.improve(@trace_path, states: options[:states],
                                        time_budget_seconds: options[:time],
                                        beam_width: options[:beam_width],
                                        output_path: options[:output], report_path: options[:report],
                                        save_lesson: options.fetch(:save_lesson, false))
      report = result.report
      puts_to(out, "Original:  #{report.dig(:original, :score)} points, #{report.dig(:original, :moves)} moves")
      delta = report.dig(:search, :score_delta)
      sign = delta.positive? ? "+" : ""
      improved = report.fetch(:improved)
      puts_to(out, "Improved: #{improved.fetch(:score)} points, #{improved.fetch(:moves)} moves (#{sign}#{delta})")
      puts_to(out, "Same tiles: #{report[:recorded_offer_sets_used]} recorded offer sets; " \
                   "#{report[:seeded_offer_sets_used]} seeded sets")
      print_first_change(out, report[:first_change])
      print_costliest_moves(out, report[:costliest_moves])
      consistency = report[:seed_consistency_reason] ? ": #{report[:seed_consistency_reason]}" : ""
      puts_to(out, "Seed consistent: #{report[:seed_consistent]}#{consistency}")
      puts_to(out, "Wrote #{result.trace_path}")
      puts_to(out, "Report: #{result.report_path}")
      puts_to(out, "Lesson: #{result.lesson_path}") if result.lesson_path
    end

    private

    def puts_to(output, message)
      output.puts(message)
    end

    def print_first_change(output, change)
      return unless change

      original = change.fetch(:original)
      improved = change.fetch(:improved)
      puts_to(output, "First change: move #{change.fetch(:move)} (#{original.fetch(:tile)} " \
                      "at (#{original.fetch(:row)},#{original.fetch(:col)}) → " \
                      "#{improved.fetch(:tile)} at (#{improved.fetch(:row)},#{improved.fetch(:col)}))")
    end

    def print_costliest_moves(output, moves)
      puts_to(output, "Costliest moves:")
      if moves.empty?
        puts_to(output, "  No better placement estimates found.")
        return
      end

      moves.each do |entry|
        original = entry.fetch(:original)
        better = entry.fetch(:better)
        move = entry.fetch(:move).to_s.rjust(3)
        tile = entry.fetch(:tile).ljust(4)
        puts_to(output, "  move #{move}  #{tile} at (#{original.fetch(:row)},#{original.fetch(:col)}) " \
                        "≈ -#{entry.fetch(:estimated_cost)} points  " \
                        "better: (#{better.fetch(:row)},#{better.fetch(:col)})")
      end
    end
  end

  COMMANDS = {"analyze" => Analyze, "train-imitation" => TrainImitation,
              "collect-training" => CollectTraining, "correct" => Correct,
              "select" => Select, "train-rl" => TrainRL, "improve" => Improve}.freeze

  def self.run(argv=ARGV, out: $stdout, err: $stderr)
    args = argv.dup
    command = args.shift
    handler = COMMANDS[command]
    unless handler
      err.puts "Usage: scripts/learn.rb COMMAND [options]"
      err.puts "Commands: #{COMMANDS.keys.join(', ')}"
      return 2
    end

    handler.new.call(args, out: out, err: err)
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength
