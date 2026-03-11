defmodule Dungeon do
  @moduledoc """
  Convenience entry points for dungeon generation and debug rendering.

  This module acts as a small facade over the lower-level dungeon pipeline:

  1. `Dungeon.Generator` builds the graph-first dungeon structure.
  2. `Dungeon.Spatializer` converts that graph into a tile-based layout.
  3. `Dungeon.Render.DebugSvg` writes the layout to an SVG file for inspection.

  It is intentionally thin. The heavy lifting stays in the generator,
  spatializer, and renderer modules.
  """

  @doc """
  Minimal sanity-check helper.

  This is mostly the default placeholder function created with a new Mix app.
  It can be kept as a simple smoke test or removed later if it no longer serves
  a purpose.

  ## Examples

      iex> Dungeon.hello()
      :world

  """
  def hello, do: :world

  @doc """
  Generates a dungeon, spatializes it, and writes a debug SVG to disk.

  This is the main convenience wrapper for the current dungeon pipeline. It
  collects a few common options, ensures the output directory exists, runs the
  full generation flow, and returns both the source dungeon graph and the final
  tile layout.

  Supported options:

  - `:seed` - deterministic RNG seed tuple, default `{1, 2, 3}`
  - `:max_checks` - generator expansion limit, default `10`
  - `:level` - dungeon depth/level metadata, default `1`
  - `:path` - output SVG path, default `"tmp/debug_map.svg"`

  On success, returns:

      {:ok, %{path: path, dungeon: dungeon, layout: layout}}

  On write failure, returns:

      {:error, reason}

  ## Examples

      iex> {:ok, result} = Dungeon.generate_dungeon()
      iex> is_binary(result.path)
      true

      iex> {:ok, result} = Dungeon.generate_dungeon(seed: {8, 9, 10}, max_checks: 20)
      iex> is_map(result.dungeon)
      true
      iex> is_map(result.layout)
      true

  """
  def generate_dungeon(opts \\ []) do
    seed = Keyword.get(opts, :seed, {1, 2, 3})
    max_checks = Keyword.get(opts, :max_checks, 10)
    level = Keyword.get(opts, :level, 1)
    path = Keyword.get(opts, :path, "tmp/debug_map.svg")

    File.mkdir_p!(Path.dirname(path))

    dungeon =
      Dungeon.Generator.generate(
        seed: seed,
        max_checks: max_checks,
        level: level
      )

    layout = Dungeon.Spatializer.spatialize(dungeon)

    case Dungeon.Render.DebugSvg.write(layout, path) do
      :ok ->
        {:ok, %{path: path, dungeon: dungeon, layout: layout}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
