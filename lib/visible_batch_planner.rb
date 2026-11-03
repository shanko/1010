# frozen_string_literal: true

require_relative "visible_position"
require_relative "learned_player"

# Bounded beam search over one visible batch. Leaves never deal another tile.
class VisibleBatchPlanner
  VERSION = 1
  INFORMATION_MODE = :visible_batch
  DEFAULT_BEAM_WIDTH = 8
  DEFAULT_MAX_STATES = 5_000
  Node = Struct.new(:position, :first_move, :rank, :order, keyword_init: true)
  Search = Struct.new(:explored, :capped, :best, :serial, keyword_init: true)
  Result = Struct.new(:move, :completed_batch, :explored_states, :cap_reason, :information_mode,
                      keyword_init: true)

  def self.settings
    {version: VERSION, information_mode: INFORMATION_MODE,
     beam_width: DEFAULT_BEAM_WIDTH, max_states: DEFAULT_MAX_STATES}
  end

  def initialize(beam_width: DEFAULT_BEAM_WIDTH, max_states: DEFAULT_MAX_STATES)
    @beam_width = Integer(beam_width)
    @max_states = Integer(max_states)
    return if @beam_width.positive? && @max_states.positive?

    raise ArgumentError,
          "beam width and max states must be positive"
  end

  def choose_move(position, option_index: nil)
    search(position, option_index: option_index).move
  end

  def search(position, option_index: nil)
    unless position.is_a?(VisiblePosition)
      raise ArgumentError,
            "visible planning requires a VisiblePosition observation"
    end

    state = Search.new(explored: 0, capped: false, serial: 0)
    return result(Node.new(position: position), state) if position.batch_complete?

    result(plan(position, state, option_index), state)
  end

  private

  def plan(position, state, option_index)
    beam = [Node.new(position: position)]
    position.options.size.times do |depth|
      children = expand_layer(beam, state, depth.zero? ? option_index : nil)
      break if children.empty?

      beam = ranked(children).first(@beam_width)
      complete = completed_batch(beam)
      return complete if complete
      break if state.capped
    end
    state.best
  end

  def completed_batch(beam)
    beam.select {|node| node.position.batch_complete? }.max_by {|node| leaf_value(node.position) }
  end

  def expand_layer(beam, state, option_index)
    children = []
    seen = {}
    beam.each do |node|
      node.position.each_action(option_index: option_index) do |index, row, col|
        if state.explored >= @max_states
          state.capped = true
          break
        end
        add_child(node, [index, row, col], children, seen, state)
      end
      break if state.capped
    end
    children
  end

  def add_child(parent, action, children, seen, state)
    state.explored += 1
    position = parent.position.after_move(*action)
    key = [position.occupied_bits, position.options, position.score]
    return if seen[key]

    seen[key] = true
    node = build_node(parent, action, position, state)
    children << node
    state.best = better_partial(node, state.best)
  end

  def build_node(parent, action, position, state)
    state.serial += 1
    Node.new(position: position, first_move: parent.first_move || action.freeze,
             rank: frontier_rank(position), order: state.serial)
  end

  def better_partial(node, previous)
    return node if !previous || (partial_rank(node) <=> partial_rank(previous)).positive?

    previous
  end

  def ranked(nodes)
    nodes.sort_by {|node| [-node.rank[0], -node.rank[1], node.order] }
  end

  def partial_rank(node)
    [node.position.score, *node.rank, -node.order]
  end

  def space_value(position)
    bits = position.occupied_bits
    largest, regions, isolated = ActionFeatures.empty_space_features(bits)
    empty = 100 - bits.digits(256).sum {|byte| ActionFeatures::BYTE_COUNTS[byte] }
    empty + (largest * 0.1) - (regions * 2.0) - (isolated * 4.0)
  end

  def frontier_rank(position)
    placements = position.options.map {|tile| position.placement_count(tile) }
    [placements.count(&:positive?), space_value(position) + Math.log(1 + placements.sum)]
  end

  def leaf_value(position)
    # The known shape catalog estimates flexibility; no future batch is sampled.
    mobility = Tile::ALL.sum {|tile| Math.log(1 + position.placement_count(tile)) }
    space_value(position) + mobility
  end

  def result(node, state)
    Result.new(move: node&.first_move, completed_batch: node ? node.position.batch_complete? : false,
               explored_states: state.explored, cap_reason: state.capped ? "states" : nil,
               information_mode: INFORMATION_MODE)
  end
end
