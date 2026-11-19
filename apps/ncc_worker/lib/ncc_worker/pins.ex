defmodule NccWorker.Pins do
  @moduledoc """
  A pinned build's project (`NCC_INPUT.pins`, lock-driven builds spec,
  section 1): the package compiled against exactly the closure a project's
  `mix.lock` gave it, or not at all.

  `reproduce/5` runs once the project exists (`Project.create_plain/2` on
  the toolchain path):

    1. the package (`== version`) and every pin are written into `mix.exs`
       before the first `deps.get` (`Project.add_pinned_package/5`), with no
       `override: true`;
    2. one `mix deps.get`. A deterministic failure (`DepsGetClassifier`)
       refuses the set as `pins_unresolvable`; a transient one is a worker
       failure (exit 10);
    3. `LockPolicy.validate/1`, unchanged: a git or path entry exits 11;
    4. the exact check: `DepsLock.read/2`, the function that writes every
       build's published `deps`, must equal the pins by name, Hex package,
       version and outer checksum (`Compatibility.Pins.compare/2`),
       `DepsLock.package_checksum/2` the set's `package_checksum`, and the
       lock may hold nothing outside the closure (`DepsLock.outside_closure/2`).

  The outcome is the result's top-level `pins`, `%{"hash", "status",
  "reason", "extra", "missing", "differing"}`, with `status` "reproduced" or
  "refused". A refused set compiles nothing: the run writes a skipped
  toolchain build (`NccWorker.Worker`), exit 0, so the same key is not built
  again. Nothing a judge or a status decides reads this module's outcome
  beyond "reproduced or not".

  The firmware path (spec phase 2) adds a template round between steps 3 and
  4 for a template dependency the closure reaches only through an optional
  edge; a toolchain project has no template, so this path has none.
  """

  alias Compatibility.Pins, as: Set
  alias NccWorker.{DepsGetClassifier, DepsLock, LockPolicy, LogTail, Project}

  @type outcome :: %{String.t() => term()}

  @doc """
  Steps 1 to 4 above in `project_dir` for `package` (`%{name, version}`)
  and a set `Compatibility.Pins.validate/3` passed. `env` is the host build
  env `deps.get` runs in; `deps_get` runs it (tests). `{:ok, outcome}` for a
  reproduced or refused set, `{:error, :policy_violation}` (exit 11), or
  `{:error, reason}` for a worker failure (exit 10).
  """
  @spec reproduce(String.t(), map(), Set.t(), list(), (String.t(), list() ->
                                                         :ok | {:error, term()})) ::
          {:ok, outcome()} | {:error, term()}
  def reproduce(project_dir, package, pins, env, deps_get) do
    case Project.add_pinned_package(project_dir, package, pins["deps"], env, deps_get) do
      {:ok, :added} ->
        with :ok <- LockPolicy.validate(project_dir),
             do: {:ok, check(project_dir, package.name, pins)}

      {:error, {:deps_get_failed, output}} = error ->
        case DepsGetClassifier.classify(output) do
          :transient ->
            error

          :deterministic ->
            {:ok, refused(pins, "pins_unresolvable", empty(), LogTail.tail(output, 2000))}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  The exact check (step 4) of the project's lock against `pins`, as
  `reproduce/5`'s outcome. Public for tests.
  """
  @spec check(String.t(), String.t(), Set.t()) :: outcome()
  def check(project_dir, package_name, pins) do
    closure = DepsLock.read(project_dir, package_name)

    diff =
      case Set.compare(pins["deps"], closure) do
        :ok -> {:ok, empty()}
        {:mismatch, reason, diff} -> {reason, diff}
      end
      |> hex_names(project_dir, pins["deps"])
      |> package_checksum(project_dir, package_name, pins["package_checksum"])
      |> outside(project_dir, package_name)

    case diff do
      {:ok, _empty} -> outcome(pins, "reproduced", nil, empty())
      {reason, diff} -> refused(pins, reason, diff, nil)
    end
  end

  # A pin resolved from another Hex package than the set names differs.
  defp hex_names(acc, project_dir, deps) do
    releases =
      case DepsLock.hex_releases(project_dir) do
        {:ok, releases} -> releases
        :error -> %{}
      end

    other =
      for pin <- deps,
          %{name: hex} <- [releases[pin["name"]]],
          hex != pin["hex"],
          do: pin["name"]

    add(acc, :differing, other, "pins_closure_mismatch")
  end

  defp package_checksum(acc, project_dir, package_name, want) do
    if DepsLock.package_checksum(project_dir, package_name) == want,
      do: acc,
      else: add(acc, :differing, [package_name], "pins_checksum_mismatch")
  end

  defp outside(acc, project_dir, package_name) do
    case DepsLock.outside_closure(project_dir, package_name) do
      {:ok, []} -> acc
      {:ok, extra} -> add(acc, :extra, extra, "pins_closure_mismatch")
      :error -> add(acc, :missing, [package_name], "pins_closure_mismatch")
    end
  end

  # A closure mismatch outranks a checksum mismatch: it is the one that
  # names what Mix resolved differently.
  defp add(acc, _key, [], _reason), do: acc

  defp add({reason, diff}, key, names, new_reason) do
    reason = if reason == "pins_closure_mismatch", do: reason, else: new_reason
    {reason, Map.update!(diff, key, &Enum.sort(Enum.uniq(&1 ++ names)))}
  end

  defp empty, do: %{extra: [], missing: [], differing: []}

  # `detail` is the tail of a deps.get that could not resolve the set.
  defp refused(pins, reason, diff, nil), do: outcome(pins, "refused", reason, diff)

  defp refused(pins, reason, diff, detail),
    do: pins |> outcome("refused", reason, diff) |> Map.put("detail", detail)

  @doc """
  The refusal's reason with the dependencies it names
  (`Compatibility.Pins.describe/2`), for the skipped build's own reason.
  """
  @spec describe(outcome()) :: String.t()
  def describe(outcome) do
    Set.describe(outcome["reason"], %{
      extra: outcome["extra"],
      missing: outcome["missing"],
      differing: outcome["differing"]
    })
  end

  defp outcome(pins, status, reason, diff) do
    %{
      "hash" => pins["hash"],
      "status" => status,
      "reason" => reason,
      "extra" => diff.extra,
      "missing" => diff.missing,
      "differing" => diff.differing
    }
  end
end
