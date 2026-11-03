# frozen_string_literal: true

require "digest"
require_relative "learned_player"

# Training resolves a named teacher explicitly instead of inheriting gameplay defaults.
module LearningModel
  def self.resolve(strategy, model)
    return nil unless strategy.to_sym == :learned

    if model.nil?
      raise ArgumentError,
            "learned training requires an explicit --model FILE (or model:); choose a heuristic otherwise"
    end

    return model if model.is_a?(LearnedPlayer)

    model.is_a?(String) ? LearnedPlayer.load(model) : LearnedPlayer.new(model)
  end

  def self.provenance(model)
    model ? {model_sha256: Digest::SHA256.hexdigest(JSON.generate(model.model))} : {}
  end
end
