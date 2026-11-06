defmodule Portal.Catalog.IngestionToolchainPrivTest do
  # The worker checks a build's priv files against the package's Hex tarball
  # inside the container, where a dependency's leftover process could still
  # change them after the check. So the host checks again at ingest, against
  # the tarball it fetches itself and the checksum the registry lists: a priv
  # file is published only when it is byte for byte the tarball's own, and a
  # build with any priv file that is not publishes nothing at all.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  alias Portal.Catalog.{ArtifactMembership, Ingestion, ToolchainBuild}
  alias Portal.Test.FakeHexDeps
  alias Portal.Workers.Ingest

  @domain Portal.Catalog

  defp unique,
    do:
      "privpkg_#{System.unique_integer([:positive])}_#{Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)}"

  defp sha(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp files_dir_with(contents) do
    dir = Path.join(System.tmp_dir!(), "priv-ingest-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Enum.each(contents, &File.write!(Path.join(dir, sha(&1)), &1))
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # A Hex tarball's bytes: the outer tar around contents.tar.gz. `files` are
  # `path => content` or `path => {content, mode}`; `links` are
  # `path => target` symlink entries.
  defp hex_tarball(files, links \\ %{}) do
    work = Path.join(System.tmp_dir!(), "priv-tarball-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    on_exit(fn -> File.rm_rf(work) end)

    entries =
      for {path, spec} <- files do
        {content, mode} = if is_tuple(spec), do: spec, else: {spec, 0o644}
        full = Path.join([work, "src", path])
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, content)
        File.chmod!(full, mode)
        {String.to_charlist(path), String.to_charlist(full)}
      end

    link_entries =
      for {path, target} <- links do
        full = Path.join([work, "src", path])
        File.mkdir_p!(Path.dirname(full))
        File.ln_s!(target, full)
        {String.to_charlist(path), String.to_charlist(full)}
      end

    contents = Path.join(work, "contents.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(contents), entries ++ link_entries, [:compressed])

    outer = Path.join(work, "outer.tar")

    :ok =
      :erl_tar.create(String.to_charlist(outer), [
        {~c"VERSION", "3"},
        {~c"CHECKSUM", String.duplicate("0", 64)},
        {~c"metadata.config", ~s({<<"name">>,<<"x">>}.\n)},
        {~c"contents.tar.gz", File.read!(contents)}
      ])

    File.read!(outer)
  end

  defp entry(path, content),
    do: %{
      "path" => path,
      "sha256" => sha(content),
      "size" => byte_size(content),
      "mode" => 33_188
    }

  defp result(name, beam, priv_entries, package_checksum) do
    %{
      "scope" => "toolchain",
      "finished_at" => "2026-11-05T10:00:00Z",
      "package" => %{"name" => name, "version" => "1.0.0"},
      "systems" => %{},
      "optional_deps" => %{"added" => [], "dropped" => [], "skipped" => [], "reason" => nil},
      "toolchain_build" => %{
        "status" => "pass",
        "reason" => nil,
        "elixir" => "1.19.1",
        "otp" => "28",
        "deps_lock" => %{},
        "package_checksum" => package_checksum,
        "compile_env" => [],
        "file_manifest" => %{
          "ebin" => [entry("ebin/#{name}.beam", beam)],
          "priv" => Enum.map(priv_entries, fn {path, content} -> entry(path, content) end)
        }
      }
    }
  end

  # Hex as the host sees it: `tarball` is what the CDN serves for the
  # release, `registry_checksum` the outer checksum the signed registry lists.
  defp opts(files_dir, tarball, registry_checksum) do
    test = self()

    %{
      run_id: "tc-#{System.unique_integer([:positive])}",
      image_digest: "sha256:toolchain",
      files_dir: files_dir,
      output_dir: files_dir,
      toolchain: "1.19/28",
      builder_version: 1,
      version: "1.0.0",
      variant: :with,
      hex_tarball: fn name, version ->
        send(test, {:tarball_fetched, name, version})
        tarball
      end,
      hex_outer_checksum: fn _name, _version -> registry_checksum end
    }
  end

  defp published?(name) do
    rows =
      ToolchainBuild
      |> Ash.Query.filter(package.name == ^name and status == :pass and is_nil(revoked_at))
      |> Ash.read!(domain: @domain)

    memberships =
      for row <- rows,
          m <-
            ArtifactMembership
            |> Ash.Query.filter(toolchain_build_id == ^row.id)
            |> Ash.read!(domain: @domain),
          do: m.sha256

    {rows != [], memberships}
  end

  defp ingest(name, beam, priv_built, tarball_files, opts_fun) do
    tarball = hex_tarball(tarball_files)
    checksum = sha(tarball)
    files_dir = files_dir_with([beam | Enum.map(priv_built, &elem(&1, 1))])
    result = result(name, beam, priv_built, checksum)
    ingest_identified(result, opts_fun.(files_dir, {:ok, tarball}, {:ok, checksum}))
  end

  # Ingest as the job would: with the identity it was enqueued for, which is
  # the result's own here. These tests are about the priv check, not about a
  # result for another package.
  defp ingest_identified(result, opts) do
    identity = %{
      package: get_in(result, ["package", "name"]),
      version: get_in(result, ["package", "version"])
    }

    Ingestion.ingest_toolchain(result, Map.merge(identity, opts))
  end

  # Whatever ingest answers for a refused build, nothing of it is served,
  # and it is refused for its priv files: a build turned away for lacking
  # the job's identity has not been checked at all.
  defp assert_nothing_published(name, outcome) do
    case outcome do
      {:ok, row} -> refute row.status == :pass
      {:error, {:identity_missing, _}} -> flunk("refused for its identity, not its priv files")
      {:error, _reason} -> :ok
    end

    assert {false, []} = published?(name)
  end

  test "a priv file the tarball carries byte for byte is published with the build" do
    name = unique()
    beam = "beam-#{name}"
    js = "console.log('#{name}')"

    assert {:ok, %{status: :pass}} =
             ingest(
               name,
               beam,
               [{"priv/static/app.js", js}],
               %{"priv/static/app.js" => js},
               &opts/3
             )

    assert {true, shas} = published?(name)
    assert Enum.sort(shas) == Enum.sort([sha(beam), sha(js)])
    assert_received {:tarball_fetched, ^name, "1.0.0"}
  end

  # Changed after the worker looked: the host's own copy of the tarball says so.
  test "a priv file that differs from the tarball's is refused" do
    name = unique()

    outcome =
      ingest(
        name,
        "beam-#{name}",
        [{"priv/data.json", ~s({"v": 2, "n": "#{name}"})}],
        %{"priv/data.json" => ~s({"v": 1})},
        &opts/3
      )

    assert_nothing_published(name, outcome)
  end

  test "a priv path the tarball does not carry is refused" do
    name = unique()

    outcome =
      ingest(
        name,
        "beam-#{name}",
        [{"priv/generated.json", ~s({"n": "#{name}"})}],
        %{"priv/data.json" => "{}"},
        &opts/3
      )

    assert_nothing_published(name, outcome)
  end

  # The lock names the release the build used; a rewritten lock names
  # another tarball than the one Hex serves for this version.
  test "a package checksum that is not the registry's is refused" do
    name = unique()
    beam = "beam-#{name}"
    js = "js-#{name}"
    tarball = hex_tarball(%{"priv/app.js" => js})
    files_dir = files_dir_with([beam, js])
    result = result(name, beam, [{"priv/app.js", js}], String.duplicate("f", 64))

    outcome =
      ingest_identified(result, opts(files_dir, {:ok, tarball}, {:ok, sha(tarball)}))

    assert_nothing_published(name, outcome)
  end

  test "a tarball entry that is executable is refused" do
    name = unique()
    script = "echo #{name}"

    outcome =
      ingest(
        name,
        "beam-#{name}",
        [{"priv/run.sh", script}],
        %{"priv/run.sh" => {script, 0o755}},
        &opts/3
      )

    assert_nothing_published(name, outcome)
  end

  test "a tarball entry that is not a regular file is refused" do
    name = unique()
    data = "data-#{name}"
    tarball = hex_tarball(%{"priv/data.json" => data}, %{"priv/alias.json" => "data.json"})
    files_dir = files_dir_with(["beam-#{name}", data])

    result =
      result(
        name,
        "beam-#{name}",
        [{"priv/data.json", data}, {"priv/alias.json", data}],
        sha(tarball)
      )

    outcome =
      ingest_identified(result, opts(files_dir, {:ok, tarball}, {:ok, sha(tarball)}))

    assert_nothing_published(name, outcome)
  end

  test "a tarball that cannot be fetched is refused" do
    name = unique()
    js = "js-#{name}"
    tarball = hex_tarball(%{"priv/app.js" => js})
    files_dir = files_dir_with(["beam-#{name}", js])
    result = result(name, "beam-#{name}", [{"priv/app.js", js}], sha(tarball))

    outcome =
      ingest_identified(
        result,
        opts(files_dir, {:error, :hex_registry_unavailable}, {:ok, sha(tarball)})
      )

    assert_nothing_published(name, outcome)
  end

  # What the CDN served is not the release the registry signed.
  test "a tarball that fails the registry's checksum is refused" do
    name = unique()
    js = "js-#{name}"
    served = hex_tarball(%{"priv/app.js" => js})
    signed = sha("another tarball")
    files_dir = files_dir_with(["beam-#{name}", js])
    result = result(name, "beam-#{name}", [{"priv/app.js", js}], signed)

    outcome = ingest_identified(result, opts(files_dir, {:ok, served}, {:ok, signed}))

    assert_nothing_published(name, outcome)
  end

  # One refused priv file refuses the build: no partial manifest of its
  # beams without the data they read.
  test "a build with one refused priv file publishes none of its files" do
    name = unique()
    good = "good-#{name}"

    outcome =
      ingest(
        name,
        "beam-#{name}",
        [{"priv/good.json", good}, {"priv/bad.json", "tampered-#{name}"}],
        %{"priv/good.json" => good, "priv/bad.json" => "original"},
        &opts/3
      )

    assert_nothing_published(name, outcome)

    refute ArtifactMembership
           |> Ash.Query.filter(sha256 in ^[sha("beam-#{name}"), sha(good)])
           |> Ash.exists?(domain: @domain)
  end

  # Without priv files there is nothing to compare: no tarball is fetched.
  test "a build without priv files needs no tarball" do
    name = unique()
    beam = "beam-#{name}"
    files_dir = files_dir_with([beam])
    result = result(name, beam, [], "outer")

    assert {:ok, %{status: :pass}} =
             ingest_identified(
               result,
               opts(files_dir, {:error, :unused}, {:error, :unused})
             )

    refute_received {:tarball_fetched, _, _}
    assert {true, [_beam]} = published?(name)
  end

  # The worker's verdict comes from the sandbox that ran the package: a pass
  # status says the worker found the priv portable, and the host checks again
  # all the same, with the same rules, on files the tarball carries byte for
  # byte.
  describe "refused on the host even when the worker reported the build portable" do
    test "native code by its magic" do
      name = unique()
      elf = <<0x7F, "ELF", 2, 1, 1, 0>> <> name

      outcome =
        ingest(name, "beam-#{name}", [{"priv/x.dat", elf}], %{"priv/x.dat" => elf}, &opts/3)

      assert_nothing_published(name, outcome)
    end

    test "native code by its name" do
      name = unique()
      lib = "not really native #{name}"

      outcome =
        ingest(name, "beam-#{name}", [{"priv/nif.so", lib}], %{"priv/nif.so" => lib}, &opts/3)

      assert_nothing_published(name, outcome)
    end

    test "more than 500 priv files" do
      name = unique()
      files = for i <- 1..501, do: {"priv/data/#{i}.txt", "#{name} #{i}"}

      outcome = ingest(name, "beam-#{name}", files, Map.new(files), &opts/3)

      assert_nothing_published(name, outcome)
    end

    test "more than 10 MiB of priv files" do
      name = unique()
      big = name <> :binary.copy("a", 10 * 1024 * 1024)

      outcome =
        ingest(name, "beam-#{name}", [{"priv/big.bin", big}], %{"priv/big.bin" => big}, &opts/3)

      assert_nothing_published(name, outcome)
    end
  end

  # The ingest job builds its own options, so there the host's Hex answers
  # come from `config :portal, :hex_deps`, whose test double reads them from
  # the test process (the job runs inline in it).
  describe "ingested by the job" do
    defp answer_hex(tarball, registry_checksum) do
      Process.put({FakeHexDeps, :tarball}, tarball)
      Process.put({FakeHexDeps, :outer_checksum}, registry_checksum)
    end

    # The run's scratch dir as a finished build leaves it for the ingest.
    defp scratch_run(name, beam, priv_built, package_checksum) do
      run_id = "tc-priv-#{System.unique_integer([:positive])}"
      scratch = Path.join(Portal.Builder.scratch_root(), Portal.Builder.safe_name(run_id))
      files = Path.join(scratch, "files")
      File.mkdir_p!(Path.join(scratch, "out"))
      File.mkdir_p!(files)
      on_exit(fn -> File.rm_rf(scratch) end)

      for content <- [beam | Enum.map(priv_built, &elem(&1, 1))],
          do: File.write!(Path.join(files, sha(content)), content)

      result = result(name, beam, priv_built, package_checksum)
      File.write!(Path.join([scratch, "out", "result.json"]), Jason.encode!(result))
      {run_id, scratch}
    end

    defp job_args(run_id, name, extra) do
      Map.merge(
        %{
          "kind" => "toolchain",
          "run_id" => run_id,
          "package" => name,
          "image_digest" => "sha256:toolchain",
          "version" => "1.0.0",
          "toolchain" => "1.19/28",
          "builder_version" => 1,
          "variant" => "with"
        },
        extra
      )
    end

    defp rows(name) do
      ToolchainBuild
      |> Ash.Query.filter(package.name == ^name)
      |> Ash.read!(domain: @domain)
    end

    # Toolchain builds only run locally today, and the job's toolchain clause
    # does not look at its source; a job that says "remote" must not route a
    # build around the check either way.
    test "a remote build's tampered priv file is refused" do
      name = unique()
      beam = "beam-#{name}"
      tarball = hex_tarball(%{"priv/data.json" => ~s({"v": 1})})
      built = [{"priv/data.json", ~s({"v": 2, "n": "#{name}"})}]
      {run_id, _scratch} = scratch_run(name, beam, built, sha(tarball))
      answer_hex({:ok, tarball}, {:ok, sha(tarball)})

      remote = %{
        "source" => "remote",
        "lease_id" => Ecto.UUID.generate(),
        "builder_id" => Ecto.UUID.generate()
      }

      perform_job(Ingest, job_args(run_id, name, remote))

      assert {false, []} = published?(name)
      assert Enum.all?(rows(name), &(&1.status != :pass))
    end

    # Hex being slow is not news about the build: nothing is published and
    # nothing recorded, and the job fails so Oban runs it again while the
    # scratch dir is still there to read.
    test "a tarball fetch that times out publishes nothing and is retried" do
      name = unique()
      beam = "beam-#{name}"
      js = "js-#{name}"
      tarball = hex_tarball(%{"priv/app.js" => js})
      {run_id, scratch} = scratch_run(name, beam, [{"priv/app.js", js}], sha(tarball))
      answer_hex({:error, :timeout}, {:ok, sha(tarball)})

      assert {:error, _reason} = perform_job(Ingest, job_args(run_id, name, %{}), attempt: 1)

      assert {false, []} = published?(name)
      assert rows(name) == []
      assert File.regular?(Path.join([scratch, "files", sha(js)]))
      assert File.regular?(Path.join([scratch, "out", "result.json"]))
    end
  end

  # What the host reads is what Hex serves, and Hex serves what anyone
  # publishes: the tarball is bounded before it is unpacked, by the bytes it
  # really inflates to, not by what its tar headers claim.
  describe "a tarball bounded before it is read" do
    @mib 1024 * 1024

    defp tar_of(entries) do
      path = Path.join(System.tmp_dir!(), "priv-tar-#{System.unique_integer([:positive])}")
      :ok = :erl_tar.create(String.to_charlist(path), entries)
      on_exit(fn -> File.rm(path) end)
      File.read!(path)
    end

    # The outer tar around `contents`, the bytes of contents.tar.gz as given.
    defp outer_around(contents) do
      tar_of([
        {~c"VERSION", "3"},
        {~c"CHECKSUM", String.duplicate("0", 64)},
        {~c"metadata.config", ~s({<<"name">>,<<"x">>}.\n)},
        {~c"contents.tar.gz", contents}
      ])
    end

    # A gzip stream of `head` followed by `mib` MiB of zeros, deflated a MiB at
    # a time so the test never holds the inflated bytes.
    defp gzip_bomb(head, mib) do
      z = :zlib.open()
      :ok = :zlib.deflateInit(z, :best_compression, :deflated, 31, 8, :default)
      zeros = :binary.copy(<<0>>, @mib)
      first = :zlib.deflate(z, head)
      body = for _ <- 1..mib, do: :zlib.deflate(z, zeros)
      last = :zlib.deflate(z, [], :finish)
      :zlib.close(z)
      IO.iodata_to_binary([first, body, last])
    end

    defp ingest_outer(name, js, outer) do
      beam = "beam-#{name}"
      files_dir = files_dir_with([beam, js])
      result = result(name, beam, [{"priv/app.js", js}], sha(outer))
      ingest_identified(result, opts(files_dir, {:ok, outer}, {:ok, sha(outer)}))
    end

    test "a served tarball over 8 MiB is refused" do
      name = unique()
      js = "js-#{name}"
      noise = :crypto.strong_rand_bytes(8 * @mib + 1)
      contents = :zlib.gzip(tar_of([{~c"priv/app.js", js}, {~c"lib/noise.bin", noise}]))
      outer = outer_around(contents)
      assert byte_size(outer) > 8 * @mib

      assert_nothing_published(name, ingest_outer(name, js, outer))
    end

    test "a contents tar of 50,000 entries is refused" do
      name = unique()
      js = "js-#{name}"
      empties = for i <- 1..50_000, do: {String.to_charlist("lib/e#{i}"), ""}
      contents = :zlib.gzip(tar_of([{~c"priv/app.js", js} | empties]))

      assert_nothing_published(name, ingest_outer(name, js, outer_around(contents)))
    end

    # The tar inside declares one small file; the gzip stream around it goes
    # on to inflate to 200 MiB of zeros, which a tar reader takes for the end
    # of the archive. Only counting what really inflates catches it.
    test "a contents.tar.gz that inflates to 200 MiB is refused, and quickly" do
      name = unique()
      js = "js-#{name}"
      contents = gzip_bomb(tar_of([{~c"priv/app.js", js}]), 200)
      outer = outer_around(contents)

      {micros, outcome} = :timer.tc(fn -> ingest_outer(name, js, outer) end)

      assert_nothing_published(name, outcome)
      assert micros < 2_000_000
    end

    test "inflating stops one chunk past the cap" do
      cap = 4 * @mib
      bomb = gzip_bomb(tar_of([{~c"priv/app.js", "x"}]), 64)

      assert {:error, {:over_cap, inflated}} = Compatibility.StaticPriv.inflate(bomb, cap)
      assert inflated > cap
      assert inflated <= cap + Compatibility.StaticPriv.inflate_chunk_bytes()
    end
  end

  # A priv file is checked as a priv file whichever key the manifest lists it
  # under: listed under ebin it would otherwise skip the host's check.
  describe "a priv/ path listed under another key" do
    defp ebin_listed(name, beam, priv_path, content, checksum) do
      result = result(name, beam, [], checksum)

      put_in(result, ["toolchain_build", "file_manifest", "ebin"], [
        entry("ebin/#{name}.beam", beam),
        entry(priv_path, content)
      ])
    end

    test "is checked against the tarball like any priv file" do
      name = unique()
      beam = "beam-#{name}"
      tampered = "tampered-#{name}"
      tarball = hex_tarball(%{"priv/app.js" => "original"})
      checksum = sha(tarball)

      result = ebin_listed(name, beam, "priv/app.js", tampered, checksum)
      files_dir = files_dir_with([beam, tampered])

      outcome =
        ingest_identified(result, opts(files_dir, {:ok, tarball}, {:ok, checksum}))

      assert_nothing_published(name, outcome)
    end

    test "is refused as native code even when the tarball carries it" do
      name = unique()
      beam = "beam-#{name}"
      lib = "not really native #{name}"
      tarball = hex_tarball(%{"priv/nif.so" => lib})
      checksum = sha(tarball)

      result = ebin_listed(name, beam, "priv/nif.so", lib, checksum)
      files_dir = files_dir_with([beam, lib])

      outcome =
        ingest_identified(result, opts(files_dir, {:ok, tarball}, {:ok, checksum}))

      assert_nothing_published(name, outcome)
    end
  end

  # The path is the container's to choose: the reason stored for it is cut
  # short however long, or however many bytes per character, it is.
  test "a misplaced entry's stored reason stays short" do
    name = unique()
    beam = "beam-#{name}"
    other = "other-#{name}"
    long_path = "lib/" <> String.duplicate("e\u0301", 5_000)
    tarball = hex_tarball(%{})
    checksum = sha(tarball)

    result =
      name
      |> result(beam, [], checksum)
      |> put_in(["toolchain_build", "file_manifest", "ebin"], [
        entry("ebin/#{name}.beam", beam),
        entry(long_path, other)
      ])

    files_dir = files_dir_with([beam, other])

    assert {:ok, %{status: :fail, reason: reason}} =
             ingest_identified(result, opts(files_dir, {:ok, tarball}, {:ok, checksum}))

    assert byte_size(reason) < 400
    assert reason =~ "under \"ebin\""
    assert {false, []} = published?(name)
  end
end
