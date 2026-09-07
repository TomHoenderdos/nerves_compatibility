defmodule NccWorker.HexHome do
  @moduledoc """
  Gives every build target its own `HEX_HOME` while keeping the expensive part
  of the cache shared.

  The container mounts one host directory at `/hex-cache` and points `HEX_HOME`
  at it, so every concurrent build wrote to the same `cache.ets`. Hex keeps its
  registry in that single file and rewrites it wholesale from
  `Hex.Registry.Server.persist/2`, which is not atomic and does not lock. Two
  mix processes persisting at the same moment left one of them matching on
  `{:error, :eaccess}`, and because that crash surfaces as a non-zero `mix`
  exit, the package was recorded as failing to build. It read as a property of
  the package, so the catalogue published false negatives: 15 of 552 builds on
  the day this was found, spread over unrelated packages and single targets,
  which is the signature of a race rather than of anything the packages had in
  common.

  Per-target isolation rather than per-container: three targets share one
  project directory inside a container and each runs its own `mix`, so a
  container-wide `HEX_HOME` would only have narrowed the race, not closed it.
  One writer per file closes it.

  What stays shared is `packages/`, the 22k downloaded tarballs, by symlink.
  Those are content-addressed, written once under a name that already encodes
  the version, and re-downloading them is what the cache exists to avoid.
  `cache.ets` is copied in instead, because it is the file being written.

  Publishing back is a copy to a temporary name in the shared directory
  followed by `rename`, which is atomic within a filesystem: a reader either
  sees the whole old file or the whole new one. Last writer wins, and a build
  that started with a slightly older registry can only put back a registry that
  is complete, never a torn one. `File.rename/2` is used rather than a plain
  copy for exactly that reason, and the temporary file has to live in the
  shared directory rather than in the build's own tree, because the two are
  separate mounts and a cross-device rename fails with `:exdev`.

  Every failure path here returns `nil` or `:ok`. The worst case is a build
  that falls back to the shared `HEX_HOME` and might hit the original race, or
  one that leaves the shared registry a little staler than it found it. Neither
  is worth failing a build over.
  """

  @registry "cache.ets"
  @config "hex.config"

  @doc """
  Creates a private `HEX_HOME` under `project_dir` and returns its path, or
  `nil` when there is no shared cache to seed it from and the caller should
  keep whatever `HEX_HOME` it already has.
  """
  @spec prepare(String.t(), String.t()) :: String.t() | nil
  def prepare(project_dir, name) do
    with shared when is_binary(shared) <- shared_root(),
         dir = Path.join([project_dir, ".hex", name]),
         false <- Path.expand(dir) == Path.expand(shared),
         :ok <- File.mkdir_p(dir) do
      link_packages(shared, dir)
      seed(shared, dir, @registry)
      seed(shared, dir, @config)
      dir
    else
      _ -> nil
    end
  end

  @doc """
  Copies this build's registry back over the shared one so the next build
  starts warm. Never raises: a stale shared registry costs a refetch.
  """
  @spec publish(String.t() | nil) :: :ok
  def publish(nil), do: :ok

  def publish(dir) do
    with shared when is_binary(shared) <- shared_root(),
         src = Path.join(dir, @registry),
         true <- File.regular?(src) do
      tmp = Path.join(shared, ".#{@registry}.#{:erlang.unique_integer([:positive])}")

      case File.cp(src, tmp) do
        :ok ->
          case File.rename(tmp, Path.join(shared, @registry)) do
            :ok -> :ok
            _ -> File.rm(tmp)
          end

        _ ->
          File.rm(tmp)
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  # The worker's own environment still points at the mounted cache: only the
  # environments handed to `mix` are rewritten, so this keeps reading the
  # original value however many private homes have been created.
  defp shared_root do
    case System.get_env("HEX_HOME") do
      dir when is_binary(dir) and dir != "" -> if File.dir?(dir), do: dir, else: nil
      _ -> nil
    end
  end

  defp link_packages(shared, dir) do
    target = Path.join(shared, "packages")
    link = Path.join(dir, "packages")

    File.mkdir_p(target)

    case File.read_link(link) do
      {:ok, _} -> :ok
      _ -> File.ln_s(target, link)
    end
  end

  defp seed(shared, dir, name) do
    src = Path.join(shared, name)
    dest = Path.join(dir, name)

    if File.regular?(src) and not File.exists?(dest) do
      File.cp(src, dest)
    end

    :ok
  end
end
