defmodule NccWorker.PackageArtifacts do
  @moduledoc """
  Where the tested package's compiled output lives after a target build.

  The determinism check hashes the package's `ebin`/`priv` files, rebuilds it
  and hashes them again. A runtime package is hashed where it ships, inside the
  release (`<build>/rel/<app>/lib/<pkg>-<vsn>`). A build-time dependency
  (`runtime: false` -- nerves itself, the nerves_system_* packages) is compiled
  but never copied into a release; for those the compiled output under
  `<build>/lib/<pkg>` is the thing to hash. Not finding the package in the
  release used to fail every target of such a package after its firmware had
  built.
  """

  @doc """
  The directory holding `package_name`'s compiled `ebin`/`priv` for the build
  at `build_path`: in the release when it ships there, else under `lib/`.
  """
  @spec lib_dir(String.t(), String.t()) :: {:ok, String.t()} | {:error, :package_not_found}
  def lib_dir(build_path, package_name) do
    rel_roots =
      [Path.join(build_path, "rel"), Path.join([build_path, "dev", "rel"])]
      |> Enum.filter(&File.dir?/1)

    case Enum.find_value(rel_roots, &in_release(&1, package_name)) do
      nil -> build_time(build_path, package_name)
      path -> {:ok, path}
    end
  end

  @doc """
  The stored log tail with the worker's own failure reason appended. A reason
  raised after the last build command otherwise leaves a tail that ends in
  "Firmware built successfully!" on a target marked failed.
  """
  @spec with_error(String.t() | nil, term()) :: String.t() | nil
  def with_error(log_tail, nil), do: log_tail
  def with_error(nil, error), do: "** ncc_worker: #{reason(error)}\n"
  def with_error(log_tail, error), do: log_tail <> "\n** ncc_worker: #{reason(error)}\n"

  defp reason(error) when is_binary(error), do: error
  defp reason(error), do: inspect(error)

  defp in_release(rel_root, package_name) do
    rel_root
    |> File.ls!()
    |> Enum.find_value(&in_lib(Path.join([rel_root, &1, "lib"]), package_name))
  end

  defp in_lib(lib_dir, package_name) do
    with {:ok, entries} <- File.ls(lib_dir),
         entry when is_binary(entry) <-
           Enum.find(entries, &String.starts_with?(&1, package_name <> "-")) do
      Path.join(lib_dir, entry)
    else
      _ -> nil
    end
  end

  defp build_time(build_path, package_name) do
    dir = Path.join([build_path, "lib", package_name])
    if File.dir?(dir), do: {:ok, dir}, else: {:error, :package_not_found}
  end
end
