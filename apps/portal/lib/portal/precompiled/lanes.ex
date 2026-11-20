defmodule Portal.Precompiled.Lanes do
  @moduledoc """
  Runs one function over many items in a bounded number of processes at once,
  with a bound on the weight of the heavy items among them: how
  `Portal.Precompiled.Batches` renders packages.

  A render is mostly CPU in this node rather than a wait on Postgres (about a
  fifth of it was queries on production), so lanes on separate schedulers
  divide the time of many renders by about their number. Its memory grows
  with the package's manifest, about 18 times its bytes on production, where
  the largest package's render peaked near 0.9 GB in a service capped at about
  2.5 GB. So heavy items carry a weight, and take a lane only while the heavy
  items running weigh no more than a budget, or while none runs: one heavier
  than the budget runs as the only heavy item. Light items fill the other
  lanes.

  Each lane is a `Task.async/1` of the caller: an item that raises fails the
  call, as a render that raised failed the batch before, and the caller
  exiting takes every lane with it. A lane checks a connection out of the
  node's one pool only while its query runs, so lanes open no connection to
  Postgres.
  """

  @doc """
  `fun` applied to every item of `heavy` (`{item, weight}`, a `nil` weight
  for an item of unknown weight, which counts as `budget`) and of `light`, in
  at most `lanes` processes at once. A heavy item starts when no heavy item
  runs, or when its weight and theirs add up to no more than `budget`; each
  list is started in its order, and a free lane takes the next heavy item
  whenever it may start. Returns `{item, result}` pairs in the order they
  finished.
  """
  @spec map([{item, pos_integer() | nil}], [item], (item -> result), pos_integer(), pos_integer()) ::
          [{item, result}]
        when item: term(), result: term()
  def map(heavy, light, fun, lanes, budget)
      when is_list(heavy) and is_list(light) and is_function(fun, 1) and is_integer(lanes) and
             lanes > 0 and is_integer(budget) and budget > 0 do
    heavy = Enum.map(heavy, fn {item, weight} -> {item, weight || budget} end)
    run(heavy, light, {fun, lanes, budget}, %{}, 0, [])
  end

  defp run([], [], _opts, running, _weight, done) when map_size(running) == 0, do: done

  defp run([{item, w} | heavy], light, {fun, lanes, budget} = opts, running, weight, done)
       when map_size(running) < lanes and (weight == 0 or weight + w <= budget) do
    ref = start(fun, item)
    run(heavy, light, opts, Map.put(running, ref, {item, w}), weight + w, done)
  end

  defp run(heavy, [item | light], {fun, lanes, _budget} = opts, running, weight, done)
       when map_size(running) < lanes do
    ref = start(fun, item)
    run(heavy, light, opts, Map.put(running, ref, {item, 0}), weight, done)
  end

  defp run(heavy, light, opts, running, weight, done) do
    receive do
      {ref, result} when is_map_key(running, ref) ->
        Process.demonitor(ref, [:flush])
        {{item, w}, running} = Map.pop!(running, ref)
        run(heavy, light, opts, running, weight - w, [{item, result} | done])

      # Reached only by a caller that traps exits: any other went down with
      # the lane already, through the link.
      {:DOWN, ref, :process, _pid, reason} when is_map_key(running, ref) ->
        exit(reason)
    end
  end

  defp start(fun, item), do: Task.async(fn -> fun.(item) end).ref

  @doc """
  `items` as the `{heavy, light}` lists `map/5` takes: an item is heavy, with
  its size as its weight, from `size_of` `heavy_at` up, or with a `nil`
  weight when `size_of` gives `nil` (a size nobody knows could be any). The
  items of known size come largest first, so the longest renders do not
  start last; the unknown ones follow the heavy ones in their order.
  """
  @spec split([item], (item -> non_neg_integer() | nil), pos_integer()) ::
          {[{item, pos_integer() | nil}], [item]}
        when item: term()
  def split(items, size_of, heavy_at) when is_function(size_of, 1) do
    {unknown, known} =
      items |> Enum.map(&{&1, size_of.(&1)}) |> Enum.split_with(&is_nil(elem(&1, 1)))

    {heavy, light} =
      known |> Enum.sort_by(&elem(&1, 1), :desc) |> Enum.split_with(&(elem(&1, 1) >= heavy_at))

    {heavy ++ unknown, Enum.map(light, &elem(&1, 0))}
  end
end
