defmodule Portal.Catalog.ReleaseIndexTest do
  # S10 round 5: the module index per release. Every release of every Hex
  # package the registry lists (not the catalog: review U3), read from its
  # compiled sources; the read set and each probed module's definer set,
  # which a batch names and the client decides each user's lock against.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Catalog.ReleaseIndex

  defp tarball(files) do
    contents = for {path, body} <- files, do: {String.to_charlist(path), body}
    gz = Path.join(System.tmp_dir!(), "ri-#{System.unique_integer([:positive])}.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(gz), contents, [:compressed])
    bytes = File.read!(gz)
    File.rm!(gz)
    tar = Path.join(System.tmp_dir!(), "ri-#{System.unique_integer([:positive])}.tar")

    :ok =
      :erl_tar.create(String.to_charlist(tar), [
        {~c"VERSION", "3"},
        {~c"metadata.config", ""},
        {~c"contents.tar.gz", bytes}
      ])

    out = File.read!(tar)
    File.rm!(tar)
    out
  end

  defp sha(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  # jason defines Jason and the protocol Jason.Encoder; jason_uo defined
  # them in 1.4.98 only (review U1); fresh_pkg is on Hex but in no catalog.
  setup do
    tarballs = %{
      {"jason", "1.4.4"} =>
        tarball(%{"lib/j.ex" => "defmodule Jason do\nend\ndefprotocol Jason.Encoder do\nend\n"}),
      {"jason_uo", "1.4.98"} =>
        tarball(%{"lib/j.ex" => "defmodule Jason do\nend\ndefprotocol Jason.Encoder do\nend\n"}),
      {"jason_uo", "1.4.99"} =>
        tarball(%{
          "lib/j.ex" => "defmodule Jason.Uo do\nend\ndefprotocol Jason.Uo.Encoder do\nend\n"
        }),
      {"fresh_pkg", "0.1.0"} => tarball(%{"lib/f.ex" => "defmodule FreshPkg do\nend\n"})
    }

    listed =
      tarballs
      |> Map.keys()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    opts = [
      registry: fn -> {:ok, listed} end,
      releases: fn name ->
        {:ok,
         for(
           {{n, v}, bytes} <- tarballs,
           n == name,
           do: %{version: v, outer_checksum: sha(bytes)}
         )}
      end,
      tarball: fn n, v -> Map.fetch(tarballs, {n, v}) end
    ]

    %{opts: opts, tarballs: tarballs, listed: listed}
  end

  defp read_set do
    Repo.query!("SELECT package, version FROM catalog_release_index WHERE state = 'read'").rows
    |> Enum.sort()
  end

  defp definers(module) do
    Repo.query!(
      "SELECT package, version FROM catalog_release_definers WHERE module = $1 ORDER BY 1, 2",
      [module]
    ).rows
  end

  test "a run reads every release the registry lists, each with its own modules", %{opts: opts} do
    assert ReleaseIndex.refresh(Keyword.put(opts, :dry_run, true)) == %{packages: 3, to_read: 4}
    assert %{packages: 3, read: 4, failed: 0, to_read: 4} = ReleaseIndex.refresh(opts)

    assert read_set() == [
             ["fresh_pkg", "0.1.0"],
             ["jason", "1.4.4"],
             ["jason_uo", "1.4.98"],
             ["jason_uo", "1.4.99"]
           ]

    # jason_uo defines Jason.Encoder in 1.4.98 only.
    assert definers("Elixir.Jason.Encoder") == [["jason", "1.4.4"], ["jason_uo", "1.4.98"]]

    # Nothing left: a second run reads nothing.
    assert %{read: 0, to_read: 0} = ReleaseIndex.refresh(opts)
  end

  test "a release that cannot be read is failed, and only the daily run tries it again",
       %{opts: opts, tarballs: tarballs} do
    broken =
      Keyword.put(opts, :tarball, fn
        "fresh_pkg", _v -> {:error, :tarball_too_large}
        n, v -> Map.fetch(tarballs, {n, v})
      end)

    assert %{read: 3, failed: 1} = ReleaseIndex.refresh(broken)
    refute ["fresh_pkg", "0.1.0"] in read_set()

    # The incremental run leaves it; the daily one (retry_failed) reads it.
    assert %{to_read: 0} = ReleaseIndex.refresh(opts)
    assert %{read: 1} = ReleaseIndex.refresh(Keyword.put(opts, :retry_failed, true))
    assert ["fresh_pkg", "0.1.0"] in read_set()
  end

  # A failure that says "ask later" is no verdict on the release: it stays
  # untried, and the next run, incremental or daily, reads it.
  test "an unavailable registry or CDN leaves the release untried", %{
    opts: opts,
    tarballs: tarballs
  } do
    flaky =
      Keyword.put(opts, :tarball, fn
        "fresh_pkg", _v -> {:error, :hex_registry_unavailable}
        n, v -> Map.fetch(tarballs, {n, v})
      end)

    assert %{read: 3, failed: 1} = ReleaseIndex.refresh(flaky)

    assert Repo.query!("SELECT count(*) FROM catalog_release_index WHERE package = 'fresh_pkg'").rows ==
             [[0]]

    assert %{read: 1} = ReleaseIndex.refresh(opts)
  end

  test "a checksum that does not match is a failure", %{opts: opts} do
    lying = Keyword.put(opts, :releases, fn _ -> {:ok, []} end)
    assert %{read: 0, failed: 4} = ReleaseIndex.refresh(lying)
    assert read_set() == []
  end

  test "a run stopped part-way resumes where it stopped", %{opts: opts} do
    assert %{packages: 1} = ReleaseIndex.refresh(Keyword.put(opts, :limit, 1))
    assert %{to_read: 3} = ReleaseIndex.refresh(Keyword.put(opts, :dry_run, true))
    assert %{read: 3} = ReleaseIndex.refresh(opts)
  end

  test "the hourly check queues one incremental run for a release not tried yet", %{
    opts: opts,
    listed: listed
  } do
    entries = fn listed ->
      for {name, versions} <- listed,
          do: %{name: name, latest_version: hd(versions), versions: versions}
    end

    # Not before a run has read something.
    assert ReleaseIndex.queue_incremental(entries.(listed)) == 0
    refute_enqueued(worker: Portal.Workers.ReleaseIndexRefresh)

    assert %{read: 4} = ReleaseIndex.refresh(opts)

    # Nothing new, but read within the replace window (review F2): an
    # incremental run checks the registry's checksums again.
    assert ReleaseIndex.queue_incremental(entries.(listed)) == 0
    assert [_job] = all_enqueued(worker: Portal.Workers.ReleaseIndexRefresh)
    Repo.delete_all(Oban.Job)

    Repo.query!("UPDATE catalog_release_index SET tried_at = now() - interval '4 hours'")
    assert ReleaseIndex.queue_incremental(entries.(listed)) == 0
    refute_enqueued(worker: Portal.Workers.ReleaseIndexRefresh)

    newer = Map.update!(listed, "jason", &["1.4.5" | &1])
    assert ReleaseIndex.queue_incremental(entries.(newer)) == 1
    assert ReleaseIndex.queue_incremental(entries.(newer)) == 1
    assert [job] = all_enqueued(worker: Portal.Workers.ReleaseIndexRefresh)
    assert job.args == %{"incremental" => true}
  end

  test "the gate: a read release defines the module, in the package's namespace", %{opts: opts} do
    assert %{read: 4} = ReleaseIndex.refresh(opts)
    assert ReleaseIndex.gate?("Elixir.Jason.Encoder", "jason")
    assert ReleaseIndex.gate?("Elixir.Jason", "jason")
    refute ReleaseIndex.gate?("Elixir.FreshPkg", "jason")
    # jason_uo 1.4.99 defines Jason.Uo.Encoder, and its root Jason in 1.4.98.
    assert ReleaseIndex.gate?("Elixir.Jason.Uo.Encoder", "jason_uo")
    refute ReleaseIndex.gate?("Elixir.Jason.Encoder", "no_such_pkg")
  end

  test "a build's modules join its release's definers", %{opts: opts} do
    assert %{read: 4} = ReleaseIndex.refresh(opts)
    :ok = ReleaseIndex.add_build_modules("jason", "1.4.4", ["Elixir.Jason.MacroMade", "Bad Name"])
    assert definers("Elixir.Jason.MacroMade") == [["jason", "1.4.4"]]
    assert definers("Bad Name") == []
  end

  test "the batch's documents: the read set in 256 shards, a definer set per probed module",
       %{opts: opts, tarballs: tarballs} do
    assert ReleaseIndex.render_docs() == nil
    assert %{read: 4} = ReleaseIndex.refresh(opts)
    :ok = ReleaseIndex.record_probed(["Elixir.Jason.Encoder", "Elixir.NoOne"])

    {object, docs} = ReleaseIndex.render_docs()
    assert object["format"] == 1
    assert map_size(object["shards"]) == 256
    assert Map.keys(object["modules"]) |> Enum.sort() == ["Elixir.Jason.Encoder", "Elixir.NoOne"]

    :ok = ReleaseIndex.store_docs(docs)

    jason_shard = object["shards"][ReleaseIndex.shard("jason")]
    assert {:ok, body} = ReleaseIndex.stored(jason_shard)
    # Each read release with the outer checksum of the tarball it was read
    # from (review F2): a lock with another checksum is unread to a client.
    outer = sha(tarballs[{"jason", "1.4.4"}])
    assert %{"read" => %{"jason" => [["1.4.4", ^outer]]}} = JSON.decode!(body)

    assert {:ok, body} = ReleaseIndex.stored(object["modules"]["Elixir.Jason.Encoder"])

    assert JSON.decode!(body) == %{
             "format" => 1,
             "module" => "Elixir.Jason.Encoder",
             "definers" => %{"jason" => ["1.4.4"], "jason_uo" => ["1.4.98"]}
           }

    assert {:ok, body} = ReleaseIndex.stored(object["modules"]["Elixir.NoOne"])
    assert %{"definers" => %{}} = JSON.decode!(body)
    assert ReleaseIndex.stored(String.duplicate("0", 64)) == :error
  end

  test "a failed release is in no read shard", %{opts: opts, tarballs: tarballs} do
    broken =
      Keyword.put(opts, :tarball, fn
        "jason_uo", "1.4.98" -> {:error, :tarball_too_large}
        n, v -> Map.fetch(tarballs, {n, v})
      end)

    assert %{failed: 1} = ReleaseIndex.refresh(broken)
    {object, docs} = ReleaseIndex.render_docs()
    :ok = ReleaseIndex.store_docs(docs)
    {:ok, body} = ReleaseIndex.stored(object["shards"][ReleaseIndex.shard("jason_uo")])
    outer = sha(tarballs[{"jason_uo", "1.4.99"}])
    assert %{"read" => %{"jason_uo" => [["1.4.99", ^outer]]}} = JSON.decode!(body)
  end

  # Review F2: `mix hex.publish --replace` swaps a release's tarball within
  # an hour of publication. A release read within the replace window is
  # read again when the registry's checksum for it differs, and the shards
  # carry the checksum of the tarball each module list came from.
  test "a replaced release is read again, with its new checksum and modules",
       %{opts: opts, tarballs: tarballs} do
    assert %{read: 4} = ReleaseIndex.refresh(opts)
    assert definers("Elixir.Jason.Uo") == [["jason_uo", "1.4.99"]]

    # jason_uo 1.4.99 replaced: same version, another tarball and checksum.
    replaced =
      Map.put(
        tarballs,
        {"jason_uo", "1.4.99"},
        tarball(%{"lib/j.ex" => "defmodule Jason.Uo.Replaced do\nend\n"})
      )

    new_opts =
      opts
      |> Keyword.put(:releases, fn name ->
        {:ok, for({{n, v}, b} <- replaced, n == name, do: %{version: v, outer_checksum: sha(b)})}
      end)
      |> Keyword.put(:tarball, fn n, v -> Map.fetch(replaced, {n, v}) end)

    # A dry run counts no new release; the run reads the replaced one again.
    assert %{to_read: 0} = ReleaseIndex.refresh(Keyword.put(new_opts, :dry_run, true))
    assert %{read: 1, failed: 0} = ReleaseIndex.refresh(new_opts)
    assert definers("Elixir.Jason.Uo") == []
    assert definers("Elixir.Jason.Uo.Replaced") == [["jason_uo", "1.4.99"]]

    :ok = ReleaseIndex.record_probed(["Elixir.Jason.Uo"])
    {object, docs} = ReleaseIndex.render_docs()
    :ok = ReleaseIndex.store_docs(docs)
    {:ok, body} = ReleaseIndex.stored(object["shards"][ReleaseIndex.shard("jason_uo")])
    outer = sha(replaced[{"jason_uo", "1.4.99"}])
    old = sha(tarballs[{"jason_uo", "1.4.99"}])
    assert %{"read" => %{"jason_uo" => [["1.4.98", _], ["1.4.99", ^outer]]}} = JSON.decode!(body)
    refute outer == old

    # Nothing changed since: the next run reads nothing.
    assert %{read: 0} = ReleaseIndex.refresh(new_opts)

    # Outside the replace window a release is not checked again.
    Repo.query!("UPDATE catalog_release_index SET tried_at = now() - interval '4 hours'")
    assert %{read: 0} = ReleaseIndex.refresh(opts)
    assert definers("Elixir.Jason.Uo.Replaced") == [["jason_uo", "1.4.99"]]
  end

  # A replaced release whose new tarball cannot be read keeps the module
  # list of the tarball it was read from, with that tarball's checksum, so
  # only a lock of the old tarball finds it read; it is not tried hourly
  # forever (its tried_at stays).
  test "a replaced release that fails to read keeps its old checksum and modules",
       %{opts: opts, tarballs: tarballs} do
    assert %{read: 4} = ReleaseIndex.refresh(opts)
    old = sha(tarballs[{"jason_uo", "1.4.99"}])

    failing =
      opts
      |> Keyword.put(:releases, fn name ->
        {:ok,
         for({{n, v}, b} <- tarballs, n == name) do
           %{
             version: v,
             outer_checksum: if({n, v} == {"jason_uo", "1.4.99"}, do: sha("x"), else: sha(b))
           }
         end}
      end)

    assert %{read: 0, failed: 1} = ReleaseIndex.refresh(failing)
    assert definers("Elixir.Jason.Uo") == [["jason_uo", "1.4.99"]]

    %{rows: [[outer, state]]} =
      Repo.query!(
        "SELECT outer_checksum, state FROM catalog_release_index WHERE package = 'jason_uo' AND version = '1.4.99'"
      )

    assert {outer, state} == {old, "read"}

    Repo.query!(
      "UPDATE catalog_release_index SET tried_at = now() - interval '4 hours' WHERE state = 'read'"
    )

    assert %{read: 0, failed: 0} = ReleaseIndex.refresh(failing)
  end

  # A release read before the index stored checksums is in no shard until
  # it is read again, which the next run does.
  test "a release read without a checksum is unread, and the next run reads it again",
       %{opts: opts} do
    assert %{read: 4} = ReleaseIndex.refresh(opts)

    Repo.query!("UPDATE catalog_release_index SET outer_checksum = NULL WHERE package = 'jason'")

    {object, docs} = ReleaseIndex.render_docs()
    :ok = ReleaseIndex.store_docs(docs)
    {:ok, body} = ReleaseIndex.stored(object["shards"][ReleaseIndex.shard("jason")])
    assert %{"read" => read} = JSON.decode!(body)
    refute Map.has_key?(read, "jason")

    assert %{read: 1, to_read: 1} = ReleaseIndex.refresh(opts)
    {object, docs} = ReleaseIndex.render_docs()
    :ok = ReleaseIndex.store_docs(docs)
    {:ok, body} = ReleaseIndex.stored(object["shards"][ReleaseIndex.shard("jason")])
    assert %{"read" => %{"jason" => [["1.4.4", _]]}} = JSON.decode!(body)
  end

  # Ingest keeps an input's `declared` only where this index confirms the
  # gate, and records the module as probed, which the next batch renders.
  test "settle keeps a declared item the index confirms, and records it as probed", %{
    opts: opts
  } do
    assert %{read: 4} = ReleaseIndex.refresh(opts)

    item = fn module, declared ->
      %{
        "kind" => "probe",
        "of" => "module",
        "name" => module,
        "answer" => "absent",
        "definers" => declared,
        "declared" => declared
      }
    end

    kept = item.("Elixir.Jason.Encoder", ["jason"])
    dropped = item.("Elixir.FreshPkg", ["jason"])

    assert {:ok, [^kept, settled]} = Portal.Catalog.ModuleIndex.settle_inputs([kept, dropped])
    refute Map.has_key?(settled, "declared")

    {object, _docs} = ReleaseIndex.render_docs()
    assert Map.keys(object["modules"]) == ["Elixir.Jason.Encoder"]
  end

  # Each batch names the index, stores its documents in the same
  # transaction, and the API serves them by sha.
  @tag :tmp_dir
  test "a batch names the release index, and its documents are served by sha", %{
    opts: opts,
    tmp_dir: dir
  } do
    assert %{read: 4} = ReleaseIndex.refresh(opts)
    :ok = ReleaseIndex.record_probed(["Elixir.Jason.Encoder"])

    path = Path.join(dir, "signing.key")
    Portal.Precompiled.Keys.write!(path, Portal.Precompiled.Keys.generate())
    previous = Application.get_env(:portal, :precompiled_signing)
    Application.put_env(:portal, :precompiled_signing, key_path: path)
    on_exit(fn -> Application.put_env(:portal, :precompiled_signing, previous) end)

    {:ok, batch} = Portal.Precompiled.Batches.build_and_sign()
    payload = JSON.decode!(batch.payload)
    sha = payload["release_index"]["modules"]["Elixir.Jason.Encoder"]
    assert {:ok, _body} = ReleaseIndex.stored(sha)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.dispatch(
        PortalWeb.Endpoint,
        :get,
        "/api/precompiled/release-index/by-sha/#{sha}.json"
      )

    assert conn.status == 200
    assert %{"module" => "Elixir.Jason.Encoder"} = JSON.decode!(conn.resp_body)

    miss =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.dispatch(
        PortalWeb.Endpoint,
        :get,
        "/api/precompiled/release-index/by-sha/#{String.duplicate("0", 64)}.json"
      )

    assert miss.status == 404
  end
end
