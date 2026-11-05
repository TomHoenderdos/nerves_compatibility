defmodule Portal.Catalog.IngestionToolchainPrivTest do
  # The worker checks a build's priv files against the package's Hex tarball
  # inside the container, where a dependency's leftover process could still
  # change them after the check. So the host checks again at ingest, against
  # the tarball it fetches itself and the checksum the registry lists: a priv
  # file is published only when it is byte for byte the tarball's own, and a
  # build with any priv file that is not publishes nothing at all.
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.Catalog.{ArtifactMembership, Ingestion, ToolchainBuild}

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
    Ingestion.ingest_toolchain(result, opts_fun.(files_dir, {:ok, tarball}, {:ok, checksum}))
  end

  # Whatever ingest answers for a refused build, nothing of it is served.
  defp assert_nothing_published(name, outcome) do
    case outcome do
      {:ok, row} -> refute row.status == :pass
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
      Ingestion.ingest_toolchain(result, opts(files_dir, {:ok, tarball}, {:ok, sha(tarball)}))

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
      Ingestion.ingest_toolchain(result, opts(files_dir, {:ok, tarball}, {:ok, sha(tarball)}))

    assert_nothing_published(name, outcome)
  end

  test "a tarball that cannot be fetched is refused" do
    name = unique()
    js = "js-#{name}"
    tarball = hex_tarball(%{"priv/app.js" => js})
    files_dir = files_dir_with(["beam-#{name}", js])
    result = result(name, "beam-#{name}", [{"priv/app.js", js}], sha(tarball))

    outcome =
      Ingestion.ingest_toolchain(
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

    outcome = Ingestion.ingest_toolchain(result, opts(files_dir, {:ok, served}, {:ok, signed}))

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
             Ingestion.ingest_toolchain(
               result,
               opts(files_dir, {:error, :unused}, {:error, :unused})
             )

    refute_received {:tarball_fetched, _, _}
    assert {true, [_beam]} = published?(name)
  end
end
