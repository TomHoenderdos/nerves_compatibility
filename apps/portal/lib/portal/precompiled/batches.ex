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
  (`Portal.Catalog.precompiled_fingerprints/0`, read before and after the
  renders, and remembered only when the two agree), the manifest shas it stored,
  and the package's blobs this host lacked. The next batch reuses those shas
  when the fingerprint is equal, none of those blobs has arrived since, and
  each stored manifest still hashes to its name; anything else renders the
  package again. Equal inputs give equal bytes, so a reused sha names exactly
  what a render would store now. The memo lives in this node's memory only, so
  the first batch after a restart renders everything, as every batch used to.
  A deploy is such a restart: blue/green starts the new release on the other
  colour with an empty memo.

  The fingerprint covers every database input of a manifest, the two settings
  that decide one included (`host_native_enabled` and
  `deterministic_builds_enabled`, through a count of their changes, so one
  turned on and off again within a batch still reads as a change). A
  manifest's other inputs are application config: the withheld list
  (`Portal.Precompiled.Withheld`, in the fingerprint by value), the artifact
  store's path and the code itself. They change only with a restart, which
  empties the memo. An operator who changes the withheld list on a running
  node (`Application.put_env/3` over rpc) and back within one batch could
  leave a manifest rendered under the other list remembered, so change it
  through the release's config and restart instead.

  ## Renders run in lanes

  A full render rendered 14,350 packages on production in 1,000 to 2,300
  seconds, one at a time, and every deploy needs one. A render is mostly CPU
  in this node, so the packages to render go through `Portal.Precompiled.Lanes`,
  four at once by default (`config :portal, Portal.Precompiled.Batches,
  lanes:`, `NCC_PRECOMPILED_BATCH_LANES`). A render's memory grows with its
  manifest (the largest, near 50 MB of manifest, peaked near 0.9 GB), so a
  package whose manifests the newest batch named at 1 MB or more
  (`heavy_bytes:`) is heavy, weighing those bytes, and heavy packages render
  at once only while they weigh 24 MB or less together
  (`heavy_budget_bytes:`); a heavier one, or one the newest batch did not
  name, renders as the only heavy one. The lanes share the node's database
  pool, holding a connection only while a query runs, so they open no
  connection to Postgres. Results do not depend on the lanes: each package's
  manifests are its own render, and the batch maps them by name.

  Content origins (`Portal.Precompiled.Content`) are read for every batch and
  go into the payload only; no manifest depends on them, so they are not part
  of the fingerprint and a change takes effect at the next batch without
  invalidating the memo. The systems table (`Portal.Precompiled.SystemAbi`)
  is the same: rendered for every batch, named in the payload as `systems`,
  and stored in the transaction that inserts the batch.
  """
  require Ash.Query
  require Logger
  alias Portal.{ArtifactStore, Catalog}

  alias Portal.Precompiled.{
    Batch,
    Content,
    Envelope,
    Keys,
    Lanes,
    ManifestRefs,
    Manifests,
    SystemAbi
  }

  # `{name, fingerprint, v1_sha | nil, v2_sha | nil, absent_shas}` per package.
  @memo Module.concat(__MODULE__, Memo)

  # Packages rendered at once; the manifest bytes (both formats, as the newest
  # batch named them) from which a package renders as heavy; and the most
  # manifest bytes of heavy packages rendered at once, unless one alone weighs
  # more. See the moduledoc.
  @lanes 4
  @heavy_bytes 1_048_576
  @heavy_budget 24 * 1_048_576

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
    started = System.monotonic_time(:millisecond)
    lanes = lanes()

    # Read before any manifest and again after the last one: a package is
    # remembered only when both reads agree, so no write that landed while it
    # was rendered, even one undone again by the second read, can leave a
    # memo entry vouching for bytes its fingerprint does not describe. The
    # package list is read beside the first read, also before any manifest.
    names_task = Task.async(&Catalog.packages_with_precompiled_files/0)
    fingerprints = Catalog.precompiled_fingerprints()
    names = Task.await(names_task, :infinity)

    {reused, stale} =
      names |> Enum.map(&{&1, Map.get(fingerprints, &1)}) |> split_remembered(lanes)

    rendered = render_packages(stale, lanes)

    {manifests, manifests_v2} = Enum.reduce(reused ++ rendered, {%{}, %{}}, &put_package/2)

    remember(rendered, Catalog.precompiled_fingerprints())
    forget_all_but(names)

    # Rendered once per batch; no manifest depends on it, so a new system
    # release changes this sha and the batch's, and no manifest's.
    systems = systems_table()

    issued = DateTime.utc_now()
    expires = DateTime.add(issued, @ttl_hours, :hour)
    # No locking: this runs from one Oban cron job with a uniqueness
    # constraint, so concurrent calls do not occur in production,
    # and `unique_sequence` turns any race into an error, not duplicate data.
    sequence =
      case latest() do
        nil -> 1
        batch -> batch.sequence + 1
      end

    payload =
      %{
        "version" => 1,
        "sequence" => sequence,
        "issued" => DateTime.to_iso8601(issued),
        "expires" => DateTime.to_iso8601(expires),
        "manifests" => manifests,
        "manifests_v2" => manifests_v2
      }
      |> put_content(Content.origins())
      |> put_systems(systems)
      |> JSON.encode!()

    %{"signatures" => signatures} = Envelope.sign(payload, [{key.keyid, key.private}])

    changeset =
      Ash.Changeset.for_create(Batch, :create, %{
        sequence: sequence,
        issued_at: issued,
        expires_at: expires,
        payload: payload,
        signatures: signatures,
        manifest_count: map_size(manifests)
      })

    # One transaction: once a client can see the batch, every sha it names is
    # servable by sha, and a batch whose insert fails leaves no refs behind.
    result =
      Portal.Repo.transaction(fn ->
        with :ok <- ManifestRefs.record(sequence, manifests, manifests_v2),
             :ok <- store_systems(systems),
             {:ok, batch} <- Ash.create(changeset, domain: Portal.Precompiled) do
          batch
        else
          {:error, error} -> Portal.Repo.rollback(error)
        end
      end)

    with {:ok, _batch} <- result do
      Logger.info(
        "Precompiled batch #{sequence}: rendered #{length(stale)} of #{length(names)} " <>
          "packages in #{lanes} lanes, #{System.monotonic_time(:millisecond) - started} ms"
      )
    end

    result
  end

  # Each `{name, fingerprint}` as `{name, v1_sha, v2_sha}` when the memo
  # vouches for its manifests, else as it is, to be rendered. Each remembered
  # manifest is read back and hashed, so the checks run in `lanes` processes,
  # each handed one share of the packages: a process gets a copy of what its
  # function closes over, made one after another by the process that starts
  # it, so no function here closes over the fingerprint map (~2 MB on
  # production), and no process is started per package.
  defp split_remembered([], _lanes), do: {[], []}

  defp split_remembered(items, lanes) do
    items
    |> Enum.chunk_every(ceil(length(items) / lanes))
    |> Task.async_stream(&check_remembered/1, ordered: false, timeout: :infinity)
    |> Enum.reduce({[], []}, fn {:ok, {reused, stale}}, {all_reused, all_stale} ->
      {reused ++ all_reused, stale ++ all_stale}
    end)
  end

  defp check_remembered(items) do
    Enum.reduce(items, {[], []}, fn {name, fingerprint} = item, {reused, stale} ->
      case remembered(name, fingerprint) do
        {:ok, v1_sha, v2_sha} -> {[{name, v1_sha, v2_sha} | reused], stale}
        :render -> {reused, [item | stale]}
      end
    end)
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

  # Renders and stores each package in `Portal.Precompiled.Lanes`, by the
  # size the newest batch named its manifests at: a render's memory grows
  # with its manifest, so the heavy ones running at once are bounded by the
  # sum of those sizes.
  # Each item is `{name, fingerprint}`, so a lane is handed its own package's
  # fingerprint only (see `split_remembered/2`).
  defp render_packages([], _lanes), do: []

  defp render_packages(items, lanes) do
    sizes = items |> Enum.map(&elem(&1, 0)) |> last_sizes()
    {heavy, light} = Lanes.split(items, &Map.get(sizes, elem(&1, 0)), heavy_bytes())

    heavy
    |> Lanes.map(light, &render_package/1, lanes, heavy_budget())
    |> Enum.map(&elem(&1, 1))
  end

  # Both formats of one package from one catalog load. A package can have one
  # format and not the other (a run without toolchain keys is format 1 only, a
  # toolchain build format 2 only), so only a package with neither, or a
  # manifest that fails to store, is worth a warning. A failed store is not
  # remembered, so the next batch renders and stores the package again.
  defp render_package({name, fingerprint}) do
    %{v1: v1, v2: v2, absent: absent} = Manifests.render_both(name)

    %{
      name: name,
      fingerprint: fingerprint,
      v1: store(name, v1, "format 1"),
      v2: store(name, v2, "format 2"),
      absent: absent,
      none?: v1 == :none and v2 == :none
    }
  end

  defp put_package({name, nil, nil}, acc), do: drop_none(acc, name)
  defp put_package({name, v1_sha, v2_sha}, acc), do: put_shas(acc, name, v1_sha, v2_sha)
  defp put_package(%{none?: true, name: name}, acc), do: drop_none(acc, name)

  defp put_package(%{name: name, v1: v1, v2: v2}, acc),
    do: put_shas(acc, name, ok_sha(v1), ok_sha(v2))

  defp drop_none(acc, name) do
    Logger.warning("Dropping #{name} from precompiled batch: :none")
    acc
  end

  defp put_shas({v1_acc, v2_acc}, name, v1_sha, v2_sha),
    do: {put_sha(v1_acc, name, v1_sha), put_sha(v2_acc, name, v2_sha)}

  defp put_sha(acc, _name, nil), do: acc
  defp put_sha(acc, name, sha), do: Map.put(acc, name, sha)

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

  # The bytes of each of `names`' manifests in the newest batch, both formats
  # summed. A package that batch did not name, or one of whose manifests is
  # not in the store, has no size, and so renders as heavy.
  defp last_sizes(names) do
    case latest() do
      nil -> %{}
      %Batch{payload: payload} -> sizes_named(JSON.decode!(payload), names)
    end
  end

  defp sizes_named(doc, names) do
    formats = [doc["manifests"] || %{}, doc["manifests_v2"] || %{}]

    for name <- names,
        shas = Enum.flat_map(formats, &List.wrap(&1[name])),
        shas != [],
        into: %{},
        do: {name, stored_size(shas)}
  end

  defp stored_size(shas) do
    sizes = Enum.map(shas, &blob_size/1)
    if nil in sizes, do: nil, else: Enum.sum(sizes)
  end

  defp blob_size(sha) do
    with true <- ArtifactStore.valid_sha256?(sha),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(ArtifactStore.blob_path(sha)) do
      size
    else
      _ -> nil
    end
  end

  # How many packages render at once, `config :portal, Portal.Precompiled.Batches,
  # lanes:` (`NCC_PRECOMPILED_BATCH_LANES`), from how many manifest bytes a
  # package renders as heavy (`heavy_bytes:`), and how many manifest bytes of
  # heavy packages render at once (`heavy_budget_bytes:`). Anything but a
  # positive integer, or a string of one, keeps the default.
  defp lanes, do: positive(:lanes, @lanes)
  defp heavy_bytes, do: positive(:heavy_bytes, @heavy_bytes)
  defp heavy_budget, do: positive(:heavy_budget_bytes, @heavy_budget)

  defp positive(key, default) do
    case Application.get_env(:portal, __MODULE__, [])[key] do
      n when is_integer(n) and n > 0 ->
        n

      text when is_binary(text) ->
        case Integer.parse(String.trim(text)) do
          {n, ""} when n > 0 -> n
          _ -> default
        end

      _ ->
        default
    end
  end

  # Additive: a client that does not know `content` ignores it, and without
  # origins the payload is byte-for-byte what it was before the field existed.
  defp put_content(doc, []), do: doc
  defp put_content(doc, origins), do: Map.put(doc, "content", origins)

  # The systems table (`Portal.Precompiled.SystemAbi`) as `{sha, body}`, or
  # nil while it has no rows. Additive like `content`: a client that does not
  # know `systems` ignores it, and without rows the payload is what it was.
  defp systems_table do
    case SystemAbi.table() do
      table when map_size(table) == 0 -> nil
      table -> SystemAbi.render(table)
    end
  end

  defp put_systems(doc, nil), do: doc
  defp put_systems(doc, {sha, _body}), do: Map.put(doc, "systems", sha)

  defp store_systems(nil), do: :ok
  defp store_systems({sha, body}), do: SystemAbi.store(sha, body)

  # Packages whose fingerprint changed during the batch are left for the next
  # one to render again, and so is a package one of whose manifests failed to
  # store.
  defp remember(rendered, fingerprints_after) do
    for %{name: name, fingerprint: fingerprint, v1: v1, v2: v2, absent: absent} <- rendered,
        fingerprint != nil,
        v1 != :error and v2 != :error,
        Map.get(fingerprints_after, name) == fingerprint do
      true = :ets.insert(@memo, {name, fingerprint, v1, v2, absent})
    end

    :ok
  end

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
