defmodule Portal.Precompiled.Lanes do
  @moduledoc """
  Runs one function over many items in a bounded number of processes at once,
  at most one of them on a heavy item: how `Portal.Precompiled.Batches`
  renders packages.

  A render is mostly CPU in this node rather than a wait on Postgres (about a
  fifth of it was queries on production), so lanes on separate schedulers
  divide the time of many renders by about their number. Its memory grows
  with the package's manifest: the largest package's render peaked near
  0.9 GB on production, in a service capped at 2.5 GB. So heavy items take a
  lane one at a time while light ones fill the others, and the peak is one
  heavy render and a few light ones, never two heavy ones.

  Each lane is a `Task.async/1` of the caller: an item that raises fails the
  call, as a render that raised failed the batch before, and the caller
  exiting takes every lane with it. A lane checks a connection out of the
  node's one pool only while its query runs, so lanes open no connection to
  Postgres.
  """

  @doc """
  `fun` applied to every item of `heavy` and `light`, in at most `lanes`
  processes at once and at most one of them on an item of `heavy`. Each list
  is started in its order, and a free lane takes a heavy item whenever no
  heavy item runs. Returns `{item, result}` pairs in the order they finished.
  """
  @spec map([item], [item], (item -> result), pos_integer()) :: [{item, result}]
        when item: term(), result: term()
  def map(heavy, light, fun, lanes)
      when is_list(heavy) and is_list(light) and is_function(fun, 1) and is_integer(lanes) and
             lanes > 0,
      do: run(heavy, light, fun, lanes, %{}, nil, [])

  defp run([], [], _fun, _lanes, running, _heavy_ref, done) when map_size(running) == 0,
    do: done

  defp run([item | heavy], light, fun, lanes, running, nil, done)
       when map_size(running) < lanes do
    ref = start(fun, item)
    run(heavy, light, fun, lanes, Map.put(running, ref, item), ref, done)
  end

  defp run(heavy, [item | light], fun, lanes, running, heavy_ref, done)
       when map_size(running) < lanes do
    ref = start(fun, item)
    run(heavy, light, fun, lanes, Map.put(running, ref, item), heavy_ref, done)
  end

  defp run(heavy, light, fun, lanes, running, heavy_ref, done) do
    receive do
      {ref, result} when is_map_key(running, ref) ->
        Process.demonitor(ref, [:flush])
        {item, running} = Map.pop!(running, ref)
        heavy_ref = if ref == heavy_ref, do: nil, else: heavy_ref
        run(heavy, light, fun, lanes, running, heavy_ref, [{item, result} | done])

      # Reached only by a caller that traps exits: any other went down with
      # the lane already, through the link.
      {:DOWN, ref, :process, _pid, reason} when is_map_key(running, ref) ->
        exit(reason)
    end
  end

  defp start(fun, item), do: Task.async(fn -> fun.(item) end).ref

  @doc """
  `items` as the `{heavy, light}` lists `map/4` takes: an item is heavy from
  `size_of` `heavy_at` up, or when `size_of` gives `nil` (a size nobody knows
  could be any, so it never runs beside another heavy one). The items of
  known size come largest first, so the longest renders do not start last;
  the unknown ones follow the heavy ones in their order.
  """
  @spec split([item], (item -> non_neg_integer() | nil), pos_integer()) :: {[item], [item]}
        when item: term()
  def split(items, size_of, heavy_at) when is_function(size_of, 1) do
    {unknown, known} =
      items |> Enum.map(&{&1, size_of.(&1)}) |> Enum.split_with(&is_nil(elem(&1, 1)))

    {heavy, light} =
      known |> Enum.sort_by(&elem(&1, 1), :desc) |> Enum.split_with(&(elem(&1, 1) >= heavy_at))

    {Enum.map(heavy ++ unknown, &elem(&1, 0)), Enum.map(light, &elem(&1, 0))}
  end
end
