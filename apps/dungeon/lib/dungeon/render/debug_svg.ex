defmodule Dungeon.Render.DebugSvg do
  @moduledoc """
  Simple top-down SVG renderer for `Dungeon.Spatializer` output.

  This renderer is still a debug renderer, but it now behaves much more like
  graph-paper dungeon cartography:

  - floor and corridor tiles are filled without per-tile border noise
  - walls are drawn on outer boundaries and between different placed nodes
  - connector seams punch openings through those walls
  - doorway connectors receive explicit door marks
  - labels remain optional
  - collision markers remain optional

  Label policy (v1):
  - show physical node labels by default
  - hide virtual/event labels by default
  - place labels using simple candidate positions
  - skip a label if it would collide with an already-placed label
  """

  @default_tile_px 32
  @default_margin_tiles 1
  @default_font_px 12
  @default_label_mode :physical_only
  @default_show_node_boxes false

  @background_fill "#f8f8f8"
  @grid_stroke "#dddddd"
  @wall_stroke "#2a2a2a"
  @wall_width 2
  @door_stroke "#8b5a2b"

  @doc """
  Renders a spatialized dungeon layout into a complete SVG document string.

  This is the main orchestration function for the renderer. It pulls the
  occupancy grid, placed nodes, connectors, and collision data out of the
  layout, computes the canvas extents, and then assembles the SVG in layers.

  Supported render layers include:

  - background
  - graph-paper grid
  - tile fills
  - wall seams
  - optional node debug boxes
  - doorway markers
  - optional collision overlays
  - optional labels

  The return value is the final SVG XML as a binary.
  """
  @spec render(map(), keyword()) :: String.t()
  def render(layout, opts \\ []) do
    tile_px = Keyword.get(opts, :tile_px, @default_tile_px)
    margin_tiles = Keyword.get(opts, :margin_tiles, @default_margin_tiles)
    font_px = Keyword.get(opts, :font_px, @default_font_px)
    show_grid? = Keyword.get(opts, :show_grid?, true)
    show_labels? = Keyword.get(opts, :show_labels?, true)
    show_node_boxes? = Keyword.get(opts, :show_node_boxes?, @default_show_node_boxes)
    show_connectors? = Keyword.get(opts, :show_connectors?, true)
    show_collision_markers? = Keyword.get(opts, :show_collision_markers?, true)
    label_mode = Keyword.get(opts, :label_mode, @default_label_mode)

    occupancy = Map.get(layout, :occupancy, %{})
    placed_nodes = Map.get(layout, :placed_nodes, %{})
    connectors = Map.get(layout, :connectors, [])
    collisions = Map.get(layout, :collisions, [])

    bounds =
      normalized_bounds(
        Map.get(layout, :bounds, %{}),
        occupancy,
        placed_nodes
      )

    canvas = canvas(bounds, margin_tiles, tile_px)
    sx = canvas.sx
    sy = canvas.sy

    connector_edges = connector_edge_keys(connectors)

    grid_layer =
      if show_grid? do
        render_grid(canvas, tile_px)
      else
        []
      end

    fill_layer = render_tile_fills(occupancy, sx, sy, tile_px)
    wall_layer = render_tile_walls(occupancy, connector_edges, sx, sy, tile_px)

    node_box_layer =
      if show_node_boxes? do
        render_node_boxes(placed_nodes, sx, sy, tile_px)
      else
        []
      end

    connector_layer =
      if show_connectors? do
        render_connectors(connectors, sx, sy, tile_px)
      else
        []
      end

    collision_layer =
      if show_collision_markers? do
        render_collision_markers(collisions, sx, sy, tile_px)
      else
        []
      end

    label_layer =
      if show_labels? and label_mode != :none do
        build_labels(
          placed_nodes,
          sx,
          sy,
          tile_px,
          font_px,
          canvas.width_px,
          canvas.height_px,
          label_mode
        )
      else
        []
      end

    IO.iodata_to_binary([
      ~s(<?xml version="1.0" encoding="UTF-8"?>),
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="#{canvas.width_px}" height="#{canvas.height_px}" viewBox="0 0 #{canvas.width_px} #{canvas.height_px}" role="img" aria-label="Dungeon debug map">),
      ~s(<rect x="0" y="0" width="#{canvas.width_px}" height="#{canvas.height_px}" fill="#{@background_fill}" />),
      grid_layer,
      fill_layer,
      wall_layer,
      node_box_layer,
      connector_layer,
      collision_layer,
      label_layer,
      ~s(</svg>)
    ])
  end

  @doc """
  Writes the rendered SVG for a layout directly to disk.

  This is a convenience wrapper around `render/2` that keeps file output logic
  out of callers. It returns the result from `File.write/2`.
  """
  @spec write(map(), binary(), keyword()) :: :ok | {:error, term()}
  def write(layout, path, opts \\ []) when is_binary(path) do
    File.write(path, render(layout, opts))
  end

  # Builds the drawable canvas description from dungeon bounds.
  #
  # This expands the logical dungeon bounds by a configurable tile margin, then
  # derives the pixel-space dimensions and two coordinate transform functions:
  #
  #   * `sx` converts dungeon x tile coordinates into SVG x pixels
  #   * `sy` converts dungeon y tile coordinates into SVG y pixels
  #
  # The resulting map is passed through the rest of the renderer so all later
  # layers can share the same coordinate system.
  defp canvas(bounds, margin_tiles, tile_px) do
    min_x = bounds.min_x - margin_tiles
    min_y = bounds.min_y - margin_tiles
    max_x = bounds.max_x + margin_tiles
    max_y = bounds.max_y + margin_tiles

    width_tiles = max_x - min_x + 1
    height_tiles = max_y - min_y + 1

    %{
      min_x: min_x,
      min_y: min_y,
      max_x: max_x,
      max_y: max_y,
      width_tiles: width_tiles,
      height_tiles: height_tiles,
      width_px: width_tiles * tile_px,
      height_px: height_tiles * tile_px,
      sx: fn x -> (x - min_x) * tile_px end,
      sy: fn y -> (y - min_y) * tile_px end
    }
  end

  # Renders the graph-paper reference grid.
  #
  # This layer is purely visual scaffolding to make the dungeon easier to inspect
  # while debugging placement and scale. It does not reflect walls or geometry;
  # it simply draws evenly spaced vertical and horizontal guide lines.
  defp render_grid(canvas, tile_px) do
    verticals =
      Enum.map(0..canvas.width_tiles, fn i ->
        x = i * tile_px

        ~s(<line x1="#{x}" y1="0" x2="#{x}" y2="#{canvas.height_px}" stroke="#{@grid_stroke}" stroke-width="1" />)
      end)

    horizontals =
      Enum.map(0..canvas.height_tiles, fn i ->
        y = i * tile_px

        ~s(<line x1="0" y1="#{y}" x2="#{canvas.width_px}" y2="#{y}" stroke="#{@grid_stroke}" stroke-width="1" />)
      end)

    [verticals, horizontals]
  end

  # Renders the base tile fill layer.
  #
  # Each occupied dungeon tile becomes a filled SVG rect. This draws the visual
  # body of floors, corridors, doors, stairs, traps, and dead ends before any
  # walls or connector symbols are added.
  #
  # Tile borders are intentionally disabled here so that wall rendering can be
  # handled separately and more accurately.
  defp render_tile_fills(occupancy, sx, sy, tile_px) do
    occupancy
    |> Enum.sort_by(fn {{x, y}, _} -> {y, x} end)
    |> Enum.map(fn {{x, y}, %{tile_kind: tile_kind}} ->
      ~s(<rect x="#{sx.(x)}" y="#{sy.(y)}" width="#{tile_px}" height="#{tile_px}" fill="#{tile_fill(tile_kind)}" stroke="none" />)
    end)
  end

  # Renders wall segments for occupied tiles.
  #
  # A wall is drawn when:
  #
  # - an occupied tile borders empty space, or
  # - an occupied tile borders a different node_id
  #
  # But if a connector exists on that exact seam, the wall is suppressed there
  # so the seam becomes an opening or doorway instead.
  #
  # Shared seams between two occupied tiles are emitted only once using a simple
  # canonical-direction rule to avoid duplicate wall lines.
  defp render_tile_walls(occupancy, connector_edges, sx, sy, tile_px) do
    occupancy
    |> Enum.sort_by(fn {{x, y}, _} -> {y, x} end)
    |> Enum.flat_map(fn {{x, y}, cell} ->
      if cell.tile_kind == :door do
        []
      else
        render_walls_for_tile(occupancy, connector_edges, {x, y}, cell, sx, sy, tile_px)
      end
    end)
  end

  # Renders the wall edges for a single tile.
  #
  # For each of the four cardinal directions, this helper decides whether the
  # edge should be treated as a solid wall. The decision is based on:
  #
  # - whether a neighboring tile exists
  # - whether that neighbor belongs to the same node
  # - whether a connector explicitly opens the seam
  #
  # This is the core of the “rooms keep their own walls” behavior.
  defp render_walls_for_tile(occupancy, connector_edges, {x, y}, cell, sx, sy, tile_px) do
    left = sx.(x)
    top = sy.(y)
    right = left + tile_px
    bottom = top + tile_px

    []
    |> maybe_wall(
      should_draw_wall?(occupancy, connector_edges, {x, y}, cell, :north),
      ~s(<line x1="#{left}" y1="#{top}" x2="#{right}" y2="#{top}" stroke="#{@wall_stroke}" stroke-width="#{@wall_width}" />)
    )
    |> maybe_wall(
      should_draw_wall?(occupancy, connector_edges, {x, y}, cell, :south),
      ~s(<line x1="#{left}" y1="#{bottom}" x2="#{right}" y2="#{bottom}" stroke="#{@wall_stroke}" stroke-width="#{@wall_width}" />)
    )
    |> maybe_wall(
      should_draw_wall?(occupancy, connector_edges, {x, y}, cell, :west),
      ~s(<line x1="#{left}" y1="#{top}" x2="#{left}" y2="#{bottom}" stroke="#{@wall_stroke}" stroke-width="#{@wall_width}" />)
    )
    |> maybe_wall(
      should_draw_wall?(occupancy, connector_edges, {x, y}, cell, :east),
      ~s(<line x1="#{right}" y1="#{top}" x2="#{right}" y2="#{bottom}" stroke="#{@wall_stroke}" stroke-width="#{@wall_width}" />)
    )
  end

  # Decides whether a specific tile edge should render as a wall.
  #
  # Rules:
  #
  # - empty neighbor => wall
  # - same node_id neighbor => no wall
  # - different node_id neighbor => wall unless a connector opens that seam
  # - shared seams between occupied tiles are only emitted from canonical sides:
  #   north and west
  defp should_draw_wall?(occupancy, connector_edges, tile, cell, dir) do
    neighbor_tile = neighbor_tile(tile, dir)
    edge_key = edge_key(tile, dir)
    neighbor = Map.get(occupancy, neighbor_tile)

    cond do
      is_nil(neighbor) ->
        true

      same_region?(cell, neighbor) ->
        false

      MapSet.member?(connector_edges, edge_key) ->
        false

      dir in [:north, :west] ->
        true

      true ->
        false
    end
  end

  # Returns the neighboring tile coordinate in the requested direction.
  defp neighbor_tile({x, y}, :north), do: {x, y - 1}
  defp neighbor_tile({x, y}, :south), do: {x, y + 1}
  defp neighbor_tile({x, y}, :west), do: {x - 1, y}
  defp neighbor_tile({x, y}, :east), do: {x + 1, y}

  # Normalizes a tile edge into a seam key.
  #
  # Horizontal edges use `{:h, x, y}` and vertical edges use `{:v, x, y}` where
  # the x/y coordinates refer to the upper-left endpoint of the unit edge in tile
  # space. This lets wall and connector logic agree on the exact same seam.
  defp edge_key({x, y}, :north), do: {:h, x, y}
  defp edge_key({x, y}, :south), do: {:h, x, y + 1}
  defp edge_key({x, y}, :west), do: {:v, x, y}
  defp edge_key({x, y}, :east), do: {:v, x + 1, y}

  # Builds a set of seam keys opened by connectors.
  #
  # Openings and doorways both suppress wall drawing on their seam; the connector
  # render layer later decides whether to draw a visible doorway marker.
  defp connector_edge_keys(connectors) do
    connectors
    |> Enum.map(&edge_key_from_connector/1)
    |> MapSet.new()
  end

  # Converts a connector into the seam key it occupies.
  defp edge_key_from_connector(%{direction: :north, from_tile: {fx, fy}}), do: {:h, fx, fy}
  defp edge_key_from_connector(%{direction: :south, from_tile: {fx, fy}}), do: {:h, fx, fy + 1}
  defp edge_key_from_connector(%{direction: :west, from_tile: {fx, fy}}), do: {:v, fx, fy}
  defp edge_key_from_connector(%{direction: :east, from_tile: {fx, fy}}), do: {:v, fx + 1, fy}

  # Returns true when two occupied cells belong to the same placed node.
  #
  # Same-node adjacency should visually merge into one contiguous region without
  # an internal wall seam.
  defp same_region?(%{node_id: a}, %{node_id: b}), do: a == b

  # Conditionally prepends a wall segment to the current wall list.
  #
  # This is a tiny helper to keep `render_walls_for_tile/7` readable while
  # building its list of SVG line fragments.
  defp maybe_wall(lines, true, line), do: [line | lines]
  defp maybe_wall(lines, false, _line), do: lines

  # Renders optional per-node debug rectangles.
  #
  # These are not meant to be part of the final cartography. They exist to show
  # the coarse node footprint chosen by the spatializer, which can be useful for
  # debugging placement and unresolved nodes.
  #
  # Virtual nodes are skipped because they are anchors in the graph rather than
  # real physical regions on the map.
  defp render_node_boxes(placed_nodes, sx, sy, tile_px) do
    placed_nodes
    |> Enum.sort_by(fn {id, _node} -> id end)
    |> Enum.flat_map(fn {_id, node} ->
      if Map.get(node, :virtual?, false) do
        []
      else
        x = sx.(node.x)
        y = sy.(node.y)
        w = node.w * tile_px
        h = node.h * tile_px

        dash =
          if Map.get(node, :unresolved?, false) do
            ~s( stroke-dasharray="6 4")
          else
            ~s( stroke-dasharray="4 4")
          end

        [
          ~s(<rect x="#{x}" y="#{y}" width="#{w}" height="#{h}" fill="none" stroke="#{node_box_stroke(node.kind)}" stroke-width="1" stroke-opacity="0.45"#{dash} />)
        ]
      end
    end)
  end

  # Renders connector symbols derived from the spatializer.
  #
  # Only doorway connectors receive a visible mark here. Plain openings work by
  # suppressing a wall seam but do not get an additional symbol.
  defp render_connectors(connectors, sx, sy, tile_px) do
    connectors
    |> Enum.flat_map(fn connector ->
      case connector.kind do
        :doorway -> render_doorway(connector, sx, sy, tile_px)
        _ -> []
      end
    end)
  end

  # Renders a horizontal door mark centered on an east-facing seam.
  defp render_doorway(%{direction: :east, from_tile: {fx, fy}}, sx, sy, tile_px) do
    x = sx.(fx) + tile_px
    cy = sy.(fy) + div(tile_px, 2)
    half = max(6, div(tile_px, 4))

    [
      ~s(<line x1="#{x - half}" y1="#{cy}" x2="#{x + half}" y2="#{cy}" stroke="#{@door_stroke}" stroke-width="3" stroke-linecap="round" />)
    ]
  end

  # Renders a horizontal door mark centered on a west-facing seam.
  defp render_doorway(%{direction: :west, from_tile: {fx, fy}}, sx, sy, tile_px) do
    x = sx.(fx)
    cy = sy.(fy) + div(tile_px, 2)
    half = max(6, div(tile_px, 4))

    [
      ~s(<line x1="#{x - half}" y1="#{cy}" x2="#{x + half}" y2="#{cy}" stroke="#{@door_stroke}" stroke-width="3" stroke-linecap="round" />)
    ]
  end

  # Renders a vertical door mark centered on a south-facing seam.
  defp render_doorway(%{direction: :south, from_tile: {fx, fy}}, sx, sy, tile_px) do
    y = sy.(fy) + tile_px
    cx = sx.(fx) + div(tile_px, 2)
    half = max(6, div(tile_px, 4))

    [
      ~s(<line x1="#{cx}" y1="#{y - half}" x2="#{cx}" y2="#{y + half}" stroke="#{@door_stroke}" stroke-width="3" stroke-linecap="round" />)
    ]
  end

  # Renders a vertical door mark centered on a north-facing seam.
  defp render_doorway(%{direction: :north, from_tile: {fx, fy}}, sx, sy, tile_px) do
    y = sy.(fy)
    cx = sx.(fx) + div(tile_px, 2)
    half = max(6, div(tile_px, 4))

    [
      ~s(<line x1="#{cx}" y1="#{y - half}" x2="#{cx}" y2="#{y + half}" stroke="#{@door_stroke}" stroke-width="3" stroke-linecap="round" />)
    ]
  end

  # Renders visual markers for collision diagnostics.
  #
  # Right now only tile-overlap collisions are visualized, using a red X over
  # the offending tile. Other collision record types are ignored by the SVG
  # layer but remain available in the layout data itself.
  defp render_collision_markers(collisions, sx, sy, tile_px) do
    collisions
    |> Enum.flat_map(fn
      %{type: :tile_overlap, tile: {x, y}} ->
        px = sx.(x)
        py = sy.(y)
        x2 = px + tile_px
        y2 = py + tile_px

        [
          ~s(<line x1="#{px}" y1="#{py}" x2="#{x2}" y2="#{y2}" stroke="#cc0000" stroke-width="3" />),
          ~s(<line x1="#{x2}" y1="#{py}" x2="#{px}" y2="#{y2}" stroke="#cc0000" stroke-width="3" />)
        ]

      _other ->
        []
    end)
  end

  # Builds the optional node label layer.
  #
  # Labels are placed greedily in priority order. Each accepted label reserves
  # a screen-space box so later labels can avoid overlapping it.
  #
  # This keeps the map readable while still surfacing useful node identifiers.
  defp build_labels(placed_nodes, sx, sy, tile_px, font_px, width_px, height_px, label_mode) do
    placed_nodes
    |> Map.values()
    |> Enum.filter(&label_visible?(&1, label_mode))
    |> Enum.sort_by(fn node -> {label_priority(node), -(node.w * node.h), node.id} end)
    |> Enum.reduce({[], []}, fn node, {boxes, xml} ->
      label = label_for(node)

      case place_label(node, label, boxes, sx, sy, tile_px, font_px, width_px, height_px) do
        nil ->
          {boxes, xml}

        %{box: box, text_x: text_x, text_y: text_y, label_w: label_w, label_h: label_h} ->
          fragment = [
            ~s(<rect x="#{box.x}" y="#{box.y}" width="#{label_w}" height="#{label_h}" rx="4" ry="4" fill="#{label_background_fill(node)}" fill-opacity="0.88" stroke="#{label_background_stroke(node)}" stroke-width="1" />),
            ~s(<text x="#{text_x}" y="#{text_y}" font-size="#{font_px}" text-anchor="middle" fill="#{label_text_fill(node)}" font-family="monospace">#{escape_xml(label)}</text>)
          ]

          {[box | boxes], [fragment | xml]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # Decides whether a node is eligible to receive a label under the chosen mode.
  #
  # This supports quick filtering such as:
  #
  #   * all labels
  #   * physical-only labels
  #   * virtual-only labels
  #   * none
  defp label_visible?(node, :all), do: true
  defp label_visible?(node, :physical_only), do: not Map.get(node, :virtual?, false)
  defp label_visible?(node, :virtual_only), do: Map.get(node, :virtual?, false)
  defp label_visible?(_node, :none), do: false
  defp label_visible?(node, _other), do: not Map.get(node, :virtual?, false)

  # Assigns a sort priority to labels before placement.
  #
  # Lower values are placed first. Rooms and chambers are prioritized because
  # they are usually the most useful landmarks, while virtual nodes are pushed
  # later to reduce clutter.
  defp label_priority(node) do
    cond do
      Map.get(node, :virtual?, false) -> 2
      node.kind in [:room, :chamber] -> 0
      true -> 1
    end
  end

  # Attempts to place a single node label on the canvas.
  #
  # The label is measured, several candidate positions are generated, and the
  # first candidate that both fits within the canvas and does not overlap any
  # already-accepted label box is returned.
  defp place_label(node, label, existing_boxes, sx, sy, tile_px, font_px, width_px, height_px) do
    nx = sx.(node.x)
    ny = sy.(node.y)
    nw = node.w * tile_px
    nh = node.h * tile_px

    label_w = label_width_px(label, font_px)
    label_h = label_height_px(font_px)

    candidates =
      label_candidates(node, nx, ny, nw, nh, label_w, label_h)
      |> Enum.map(fn {x, y} ->
        %{
          box: %{x: x, y: y, w: label_w, h: label_h},
          text_x: x + div(label_w, 2),
          text_y: y + div(label_h, 2) + div(font_px, 3),
          label_w: label_w,
          label_h: label_h
        }
      end)

    Enum.find(candidates, fn %{box: box} ->
      within_canvas?(box, width_px, height_px) and not overlaps_any?(box, existing_boxes)
    end)
  end

  # Generates candidate label anchor positions for a node.
  #
  # Different node kinds prefer different label placements. For example, rooms
  # and chambers try to label themselves internally first, while passages prefer
  # above/below placements to keep the corridor readable.
  defp label_candidates(node, nx, ny, nw, nh, label_w, label_h) do
    inside_center = {nx + div(nw - label_w, 2), ny + div(nh - label_h, 2)}
    above_center = {nx + div(nw - label_w, 2), ny - label_h - 4}
    below_center = {nx + div(nw - label_w, 2), ny + nh + 4}
    right_center = {nx + nw + 4, ny + div(nh - label_h, 2)}
    left_center = {nx - label_w - 4, ny + div(nh - label_h, 2)}

    case node.kind do
      kind when kind in [:room, :chamber] ->
        [inside_center, above_center, below_center, right_center, left_center]

      :passage ->
        [above_center, below_center, right_center, inside_center]

      :dead_end ->
        [above_center, right_center, below_center, inside_center]

      :entrance ->
        [left_center, above_center, below_center, inside_center]

      _ ->
        [right_center, below_center, above_center, inside_center]
    end
  end

  # Returns true when a proposed label box fits entirely within the SVG canvas.
  defp within_canvas?(box, width_px, height_px) do
    box.x >= 0 and box.y >= 0 and box.x + box.w <= width_px and box.y + box.h <= height_px
  end

  # Returns true when a proposed label box collides with any existing label box.
  defp overlaps_any?(box, existing_boxes) do
    Enum.any?(existing_boxes, &boxes_overlap?(box, &1))
  end

  # Performs rectangle-overlap testing with a small padding buffer.
  #
  # The added buffer prevents labels from visually touching even when they do
  # not strictly intersect.
  defp boxes_overlap?(a, b) do
    not (a.x + a.w + 4 <= b.x or
           b.x + b.w + 4 <= a.x or
           a.y + a.h + 4 <= b.y or
           b.y + b.h + 4 <= a.y)
  end

  # Estimates label width in pixels using a simple monospace approximation.
  #
  # This does not need to be typographically exact; it only needs to be stable
  # enough for collision avoidance and placement.
  defp label_width_px(label, font_px) do
    trunc(String.length(label) * font_px * 0.62) + 10
  end

  # Computes the total pixel height of a label background box.
  defp label_height_px(font_px), do: font_px + 8

  # Normalizes or derives map bounds for rendering.
  #
  # Preferred source is the explicit `layout.bounds`. If that is unavailable,
  # bounds are inferred from occupied tiles. As a final fallback, they are
  # inferred from node footprints.
  defp normalized_bounds(bounds, occupancy, placed_nodes) do
    cond do
      is_map(bounds) and Map.has_key?(bounds, :min_x) and Map.has_key?(bounds, :min_y) and
          Map.has_key?(bounds, :max_x) and Map.has_key?(bounds, :max_y) ->
        bounds

      map_size(occupancy) > 0 ->
        occupancy
        |> Map.keys()
        |> points_to_bounds()

      map_size(placed_nodes) > 0 ->
        placed_nodes
        |> Map.values()
        |> Enum.flat_map(fn node ->
          [
            {node.x, node.y},
            {node.x + node.w - 1, node.y + node.h - 1}
          ]
        end)
        |> points_to_bounds()

      true ->
        %{min_x: 0, min_y: 0, max_x: 0, max_y: 0}
    end
  end

  # Converts a set of `{x, y}` points into a bounding rectangle.
  defp points_to_bounds(points) do
    xs = Enum.map(points, &elem(&1, 0))
    ys = Enum.map(points, &elem(&1, 1))

    %{
      min_x: Enum.min(xs),
      min_y: Enum.min(ys),
      max_x: Enum.max(xs),
      max_y: Enum.max(ys)
    }
  end

  # Builds the human-facing text shown for a node label.
  #
  # The base format is `id:kind`, with optional suffixes for unresolved or
  # virtual nodes so debug output stays informative.
  defp label_for(node) do
    base = "#{node.id}:#{node.kind}"

    cond do
      Map.get(node, :unresolved?, false) -> base <> " ?"
      Map.get(node, :virtual?, false) -> base <> " v"
      true -> base
    end
  end

  # Returns the background fill color used behind a label.
  #
  # Virtual nodes get a slightly duller background so they visually read as less
  # “solid” than physical map features.
  defp label_background_fill(node) do
    if Map.get(node, :virtual?, false), do: "#f0f0f0", else: "#ffffff"
  end

  # Returns the outline color used for a label box.
  #
  # Unresolved nodes are highlighted in red, virtual nodes in gray, and normal
  # physical nodes in a neutral dark stroke.
  defp label_background_stroke(node) do
    cond do
      Map.get(node, :unresolved?, false) -> "#cc0000"
      Map.get(node, :virtual?, false) -> "#999999"
      true -> "#333333"
    end
  end

  # Returns the text color used inside a label box.
  defp label_text_fill(node) do
    if Map.get(node, :virtual?, false), do: "#666666", else: "#111111"
  end

  # Maps tile kinds to their fill colors.
  #
  # Door tiles intentionally reuse the room/floor fill because the visible door
  # symbol itself is drawn separately by the connector layer.
  defp tile_fill(:floor), do: "#d9d2c3"
  defp tile_fill(:corridor), do: "#b7c7d6"
  defp tile_fill(:door), do: "#d9d2c3"
  defp tile_fill(:stairs), do: "#9fbf7f"
  defp tile_fill(:dead_end), do: "#b56576"
  defp tile_fill(:trap), do: "#f4a261"
  defp tile_fill(_other), do: "#cccccc"

  # Maps node kinds to the stroke color used by optional debug node boxes.
  defp node_box_stroke(:entrance), do: "#222222"
  defp node_box_stroke(:room), do: "#444444"
  defp node_box_stroke(:chamber), do: "#444444"
  defp node_box_stroke(:passage), do: "#2f4f6f"
  defp node_box_stroke(:stairs), do: "#4b6b3c"
  defp node_box_stroke(:dead_end), do: "#7f3b4d"
  defp node_box_stroke(:door), do: "#5b3a1d"
  defp node_box_stroke(:trap), do: "#a14d00"
  defp node_box_stroke(_other), do: "#555555"

  # Escapes XML-sensitive characters before inserting text into the SVG.
  #
  # This protects label text from breaking the output document.
  defp escape_xml(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
