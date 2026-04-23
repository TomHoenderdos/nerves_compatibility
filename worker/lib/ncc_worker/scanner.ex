defmodule NccWorker.Scanner do
  @moduledoc """
  Scans build output directories for firmware files and release artifacts.
  """

  @doc """
  Finds firmware (.fw) file in the build directory and returns its metadata.

  The worker sets MIX_BUILD_PATH to `<project>/_build/<target>`, so Nerves
  drops firmware at `<build_path>/nerves/images/*.fw` — there is no `dev/`
  subdirectory in this layout.

  ## Parameters
    - build_path: Path to the MIX_BUILD_PATH for a specific target

  ## Returns
    - Map with :size (in bytes) and :path, or empty map if not found
  """
  @spec find_firmware(String.t()) :: %{size: integer(), path: String.t()} | %{}
  def find_firmware(build_path) do
    images_dir = Path.join([build_path, "nerves", "images"])

    with {:ok, files} <- File.ls(images_dir),
         fw_file when is_binary(fw_file) <- Enum.find(files, &String.ends_with?(&1, ".fw")),
         fw_path = Path.join(images_dir, fw_file),
         {:ok, %{size: size}} <- File.stat(fw_path) do
      %{size: size, path: fw_path}
    else
      _ -> %{}
    end
  end
end
