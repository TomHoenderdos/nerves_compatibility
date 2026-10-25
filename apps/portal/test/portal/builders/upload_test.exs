defmodule Portal.Builders.UploadTest do
  use Portal.DataCase, async: false

  alias Portal.ArtifactStore
  alias Portal.Builders.{Builder, Lease, Leases, Upload}

  setup do
    root = Path.join(System.tmp_dir!(), "uploads-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:portal, Upload, [])

    Application.put_env(
      :portal,
      Upload,
      Keyword.merge(previous,
        root: root,
        max_file_bytes: 1000,
        max_total_bytes: 5000,
        max_batch_bytes: 4096
      )
    )

    # The free-space floor is a host property; tests that need it set their own.
    builder_config = Application.get_env(:portal, Portal.Builder, [])

    Application.put_env(
      :portal,
      Portal.Builder,
      Keyword.put(builder_config, :min_free_disk_gb, 0)
    )

    on_exit(fn ->
      Application.put_env(:portal, Upload, previous)
      Application.put_env(:portal, Portal.Builder, builder_config)
      File.rm_rf(root)
    end)

    {:ok, _queued} =
      Leases.enqueue(%{
        package: "jason",
        version: "1.4.4",
        image_name: "i",
        image_digest: "sha256:d",
        args: %{},
        scan_request_id: nil,
        priority: 5
      })

    builder =
      Builder
      |> Ash.Changeset.for_create(:enrol, %{
        name: "up",
        fingerprint: "fp-up",
        cert_pem: "p",
        cert_expires_at: DateTime.utc_now(),
        slots: 1,
        enrolled_at: DateTime.utc_now()
      })
      |> Ash.create!(domain: Portal.Builders)

    {:ok, lease} = Leases.claim(builder)
    %{lease: lease}
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp tar(entries) do
    dir = Path.join(System.tmp_dir!(), "utar-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    files =
      for {name, bytes} <- entries do
        File.write!(Path.join(dir, name), bytes)
        {String.to_charlist(name), String.to_charlist(Path.join(dir, name))}
      end

    out = Path.join(dir, "b.tar")
    :ok = :erl_tar.create(String.to_charlist(out), files)
    bin = File.read!(out)
    File.rm_rf!(dir)
    bin
  end

  defp reader(bin, chunk \\ 700) do
    {:ok, agent} = Agent.start_link(fn -> bin end)

    fn ->
      Agent.get_and_update(agent, fn
        "" ->
          {:done, ""}

        rest when byte_size(rest) <= chunk ->
          {{:ok, rest}, ""}

        rest ->
          {{:more, binary_part(rest, 0, chunk)},
           binary_part(rest, chunk, byte_size(rest) - chunk)}
      end)
    end
  end

  test "missing filters the store and the lease's own files", %{lease: lease} do
    present = sha("already")
    tmp = Path.join(System.tmp_dir!(), present)
    File.write!(tmp, "already")
    {:ok, _} = ArtifactStore.put(present, tmp)
    mine = sha("mine")
    File.mkdir_p!(Upload.files_dir(lease.id))
    File.write!(Path.join(Upload.files_dir(lease.id), mine), "mine")
    wanted = sha("wanted")
    assert {:ok, [^wanted]} = Upload.missing(lease.id, [present, mine, wanted])
    assert {:error, :invalid_sha} = Upload.missing(lease.id, ["../x"])

    Application.put_env(
      :portal,
      Upload,
      Keyword.put(Application.get_env(:portal, Upload), :max_files, 2)
    )

    assert {:error, :too_many} = Upload.missing(lease.id, [present, mine, wanted])
  end

  test "a bad sha is discarded, the batch is 422-shaped, the good entry stays", %{lease: lease} do
    good = sha("good bytes")
    bad = sha("something else")
    bin = tar([{good, "good bytes"}, {bad, "not those bytes"}])

    assert {:ok, %{stored: [^good], bad: [^bad], bytes: n}} =
             Upload.receive_batch(lease, reader(bin), content_length: byte_size(bin))

    assert n == byte_size(bin)
    assert File.read!(Path.join(Upload.files_dir(lease.id), good)) == "good bytes"
    refute File.exists?(Path.join(Upload.files_dir(lease.id), bad))
    assert [] = Path.wildcard(Path.join(Upload.files_dir(lease.id), ".incoming-*"))
    assert Ash.get!(Lease, lease.id, domain: Portal.Builders).bytes_uploaded == n
  end

  test "an entry that is not a sha refuses the batch; a too-large entry is bad, not fatal",
       %{lease: lease} do
    bin = tar([{"README", "x"}])

    assert {:error, {:unsupported_entry, "README"}} =
             Upload.receive_batch(lease, reader(bin), content_length: byte_size(bin))

    big = String.duplicate("b", 1500)
    bin = tar([{sha(big), big}, {sha("ok"), "ok"}])

    assert {:ok, %{stored: [_], bad: [_]}} =
             Upload.receive_batch(lease, reader(bin), content_length: byte_size(bin))
  end

  test "a non-sha entry after a good one leaves no partial file behind", %{lease: lease} do
    good = sha("first")
    bin = tar([{good, "first"}, {"README", "x"}])

    assert {:error, {:unsupported_entry, "README"}} =
             Upload.receive_batch(lease, reader(bin, 512), content_length: byte_size(bin))

    assert [] = Path.wildcard(Path.join(Upload.files_dir(lease.id), ".incoming-*"))
  end

  test "batch and total caps and the free-space floor are enforced before reading",
       %{lease: lease} do
    assert {:error, :batch_too_large} =
             Upload.receive_batch(lease, reader(""), content_length: 5000)

    {:ok, lease} = Leases.add_bytes(lease, 4900)

    assert {:error, :total_exceeded} =
             Upload.receive_batch(lease, reader(""), content_length: 200)

    previous = Application.get_env(:portal, Portal.Builder, [])

    Application.put_env(
      :portal,
      Portal.Builder,
      Keyword.put(previous, :min_free_disk_gb, 1_000_000)
    )

    on_exit(fn -> Application.put_env(:portal, Portal.Builder, previous) end)

    assert {:error, :insufficient_disk} =
             Upload.receive_batch(lease, reader(""), content_length: 10)
  end

  test "a re-sent batch is idempotent", %{lease: lease} do
    good = sha("twice")
    bin = tar([{good, "twice"}])

    assert {:ok, %{stored: [^good]}} =
             Upload.receive_batch(lease, reader(bin), content_length: byte_size(bin))

    assert {:ok, %{stored: [^good]}} =
             Upload.receive_batch(
               Ash.get!(Lease, lease.id, domain: Portal.Builders),
               reader(bin),
               content_length: byte_size(bin)
             )

    assert {:ok, []} = Upload.missing(lease.id, [good])
  end

  test "outputs are written and loaded in Portal.Builder.load_run/1's shape", %{lease: lease} do
    dir = Path.join(System.tmp_dir!(), "parts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "logs"))
    File.write!(Path.join(dir, "result.json"), ~s({"run_id":"rb-1","systems":{}}))
    File.write!(Path.join(dir, "logs/host.log"), "host log")
    File.write!(Path.join(dir, "logs/evil"), "nope")
    File.write!(Path.join(dir, "runner.log"), "runner says hi")

    :ok =
      :erl_tar.create(
        String.to_charlist(Path.join(dir, "logs.tar.gz")),
        [{~c"host.log", String.to_charlist(Path.join(dir, "logs/host.log"))}],
        [:compressed]
      )

    :ok =
      :erl_tar.create(
        String.to_charlist(Path.join(dir, "bad.tar.gz")),
        [{~c"evil", String.to_charlist(Path.join(dir, "logs/evil"))}],
        [:compressed]
      )

    upload = fn name ->
      %Plug.Upload{
        path: Path.join(dir, name),
        filename: name,
        content_type: "application/octet-stream"
      }
    end

    assert {:error, :logs_invalid} =
             Upload.write_outputs(lease.id, %{
               result: upload.("result.json"),
               logs: upload.("bad.tar.gz"),
               runner_log: nil
             })

    assert :ok =
             Upload.write_outputs(lease.id, %{
               result: upload.("result.json"),
               logs: upload.("logs.tar.gz"),
               runner_log: upload.("runner.log")
             })

    assert {:ok,
            %{
              exit_code: 0,
              result: %{"run_id" => "rb-1"},
              files_dir: files,
              output_dir: out,
              log: "runner says hi"
            }} = Upload.load_run(lease.id)

    assert files == Upload.files_dir(lease.id)
    assert File.read!(Path.join(out, "logs/host.log")) == "host log"
    File.write!(Path.join(dir, "result.json"), "{nope")

    assert {:error, :result_unparsable} =
             Upload.write_outputs(lease.id, %{
               result: upload.("result.json"),
               logs: nil,
               runner_log: nil
             })

    assert :ok = Upload.cleanup(lease.id)
    refute File.exists?(Upload.lease_dir(lease.id))
    assert {:error, :missing_result_json} = Upload.load_run(lease.id)
    File.rm_rf(dir)
  end
end
