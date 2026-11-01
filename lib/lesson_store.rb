# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require_relative "offer_replay"

# Versioned local storage for reproducible improvement-search lessons.
class LessonStore
  DIRECTORY = "learning_data"
  SCHEMA_VERSION = 1

  def initialize(directory: DIRECTORY)
    @directory = directory
  end

  # Dedupe by initial decision state and exact offer history. Repeated sources
  # are retained in provenance instead of silently producing duplicate lessons.
  def save(lesson)
    validate!(lesson)
    FileUtils.mkdir_p(@directory)
    identity = identity_for(lesson)
    existing_path = find_existing_path(identity)
    return update_existing(existing_path, lesson) if existing_path

    write_new(lesson, identity)
  end

  def self.read(path)
    lesson = JSON.parse(File.read(path))
    raise ArgumentError, "unsupported lesson schema version" unless lesson["schema_version"] == SCHEMA_VERSION

    lesson
  rescue JSON::ParserError => e
    raise ArgumentError, "invalid lesson JSON: #{e.message}"
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
    provenance = existing.fetch("provenance")
    lesson.fetch(:provenance).each do |source|
      provenance << source unless provenance.include?(source)
    end
    write_atomically(path, existing)
    {path: path, deduplicated: true}
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

    %i[source_episode initial_state offers actual_sequence actual_score candidate_sequence candidate_score
       improvement_delta search provenance].each {|key| lesson.fetch(key) }
  end

  def identity_for(lesson)
    state = {initial_state:    lesson.fetch(:initial_state),
             actual_offers:    lesson.fetch(:actual_offers, lesson.fetch(:offers)),
             candidate_offers: lesson.fetch(:candidate_offers, lesson.fetch(:offers))}
    Digest::SHA256.hexdigest(JSON.generate(state))
  end

  def write_atomically(path, payload)
    temporary = "#{path}.tmp-#{Process.pid}"
    File.write(temporary, "#{JSON.pretty_generate(payload)}\n")
    File.rename(temporary, path)
  ensure
    File.delete(temporary) if temporary && File.exist?(temporary)
  end
end
