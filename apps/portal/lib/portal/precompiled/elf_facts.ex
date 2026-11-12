defmodule Portal.Precompiled.ElfFacts do
  @moduledoc """
  What a target build's published priv files say about running it on another
  release of the same Nerves system, read once at ingest and kept on its
  `Portal.Catalog.SystemResult`:

    * `native` - some priv file starts with the ELF magic;
    * `portable` - every such file reads (`Compatibility.Elf.read/1`) as a
      type that loads as built, so its needs are known;
    * `needs` - every library those files need, soname => the symbol
      versions needed from it, sorted and deduplicated. A library needed
      with no version maps to `[]`.

  A build with no ELF file is not native and portable, with no needs.
  """

  alias Compatibility.Elf
  alias Portal.ArtifactStore
  alias Portal.Catalog.SystemResult

  # `Compatibility.Elf.read/1` refuses a larger file; a blob past it is read
  # only far enough to see whether it is ELF at all.
  @max_elf 64 * 1024 * 1024

  @type facts :: %{native: boolean(), portable: boolean(), needs: %{String.t() => [String.t()]}}

  @doc """
  The facts of the priv `entries`, each blob read with `read_blob`. A blob
  that cannot be read is `{:error, {:blob, sha256}}`: the facts of a build
  are known whole or not at all.
  """
  @spec compute(
          [%{String.t() => String.t()}],
          (String.t() -> {:ok, binary()} | {:error, term()})
        ) :: facts() | {:error, term()}
  def compute(entries, read_blob) when is_list(entries) and is_function(read_blob, 1) do
    entries
    |> Enum.reduce_while(%{native: false, portable: true, needs: %{}}, fn entry, acc ->
      sha = entry["sha256"]

      case read_blob.(sha) do
        {:ok, bin} when is_binary(bin) -> {:cont, add(acc, bin)}
        _ -> {:halt, {:error, {:blob, sha}}}
      end
    end)
    |> sorted()
  end

  @doc """
  Computes the facts of a stored system result from the priv files its
  manifest (`beam_scan.footprint.file_manifest.priv`) publishes and their
  blobs in `Portal.ArtifactStore`, and records them on the row. When they
  cannot be computed the columns stay null.
  """
  @spec store_for(Ecto.UUID.t()) :: {:ok, SystemResult.t()} | {:error, term()}
  def store_for(system_result_id) do
    with {:ok, result} <- Ash.get(SystemResult, system_result_id, domain: Portal.Catalog),
         %{} = facts <- compute(priv_entries(result.beam_scan), &read_blob/1) do
      result
      |> Ash.Changeset.for_update(:store_elf_facts, %{
        native: facts.native,
        portable: facts.portable,
        elf_needs: facts.needs
      })
      |> Ash.update(domain: Portal.Catalog)
    end
  end

  @doc "The priv entries a beam scan's file manifest publishes."
  @spec priv_entries(map() | nil) :: [%{String.t() => String.t()}]
  def priv_entries(beam_scan) do
    case get_in(beam_scan || %{}, ["footprint", "file_manifest", "priv"]) do
      entries when is_list(entries) ->
        Enum.filter(entries, &(is_map(&1) and is_binary(&1["sha256"])))

      _ ->
        []
    end
  end

  defp add(acc, <<0x7F, "ELF", _::binary>> = bin) do
    acc = %{acc | native: true}

    case Elf.read(bin) do
      {:ok, %{type: type, needed: needed, needs: needs}} ->
        %{
          acc
          | portable: acc.portable and Elf.portable_type?(type),
            needs: merge_needs(acc.needs, needed, needs)
        }

      _ ->
        %{acc | portable: false}
    end
  end

  defp add(acc, _bin), do: acc

  defp merge_needs(acc, needed, needs) do
    acc = Enum.reduce(needed, acc, &Map.put_new(&2, &1, []))
    Map.merge(acc, needs, fn _soname, a, b -> a ++ b end)
  end

  defp sorted({:error, _} = error), do: error

  defp sorted(facts),
    do: %{
      facts
      | needs: Map.new(facts.needs, fn {k, v} -> {k, v |> Enum.uniq() |> Enum.sort()} end)
    }

  # A blob over the ELF reader's limit is read only as far as its magic: it
  # still counts as native, and reads as not portable.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_blob(sha) do
    path = ArtifactStore.blob_path(sha)

    with {:ok, %File.Stat{size: size}} <- File.stat(path) do
      if size > @max_elf, do: read_head(path), else: File.read(path)
    end
  rescue
    ArgumentError -> {:error, :invalid_sha256}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_head(path) do
    File.open(path, [:read, :binary], fn file ->
      case IO.binread(file, 4) do
        bin when is_binary(bin) -> bin
        _ -> ""
      end
    end)
  end
end
