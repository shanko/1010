# frozen_string_literal: true

# Compact append-only log for one played game.
class GameLog
  DIRECTORY = "logs"

  attr_reader :path

  def initialize(seed: nil, directory: DIRECTORY)
    Dir.mkdir(directory) unless Dir.exist?(directory)
    timestamp = Time.now.strftime("%Y%m%d-%H%M%S-%6N")
    suffix = 0
    loop do
      @path = File.join(directory, "#{timestamp}-#{Process.pid}-#{suffix}.moves")
      begin
        @file = File.open(@path, File::WRONLY | File::CREAT | File::EXCL, 0o644)
        break
      rescue Errno::EEXIST
        suffix += 1
      end
    end
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
