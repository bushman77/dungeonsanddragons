defmodule Dungeon.Generator do
  @moduledoc """
  Graph-first implementation of the AD&D 1e DMG Appendix A random dungeon generator.

  This module:
    - follows Appendix A table flow
    - returns a dungeon graph (nodes + edges)
    - keeps monster/magic treasure as external hooks
    - is deterministic when given a seed

  It does NOT yet do collision-safe 2D placement.
  That should be a second pass layered on top of this engine.
  """

  @type seed :: {integer(), integer(), integer()}

  @type dungeon_node :: %{
          id: integer(),
          kind: atom(),
          data: map()
        }

  @type dungeon_edge :: %{
          from: integer(),
          to: integer(),
          via: atom()
        }

  @type dungeon :: %{
          seed: seed(),
          nodes: [dungeon_node()],
          edges: [dungeon_edge()]
        }

  @default_seed {11, 22, 33}

  @spec generate(keyword()) :: dungeon()
  def generate(opts \\ []) do
    seed = Keyword.get(opts, :seed, @default_seed)
    max_checks = Keyword.get(opts, :max_checks, 50)
    level = Keyword.get(opts, :level, 1)
    env = if Keyword.get(opts, :lowest_level?, false), do: :caves, else: :standard

    state =
      new_state(seed, max_checks)

    {state, entrance_id} =
      add_node(state, :entrance, %{
        label: "entrance",
        level: level,
        env: env
      })

    state =
      state
      |> enqueue(%{from: entrance_id, level: level, env: env, depth: 0, source: :entrance})
      |> run()

    %{
      seed: seed,
      nodes: state.nodes |> Map.values() |> Enum.sort_by(& &1.id),
      edges: Enum.reverse(state.edges)
    }
  end

  defp new_state(seed, max_checks) do
    %{
      rng: seed_rng(seed),
      next_id: 1,
      nodes: %{},
      edges: [],
      frontier: :queue.new(),
      remaining: max_checks
    }
  end

  defp run(%{remaining: remaining} = state) when remaining <= 0, do: state

  defp run(state) do
    case :queue.out(state.frontier) do
      {{:value, item}, frontier} ->
        state
        |> Map.put(:frontier, frontier)
        |> Map.update!(:remaining, &(&1 - 1))
        |> step(item)
        |> run()

      {:empty, _frontier} ->
        state
    end
  end

  # ------------------------------------------------------------
  # Main exploration step (TABLE I)
  # ------------------------------------------------------------

  defp step(state, item) do
    {state, die} = d20(state)

    cond do
      die <= 2 ->
        {state, _passage_id} =
          add_connected_node(state, item.from, :passage, %{
            form: :straight,
            length_ft: 60,
            level: item.level
          })

        recheck(state, item, :straight_60)

      die <= 5 ->
        spawn_door(state, item)

      die <= 10 ->
        spawn_side_passage(state, item)

      die <= 13 ->
        spawn_turn(state, item)

      die <= 16 ->
        spawn_space(state, item, :chamber)

      die == 17 ->
        spawn_stairs_node(state, item)

      die == 18 ->
        {state, _dead_end_id} =
          add_connected_node(state, item.from, :dead_end, %{level: item.level})

        state

      die == 19 ->
        state
        |> spawn_trap_node(item)
        |> recheck_from(item, :after_trap_30, item.from)

      true ->
        {state, _wm_id} =
          add_connected_node(state, item.from, :wandering_monster_hook, %{
            level: item.level,
            source: :appendix_c_random_monster
          })

        recheck_from(state, item, :immediate_after_wandering_monster, item.from)
    end
  end

  defp recheck(state, item, source) do
    enqueue(state, %{
      from: latest_id(state),
      level: item.level,
      env: item.env,
      depth: item.depth + 1,
      source: source
    })
  end

  defp recheck_from(state, item, source, from_id) do
    enqueue(state, %{
      from: from_id,
      level: item.level,
      env: item.env,
      depth: item.depth + 1,
      source: source
    })
  end

  defp next_frontier(item, from_id, source) do
    %{
      from: from_id,
      level: item.level,
      env: item.env,
      depth: item.depth + 1,
      source: source
    }
  end

  # ------------------------------------------------------------
  # TABLE II - Doors
  # ------------------------------------------------------------

  defp spawn_door(state, item) do
    {state, loc_die} = d20(state)
    location = door_location(loc_die)

    {state, beyond_die} = d20(state)
    beyond = door_beyond(beyond_die)

    {state, passage_profile} =
      case beyond do
        %{kind: :passage} -> roll_passage_profile(state)
        _ -> {state, nil}
      end

    {state, door_id} =
      add_connected_node(state, item.from, :door, %{
        level: item.level,
        location: location,
        beyond: beyond,
        passage_profile: passage_profile
      })

    case beyond do
      %{kind: :room, width_ft: w, height_ft: h} ->
        forced = %{shape: :square, width_ft: w, height_ft: h, area_sqft: w * h}
        spawn_forced_space(state, door_id, item, :room, forced)

      %{kind: :room} ->
        spawn_space(state, %{item | from: door_id}, :room)

      %{kind: :chamber} ->
        spawn_space(state, %{item | from: door_id}, :chamber)

      %{kind: :passage, branches: 2} ->
        {state, pass_id} =
          add_connected_node(state, door_id, :passage, %{
            level: item.level,
            form: :parallel,
            length_ft: 30,
            profile: passage_profile
          })

        state
        |> enqueue(next_frontier(item, pass_id, :parallel_passage_a))
        |> enqueue(next_frontier(item, pass_id, :parallel_passage_b))

      %{kind: :passage} ->
        {state, pass_id} =
          add_connected_node(state, door_id, :passage, %{
            level: item.level,
            form: beyond.form,
            length_ft: 30,
            profile: passage_profile
          })

        enqueue(state, next_frontier(item, pass_id, :door_to_passage))
    end
  end

  defp door_location(die) when die <= 6, do: :left
  defp door_location(die) when die <= 12, do: :right
  defp door_location(_die), do: :ahead

  defp door_beyond(die) when die <= 4, do: %{kind: :passage, form: :parallel, branches: 2}
  defp door_beyond(die) when die <= 8, do: %{kind: :passage, form: :straight, branches: 1}
  defp door_beyond(9), do: %{kind: :passage, form: :angle_45_ahead, branches: 1}
  defp door_beyond(10), do: %{kind: :passage, form: :angle_45_behind, branches: 1}
  defp door_beyond(die) when die <= 18, do: %{kind: :room}
  defp door_beyond(_die), do: %{kind: :chamber}

  # ------------------------------------------------------------
  # TABLE III / III.A / III.B - Side passages and width
  # ------------------------------------------------------------

  defp spawn_side_passage(state, item) do
    {state, side_die} = d20(state)
    side_form = side_passage_form(side_die)

    {state, profile} = roll_passage_profile(state)

    {state, pass_id} =
      add_node(state, :passage, %{
        level: item.level,
        form: side_form,
        length_ft: 30,
        profile: profile
      })

    state
    |> add_edge(item.from, pass_id, :side_passage)
    |> enqueue(next_frontier(item, pass_id, :branch_from_side_passage))
    |> enqueue(next_frontier(item, pass_id, :main_line_after_30))
  end

  defp side_passage_form(die) when die <= 2, do: :left_90
  defp side_passage_form(die) when die <= 4, do: :right_90
  defp side_passage_form(5), do: :left_45_ahead
  defp side_passage_form(6), do: :right_45_ahead
  defp side_passage_form(7), do: :left_135
  defp side_passage_form(8), do: :right_135
  defp side_passage_form(9), do: :left_curve_45
  defp side_passage_form(10), do: :right_curve_45
  defp side_passage_form(die) when die <= 13, do: :tee
  defp side_passage_form(die) when die <= 15, do: :wye
  defp side_passage_form(die) when die <= 19, do: :four_way
  defp side_passage_form(_die), do: :cross

  defp roll_passage_profile(state) do
    {state, die} = d20(state)

    cond do
      die <= 12 ->
        {state, %{width_ft: 10}}

      die <= 16 ->
        {state, %{width_ft: 20}}

      die == 17 ->
        {state, %{width_ft: 30}}

      die == 18 ->
        {state, %{width_ft: 5}}

      true ->
        roll_special_passage(state)
    end
  end

  defp roll_special_passage(state) do
    {state, die} = d20(state)

    cond do
      die <= 4 ->
        {state, %{special: :columns_center, width_ft: 40}}

      die <= 7 ->
        {state, %{special: :double_columns, width_ft: 40}}

      die <= 10 ->
        {state, %{special: :double_columns, width_ft: 50}}

      die <= 12 ->
        {state, %{special: :upper_galleries, width_ft: 50, gallery_height_ft: 20}}

      die <= 15 ->
        {state, crossing} = roll_stream_crossing(state)
        {state, %{special: :stream, width_ft: 10, crossing: crossing}}

      die <= 17 ->
        {state, crossing} = roll_river_crossing(state)
        {state, %{special: :river, width_ft: 20, crossing: crossing}}

      die == 18 ->
        {state, crossing} = roll_river_crossing(state)
        {state, %{special: :river, width_ft: 40, crossing: crossing}}

      die == 19 ->
        {state, crossing} = roll_river_crossing(state)
        {state, %{special: :river, width_ft: 60, crossing: crossing}}

      true ->
        {state, crossing} = roll_chasm_crossing(state)

        {state, %{special: :chasm, width_ft: 20, crossing: crossing, depth_ft: {150, 200}}}
    end
  end

  defp roll_stream_crossing(state) do
    {state, die} = d20(state)
    {state, if(die <= 15, do: :bridged, else: :obstacle)}
  end

  defp roll_river_crossing(state) do
    {state, die} = d20(state)

    crossing =
      cond do
        die <= 10 -> :bridged
        die <= 15 -> :boat
        true -> :obstacle
      end

    {state, crossing}
  end

  defp roll_chasm_crossing(state) do
    {state, die} = d20(state)

    crossing =
      cond do
        die <= 10 -> :bridged
        die <= 15 -> {:jumping_place, {5, 10}}
        true -> :obstacle
      end

    {state, crossing}
  end

  # ------------------------------------------------------------
  # TABLE IV - Turns
  # ------------------------------------------------------------

  defp spawn_turn(state, item) do
    {state, die} = d20(state)
    turn = turn_form(die)
    {state, profile} = roll_passage_profile(state)

    {state, _pass_id} =
      add_connected_node(state, item.from, :passage, %{
        level: item.level,
        form: turn,
        length_ft: 30,
        profile: profile
      })

    recheck(state, item, :after_turn_30)
  end

  defp turn_form(die) when die <= 8, do: :left_90
  defp turn_form(9), do: :left_45_ahead
  defp turn_form(10), do: :left_135
  defp turn_form(die) when die <= 18, do: :right_90
  defp turn_form(19), do: :right_45_ahead
  defp turn_form(_die), do: :right_135

  # ------------------------------------------------------------
  # TABLE V / V.A / V.B / V.C / V.D / V.E / V.F / V.G / V.H / V.I / V.J
  # ------------------------------------------------------------

  defp spawn_space(state, item, kind) do
    {state, geometry} =
      case item.env do
        :caves -> roll_cave_geometry(state)
        :standard -> roll_standard_geometry(state, kind)
      end

    {state, contents} = roll_space_contents(state, item.level)
    {state, exits} = roll_space_exits(state, geometry.area_sqft)

    {state, node_id} =
      add_connected_node(state, item.from, kind, %{
        level: item.level,
        env: item.env,
        geometry: geometry,
        contents: contents,
        exits: exits
      })

    enqueue_space_exits(state, node_id, item)
  end

  defp spawn_forced_space(state, from_id, item, kind, geometry) do
    {state, contents} = roll_space_contents(state, item.level)
    {state, exits} = roll_space_exits(state, geometry.area_sqft)

    {state, node_id} =
      add_connected_node(state, from_id, kind, %{
        level: item.level,
        env: item.env,
        geometry: geometry,
        contents: contents,
        exits: exits,
        forced: true
      })

    enqueue_space_exits(state, node_id, item)
  end

  defp roll_standard_geometry(state, kind) do
    {state, die} = d20(state)

    case standard_geometry(kind, die) do
      nil ->
        {state, shape} = roll_unusual_shape(state)
        {state, area_sqft} = roll_unusual_size(state)

        {state,
         %{
           shape: shape,
           area_sqft: area_sqft,
           unusual: true
         }}

      geometry ->
        {state, geometry}
    end
  end

  defp standard_geometry(:chamber, x) when x <= 2, do: dims(:square, 20, 20)
  defp standard_geometry(:room, x) when x <= 2, do: dims(:square, 10, 10)

  defp standard_geometry(:chamber, x) when x <= 4, do: dims(:square, 20, 20)
  defp standard_geometry(:room, x) when x <= 4, do: dims(:square, 20, 20)

  defp standard_geometry(:chamber, x) when x <= 6, do: dims(:square, 30, 30)
  defp standard_geometry(:room, x) when x <= 6, do: dims(:square, 30, 30)

  defp standard_geometry(:chamber, x) when x <= 8, do: dims(:square, 40, 40)
  defp standard_geometry(:room, x) when x <= 8, do: dims(:square, 40, 40)

  defp standard_geometry(:chamber, x) when x <= 10, do: dims(:rectangular, 20, 30)
  defp standard_geometry(:room, x) when x <= 10, do: dims(:rectangular, 10, 20)

  defp standard_geometry(:chamber, x) when x <= 13, do: dims(:rectangular, 20, 30)
  defp standard_geometry(:room, x) when x <= 13, do: dims(:rectangular, 20, 30)

  defp standard_geometry(:chamber, x) when x <= 15, do: dims(:rectangular, 30, 50)
  defp standard_geometry(:room, x) when x <= 15, do: dims(:rectangular, 20, 40)

  defp standard_geometry(:chamber, x) when x <= 17, do: dims(:rectangular, 40, 60)
  defp standard_geometry(:room, x) when x <= 17, do: dims(:rectangular, 30, 40)

  defp standard_geometry(_kind, _die), do: nil

  defp roll_unusual_shape(state) do
    {state, die} = d20(state)

    shape =
      cond do
        die <= 5 -> :circular
        die <= 8 -> :triangular
        die <= 11 -> :trapezoidal
        die <= 13 -> :odd_shaped
        die <= 15 -> :oval
        die <= 17 -> :hexagonal
        die <= 19 -> :octagonal
        true -> :cave
      end

    {state, shape}
  end

  defp roll_unusual_size(state) do
    {state, die} = d20(state)

    base =
      cond do
        die <= 3 -> 500
        die <= 6 -> 900
        die <= 8 -> 1300
        die <= 10 -> 2000
        die <= 12 -> 2700
        die <= 14 -> 3400
        true -> :roll_again
      end

    case base do
      :roll_again ->
        {state, extra} = roll_unusual_size(state)
        {state, 2000 + extra}

      sqft ->
        {state, sqft}
    end
  end

  defp roll_space_exits(state, area_sqft) do
    {state, die} = d20(state)

    {state, count, secret_only?} =
      cond do
        die <= 3 and area_sqft <= 600 ->
          {state, 1, false}

        die <= 3 ->
          {state, 2, false}

        die <= 6 and area_sqft <= 600 ->
          {state, 2, false}

        die <= 6 ->
          {state, 3, false}

        die <= 9 and area_sqft <= 600 ->
          {state, 3, false}

        die <= 9 ->
          {state, 4, false}

        die <= 12 and area_sqft <= 1200 ->
          {state, 0, true}

        die <= 12 ->
          {state, 1, false}

        die <= 15 and area_sqft <= 1600 ->
          {state, 0, true}

        die <= 15 ->
          {state, 1, false}

        die <= 18 ->
          {state, count} = roll_d4(state)
          {state, count, false}

        true ->
          {state, 1, false}
      end

    {state, exits} =
      if count == 0 do
        {state, []}
      else
        Enum.reduce(1..count, {state, []}, fn _, {acc, xs} ->
          {acc, exit_desc} = roll_exit_descriptor(acc)
          {acc, [exit_desc | xs]}
        end)
      end

    {state, %{count: count, secret_only?: secret_only?, descriptors: Enum.reverse(exits)}}
  end

  defp roll_exit_descriptor(state) do
    {state, loc_die} = d20(state)
    location = exit_location(loc_die)

    {state, dir_die} = d20(state)
    direction = exit_direction(dir_die)

    {state, %{location: location, direction: direction}}
  end

  defp exit_location(die) when die <= 7, do: :opposite_wall
  defp exit_location(die) when die <= 12, do: :left_wall
  defp exit_location(die) when die <= 17, do: :right_wall
  defp exit_location(_die), do: :same_wall

  defp exit_direction(die) when die <= 16, do: :straight_ahead
  defp exit_direction(die) when die <= 18, do: :left_or_right_45
  defp exit_direction(_die), do: :right_or_left_45

  defp enqueue_space_exits(state, room_id, item) do
    exits = get_in(state.nodes[room_id], [:data, :exits, :descriptors]) || []

    Enum.reduce(exits, state, fn exit_desc, acc ->
      enqueue(
        acc,
        %{
          from: room_id,
          level: item.level,
          env: item.env,
          depth: item.depth + 1,
          source: {:room_exit, exit_desc}
        }
      )
    end)
  end

  defp roll_space_contents(state, level) do
    {state, die} = d20(state)

    case die do
      x when x <= 12 ->
        {state, %{kind: :empty}}

      x when x <= 14 ->
        {state,
         %{
           kind: :monster_only,
           monster: %{source: :appendix_c_random_monster, level: level}
         }}

      x when x <= 17 ->
        {state, treasure} = roll_treasure(state, level, true)

        {state,
         %{
           kind: :monster_and_treasure,
           monster: %{source: :appendix_c_random_monster, level: level},
           treasure: treasure
         }}

      18 ->
        {state, special} = roll_special_or_stairs(state)

        {state,
         %{
           kind: :special_or_stairs,
           value: special
         }}

      19 ->
        {state, trap} = roll_trap(state)

        {state,
         %{
           kind: :trap,
           trap: trap
         }}

      20 ->
        {state, treasure} = roll_treasure(state, level, false)

        {state,
         %{
           kind: :treasure,
           treasure: treasure
         }}
    end
  end

  defp roll_special_or_stairs(state) do
    {state, die} = d20(state)

    special =
      cond do
        die <= 5 -> %{kind: :stairs, delta: +1}
        die == 6 -> %{kind: :special}
        die <= 8 -> %{kind: :stairs, delta: +2}
        die <= 14 -> %{kind: :stairs, delta: -1}
        die <= 19 -> %{kind: :stairs, delta: -2}
        true -> %{kind: :stairs, delta: -3, slanting_passage: true}
      end

    {state, special}
  end

  defp roll_treasure(state, level, with_monster?) do
    if with_monster? do
      {state, a} = roll_treasure(state, level, false)
      {state, b} = roll_treasure(state, level, false)

      {state,
       %{
         kind: :compound,
         with_monster_bonus_pct: 10,
         entries: [a, b]
       }}
    else
      {state, die} = d100(state)
      {state, container_info} = roll_container_and_protection(state)

      payload =
        cond do
          die <= 25 -> %{kind: :coins, currency: :cp, amount: 1000 * level}
          die <= 50 -> %{kind: :coins, currency: :sp, amount: 1000 * level}
          die <= 65 -> %{kind: :coins, currency: :ep, amount: 750 * level}
          die <= 80 -> %{kind: :coins, currency: :gp, amount: 250 * level}
          die <= 90 -> %{kind: :coins, currency: :pp, amount: 100 * level}
          die <= 94 -> %{kind: :gems, count_per_level: {1, 4}, level: level}
          die <= 97 -> %{kind: :jewelry, pieces: level}
          true -> %{kind: :magic_item_hook, source: :magic_item_tables}
        end

      {state, Map.put(payload, :container, container_info)}
    end
  end

  defp roll_container_and_protection(state) do
    {state, container_die} = d20(state)

    container =
      cond do
        container_die <= 2 -> :bags
        container_die <= 4 -> :sacks
        container_die <= 6 -> :small_coffers
        container_die <= 8 -> :chests
        container_die <= 10 -> :huge_chests
        container_die <= 12 -> :pottery_jars
        container_die <= 14 -> :metal_urns
        container_die <= 16 -> :stone_containers
        container_die <= 18 -> :iron_trunks
        true -> :loose
      end

    {state, protect_die} = d20(state)

    if protect_die <= 8 do
      {state, guard_die} = d20(state)

      {state, %{container: container, protection: %{mode: :guarded, by: guard_result(guard_die)}}}
    else
      {state, hidden_die} = d20(state)

      {state,
       %{container: container, protection: %{mode: :hidden, by: hidden_result(hidden_die)}}}
    end
  end

  defp guard_result(die) when die <= 2, do: :contact_poison_on_container
  defp guard_result(die) when die <= 4, do: :contact_poison_on_treasure
  defp guard_result(die) when die <= 6, do: :poisoned_needles_in_lock
  defp guard_result(7), do: :poisoned_needles_in_handles
  defp guard_result(8), do: :spring_darts_front
  defp guard_result(9), do: :spring_darts_top
  defp guard_result(10), do: :spring_darts_bottom
  defp guard_result(die) when die <= 12, do: :blade_inside
  defp guard_result(13), do: :poisonous_insects_or_reptiles
  defp guard_result(14), do: :gas_release
  defp guard_result(15), do: :trapdoor_in_front
  defp guard_result(16), do: :trapdoor_six_feet_in_front
  defp guard_result(17), do: :stone_block_drop
  defp guard_result(18), do: :wall_spears
  defp guard_result(19), do: :explosive_runes
  defp guard_result(_die), do: :symbol

  defp hidden_result(die) when die <= 3, do: :invisibility
  defp hidden_result(die) when die <= 5, do: :illusion
  defp hidden_result(6), do: :secret_space_under_container
  defp hidden_result(die) when die <= 8, do: :secret_compartment
  defp hidden_result(9), do: :inside_ordinary_item
  defp hidden_result(10), do: :disguised_as_something_else
  defp hidden_result(11), do: :under_trash_or_dung
  defp hidden_result(die) when die <= 13, do: :under_loose_floor_stone
  defp hidden_result(die) when die <= 15, do: :behind_loose_wall_stone
  defp hidden_result(_die), do: :secret_room_nearby

  # ------------------------------------------------------------
  # TABLE VI - Stairs
  # ------------------------------------------------------------

  defp spawn_stairs_node(state, item) do
    {state, stairs} = roll_stairs(state)

    {state, stairs_id} =
      add_connected_node(state, item.from, :stairs, Map.put(stairs, :level, item.level))

    enqueue(
      state,
      %{
        from: stairs_id,
        level: item.level + Map.get(stairs, :net_delta, 0),
        env: item.env,
        depth: item.depth + 1,
        source: :after_stairs
      }
    )
  end

  defp roll_stairs(state) do
    {state, die} = d20(state)

    stairs =
      cond do
        die <= 5 -> %{kind: :stairs, net_delta: -1, closure_chance_in_20: 1}
        die == 6 -> %{kind: :stairs, net_delta: -2, closure_chance_in_20: 2}
        die == 7 -> %{kind: :stairs, net_delta: -3, closure_chance_in_20: 3}
        die == 8 -> %{kind: :stairs, net_delta: +1}
        die == 9 -> %{kind: :up_dead_end, chute_chance_in_6: 1, chute_delta: -2}
        die == 10 -> %{kind: :down_dead_end, chute_chance_in_6: 1, chute_delta: -1}
        die == 11 -> %{kind: :chimney_up, net_delta: +1, continues: true}
        die == 12 -> %{kind: :chimney_up, net_delta: +2, continues: true}
        die == 13 -> %{kind: :chimney_down, net_delta: -2, continues: true}
        die <= 16 -> %{kind: :trapdoor_down, net_delta: -1, continues: true}
        die == 17 -> %{kind: :trapdoor_down, net_delta: -2, continues: true}
        true -> %{kind: :switchback, net_delta: -1, chamber_at_end: true}
      end

    {state, stairs}
  end

  # ------------------------------------------------------------
  # TABLE VII / VII.A - Traps and gas
  # ------------------------------------------------------------

  defp spawn_trap_node(state, item) do
    {state, trap} = roll_trap(state)

    {state, _trap_id} =
      add_connected_node(state, item.from, :trap, Map.put(trap, :level, item.level))

    state
  end

  defp roll_trap(state) do
    {state, die} = d20(state)

    cond do
      die <= 5 ->
        {state, %{kind: :secret_door_or_hidden_access}}

      die <= 7 ->
        {state, %{kind: :pit, depth_ft: 10, fall_chance_in_6: 3}}

      die == 8 ->
        {state, %{kind: :spiked_pit, depth_ft: 10, fall_chance_in_6: 3}}

      die == 9 ->
        {state, %{kind: :elevator_room, descent_levels: 1, lockout_turns: 30}}

      die == 10 ->
        {state, %{kind: :elevator_room, descent_levels: 2, lockout_turns: 30}}

      die == 11 ->
        {state, %{kind: :elevator_room_variable, descent_levels: {2, 5}, lockout_turns: 60}}

      die == 12 ->
        {state, %{kind: :sliding_wall, duration_turns: {40, 60}}}

      die == 13 ->
        {state, %{kind: :oil_and_cinder, damage_hp: {2, 12}, save_damage_hp: {1, 3}}}

      die == 14 ->
        {state, %{kind: :crushing_pit, depth_ft: 10, crush_in_rounds: {2, 5}}}

      die == 15 ->
        {state, %{kind: :arrow_trap, arrows: {1, 3}, poison_chance_in_20: 1}}

      die == 16 ->
        {state, %{kind: :spear_trap, spears: {1, 3}, poison_chance_in_20: 1}}

      die == 17 ->
        {state, subtype} = roll_gas(state)
        {state, %{kind: :gas, subtype: subtype}}

      die == 18 ->
        {state, %{kind: :falling_door_or_stone, damage_hp: {1, 10}, stone_damage_hp: {2, 20}}}

      die == 19 ->
        {state, %{kind: :illusionary_wall, concealed: :pit_or_chute_or_chamber}}

      true ->
        {state, %{kind: :chute, net_delta: -1}}
    end
  end

  defp roll_gas(state) do
    {state, die} = d20(state)

    gas =
      cond do
        die <= 7 -> :obscures_vision
        die <= 9 -> {:blindness, {1, 6}}
        die <= 12 -> :fear
        die == 13 -> {:sleep, {2, 12}}
        die <= 18 -> {:strength_bonus, {1, 6}, {1, 10}}
        die == 19 -> :sickness_return_to_surface
        true -> :poison_save_or_die
      end

    {state, gas}
  end

  # ------------------------------------------------------------
  # TABLE VIII / VIII.A / VIII.B / VIII.C - Caves, pools, lakes
  # ------------------------------------------------------------

  defp roll_cave_geometry(state) do
    {state, die} = d20(state)

    base =
      cond do
        die <= 5 ->
          %{shape: :cave, width_ft: 40, height_ft: 60, area_sqft: 2400}

        die <= 7 ->
          %{shape: :cave, width_ft: 50, height_ft: 75, area_sqft: 3750}

        die <= 9 ->
          %{shape: :double_cave, chambers: [{20, 30}, {60, 60}], area_sqft: 4200}

        die <= 11 ->
          %{shape: :double_cave, chambers: [{35, 50}, {80, 90}], area_sqft: 8950}

        die <= 14 ->
          %{shape: :cavern, width_ft: 95, height_ft: 125, area_sqft: 11_875}

        die <= 16 ->
          %{shape: :cavern, width_ft: 120, height_ft: 150, area_sqft: 18_000}

        die <= 18 ->
          %{shape: :cavern, width_ft: 150, height_ft: 200, area_sqft: 30_000}

        true ->
          %{
            shape: :mammoth_cavern,
            width_ft: {250, 300},
            height_ft: {350, 400},
            area_sqft: 96_250
          }
      end

    {state, feature} =
      cond do
        die in [10, 11, 12, 13, 14, 17, 18] ->
          roll_pool_feature(state)

        die in [19, 20] ->
          roll_lake_feature(state)

        true ->
          {state, nil}
      end

    {state, Map.put(base, :feature, feature)}
  end

  defp roll_pool_feature(state) do
    {state, die} = d20(state)

    cond do
      die <= 8 ->
        {state, :no_pool}

      die <= 10 ->
        {state, :pool_no_monster}

      die <= 12 ->
        {state, :pool_monster}

      die <= 18 ->
        {state, :pool_monster_and_treasure}

      true ->
        {state, magic_pool} = roll_magic_pool(state)
        {state, {:magic_pool, magic_pool}}
    end
  end

  defp roll_lake_feature(state) do
    {state, die} = d20(state)

    feature =
      cond do
        die <= 10 -> :no_lake
        die <= 15 -> :lake_no_monsters
        die <= 18 -> :lake_with_monsters
        true -> :enchanted_lake
      end

    {state, feature}
  end

  defp roll_magic_pool(state) do
    {state, die} = d20(state)

    pool =
      cond do
        die <= 8 -> :transmute_gold
        die <= 15 -> :one_time_attribute_change
        die <= 17 -> :talking_wish_pool
        true -> :transporter_pool
      end

    {state, pool}
  end

  # ------------------------------------------------------------
  # Utilities
  # ------------------------------------------------------------

  defp dims(shape, w, h), do: %{shape: shape, width_ft: w, height_ft: h, area_sqft: w * h}

  defp seed_rng({a, b, c}), do: :rand.seed_s(:exsplus, {a, b, c})

  defp d20(state), do: roll(state, 20)
  defp d100(state), do: roll(state, 100)
  defp roll_d4(state), do: roll(state, 4)

  defp roll(state, sides) do
    {value, rng} = :rand.uniform_s(sides, state.rng)
    {%{state | rng: rng}, value}
  end

  defp enqueue(state, item) do
    %{state | frontier: :queue.in(item, state.frontier)}
  end

  defp add_node(state, kind, data) do
    id = state.next_id

    node = %{
      id: id,
      kind: kind,
      data: data
    }

    {
      %{state | next_id: id + 1, nodes: Map.put(state.nodes, id, node)},
      id
    }
  end

  defp add_connected_node(state, from_id, kind, data) do
    {state, id} = add_node(state, kind, data)
    {add_edge(state, from_id, id, kind), id}
  end

  defp add_edge(state, from_id, to_id, via) do
    %{state | edges: [%{from: from_id, to: to_id, via: via} | state.edges]}
  end

  defp latest_id(state), do: state.next_id - 1
end
