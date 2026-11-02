# frozen_string_literal: true

require_relative "auto_player"

# Command-line options for the graphical front end, kept independent of Gosu.
class GameOptions
  USAGE = <<~TEXT.chomp.freeze
    Usage: ./1010 [auto [strategy]] [--seed N] [--model PATH] [--delay SECONDS] [GAME.moves]
           ./1010 --headless [strategy] [--games N] [--seed N] [--model PATH]
  TEXT

  def self.parse(argv)
    args = argv.dup
    options = {}
    parse_seed(args, options)
    parse_delay(args, options)
    parse_model(args, options)
    parse_games(args, options)
    options[:headless] = true if args.delete("--headless")
    parse_positionals(args, options)
    validate_headless(options)
    validate_strategy(options)
    raise ArgumentError, "unexpected command line arguments: #{args.join(' ')}" unless args.empty?

    options
  end

  def self.parse_seed(args, options)
    seed_at = args.index("--seed")
    return unless seed_at

    raise ArgumentError, "--seed requires an integer" unless args[seed_at + 1]

    options[:seed] = Integer(args[seed_at + 1])
    args.slice!(seed_at, 2)
  end

  def self.parse_delay(args, options)
    delay_at = args.index("--delay")
    return unless delay_at

    value = args[delay_at + 1]
    raise ArgumentError, "--delay requires seconds (for example: --delay 1.5)" unless value

    begin
      options[:replay_delay] = Float(value)
    rescue ArgumentError
      raise ArgumentError, "invalid --delay value #{value.inspect}; use seconds, for example --delay 1.5"
    end

    unless options[:replay_delay].finite? && options[:replay_delay] >= 0
      raise ArgumentError, "--delay must be a finite non-negative number of seconds"
    end

    args.slice!(delay_at, 2)
  end

  def self.parse_model(args, options)
    model_at = args.index("--model")
    return unless model_at

    value = args[model_at + 1]
    raise ArgumentError, "--model requires a model JSON path" unless value

    options[:model] = value
    args.slice!(model_at, 2)
  end

  def self.parse_games(args, options)
    games_at = args.index("--games")
    return unless games_at

    options[:games] = Integer(args[games_at + 1].to_s, exception: false)
    raise ArgumentError, "--games requires a positive integer" unless options[:games]&.positive?

    args.slice!(games_at, 2)
  end

  def self.parse_positionals(args, options)
    replay_at = args.index {|arg| arg.end_with?(".moves") }
    options[:replay_file] = args.delete_at(replay_at) if replay_at

    options[:auto] = !args.delete("auto").nil?
    options[:strategy] = args.shift unless args.empty?
  end

  # Headless play has nobody to take a turn, so it is always auto mode.
  def self.validate_headless(options)
    raise ArgumentError, "--games requires --headless" if options[:games] && !options[:headless]
    return unless options[:headless]

    raise ArgumentError, "--headless cannot replay a .moves file" if options[:replay_file]
    raise ArgumentError, "--headless has no animation, so --delay does not apply" if options[:replay_delay]

    options[:auto] = true
  end

  def self.validate_strategy(options)
    strategy_name = (options[:strategy] || AutoPlayer::DEFAULT_STRATEGY).to_sym
    return unless strategy_name == :learned

    options[:model] ||= AutoPlayer::DEFAULT_MODEL_PATH
    return if File.file?(options[:model])

    raise ArgumentError, "learned model does not exist: #{options[:model]}"
  end
  private_class_method :parse_seed, :parse_delay, :parse_model, :parse_games, :parse_positionals,
                       :validate_headless, :validate_strategy
end
