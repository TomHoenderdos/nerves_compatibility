defmodule NccWorker.LockPolicy do
  @moduledoc """
  Validates that all dependencies are from Hex (no git/path deps).

  This enforces the mandatory Hex-only policy for reproducible builds.
  """

  @doc """
  Validates the mix.lock file to ensure all dependencies are from Hex.

  Returns :ok if all dependencies are Hex dependencies.
  Returns {:error, :policy_violation} if any git/path deps are found.
  """
  @spec validate(String.t()) :: :ok | {:error, :policy_violation}
  def validate(project_dir) do
    lock_file = Path.join(project_dir, "mix.lock")

    case File.read(lock_file) do
      {:ok, content} ->
        case eval_lock(content) do
          {lock, _} when is_map(lock) ->
            check_dependencies(lock)

          _ ->
            {:error, :policy_violation}
        end

      {:error, _} ->
        # No lock file yet - that's okay, deps.get hasn't run
        :ok
    end
  end

  # Mix writes `mix.lock` with quoted keys (`"jason": {:hex, ...}`), and every
  # one of them makes the evaluator print "found quoted keyword ... but the
  # quotes are not required". That is the lock's own generated syntax -- no
  # package author can fix it -- so on a project with 60 dependencies it is 60
  # lines of noise in a build log we now store and show to the person who asked
  # for the scan. `with_diagnostics/1` collects the warnings instead of printing
  # them; the evaluated value is unchanged, and a malformed lock still raises
  # exactly as it did before.
  defp eval_lock(content) do
    {result, _diagnostics} = Code.with_diagnostics(fn -> Code.eval_string(content) end)
    result
  end

  @spec check_dependencies(map()) :: :ok | {:error, :policy_violation}
  defp check_dependencies(lock) do
    violations =
      lock
      |> Enum.filter(fn {_name, dep} -> !is_hex_dep?(dep) end)
      |> Enum.map(fn {name, _} -> name end)

    if Enum.empty?(violations) do
      :ok
    else
      IO.puts(:stderr, "Policy violation: Non-Hex dependencies detected: #{inspect(violations)}")
      {:error, :policy_violation}
    end
  end

  @spec is_hex_dep?(tuple()) :: boolean()
  defp is_hex_dep?({:hex, _, _, _, _, _, _, _}), do: true
  defp is_hex_dep?(_), do: false
end
