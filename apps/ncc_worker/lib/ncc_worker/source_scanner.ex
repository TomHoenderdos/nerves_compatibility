defmodule NccWorker.SourceScanner do
  @moduledoc """
  Snapshots a dependency's source directory (`deps/<pkg>/`) and diffs two
  snapshots to detect whether the build wrote anything back into source.

  Writing build artifacts into the source directory is bad form on Nerves
  because those artifacts persist across `MIX_TARGET` switches —
  a NIF compiled for rpi4 stays in source and confuses the x86_64 build
  that follows. The firmware-build process should only write under
  MIX_BUILD_PATH, which the worker explicitly points at
  `_build/<target>/` outside the source tree.

  Representation is (path, mtime, size) per file — path-listing alone
  would miss in-place modifications, full hashing would be overkill for
  "did anything change at all?" on trees with thousands of files.
  """

  @type snapshot :: %{optional(String.t()) => {integer(), non_neg_integer()}}

  @type diff :: %{
          changed: boolean(),
          added: [String.t()],
          modified: [String.t()],
          deleted: [String.t()]
        }

  # Directories whose contents are tool-owned build scratch, not source —
  # excluded from both snapshots so rebar3 / elixir_ls / git don't trigger
  # false-positive "writes to source" warnings. Matched as the first path
  # component (i.e. relative to the package root).
  @ignored_top_dirs ~w(_build .rebar3 .elixir_ls .git .fetch .hex)

  @doc """
  Build a snapshot of `dir`: every regular file under it, keyed by its
  path relative to `dir`, with `{mtime_posix, size}` as the value.

  Returns `{:ok, snapshot}` on success, `{:error, reason}` if `dir` doesn't
  exist or is unreadable. Missing dir returns `{:ok, %{}}` so early-failure
  flows (`mix deps.get` failed, so no `deps/<pkg>/`) can still diff cleanly.
  """
  @spec snapshot(Path.t()) :: {:ok, snapshot()} | {:error, term()}
  def snapshot(dir) do
    cond do
      not File.dir?(dir) ->
        {:ok, %{}}

      true ->
        entries =
          dir
          |> Path.join("**/*")
          |> Path.wildcard(match_dot: true)
          |> Enum.filter(&File.regular?/1)
          |> Enum.reduce(%{}, fn path, acc ->
            rel = Path.relative_to(path, dir)

            if ignored?(rel) do
              acc
            else
              case File.stat(path, time: :posix) do
                {:ok, %{mtime: mtime, size: size}} ->
                  Map.put(acc, rel, {mtime, size})

                _ ->
                  acc
              end
            end
          end)

        {:ok, entries}
    end
  end

  defp ignored?(rel_path) do
    case Path.split(rel_path) do
      [top | _] -> top in @ignored_top_dirs
      _ -> false
    end
  end

  @doc """
  Diff `before` vs `after`. Empty `added`/`modified`/`deleted` lists and
  `changed: false` when the trees match.
  """
  @spec diff(snapshot(), snapshot()) :: diff()
  def diff(before_snap, after_snap) do
    added =
      after_snap
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(before_snap, &1))
      |> Enum.sort()

    deleted =
      before_snap
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(after_snap, &1))
      |> Enum.sort()

    modified =
      before_snap
      |> Enum.reduce([], fn {path, meta}, acc ->
        case Map.get(after_snap, path) do
          ^meta -> acc
          nil -> acc
          _different -> [path | acc]
        end
      end)
      |> Enum.sort()

    %{
      changed: added != [] or modified != [] or deleted != [],
      added: added,
      modified: modified,
      deleted: deleted
    }
  end
end
