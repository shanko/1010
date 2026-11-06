# frozen_string_literal: true

require "tempfile"

# Keep feature vectors on private temporary storage; only offsets and episode
# identities grow with the corpus. Epoch shuffling preserves the Array order.
class ImitationExamples
  def self.open
    Tempfile.create(["1010-imitation-", ".cache"]) do |file|
      file.binmode
      yield new(file)
    end
  end

  def initialize(file)
    @file = file
    @offsets = []
    @episodes = {}
  end

  def <<(example)
    @file.seek(0, IO::SEEK_END)
    @offsets << @file.pos
    @episodes[example.fetch(:episode)] = true
    Marshal.dump(example, @file)
    self
  end

  def empty?
    @offsets.empty?
  end

  def episode_count
    @episodes.size
  end

  def shuffle(random:)
    offsets = @offsets.shuffle(random: random)
    Enumerator.new do |output|
      offsets.each do |offset|
        @file.seek(offset)
        # Only deserialize examples written by this process to its private file.
        output << Marshal.load(@file) # rubocop:disable Security/MarshalLoad
      end
    end
  end
end
