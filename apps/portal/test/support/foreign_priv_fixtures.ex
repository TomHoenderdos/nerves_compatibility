defmodule Portal.Test.ForeignPrivFixtures do
  @moduledoc """
  A real foreign priv toolchain result: kino_vega_lite 0.1.13's real beams,
  its two real Kino.JS archives and its real Hex tarball
  (`apps/compatibility/test/fixtures/kino_assets`), against a kino 0.19.1
  tarball holding the real reviewed `lib/kino/js.ex`, with the ingest's Hex
  fakes answering for both.
  """

  import ExUnit.Assertions

  alias Portal.Catalog.Ingestion

  @regular ~w(builds builds_with_inputs builds_closure builds_host_native)

  @dir Path.expand("../../../compatibility/test/fixtures/kino_assets", __DIR__)
  @dirs [
    {"Kino_VegaLite", "Elixir.Kino.VegaLite", "lib/assets/vega_lite/build"},
    {"KinoVegaLite_ChartCell", "Elixir.KinoVegaLite.ChartCell", "lib/assets/chart_cell"}
  ]

  def dir, do: @dir
  def sha(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
  def archive(otp, d), do: hd(Path.wildcard(Path.join([@dir, otp, d, "*.tar.gz"])))
  def writer_tarball, do: File.read!(Path.join(@dir, "kino_vega_lite-0.1.13.tar"))
  def beam(module), do: File.read!(Path.join(@dir, module <> ".beam"))

  @doc """
  A kino Hex tarball (outer tar) whose contents hold `js` as lib/kino/js.ex,
  the same bytes on every call with the same `js`: `:erl_tar` stamps each
  member with the clock, and the lock and the Hex fake must name one sha.
  """
  def kino_tarball(js \\ File.read!(Path.join(@dir, "kino-0.19.1-js.ex.txt"))) do
    key = {__MODULE__, :kino_tarball, sha(js)}

    case :persistent_term.get(key, nil) do
      nil ->
        bytes = build_kino_tarball(js)
        :persistent_term.put(key, bytes)
        bytes

      bytes ->
        bytes
    end
  end

  defp build_kino_tarball(js) do
    tmp = Path.join(System.tmp_dir!(), "fpf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    contents = Path.join(tmp, "contents.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(contents), [{~c"lib/kino/js.ex", js}], [:compressed])
    outer = Path.join(tmp, "outer.tar")

    :ok =
      :erl_tar.create(String.to_charlist(outer), [
        {~c"VERSION", "3"},
        {~c"metadata.config", ~s({<<"name">>,<<"kino">>}.\n{<<"version">>,<<"0.19.1">>}.\n)},
        {~c"contents.tar.gz", File.read!(contents)}
      ])

    bytes = File.read!(outer)
    File.rm_rf!(tmp)
    bytes
  end

  @doc "The foreign entries of the fixture archives packed on `otp`."
  def entries(otp \\ "otp28") do
    for {d, module, assets} <- @dirs do
      bytes = File.read!(archive(otp, d))

      %{
        "app" => "kino",
        "path" => "priv/assets/#{d}/#{Path.basename(archive(otp, d))}",
        "sha256" => sha(bytes),
        "size" => byte_size(bytes),
        "mode" => 33_188,
        "module" => module,
        "assets_path" => assets
      }
    end
  end

  @doc "Every blob the result names, in a files dir named by sha."
  def files_dir!(extra \\ []) do
    dir = Path.join(System.tmp_dir!(), "fpf-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    blobs =
      [beam("Elixir.Kino.VegaLite"), beam("Elixir.KinoVegaLite.ChartCell")] ++
        for(otp <- ~w(otp28 otp29), {d, _, _} <- @dirs, do: File.read!(archive(otp, d))) ++ extra

    Enum.each(blobs, &File.write!(Path.join(dir, sha(&1)), &1))
    dir
  end

  @doc "kino_vega_lite 0.1.13's toolchain result; `over` merges into its toolchain_build."
  def writer_result(over \\ %{}) do
    beams = for m <- ~w(Elixir.Kino.VegaLite Elixir.KinoVegaLite.ChartCell), do: {m, beam(m)}

    build =
      Map.merge(
        %{
          "status" => "pass",
          "reason" => nil,
          "elixir" => "1.20.3",
          "otp" => "29",
          "deps_lock" => %{"kino" => %{"version" => "0.19.1", "checksum" => sha(kino_tarball())}},
          "package_checksum" => sha(writer_tarball()),
          "compile_env" => [],
          "compile_env_rule" => 1,
          "compile_inputs" => [%{"kind" => "os_type", "family" => "unix"}],
          "config_variant" => "default",
          "file_manifest" => %{
            "ebin" =>
              for(
                {m, b} <- beams,
                do: %{
                  "path" => "ebin/#{m}.beam",
                  "sha256" => sha(b),
                  "size" => byte_size(b),
                  "mode" => 33_188
                }
              ),
            "priv" => []
          },
          "foreign_priv" => entries(),
          "foreign_priv_rule" => "kino_js_v1",
          "judge_revision" => 29,
          "portability_rule" => 2
        },
        over
      )

    %{
      "scope" => "toolchain",
      "finished_at" => "2026-11-20T10:00:00Z",
      "package" => %{"name" => "kino_vega_lite", "version" => "0.1.13"},
      "systems" => %{},
      "optional_deps" => %{"added" => [], "dropped" => [], "skipped" => [], "reason" => nil},
      "toolchain_build" => build
    }
  end

  @doc "Ingest opts with Hex fakes: `hex` maps `{name, version}` to what Hex answers."
  def ingest_opts(files_dir, hex \\ default_hex()) do
    %{
      run_id: "tc-#{System.unique_integer([:positive])}",
      image_digest: "sha256:toolchain",
      files_dir: files_dir,
      output_dir: files_dir,
      toolchain: "1.20/29",
      builder_version: 1,
      package: "kino_vega_lite",
      version: "0.1.13",
      variant: :with,
      hex_tarball: fn name, version ->
        Map.get(hex, {name, version}, {:error, :unknown_release})
      end,
      hex_outer_checksum: fn name, version ->
        case Map.get(hex, {name, version}) do
          {:ok, tarball} -> {:ok, sha(tarball)}
          other -> other || {:error, :unknown_release}
        end
      end
    }
  end

  def default_hex,
    do: %{
      {"kino_vega_lite", "0.1.13"} => {:ok, writer_tarball()},
      {"kino", "0.19.1"} => {:ok, kino_tarball()}
    }

  @doc "Ingests the writer's result with `over` and `hex`; the ingest's answer."
  def ingest!(over \\ %{}, hex \\ default_hex()),
    do: Ingestion.ingest_toolchain(writer_result(over), ingest_opts(files_dir!(), hex))

  @doc """
  Spec 4.5's contract, over any rendered format-2 manifest: no regular list,
  at the top or in `deterministic`, carries a foreign entry, a foreign rule
  or a 0b target. Clients before 0.8.0 read those lists only.
  """
  def assert_contract!(nil), do: :ok

  def assert_contract!(%{"versions" => versions}) do
    for {_v, version} <- versions,
        lists <- [version, version["deterministic"] || %{}],
        key <- @regular,
        build <- List.wrap(lists[key]) do
      refute Map.has_key?(build, "foreign_priv"), inspect({key, build["target"]})

      refute Map.has_key?(build["build"] || %{}, "foreign_priv_target"),
             inspect({key, build["target"]})

      refute Map.has_key?(build["build"] || %{}, "foreign_priv_rule"),
             inspect({key, build["target"]})
    end

    :ok
  end

  @doc """
  The writer's deterministic sibling as `result.json` carries it: its beams
  the build's with a deterministic compile info (an Elixir module's other
  chunks are the build's, `Compatibility.DeterministicBeams`), its foreign
  entries `entries`. Returns `{sibling, beams}`, the sibling beams' bytes to
  stage with `files_dir!/1`.
  """
  def sibling(entries \\ entries("otp29")) do
    build = writer_result()["toolchain_build"]

    beams =
      for %{"path" => "ebin/" <> file} <- build["file_manifest"]["ebin"],
          do: {file, deterministic_beam(beam(Path.rootname(file)))}

    ebin =
      for {file, bytes} <- beams,
          do: %{
            "path" => "ebin/" <> file,
            "sha256" => sha(bytes),
            "size" => byte_size(bytes),
            "mode" => 33_188
          }

    sibling =
      Map.merge(build, %{
        "erl_compiler_options" => Compatibility.DeterministicBeams.options(),
        "file_manifest" => %{"ebin" => ebin, "priv" => []},
        "foreign_priv" => entries
      })

    {sibling, Enum.map(beams, &elem(&1, 1))}
  end

  defp deterministic_beam(beam) do
    {:ok, _module, chunks} = :beam_lib.all_chunks(beam)
    info = :erlang.term_to_binary(version: ~c"9.0")
    chunks = List.keyreplace(chunks, ~c"CInf", 0, {~c"CInf", info})
    {:ok, bytes} = :beam_lib.build_module(chunks)
    bytes
  end
end
