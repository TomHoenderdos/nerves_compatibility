defmodule NccWorker.WorldDeps do
  @moduledoc """
  A world build's closure (`NCC_INPUT.optional_deps: "world"`, toolchain
  mode): the package compiled with exactly the optional dependencies a real
  application of one common shape has.

  A world is a named set of Hex package names, the prod packages of such an
  application (the portal's `phx` world is a `mix phx.new` app's). The
  portal sends the members in `NCC_INPUT`, so the image pins no list; they
  are checked here (`validate/2`) before anything runs, and a list that fails
  is a worker failure (exit 10, no result), the way an unknown
  `optional_deps` value is.

  The closure Mix gives a package in an application depends only on which of
  the optional dependencies reachable from it are present. So the world build
  adds, at every depth of the package's closure, each unresolved optional
  dependency that is a member, runs `mix deps.get`, and repeats until a round
  finds nothing to add (`resolve/4`): phoenix gets bandit, jason and
  phoenix_html in the first round, decimal (under jason) in the second, and
  never cowboy or phoenix_view, which are not members. A round is one read of
  the lock, so phoenix converges in 3 rounds; a round that still finds
  something to add at the cap (6) is `world_not_converged`.

  After the last `deps.get` the lock may hold nothing but the package and its
  closure (`DepsLock.outside_closure/2`): a stray dependency would be
  loadable while the package compiles, and the application does not have it.

  There is no fallback. When any step fails, nothing is compiled without the
  members: the run yields a skipped toolchain build with no files, whose
  reason says why (`NccWorker.Worker.toolchain_compile/5`).
  """

  alias NccWorker.{DepsLock, LockPolicy, Project}

  @max_members 200
  @max_name_bytes 64
  @max_rounds 6
  @name ~r/\A[a-z][a-z0-9_]*\z/

  @type world :: %{name: String.t(), members: [String.t()]}

  @typedoc """
  What the fixpoint did: the applications it added, in the order it added
  them, and the rounds it took (lock reads, the last one included).
  """
  @type progress :: %{added: [String.t()], rounds: pos_integer()}

  @doc "The most rounds `resolve/4` runs before it gives up."
  @spec max_rounds() :: pos_integer()
  def max_rounds, do: @max_rounds

  @doc """
  Checks a world from `NCC_INPUT`: a name and its members, each matching
  `^[a-z][a-z0-9_]*$` and at most #{@max_name_bytes} bytes, between 1 and
  #{@max_members} members, no duplicates, and none on
  `Compatibility.OptionalDeps.never_added/0`. `{:error, {:invalid_world,
  why}}` otherwise.
  """
  @spec validate(term(), term()) :: {:ok, world()} | {:error, {:invalid_world, term()}}
  def validate(name, members) do
    cond do
      not valid_name?(name) ->
        {:error, {:invalid_world, {:name, name}}}

      not is_list(members) or members == [] ->
        {:error, {:invalid_world, :members_not_a_list}}

      length(members) > @max_members ->
        {:error, {:invalid_world, {:too_many_members, length(members)}}}

      bad = Enum.find(members, &(not valid_name?(&1))) ->
        {:error, {:invalid_world, {:member, bad}}}

      length(Enum.uniq(members)) != length(members) ->
        {:error, {:invalid_world, {:duplicate_members, members -- Enum.uniq(members)}}}

      never = Enum.find(members, &(&1 in Compatibility.OptionalDeps.never_added())) ->
        {:error, {:invalid_world, {:never_added, never}}}

      true ->
        {:ok, %{name: name, members: members}}
    end
  end

  defp valid_name?(name),
    do: is_binary(name) and byte_size(name) <= @max_name_bytes and Regex.match?(@name, name)

  @doc """
  The deep fixpoint, from the project as `Project.add_package/3` and
  `LockPolicy.validate/1` left it. Each round reads the lock
  (`DepsLock.unresolved_optional_deps_in_closure/2`), keeps the members, and
  when there are any adds them (`Project.add_optional_deps/5`: the injection
  and `mix deps.get`) and checks the lock policy again. Then it checks that
  the lock holds nothing outside the package's closure.

  `{:ok, progress}` when the lock is the world closure;
  `{:error, reason, detail, progress}` otherwise, `reason` one of
  "deps_get_failed", "mix_exs_edit_failed", "stale_build_not_removed",
  "lock_policy_violation", "world_not_converged", "world_extra_deps" or
  "deps_lock_unreadable". `progress.added` is what the earlier rounds added
  and the project still has; a failed round's own additions are put back by
  `Project.add_optional_deps/5`. `{:error, {:restore_failed, _, _}}` is a
  worker failure (exit 10): the project could not be put back.

  `opts`: `env:` (the host build env `deps.get` runs in), `deps_get:`
  (`Project.add_optional_deps/5`'s, for tests), `max_rounds:`.
  """
  @spec resolve(String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, progress()}
          | {:error, String.t(), term(), progress()}
          | {:error, {:restore_failed, term(), term()}}
  def resolve(project_dir, package_name, members, opts) do
    max = Keyword.get(opts, :max_rounds, @max_rounds)
    round(project_dir, package_name, MapSet.new(members), opts, %{added: [], rounds: 1}, max)
  end

  @doc """
  The unresolved optional dependencies in the package's closure that are not
  world members, sorted: what a world build set aside, for
  `optional_deps.skipped`.
  """
  @spec set_aside(String.t(), String.t(), [String.t()]) :: [String.t()]
  def set_aside(project_dir, package_name, members) do
    for dep <- DepsLock.unresolved_optional_deps_in_closure(project_dir, package_name),
        dep.app not in members,
        do: dep.app
  end

  defp round(project_dir, package_name, members, opts, progress, max) do
    case members_to_add(project_dir, package_name, members) do
      [] ->
        verify(project_dir, package_name, progress)

      deps when progress.rounds >= max ->
        {:error, "world_not_converged", Enum.map(deps, & &1.app), progress}

      deps ->
        with {:ok, added} <- add(project_dir, package_name, deps, opts, progress),
             :ok <- policy(project_dir, progress) do
          next = %{added: progress.added ++ added, rounds: progress.rounds + 1}
          round(project_dir, package_name, members, opts, next, max)
        end
    end
  end

  defp members_to_add(project_dir, package_name, members) do
    project_dir
    |> DepsLock.unresolved_optional_deps_in_closure(package_name)
    |> Enum.filter(&MapSet.member?(members, &1.app))
  end

  defp add(project_dir, package_name, deps, opts, progress) do
    env = Keyword.get(opts, :env, [])

    result =
      case Keyword.fetch(opts, :deps_get) do
        {:ok, deps_get} ->
          Project.add_optional_deps(project_dir, package_name, deps, env, deps_get)

        :error ->
          Project.add_optional_deps(project_dir, package_name, deps, env)
      end

    case result do
      {:ok, added} -> {:ok, added}
      {:error, {:restore_failed, _reason, _cause}} = error -> error
      {:error, reason} -> {:error, add_reason(reason), reason, progress}
    end
  end

  defp add_reason({:deps_get_failed, _output}), do: "deps_get_failed"
  defp add_reason({:rm_rf_failed, _reason, _path}), do: "stale_build_not_removed"
  defp add_reason(_reason), do: "mix_exs_edit_failed"

  defp policy(project_dir, progress) do
    case LockPolicy.validate(project_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, "lock_policy_violation", reason, progress}
    end
  end

  defp verify(project_dir, package_name, progress) do
    case DepsLock.outside_closure(project_dir, package_name) do
      {:ok, []} -> {:ok, progress}
      {:ok, extra} -> {:error, "world_extra_deps", extra, progress}
      :error -> {:error, "deps_lock_unreadable", nil, progress}
    end
  end
end
