# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require_relative "offer_replay"
require_relative "artifact_file"

# Versioned local storage for reproducible improvement-search lessons.
class LessonStore
  DIRECTORY = "learning_data"
  SCHEMA_VERSION = 2

  def initialize(directory: DIRECTORY)
    @directory = directory
  end

  # Keep the strongest analysis per state/offer history and completeness class.
  # Incomplete high scores never replace complete examples usable for training.
  def save(lesson)
    validate!(lesson)
    FileUtils.mkdir_p(@directory)
    identity = identity_for(lesson)
    existing_path = find_existing_path(identity)
    return update_existing(existing_path, lesson) if existing_path

    write_new(lesson, identity)
  end

  def self.read(path, allow_legacy: true)
    lesson = JSON.parse(File.read(path))
    validate_versions!(lesson, allow_legacy: allow_legacy)
    lesson
  rescue JSON::ParserError => e
    raise ArgumentError, "invalid lesson JSON: #{e.message}"
  end

  def self.versions(source_trace: nil)
    require_relative "game_simulator" unless defined?(GameSimulator)
    {rule: GameRules::VERSION, simulator: GameSimulator::VERSION, source_trace: source_trace}
  end

  def self.validate_versions!(lesson, allow_legacy: false)
    if lesson["schema_version"] == 1
      return if allow_legacy

      raise ArgumentError,
            "legacy lesson v1 has unrecorded versions; recollect or use --allow-legacy-lessons to reproduce history"
    end
    unless lesson["schema_version"] == SCHEMA_VERSION
      raise ArgumentError, "unsupported lesson schema version; use matching tooling or regenerate lessons"
    end

    validate_current_versions!(lesson)
  end

  def self.validate_current_versions!(lesson)
    recorded = lesson["versions"] || {}
    versions.each do |key, current|
      next if key == :source_trace || recorded[key.to_s] == current

      raise ArgumentError, "lesson #{key} version differs from #{current}; use matching tooling or recollect lessons"
    end
    validate_source_version!(recorded)
    require_relative "improvement_search" unless defined?(ImprovementSearch)
    return if lesson.dig("search", "version") == ImprovementSearch::VERSION

    raise ArgumentError, "lesson search version differs; use matching search tooling or recollect lessons"
  end

  def self.validate_source_version!(recorded)
    return if recorded.key?("source_trace") && [nil, 2, 3, 4].include?(recorded["source_trace"])

    raise ArgumentError, "unsupported lesson source_trace version; use matching trace tooling or recollect lessons"
  end

  # Reconstruct and validate a recorded sequence against the saved board and
  # frozen offers. Returns the resulting board for score/state assertions.
  def self.replay(lesson, sequence_key)
    lesson = JSON.parse(JSON.generate(lesson)) # normalize nested symbol keys to JSON keys
    sequence_name = sequence_key.to_s.delete_suffix("_sequence")
    offers = lesson["#{sequence_name}_offers"] || lesson.fetch("offers")
    score_key = sequence_name == "actual" ? "actual_score" : "candidate_score"
    OfferReplay.replay(board: board_from_lesson(lesson), moves: lesson.fetch(sequence_key), offers: offers,
                       expected_score: lesson[score_key], strict_offers: false)
  end

  def self.board_from_lesson(lesson)
    initial = lesson.fetch("initial_state")
    options = initial.fetch("options").map {|name| Tile.fetch(name) }
    Board1010.new(cells: initial.fetch("cells"), tile_ids: initial.fetch("tile_ids"),
                  score: initial.fetch("score"), options: options)
  end
  private_class_method :board_from_lesson

  private

  def find_existing_path(identity)
    Dir.glob(File.join(@directory, "*.json")).find do |path|
      JSON.parse(File.read(path))["state_fingerprint"] == identity
    rescue JSON::ParserError
      false
    end
  end

  def update_existing(path, lesson)
    existing = JSON.parse(File.read(path))
    incoming = JSON.parse(JSON.generate(lesson))
    preferred = (analysis_rank(incoming) <=> analysis_rank(existing)).positive? ? incoming : existing
    preferred["state_fingerprint"] = existing.fetch("state_fingerprint")
    preferred["provenance"] = (existing.fetch("provenance") + incoming.fetch("provenance")).uniq
    write_atomically(path, preferred)
    {path: path, deduplicated: true}
  end

  def analysis_rank(lesson)
    [lesson.fetch("candidate_score"), lesson.dig("search", "status") == "improved" ? 1 : 0]
  end

  def write_new(lesson, identity)
    payload = lesson.transform_keys(&:to_s)
    payload["state_fingerprint"] = identity
    path = unique_path
    write_atomically(path, payload)
    {path: path, deduplicated: false}
  end

  def unique_path
    timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%S%6NZ")
    base = File.join(@directory, "lesson-#{timestamp}-#{Process.pid}")
    path = "#{base}.json"
    suffix = 0
    while File.exist?(path)
      suffix += 1
      path = "#{base}-#{suffix}.json"
    end
    path
  end

  def validate!(lesson)
    unless lesson.fetch(:schema_version) == SCHEMA_VERSION
      raise ArgumentError,
            "lesson schema version must be #{SCHEMA_VERSION}"
    end

    self.class.validate_versions!(JSON.parse(JSON.generate(lesson)))
    %i[source_episode initial_state offers actual_sequence actual_score candidate_sequence candidate_score
       improvement_delta search provenance].each {|key| lesson.fetch(key) }
    validate_scores!(lesson)
  end

  def validate_scores!(lesson)
    actual = self.class.replay(lesson, "actual_sequence")
    candidate = self.class.replay(lesson, "candidate_sequence")
    return if candidate.score - actual.score == lesson.fetch(:improvement_delta)

    raise ArgumentError, "lesson improvement delta differs from replayed scores"
  end

  def identity_for(lesson)
    lesson = JSON.parse(JSON.generate(lesson))
    state = {versions: lesson.fetch("versions"), search_version: lesson.dig("search", "version"),
             initial_state: lesson.fetch("initial_state"),
             actual_offers: lesson.fetch("actual_offers", lesson.fetch("offers")),
             candidate_offers: lesson.fetch("candidate_offers", lesson.fetch("offers")),
             actual_sequence: lesson.fetch("actual_sequence"),
             seed: lesson.dig("source_episode", "seed"), seed_kind: lesson.dig("source_episode", "seed_kind"),
             candidate_complete: lesson.dig("search", "candidate_complete")}
    Digest::SHA256.hexdigest(JSON.generate(state))
  end

  def write_atomically(path, payload)
    ArtifactFile.write(path, "#{JSON.pretty_generate(payload)}\n")
  end
end
