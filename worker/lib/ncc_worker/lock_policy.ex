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
        case Code.eval_string(content) do
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
