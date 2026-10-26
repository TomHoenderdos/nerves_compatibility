defmodule Portal.BuildCache.L2.Push do
  @moduledoc """
  One-time, resumable push of an existing local build cache into L2: every
  `<root>/<slug>/<64hex>` entry that a HEAD does not find in the bucket is
  packed and uploaded through `Portal.BuildCache.L2.upload/5`. Resumable
  because the HEAD is the state: run it again and it carries on. Bounded by
  `limit` entries and `max_bytes` uploaded. Runs under `mix
  portal.build_cache.push` or `bin/portal eval`.

  Slugs and keys are walked in sorted order so a bounded run is repeatable.
  Only shareable slugs (`Portal.BuildCache.L2.shareable_slug?/1`) are
  walked; any other slug directory is reported as ignored.
  Staging directories, symlinks and strays are ignored: only a real
  directory named by a 64-hex key is an entry. Every entry under the root
  already passed `Portal.BuildCache.Promotion` with its package name bound,
  and the entry does not record that name, so the upload binds `:any`.

  Options: `root`, `slug`, `limit`, `max_bytes`, `dry_run`, `config` (a
  `Portal.BuildCache.L2.Config`, or `nil` for off) and `io` (an IO device,
  default `:stdio`).
  """
  alias Portal.BuildCache.L2
  alias Portal.BuildCache.L2.{Client, Config}

  @key ~r/\A[0-9a-f]{64}\z/

  @type summary :: %{
          present: non_neg_integer(),
          uploaded: non_neg_integer(),
          failed: non_neg_integer(),
          skipped: non_neg_integer(),
          bytes: non_neg_integer()
        }

  @spec run(keyword()) :: {:ok, summary()} | {:error, String.t()}
  def run(opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:req)
    io = Keyword.get(opts, :io, :stdio)

    with {:ok, cfg} <- config(Keyword.get_lazy(opts, :config, &configured/0)),
         {:ok, root} <- root(Keyword.get_lazy(opts, :root, &Portal.Builder.build_cache/0)) do
      entries = entries(root, Keyword.get(opts, :slug), io)
      IO.puts(io, "#{length(entries)} entries under #{root}")

      summary =
        Enum.reduce(
          entries,
          %{present: 0, uploaded: 0, failed: 0, skipped: 0, bytes: 0},
          &push_one(&1, &2, cfg, opts, io)
        )

      IO.puts(io, "done: #{inspect(summary)}")
      {:ok, summary}
    end
  end

  defp configured do
    case Config.config() do
      {:ok, cfg} -> cfg
      _ -> nil
    end
  end

  defp config(nil),
    do: {:error, "build cache L2 is off (NCC_BUILD_CACHE_S3_ENDPOINT unset or incomplete)"}

  defp config(%Config{read_only?: true}),
    do:
      {:error,
       "build cache L2 is read-only on this host (NCC_BUILD_CACHE_S3_READ_ONLY=1); " <>
         "the push needs the read-write key"}

  defp config(%Config{} = cfg), do: {:ok, cfg}

  defp root(nil), do: {:error, "no local build cache (NCC_BUILD_CACHE unset); pass a root"}
  defp root(root), do: {:ok, root}

  # sobelow_skip ["Traversal.FileModule"]
  # The root is operator-supplied and the names are listed from it, filtered
  # to a 64-hex pattern, and checked with lstat so a symlink is never followed.
  defp entries(root, slug, io) do
    root
    |> ls()
    |> Enum.filter(&(is_nil(slug) or &1 == slug))
    |> Enum.sort()
    |> Enum.filter(&shareable?(&1, io))
    |> Enum.flat_map(fn s ->
      dir = Path.join(root, s)

      dir
      |> ls()
      |> Enum.filter(&(&1 =~ @key and real_dir?(Path.join(dir, &1))))
      |> Enum.sort()
      |> Enum.map(&{s, &1, Path.join(dir, &1)})
    end)
  end

  defp shareable?(slug, io) do
    if L2.shareable_slug?(slug) do
      true
    else
      IO.puts(io, "#{inspect(slug)} ignored: not a shareable slug (sha256_<64 hex>)")
      false
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  # Lists a directory under the operator-supplied root.
  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  # lstat on a path under the operator-supplied root; a symlink is not an entry.
  defp real_dir?(path) do
    match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))
  end

  defp push_one({slug, key, dir}, summary, cfg, opts, io) do
    name = "#{slug}/#{key}"

    cond do
      over?(summary.uploaded, opts[:limit]) -> skip(summary, io, name, "limit")
      over?(summary.bytes, opts[:max_bytes]) -> skip(summary, io, name, "max bytes")
      opts[:dry_run] -> skip(summary, io, name, "dry run")
      true -> transfer(summary, io, name, cfg, slug, key, dir)
    end
  end

  defp over?(_count, nil), do: false
  defp over?(count, max), do: count >= max

  defp skip(summary, io, name, why) do
    IO.puts(io, "#{name} skipped (#{why})")
    Map.update!(summary, :skipped, &(&1 + 1))
  end

  defp transfer(summary, io, name, cfg, slug, key, dir) do
    case Client.head(cfg, L2.object_key(slug, key)) do
      {:ok, _} ->
        IO.puts(io, "#{name} present")
        Map.update!(summary, :present, &(&1 + 1))

      {:error, :not_found} ->
        upload(summary, io, name, cfg, slug, key, dir)

      {:error, reason} ->
        fail(summary, io, name, reason)
    end
  end

  defp upload(summary, io, name, cfg, slug, key, dir) do
    case L2.upload(dir, slug, key, :any, config: cfg) do
      {:ok, bytes} ->
        IO.puts(io, "#{name} uploaded #{bytes} bytes")

        summary
        |> Map.update!(:uploaded, &(&1 + 1))
        |> Map.update!(:bytes, &(&1 + bytes))

      other ->
        fail(summary, io, name, other)
    end
  end

  defp fail(summary, io, name, reason) do
    IO.puts(io, "#{name} failed #{inspect(reason)}")
    Map.update!(summary, :failed, &(&1 + 1))
  end
end
