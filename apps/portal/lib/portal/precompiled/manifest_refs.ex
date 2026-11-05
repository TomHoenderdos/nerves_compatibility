defmodule Portal.Precompiled.ManifestRefs do
  @moduledoc """
  Which stored blobs are manifests a signed batch named, per format; see
  `Portal.Precompiled.ManifestRef`. A batch records every sha it names in one
  statement (`unnest`), so the batch's query count does not grow with the
  catalog. Conflicts do nothing: a row keeps the sequence of the first batch
  that named it.

  Shas named only by batches signed before this table existed are not here;
  a client asking for one by sha gets a 404 and falls back to the per-name
  route, as it would without a content origin.
  """
  require Ash.Query
  alias Portal.ArtifactStore
  alias Portal.Precompiled.ManifestRef

  @insert """
  INSERT INTO precompiled_manifest_refs (sha256, format, first_sequence, inserted_at)
  SELECT s, f, $3, (now() AT TIME ZONE 'utc')
  FROM unnest($1::text[], $2::bigint[]) AS t(s, f)
  ON CONFLICT (sha256, format) DO NOTHING
  """

  @doc """
  Records the shas a batch names. `Portal.Precompiled.Batches` calls it in the
  transaction that inserts the batch, so no batch exists without its refs.
  """
  @spec record(pos_integer(), %{String.t() => String.t()}, %{String.t() => String.t()}) :: :ok
  def record(sequence, v1, v2) when is_integer(sequence) do
    pairs =
      (for(sha <- Map.values(v1), do: {sha, 1}) ++ for(sha <- Map.values(v2), do: {sha, 2}))
      |> Enum.uniq()

    case Enum.unzip(pairs) do
      {[], []} ->
        :ok

      {shas, formats} ->
        _ = Portal.Repo.query!(@insert, [shas, formats, sequence])
        :ok
    end
  end

  @spec named?(String.t(), 1 | 2) :: boolean()
  def named?(sha, format) when format in [1, 2] do
    ArtifactStore.valid_sha256?(sha) and
      ManifestRef
      |> Ash.Query.filter(sha256 == ^sha and format == ^format)
      |> Ash.exists?(domain: Portal.Precompiled)
  end
end
