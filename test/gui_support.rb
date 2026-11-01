# frozen_string_literal: true

# Headless machines may skip the Gemfile's :gui group
# (`bundle config set --local without gui`). Window tests skip only then;
# anywhere else a missing or broken Gosu still fails them.
module GuiSupport
  def self.excluded?
    return false unless defined?(Bundler)

    Array(Bundler.settings[:without]).map(&:to_sym).include?(:gui)
  end

  SKIP_MESSAGE = "the Gemfile :gui group is excluded (bundle config without gui)"
end
