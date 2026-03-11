defmodule Dungeon.Spatializer do
  @moduledoc """
  Converts a graph-first dungeon into a tile-based map layout.

  V1 goals:
  - fixed scale: 1 tile = 10 feet (default)
  - place nodes on a graph-paper grid
  - support the common physical node kinds first:
    :entrance, :room, :chamber, :passage, :dead_end, :stairs
  - keep non-physical/event-ish nodes in the placed_nodes map as virtual anchors
    so traversal can continue without forcing them into occupancy

  Collision policy (v1):
  - touching edges is allowed
  - overlapping occupied tiles is not allowed
  - when blocked, try the same intended direction with increasing offset bands
  - if still blocked, rotate through the other cardinal directions
  - if all attempts fail, place the node as a virtual unresolved anchor and record it

  Door policy (v2):
  - a `:door` node respects its generator-side `data.location` when choosing a wall
  - anything placed beyond a physical door continues through that same door-facing
    direction rather than rotating to a different side
  - a physical parent/child placement only succeeds if a valid connector seam can
    be derived from the final geometry
  """

  @type direction :: :north | :east | :south | :west
  @type tile :: {integer(), integer()}

  @type connector :: %{
          from_id: integer(),
          to_id: integer(),
          kind: atom(),
          direction: direction(),
          from_tile: tile(),
          to_tile: tile()
        }

  @type placed_node :: %{
          required(:id) => integer(),
          required(:kind) => atom(),
          required(:x) => integer(),
          required(:y) => integer(),
          required(:w) => pos_integer(),
          required(:h) => pos_integer(),
          required(:facing) => direction(),
          required(:virtual?) => boolean(),
          optional(:parent_id) => integer(),
          optional(:via) => atom(),
          optional(:center) => tile(),
          optional(:unresolved?) => boolean()
        }

  @type map_layout :: %{
          scale_ft_per_tile: pos_integer(),
          bounds: %{min_x: integer(), min_y: integer(), max_x: integer(), max_y: integer()},
          placed_nodes: %{required(integer()) => placed_node()},
          occupancy: %{optional(tile()) => %{node_id: integer(), tile_kind: atom()}},
          connectors: [connector()],
          collisions: [map()]
        }

  @default_scale_ft_per_tile 10
  @default_gap_tiles 0
  @default_max_offset_bands 6

  @physical_kinds [:entrance, :room, :chamber, :passage, :dead_end, :stairs, :door, :trap]

  @doc """
  Converts a dungeon graph into a spatial map layout.

  This is the public entrypoint for the spatialization pass. It builds lookup
  structures from the graph, chooses a root node, initializes traversal state,
  walks the graph breadth-first, and returns a final layout map containing:

  - `placed_nodes` for node footprints and positions
  - `occupancy` for tile-level materialization
  - `connectors` for explicit openings and doors between adjacent regions
  - `collisions` for unresolved placement or overlap diagnostics
  - `bounds` for downstream renderers
  """
  @spec spatialize(Dungeon.Generator.dungeon(), keyword()) :: map_layout()
  def spatialize(%{nodes: nodes, edges: edges}, opts \\ []) do
    scale_ft_per_tile = Keyword.get(opts, :scale_ft_per_tile, @default_scale_ft_per_tile)
    gap_tiles = Keyword.get(opts, :gap_tiles, @default_gap_tiles)
    max_offset_bands = Keyword.get(opts, :max_offset_bands, @default_max_offset_bands)

    node_map = Map.new(nodes, &{&1.id, &1})
    outgoing = Enum.group_by(edges, & &1.from)

    root_id = root_node_id(nodes)
    root_node = Map.fetch!(node_map, root_id)
    root_placed = place_root(root_node)

    state = %{
      scale_ft_per_tile: scale_ft_per_tile,
      gap_tiles: gap_tiles,
      max_offset_bands: max_offset_bands,
      node_map: node_map,
      outgoing: outgoing,
      placed_nodes: %{root_id => root_placed},
      occupancy: %{},
      connectors: [],
      collisions: [],
      queue: :queue.from_list([root_id])
    }

    state =
      state
      |> occupy_node(root_id, root_placed)
      |> walk()

    %{
      scale_ft_per_tile: scale_ft_per_tile,
      bounds: bounds(state.occupancy, state.placed_nodes),
      placed_nodes: state.placed_nodes,
      occupancy: state.occupancy,
      connectors: Enum.reverse(state.connectors),
      collisions: Enum.reverse(state.collisions)
    }
  end

  # ------------------------------------------------------------
  # Root / traversal
  # ------------------------------------------------------------

  # Chooses the traversal root for the dungeon graph.
  #
  # Preference is given to an explicit `:entrance` node. If none exists, the
  # smallest node id is used as a deterministic fallback.
  defp root_node_id(nodes) do
    case Enum.find(nodes, &(&1.kind == :entrance)) do
      nil -> nodes |> Enum.min_by(& &1.id) |> Map.fetch!(:id)
      node -> node.id
    end
  end

  # Creates the initial placed footprint for the root node.
  #
  # The root is always anchored at `{0, 0}` and starts as a non-virtual node
  # facing north so the rest of the traversal has a stable spatial reference.
  defp place_root(node) do
    %{
      id: node.id,
      kind: node.kind,
      x: 0,
      y: 0,
      w: 1,
      h: 1,
      facing: :north,
      virtual?: false,
      center: {0, 0}
    }
  end

  # Walks the graph placement queue until all reachable nodes have been handled.
  #
  # This acts as the main traversal loop. Each dequeued parent id is expanded
  # into its outgoing edges, and each edge is offered to `place_child_from_edge/4`.
  defp walk(state) do
    case :queue.out(state.queue) do
      {{:value, parent_id}, queue} ->
        state = %{state | queue: queue}
        edges = Map.get(state.outgoing, parent_id, [])

        state =
          edges
          |> Enum.with_index()
          |> Enum.reduce(state, fn {edge, idx}, acc ->
            place_child_from_edge(acc, parent_id, edge, idx)
          end)

        walk(state)

      {:empty, _queue} ->
        state
    end
  end

  # Attempts to place one child node reached from a specific parent edge.
  #
  # This function handles three major cases:
  #
  # - already placed child nodes are skipped
  # - children of virtual parents become unresolved virtual descendants
  # - normal physical children go through full placement search
  #
  # On success or unresolved fallback, the resulting placement is committed into
  # state through `commit_placement/3`.
  defp place_child_from_edge(state, parent_id, edge, idx) do
    child_id = edge.to

    if Map.has_key?(state.placed_nodes, child_id) do
      state
    else
      parent_node = Map.fetch!(state.node_map, parent_id)
      parent_placed = Map.fetch!(state.placed_nodes, parent_id)
      child_node = Map.fetch!(state.node_map, child_id)

      cond do
        Map.get(parent_placed, :virtual?, false) and physical_node_kind?(child_node.kind) ->
          placed =
            virtual_descendant_placement(
              parent_placed,
              child_node,
              edge.via,
              state.scale_ft_per_tile
            )

          state
          |> record_virtual_parent_block(parent_id, child_node)
          |> commit_placement(child_id, placed)

        true ->
          preferred_dir = choose_direction(parent_node, parent_placed, child_node, edge.via, idx)

          case find_placement(state, parent_placed, child_node, edge.via, preferred_dir) do
            {:ok, placed} ->
              commit_placement(state, child_id, placed)

            {:unresolved, placed, attempts} ->
              state
              |> record_unresolved_collision(parent_id, child_node, preferred_dir, attempts)
              |> commit_placement(child_id, placed)
          end
      end
    end
  end

  # Finalizes a chosen placement and threads it into traversal state.
  #
  # A committed node is:
  #
  # - inserted into `placed_nodes`
  # - offered to connector derivation
  # - painted into `occupancy` if physical
  # - enqueued for later child expansion
  defp commit_placement(state, child_id, placed) do
    state
    |> put_in([:placed_nodes, child_id], placed)
    |> maybe_add_connector(placed)
    |> occupy_node(child_id, placed)
    |> enqueue(child_id)
  end

  # Pushes a node id into the BFS traversal queue.
  defp enqueue(state, id) when is_integer(id) do
    %{state | queue: :queue.in(id, state.queue)}
  end

  # ------------------------------------------------------------
  # Placement search
  # ------------------------------------------------------------

  # Searches for a valid physical placement for a child node.
  #
  # The search starts with the preferred direction and then fans out across
  # allowed directions and increasing offset bands. A placement is accepted only
  # if it is both non-overlapping and connector-compatible with the parent.
  #
  # If all attempts fail, the child falls back to an unresolved virtual anchor.
  defp find_placement(state, parent_placed, child_node, via, preferred_dir) do
    initial =
      place_child(
        parent_placed,
        child_node,
        via,
        preferred_dir,
        0,
        state.scale_ft_per_tile,
        state.gap_tiles
      )

    if initial.virtual? do
      {:ok, initial}
    else
      attempts =
        for dir <- candidate_directions(preferred_dir, parent_placed, child_node),
            band <- 0..state.max_offset_bands do
          placed =
            place_child(
              parent_placed,
              child_node,
              via,
              dir,
              band,
              state.scale_ft_per_tile,
              state.gap_tiles
            )

          %{dir: dir, band: band, placed: placed}
        end

      case Enum.find(attempts, fn %{placed: placed} ->
             connectable_placement?(state, parent_placed, via, placed)
           end) do
        %{placed: placed} ->
          {:ok, placed}

        nil ->
          fallback =
            initial
            |> Map.put(:virtual?, true)
            |> Map.put(:unresolved?, true)

          {:unresolved, fallback, attempts}
      end
    end
  end

  # Produces the ordered list of directions to try during placement search.
  #
  # Most nodes can rotate across all four cardinals if needed. Doors with an
  # explicit wall location, and nodes placed beyond a physical door, are kept on
  # their required side and do not rotate away from that seam.
  defp candidate_directions(preferred_dir, parent_placed, child_node) do
    if constrained_direction?(parent_placed, child_node) do
      [preferred_dir]
    else
      preferred_dir
      |> rotate_cardinals()
      |> Enum.uniq()
    end
  end

  # Returns true when placement direction must remain fixed.
  #
  # We constrain direction in two cases:
  #
  # - placing a door that carries an explicit `left/right/ahead` wall location
  # - placing a physical node beyond an already-placed physical door
  defp constrained_direction?(parent_placed, child_node) do
    explicit_door_location?(child_node) or
      (parent_placed.kind == :door and physical_node_kind?(child_node.kind))
  end

  # Returns true when a door node carries a hard wall-location hint.
  defp explicit_door_location?(%{kind: :door} = node) do
    get_in(node, [:data, :location]) in [:left, :right, :ahead]
  end

  defp explicit_door_location?(_node), do: false

  # Checks whether a candidate placement is both placeable and connectable.
  #
  # A placement fails if it overlaps occupied tiles. For physical-to-physical
  # adjacency, it must also admit a valid connector seam. Virtual or nonphysical
  # cases bypass connector validation.
  defp connectable_placement?(state, parent_placed, via, placed) do
    cond do
      not placeable?(state, placed) ->
        false

      Map.get(placed, :virtual?, false) ->
        true

      Map.get(parent_placed, :virtual?, false) ->
        true

      not physical_node_kind?(parent_placed.kind) ->
        true

      not physical_node_kind?(placed.kind) ->
        true

      true ->
        match?({:ok, _}, derive_connector(parent_placed, placed, via))
    end
  end

  # Declares virtual placements always placeable.
  defp placeable?(state, %{virtual?: true}), do: true

  # Checks whether every tile in a candidate footprint is currently empty.
  defp placeable?(state, placed) do
    Enum.all?(tiles_for(placed), fn tile ->
      not Map.has_key?(state.occupancy, tile)
    end)
  end

  # Builds a candidate placed-node record from a parent, child, direction, and band.
  #
  # This is the raw geometry constructor used by placement search before the
  # candidate is validated and committed.
  defp place_child(parent, child_node, via, dir, band, scale_ft_per_tile, gap_tiles) do
    {w, h, virtual?} = footprint_tiles(child_node, dir, scale_ft_per_tile)
    {x, y} = attach_rect(parent, {w, h}, dir, band, gap_tiles)

    %{
      id: child_node.id,
      kind: child_node.kind,
      x: x,
      y: y,
      w: w,
      h: h,
      facing: dir,
      virtual?: virtual?,
      parent_id: parent.id,
      via: via,
      center: center_of(x, y, w, h)
    }
  end

  # Creates an unresolved virtual placement for a physical child whose parent
  # is already virtual.
  #
  # This preserves graph continuity without pretending the child has a valid
  # physical location in the occupancy grid.
  defp virtual_descendant_placement(parent_placed, child_node, via, scale_ft_per_tile) do
    {w, h, _virtual?} = footprint_tiles(child_node, parent_placed.facing, scale_ft_per_tile)

    %{
      id: child_node.id,
      kind: child_node.kind,
      x: parent_placed.x,
      y: parent_placed.y,
      w: w,
      h: h,
      facing: parent_placed.facing,
      virtual?: true,
      unresolved?: true,
      parent_id: parent_placed.id,
      via: via,
      center: center_of(parent_placed.x, parent_placed.y, w, h)
    }
  end

  # ------------------------------------------------------------
  # Connectors
  # ------------------------------------------------------------

  # Skips connector creation for virtual placements.
  defp maybe_add_connector(state, %{virtual?: true}), do: state

  # Attempts to derive and record a connector between a placed node and its parent.
  #
  # Connectors are only created when both parent and child are present, physical,
  # and adjacent in a way that exposes a valid seam. Failed derivation is logged
  # as a missing-connector collision.
  defp maybe_add_connector(state, placed) do
    parent_id = Map.get(placed, :parent_id)

    cond do
      not is_integer(parent_id) ->
        state

      true ->
        parent = Map.get(state.placed_nodes, parent_id)

        cond do
          is_nil(parent) ->
            state

          Map.get(parent, :virtual?, false) ->
            state

          not physical_node_kind?(parent.kind) ->
            state

          not physical_node_kind?(placed.kind) ->
            state

          true ->
            case derive_connector(parent, placed, Map.get(placed, :via)) do
              {:ok, connector} ->
                %{state | connectors: [connector | state.connectors]}

              :error ->
                record_missing_connector(state, parent, placed)
            end
        end
    end
  end

  # Derives a connector seam between two adjacent node rectangles.
  #
  # The connector is only valid when the parent and child touch on exactly one
  # side with a shared overlap interval across the perpendicular axis.
  #
  # The returned connector includes:
  #
  # - ids of the two connected nodes
  # - connector kind (`:opening` or `:doorway`)
  # - seam direction from the parent’s perspective
  # - from/to seam tiles
  defp derive_connector(parent, child, via) do
    {parent_left, parent_right, parent_top, parent_bottom} = rect_bounds(parent)
    {child_left, child_right, child_top, child_bottom} = rect_bounds(child)

    cond do
      child_left == parent_right + 1 ->
        with y when not is_nil(y) <-
               overlap_center(parent_top, parent_bottom, child_top, child_bottom) do
          {:ok,
           %{
             from_id: parent.id,
             to_id: child.id,
             kind: connector_kind(via, parent.kind, child.kind),
             direction: :east,
             from_tile: {parent_right, y},
             to_tile: {child_left, y}
           }}
        else
          _ -> :error
        end

      child_right + 1 == parent_left ->
        with y when not is_nil(y) <-
               overlap_center(parent_top, parent_bottom, child_top, child_bottom) do
          {:ok,
           %{
             from_id: parent.id,
             to_id: child.id,
             kind: connector_kind(via, parent.kind, child.kind),
             direction: :west,
             from_tile: {parent_left, y},
             to_tile: {child_right, y}
           }}
        else
          _ -> :error
        end

      child_top == parent_bottom + 1 ->
        with x when not is_nil(x) <-
               overlap_center(parent_left, parent_right, child_left, child_right) do
          {:ok,
           %{
             from_id: parent.id,
             to_id: child.id,
             kind: connector_kind(via, parent.kind, child.kind),
             direction: :south,
             from_tile: {x, parent_bottom},
             to_tile: {x, child_top}
           }}
        else
          _ -> :error
        end

      child_bottom + 1 == parent_top ->
        with x when not is_nil(x) <-
               overlap_center(parent_left, parent_right, child_left, child_right) do
          {:ok,
           %{
             from_id: parent.id,
             to_id: child.id,
             kind: connector_kind(via, parent.kind, child.kind),
             direction: :north,
             from_tile: {x, parent_top},
             to_tile: {x, child_bottom}
           }}
        else
          _ -> :error
        end

      true ->
        :error
    end
  end

  # Converts a node footprint into `{left, right, top, bottom}` rectangle bounds.
  defp rect_bounds(node) do
    left = node.x
    right = node.x + node.w - 1
    top = node.y
    bottom = node.y + node.h - 1
    {left, right, top, bottom}
  end

  # Computes the midpoint of the overlapping interval between two 1D ranges.
  #
  # This is used to choose the seam coordinate for a connector when two adjacent
  # rectangles overlap across the perpendicular axis.
  defp overlap_center(a1, a2, b1, b2) do
    lo = max(a1, b1)
    hi = min(a2, b2)

    if lo <= hi do
      div(lo + hi, 2)
    else
      nil
    end
  end

  # Determines whether a connector should be rendered as a doorway or an open seam.
  #
  # Any direct `:door` edge or any adjacency involving a physical `:door` node is
  # treated as `:doorway`; everything else becomes an `:opening`.
  defp connector_kind(via, parent_kind, child_kind) do
    cond do
      via == :door -> :doorway
      parent_kind == :door -> :doorway
      child_kind == :door -> :doorway
      true -> :opening
    end
  end

  # ------------------------------------------------------------
  # Direction / orientation
  # ------------------------------------------------------------

  # Chooses the preferred outgoing direction for a child placement.
  #
  # Door nodes use their stored wall-location hint when available. Passages can
  # influence direction using passage form, while other node kinds use slot
  # rotation based on the parent’s facing and sibling index.
  defp choose_direction(_parent_node, parent_placed, child_node, _via, idx) do
    base = Map.get(parent_placed, :facing, :north)

    cond do
      child_node.kind == :door ->
        door_direction(base, get_in(child_node, [:data, :location]), idx)

      child_node.kind == :passage ->
        passage_direction(base, get_in(child_node, [:data, :form]), idx)

      true ->
        slot_direction(base, idx)
    end
  end

  # Resolves door placement metadata into a wall-relative direction.
  #
  # `:ahead` continues straight through the parent-facing direction, while
  # `:left` and `:right` rotate accordingly. Unknown values fall back to the
  # normal sibling-slot policy.
  defp door_direction(base, location, idx) do
    case location do
      :ahead -> base
      :left -> turn_left(base)
      :right -> turn_right(base)
      _ -> slot_direction(base, idx)
    end
  end

  # Resolves passage forms into an outgoing direction.
  #
  # Straight and parallel passages keep the base direction. Turning forms rotate
  # left or right. Junction forms fall back to slot-based sibling distribution.
  defp passage_direction(base, form, idx) do
    case form do
      :straight -> base
      :parallel -> base
      :left_90 -> turn_left(base)
      :right_90 -> turn_right(base)
      :left_45_ahead -> turn_left(base)
      :right_45_ahead -> turn_right(base)
      :left_curve_45 -> turn_left(base)
      :right_curve_45 -> turn_right(base)
      :left_135 -> turn_left(base)
      :right_135 -> turn_right(base)
      :tee -> slot_direction(base, idx)
      :wye -> slot_direction(base, idx)
      :four_way -> slot_direction(base, idx)
      :cross -> slot_direction(base, idx)
      _ -> slot_direction(base, idx)
    end
  end

  # Assigns one of the four cardinal directions based on sibling slot index.
  #
  # This is the default spatial fan-out policy for non-passage children.
  defp slot_direction(base, idx) do
    rotated = rotate_cardinals(base)
    Enum.at(rotated, rem(idx, 4), base)
  end

  # Rotates cardinal ordering so the current facing comes first.
  defp rotate_cardinals(:north), do: [:north, :east, :south, :west]
  defp rotate_cardinals(:east), do: [:east, :south, :west, :north]
  defp rotate_cardinals(:south), do: [:south, :west, :north, :east]
  defp rotate_cardinals(:west), do: [:west, :north, :east, :south]

  # Rotates one step counter-clockwise.
  defp turn_left(:north), do: :west
  defp turn_left(:west), do: :south
  defp turn_left(:south), do: :east
  defp turn_left(:east), do: :north

  # Rotates one step clockwise.
  defp turn_right(:north), do: :east
  defp turn_right(:east), do: :south
  defp turn_right(:south), do: :west
  defp turn_right(:west), do: :north

  # ------------------------------------------------------------
  # Geometry / footprint
  # ------------------------------------------------------------

  # Computes the tile footprint for a node kind under the given direction.
  #
  # Rooms and chambers derive their footprint from stored geometry, passages
  # derive from length/width, and single-tile features like doors and traps are
  # normalized to `1x1`. Nonphysical nodes return a virtual `1x1` placeholder.
  defp footprint_tiles(node, dir, scale_ft_per_tile) do
    case node.kind do
      kind when kind in [:room, :chamber] ->
        geometry = get_in(node, [:data, :geometry]) || %{}
        {geometry_w, geometry_h} = geometry_tiles(geometry, scale_ft_per_tile)
        {geometry_w, geometry_h, false}

      :passage ->
        width_ft =
          get_in(node, [:data, :profile, :width_ft]) ||
            get_in(node, [:data, :width_ft]) ||
            10

        length_ft = get_in(node, [:data, :length_ft]) || 10

        width_tiles = to_tiles(width_ft, scale_ft_per_tile)
        length_tiles = to_tiles(length_ft, scale_ft_per_tile)

        case dir do
          d when d in [:north, :south] -> {width_tiles, length_tiles, false}
          _ -> {length_tiles, width_tiles, false}
        end

      kind when kind in [:entrance, :dead_end, :stairs, :door, :trap] ->
        {1, 1, false}

      _ ->
        {1, 1, true}
    end
  end

  # Converts stored room/chamber geometry into tile dimensions.
  #
  # Supported geometry encodings include:
  #
  # - explicit width/height integers
  # - width/height tuples averaged into a representative size
  # - multi-chamber lists combined into total width / max height
  # - area-only fallback approximated as a square
  defp geometry_tiles(geometry, scale_ft_per_tile) do
    width_ft = Map.get(geometry, :width_ft)
    height_ft = Map.get(geometry, :height_ft)

    cond do
      is_integer(width_ft) and is_integer(height_ft) ->
        {to_tiles(width_ft, scale_ft_per_tile), to_tiles(height_ft, scale_ft_per_tile)}

      is_tuple(width_ft) and is_tuple(height_ft) ->
        {
          width_ft |> avg_tuple() |> to_tiles(scale_ft_per_tile),
          height_ft |> avg_tuple() |> to_tiles(scale_ft_per_tile)
        }

      is_list(Map.get(geometry, :chambers)) ->
        chambers = Map.get(geometry, :chambers, [])
        total_width_ft = chambers |> Enum.map(fn {w, _h} -> w end) |> Enum.sum()
        max_height_ft = chambers |> Enum.map(fn {_w, h} -> h end) |> Enum.max(fn -> 10 end)
        {to_tiles(total_width_ft, scale_ft_per_tile), to_tiles(max_height_ft, scale_ft_per_tile)}

      is_integer(Map.get(geometry, :area_sqft)) ->
        approx_side_ft = geometry.area_sqft |> :math.sqrt() |> Float.ceil() |> trunc()
        side_tiles = to_tiles(approx_side_ft, scale_ft_per_tile)
        {side_tiles, side_tiles}

      true ->
        {1, 1}
    end
  end

  # Averages a `{min, max}` tuple into a single representative dimension.
  defp avg_tuple({a, b}), do: div(a + b, 2)

  # Converts feet into tiles using ceiling-style integer division.
  #
  # This guarantees a minimum of one tile for any positive physical dimension.
  defp to_tiles(feet, scale_ft_per_tile) when is_integer(feet) and feet > 0 do
    max(1, div(feet + scale_ft_per_tile - 1, scale_ft_per_tile))
  end

  # Computes the top-left placement for a child rectangle attached to a parent.
  #
  # The chosen direction determines which face of the parent is used, and the
  # band value pushes sibling candidates farther along the parent edge to search
  # for non-colliding alternatives.
  defp attach_rect(parent, {child_w, child_h}, dir, band, gap_tiles) do
    case dir do
      :north ->
        x = parent.x + div(parent.w - child_w, 2) + band * (child_w + 1)
        y = parent.y - gap_tiles - child_h
        {x, y}

      :east ->
        x = parent.x + parent.w + gap_tiles
        y = parent.y + div(parent.h - child_h, 2) + band * (child_h + 1)
        {x, y}

      :south ->
        x = parent.x + div(parent.w - child_w, 2) + band * (child_w + 1)
        y = parent.y + parent.h + gap_tiles
        {x, y}

      :west ->
        x = parent.x - gap_tiles - child_w
        y = parent.y + div(parent.h - child_h, 2) + band * (child_h + 1)
        {x, y}
    end
  end

  # Computes the logical center tile for a rectangular footprint.
  #
  # This is mostly useful for labels and debug rendering.
  defp center_of(x, y, w, h) do
    {x + div(w - 1, 2), y + div(h - 1, 2)}
  end

  # ------------------------------------------------------------
  # Occupancy
  # ------------------------------------------------------------

  # Virtual nodes do not contribute to occupancy.
  defp occupy_node(state, _node_id, %{virtual?: true}), do: state

  # Paints a physical node footprint into the occupancy grid.
  #
  # Each tile in the node’s rectangle receives a materialized tile entry. Any
  # overlap against an existing different node is recorded as a tile collision.
  defp occupy_node(state, node_id, placed) do
    if placed.kind in @physical_kinds do
      Enum.reduce(tiles_for(placed), state, fn tile, acc ->
        put_tile(acc, tile, node_id, tile_kind(placed.kind))
      end)
    else
      state
    end
  end

  # Expands a rectangular footprint into its full list of tile coordinates.
  defp tiles_for(%{x: x, y: y, w: w, h: h}) do
    for ty <- y..(y + h - 1), tx <- x..(x + w - 1), do: {tx, ty}
  end

  # Maps node kinds into occupancy tile material kinds.
  #
  # This keeps rendering and downstream logic working with a smaller vocabulary
  # than the full graph node taxonomy.
  defp tile_kind(:passage), do: :corridor
  defp tile_kind(:door), do: :door
  defp tile_kind(:stairs), do: :stairs
  defp tile_kind(:dead_end), do: :dead_end
  defp tile_kind(:trap), do: :trap
  defp tile_kind(_kind), do: :floor

  # Inserts a single tile into the occupancy grid or records an overlap collision.
  #
  # Rewriting the same node into the same tile is allowed. Colliding with a
  # different node is not.
  defp put_tile(state, tile, node_id, tile_kind) do
    case Map.get(state.occupancy, tile) do
      nil ->
        put_in(state, [:occupancy, tile], %{node_id: node_id, tile_kind: tile_kind})

      %{node_id: ^node_id} ->
        state

      existing ->
        collision = %{
          type: :tile_overlap,
          tile: tile,
          existing: existing,
          incoming: %{node_id: node_id, tile_kind: tile_kind}
        }

        %{state | collisions: [collision | state.collisions]}
    end
  end

  # ------------------------------------------------------------
  # Collision recording
  # ------------------------------------------------------------

  # Records that a physical child could not be meaningfully placed because its
  # parent was already virtual.
  defp record_virtual_parent_block(state, parent_id, child_node) do
    collision = %{
      type: :virtual_parent_block,
      parent_id: parent_id,
      child_id: child_node.id,
      child_kind: child_node.kind
    }

    %{state | collisions: [collision | state.collisions]}
  end

  # Records that two physically placed nodes could not produce a valid connector.
  #
  # This usually indicates the placement search found a non-overlapping position
  # that still failed adjacency semantics.
  defp record_missing_connector(state, parent, child) do
    collision = %{
      type: :missing_connector,
      parent_id: parent.id,
      child_id: child.id,
      parent_kind: parent.kind,
      child_kind: child.kind
    }

    %{state | collisions: [collision | state.collisions]}
  end

  # Records a fully failed placement search.
  #
  # The collision entry keeps a compact summary of all attempted directions and
  # bands so the caller or renderer can inspect why the child fell back to an
  # unresolved virtual placement.
  defp record_unresolved_collision(state, parent_id, child_node, preferred_dir, attempts) do
    collision = %{
      type: :unresolved_placement,
      parent_id: parent_id,
      child_id: child_node.id,
      child_kind: child_node.kind,
      preferred_dir: preferred_dir,
      attempts:
        Enum.map(attempts, fn %{dir: dir, band: band, placed: placed} ->
          %{
            dir: dir,
            band: band,
            x: placed.x,
            y: placed.y,
            w: placed.w,
            h: placed.h
          }
        end)
    }

    %{state | collisions: [collision | state.collisions]}
  end

  # ------------------------------------------------------------
  # Predicates / bounds
  # ------------------------------------------------------------

  # Returns true when a node kind should occupy real map tiles.
  defp physical_node_kind?(kind), do: kind in @physical_kinds

  # Computes layout bounds from occupancy and placed-node anchors.
  #
  # Occupancy tiles provide the primary spatial extent. Node anchor points are
  # included as a fallback so the bounds remain stable even in sparse or mostly
  # virtual layouts.
  defp bounds(occupancy, placed_nodes) do
    points =
      occupancy
      |> Map.keys()
      |> Enum.concat(Enum.map(Map.values(placed_nodes), fn node -> {node.x, node.y} end))

    case points do
      [] ->
        %{min_x: 0, min_y: 0, max_x: 0, max_y: 0}

      _ ->
        xs = Enum.map(points, &elem(&1, 0))
        ys = Enum.map(points, &elem(&1, 1))

        %{
          min_x: Enum.min(xs),
          min_y: Enum.min(ys),
          max_x: Enum.max(xs),
          max_y: Enum.max(ys)
        }
    end
  end
end
