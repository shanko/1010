# frozen_string_literal: true

# Compact append-only log for one played game.
class GameLog
  DIRECTORY = "logs"

  attr_reader :path

  def initialize(seed: nil, directory: DIRECTORY)
    Dir.mkdir(directory) unless Dir.exist?(directory)
    @path = File.join(directory, "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{Process.pid}-#{object_id}.moves")
    @file = File.open(@path, "ab")
    @file.write("s#{seed || '-'}\n")
    @file.flush
  end

  # Fixed width: m + option index + row + column, all zero-based single digits.
  def move(index, row, col)
    @file.write("m#{index}#{row}#{col}\n")
    @file.flush
  end

  def undo
    @file.write("u\n")
    @file.flush
  end

  def close
    @file.close unless @file.closed?
  end
end
