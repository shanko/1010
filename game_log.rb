# frozen_string_literal: true

require_relative "board"
require "fileutils"

# Versioned, append-only trace for one game. Each file can be replayed without
# relying on the current tile dealer or the original random number generator.
class GameLog
  DIRECTORY = "logs"
  VERSION_HEADER = "1010-moves-v3"

  attr_reader :path

  def initialize(board:, mode:, seed: nil, directory: DIRECTORY)
    FileUtils.mkdir_p(directory)
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

    @finished = false
    @file.write("#{VERSION_HEADER}\ns#{seed || '-'}\nmode=#{mode}\n")
    BoardSnapshot.records(board).each {|record| @file.write("#{record}\n") }
    @file.flush
  end

  # Record the exact offered tiles in their offered order.
  def deal(tiles)
    write("d#{tiles.map {|tile| tile.id.to_s(36) }.join}\n")
  end

  # Record tile identity as well as the chosen option and anchor coordinates.
  def move(tile_name, index, row, col)
    write("m#{tile_name},#{index},#{row},#{col}\n")
  end

  def undo
    write("u\n")
  end

  def finish(reason:, score:)
    return if @finished

    write("z#{reason}|#{score}\n")
    @finished = true
    close
  end

  def close
    @file.close unless @file.closed?
  end

  private

  def write(text)
    raise IOError, "game trace is already finished" if @finished

    @file.write(text)
    @file.flush
  end
end
