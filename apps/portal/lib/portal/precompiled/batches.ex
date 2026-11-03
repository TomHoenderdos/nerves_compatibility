defmodule Portal.Precompiled.Batches do
  @moduledoc """
  Builds and signs batch indexes. A batch names every package that has
  precompiled files and the SHA-256 of its manifest bytes; the client uses a
  manifest only if the newest valid batch names its hash.

  ## Unchanged packages are not rendered again

  Rendering a package reads its runs, results, memberships and toolchain
  builds and checks each of its blobs on disk. Done for every package in every
  batch, that took ~15 minutes on production (3,935 packages, ~240 ms each)
  against a 15-minute schedule, so every other cron slot found the previous
  job still running and was skipped.

  A batch now remembers, per package, the fingerprint of its rows
  (`Portal.Catalog.precompiled_fingerprints/0`), the manifest shas it stored,
  and the package's blobs this host lacked. The next batch reuses those shas
  when the fingerprint is equal, none of those blobs has arrived since, and
  each stored manifest still hashes to its name; anything else renders the
  package again. Equal inputs give equal bytes, so a reused sha names exactly
  what a render would store now. The memo lives in this node's memory only, so
  the first batch after a restart renders everything, as every batch used to.
  """
  require Ash.Query
  require Logger
  alias Portal.{ArtifactStore, Catalog}
  alias Portal.Precompiled.{Batch, Envelope, Keys, Manifests}

  # `{name, fingerprint, v1_sha | nil, v2_sha | nil, absent_shas}` per package.
  @memo Module.concat(__MODULE__, Memo)

  # A batch is signed every 15 minutes; clients refuse one older than 24 hours
  # anyway (freshness bound), so a longer lifetime only widens the window in
  # which an old, validly signed batch can be replayed.
  @ttl_hours 24

  @spec build_and_sign() ::
          {:ok, Batch.t()} | {:error, :no_signing_key | :signing_key_unreadable | term()}
  def build_and_sign do
    case Keys.load() do
      {:ok, key} ->
        do_build(key)

      {:error, :no_key} ->
        {:error, :no_signing_key}

      {:error, :unreadable} ->
        Logger.error(
          "Precompiled signing key at #{inspect(Keys.key_path())} is configured but unreadable"
        )

        {:error, :signing_key_unreadable}
    end
  end

  @doc """
  Creates the ETS table that remembers each package's manifests between
  batches (see the moduledoc). Called once from `Portal.Application.start/2`,
  whose process owns it for the life of the application.
  """
  @spec create_memo_table() :: :ok
  def create_memo_table do
    _ = :ets.new(@memo, [:named_table, :public, :set])
    :ok
  end

  defp do_build(key) do
    # Before any manifest is read: a write after this point makes the next
    # batch's fingerprint differ from the one remembered with it.
    fingerprints = Catalog.precompiled_fingerprints()
    names = Catalog.packages_with_precompiled_files()

    {manifests, manifests_v2} =
      Enum.reduce(names, {%{}, %{}}, fn name, acc ->
        add_package(acc, name, Map.get(fingerprints, name))
      end)

    forget_all_but(names)

    issued = DateTime.utc_now()
    expires = DateTime.add(issued, @ttl_hours, :hour)
    # No locking: this runs from one Oban cron job with a uniqueness
    # constraint (Task 7), so concurrent calls do not occur in production,
    # and `unique_sequence` turns any race into an error, not duplicate data.
    sequence =
      case latest() do
        nil -> 1
        batch -> batch.sequence + 1
      end

    payload =
      JSON.encode!(%{
        "version" => 1,
        "sequence" => sequence,
        "issued" => DateTime.to_iso8601(issued),
        "expires" => DateTime.to_iso8601(expires),
        "manifests" => manifests,
        "manifests_v2" => manifests_v2
      })

    %{"signatures" => signatures} = Envelope.sign(payload, [{key.keyid, key.private}])

    Batch
    |> Ash.Changeset.for_create(:create, %{
      sequence: sequence,
      issued_at: issued,
      expires_at: expires,
      payload: payload,
      signatures: signatures,
      manifest_count: map_size(manifests)
    })
    |> Ash.create(domain: Portal.Precompiled)
  end

  defp add_package(acc, name, fingerprint) do
    case remembered(name, fingerprint) do
      {:ok, nil, nil} -> drop_none(acc, name)
      {:ok, v1_sha, v2_sha} -> put_shas(acc, name, v1_sha, v2_sha)
      :render -> render_package(acc, name, fingerprint)
    end
  end

  defp remembered(_name, nil), do: :render

  defp remembered(name, fingerprint) do
    with [{^name, ^fingerprint, v1_sha, v2_sha, absent}] <- :ets.lookup(@memo, name),
         false <- Enum.any?(absent, &ArtifactStore.present?/1),
         true <- [v1_sha, v2_sha] |> Enum.reject(&is_nil/1) |> Enum.all?(&Manifests.intact?/1) do
      {:ok, v1_sha, v2_sha}
    else
      _ -> :render
    end
  end

  defp drop_none(acc, name) do
    Logger.warning("Dropping #{name} from precompiled batch: :none")
    acc
  end

  defp put_shas({v1_acc, v2_acc}, name, v1_sha, v2_sha),
    do: {put_sha(v1_acc, name, v1_sha), put_sha(v2_acc, name, v2_sha)}

  defp put_sha(acc, _name, nil), do: acc
  defp put_sha(acc, name, sha), do: Map.put(acc, name, sha)

  # Both formats of one package from one catalog load. A package can have one
  # format and not the other (a run without toolchain keys is format 1 only, a
  # toolchain build format 2 only), so only a package with neither, or a
  # manifest that fails to store, is worth a warning. A failed store is not
  # remembered, so the next batch renders and stores the package again.
  defp render_package(acc, name, fingerprint) do
    %{v1: v1, v2: v2, absent: absent} = Manifests.render_both(name)
    v1_sha = store(name, v1, "format 1")
    v2_sha = store(name, v2, "format 2")

    if v1_sha != :error and v2_sha != :error and fingerprint != nil do
      true = :ets.insert(@memo, {name, fingerprint, v1_sha, v2_sha, absent})
    end

    if v1 == :none and v2 == :none,
      do: drop_none(acc, name),
      else: put_shas(acc, name, ok_sha(v1_sha), ok_sha(v2_sha))
  end

  defp store(_name, :none, _format), do: nil

  defp store(name, {:ok, bytes}, format) do
    case Manifests.store(bytes) do
      {:ok, sha} ->
        sha

      reason ->
        Logger.warning("Dropping #{name} (#{format}) from precompiled batch: #{inspect(reason)}")
        :error
    end
  end

  defp ok_sha(:error), do: nil
  defp ok_sha(sha), do: sha

  # A package that has nothing to publish any more leaves the memo.
  defp forget_all_but(names) do
    keep = MapSet.new(names)

    @memo
    |> :ets.select([{{:"$1", :_, :_, :_, :_}, [], [:"$1"]}])
    |> Enum.reject(&MapSet.member?(keep, &1))
    |> Enum.each(&:ets.delete(@memo, &1))
  end

  @spec latest() :: Batch.t() | nil
  def latest do
    Batch
    |> Ash.Query.sort(sequence: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(domain: Portal.Precompiled)
    |> List.first()
  end

  @spec get(integer()) :: Batch.t() | nil
  def get(sequence) do
    Batch |> Ash.Query.filter(sequence == ^sequence) |> Ash.read_one!(domain: Portal.Precompiled)
  end

  @spec envelope(Batch.t()) :: binary()
  def envelope(%Batch{payload: payload, signatures: signatures}) do
    JSON.encode!(%{
      "payload" => Base.url_encode64(payload, padding: false),
      "signatures" => signatures
    })
  end

  @spec manifests(Batch.t()) :: %{String.t() => String.t()}
  def manifests(%Batch{payload: payload}), do: JSON.decode!(payload)["manifests"]

  @doc "Format-2 manifest shas of a batch; `%{}` for a batch made before format 2."
  @spec manifests_v2(Batch.t()) :: %{String.t() => String.t()}
  def manifests_v2(%Batch{payload: payload}), do: JSON.decode!(payload)["manifests_v2"] || %{}
end
