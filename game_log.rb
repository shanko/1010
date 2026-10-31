# frozen_string_literal: true

# Versioned, append-only trace for one game. Each file can be replayed without
# relying on the current tile dealer or the original random number generator.
class GameLog
  DIRECTORY = "logs"
  VERSION_HEADER = "1010-moves-v2"

  attr_reader :path

  def initialize(seed: nil, board:, mode:, directory: DIRECTORY)
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

    @finished = false
    @file.write("#{VERSION_HEADER}\ns#{seed || '-'}\nmode=#{mode}\n")
    @file.write("i#{board.score}|#{board.cells.flatten.join}|#{board.tile_ids.flatten.map {|id| id.to_s(36) }.join}\n")
    deal(board.options)
    @file.flush
  end

  # Record the exact offered tiles in their offered order.
  def deal(tiles)
    write("d#{tiles.map(&:name).join(',')}\n")
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
