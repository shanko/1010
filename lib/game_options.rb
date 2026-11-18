# frozen_string_literal: true

require_relative "board"
require_relative "auto_player"

# Command-line options for the graphical front end, kept independent of Gosu.
class GameOptions
  # The window draws unfilled squares in one of these colors; mint is default.
  EMPTY_COLORS = %w[mint cream grey].freeze

  USAGE = <<~TEXT.chomp.freeze
    Usage: ./1010 [auto [strategy] [--games N]] [--seed N] [--level 0-100 | --bias TILE=PCT,...]
                  [--model PATH] [--delay SECONDS] [--empty-color #{EMPTY_COLORS.join('|')}] [GAME.moves]
           ./1010 --headless [strategy] [--games N] [--seed N] [--level 0-100 | --bias TILE=PCT,...]
                  [--model PATH]
      --level  difficulty: 0 deals only dots, 50 plain random tiles, 100 only 3x3 squares
      --bias   e.g. dot=20,sq3=10: deal that percentage of each tile, the rest at random
  TEXT

  def self.parse(argv)
    args = argv.dup
    options = {}
    parse_seed(args, options)
    parse_bias(args, options)
    parse_delay(args, options)
    parse_empty_color(args, options)
    parse_model(args, options)
    parse_games(args, options)
    options[:headless] = true if args.delete("--headless")
    parse_positionals(args, options)
    validate(options)
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

  # --level N or --bias TILE=PCT,... both become options[:bias].
  def self.parse_bias(args, options)
    raise ArgumentError, "use either --level or --bias, not both" if args.include?("--level") && args.include?("--bias")

    parse_level(args, options)
    parse_bias_text(args, options)
  end

  def self.parse_level(args, options)
    level_at = args.index("--level")
    return unless level_at

    level = Integer(args[level_at + 1].to_s, exception: false)
    raise ArgumentError, "--level requires an integer from 0 to #{Board1010::MAX_LEVEL}" unless level

    options[:bias] = Board1010.bias_for_level(level)
    args.slice!(level_at, 2)
  end

  def self.parse_bias_text(args, options)
    bias_at = args.index("--bias")
    return unless bias_at

    raise ArgumentError, "--bias requires tile percentages, for example dot=20,sq3=10" unless args[bias_at + 1]

    options[:bias] = Board1010.bias_from_text(args[bias_at + 1])
    args.slice!(bias_at, 2)
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

  def self.parse_empty_color(args, options)
    color_at = args.index("--empty-color")
    return unless color_at

    value = args[color_at + 1]
    raise ArgumentError, "--empty-color requires one of: #{EMPTY_COLORS.join(', ')}" unless value

    name = value == "gray" ? "grey" : value
    unless EMPTY_COLORS.include?(name)
      raise ArgumentError, "unknown --empty-color #{value.inspect}; choose from #{EMPTY_COLORS.join(', ')}"
    end

    options[:empty_color] = name.to_sym
    args.slice!(color_at, 2)
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

  def self.validate(options)
    validate_headless(options)
    validate_games(options)
    validate_bias(options)
    validate_strategy(options)
  end

  # Headless play has nobody to take a turn, so it is always auto mode.
  def self.validate_headless(options)
    return unless options[:headless]

    raise ArgumentError, "--headless cannot replay a .moves file" if options[:replay_file]
    raise ArgumentError, "--headless has no animation, so --delay does not apply" if options[:replay_delay]
    raise ArgumentError, "--headless has no window, so --empty-color does not apply" if options[:empty_color]

    options[:auto] = true
  end

  def self.validate_games(options)
    return unless options[:games]

    raise ArgumentError, "--games requires auto or --headless" unless options[:auto]
    raise ArgumentError, "--games cannot be used when replaying a .moves file" if options[:replay_file]
  end

  # A replay deals the recorded tiles, so a requested bias would be ignored.
  def self.validate_bias(options)
    return unless options.key?(:bias) && options[:replay_file]

    raise ArgumentError, "--level and --bias cannot be used when replaying a .moves file"
  end

  def self.validate_strategy(options)
    strategy_name = (options[:strategy] || AutoPlayer::DEFAULT_STRATEGY).to_sym
    return unless strategy_name == :learned

    options[:model] ||= AutoPlayer::DEFAULT_MODEL_PATH
    return if File.file?(options[:model])

    raise ArgumentError, "learned model does not exist: #{options[:model]}"
  end
  private_class_method :parse_seed, :parse_bias, :parse_level, :parse_bias_text, :parse_delay, :parse_empty_color,
                       :parse_model, :parse_games, :parse_positionals, :validate, :validate_headless,
                       :validate_games, :validate_bias, :validate_strategy
end
