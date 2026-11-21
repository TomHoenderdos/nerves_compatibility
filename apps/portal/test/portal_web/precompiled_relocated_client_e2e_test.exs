defmodule PortalWeb.PrecompiledRelocatedClientE2ETest do
  @moduledoc """
  S4 end to end (the client re-review's R6): a relocated build of fine
  0.2.0 at the worker's real three roots (`Compatibility.Relocation`),
  ingested and signed by this portal and served on a loopback port, then
  installed by the precompiled client into a child Mix project and
  relocated to that project's own paths. The client pins the same root
  layout in its own source, so a drift between the two fails here.

  fine is compiled from source in a builder project at a temp path and
  moved to the worker's first root (`/work/proj`) with
  `Compatibility.Relocation.relocate/4`, its `CInf` source set to the file
  under `/work/proj/deps/fine`: the beam the worker's compile there writes,
  but for `Dbgi` and `Docs`. Needs the client checkout in
  `PRECOMPILED_CLIENT_DIR` and fine 0.2.0 in the Hex cache (`HEX_HOME`, else
  `~/.hex`); excluded by default (tag `:e2e`).

      PRECOMPILED_CLIENT_DIR=../elixir_precompiled make test-relocate-e2e
  """
  use PortalWeb.ConnCase, async: false

  alias Compatibility.Relocation
  alias Portal.Catalog.Ingestion
  alias Portal.Precompiled.{Batches, Envelope, Keys, Root}

  @moduletag :e2e
  @moduletag timeout: 600_000
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    client =
      System.get_env("PRECOMPILED_CLIENT_DIR") ||
        flunk("set PRECOMPILED_CLIENT_DIR to a precompiled checkout")

    server =
      start_supervised!(
        {Bandit,
         plug: PortalWeb.Endpoint, scheme: :http, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    # The signing key and its root, as the trust endpoints' tests make them.
    old = Application.get_env(:portal, :precompiled_signing)
    on_exit(fn -> Application.put_env(:portal, :precompiled_signing, old) end)
    key = Keys.generate()
    Keys.write!(Path.join(dir, "signing.key"), key)
    root = Root.payload(key.keyid, key.public, DateTime.add(DateTime.utc_now(), 300, :day))
    root_path = Path.join(dir, "root.json")
    File.write!(root_path, JSON.encode!(Envelope.sign(root, [{key.keyid, key.private}])))
    Application.put_env(:portal, :precompiled_signing, key_path: Path.join(dir, "signing.key"))

    {:ok, _} = Portal.Settings.save(%{relocated_enabled: true})

    %{client: client, port: port, root_path: root_path, base: clean_base!()}
  end

  # A real dir for the child projects inside the envelope of the real roots
  # (their characters are letters, digits, space and `._-/@~`; ExUnit's tmp
  # dir holds the test's name), with this checkout's toolchain pinned for
  # asdf, so the children compile with the VM the record names.
  defp clean_base! do
    base = Path.join(System.tmp_dir!(), "ncc-reloc-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    case tool_versions(File.cwd!()) do
      nil -> :ok
      file -> File.cp!(file, Path.join(base, ".tool-versions"))
    end

    File.cd!(base, &File.cwd!/0)
  end

  defp tool_versions("/"), do: nil

  defp tool_versions(dir) do
    file = Path.join(dir, ".tool-versions")
    if File.exists?(file), do: file, else: tool_versions(Path.dirname(dir))
  end

  # The user's Hex cache (its registry and fine's tarball) copied into the
  # children's own HEX_HOME, which they use offline.
  defp hex_home!(base) do
    src = System.get_env("HEX_HOME") || Path.join(System.user_home!(), ".hex")
    home = Path.join(base, "hex")
    File.mkdir_p!(Path.join(home, "packages/hexpm"))

    # Hex 2.6 keeps its registry in cache.bin, earlier ones in cache.ets.
    for rel <- ["cache.ets", "cache.bin", "packages/hexpm/fine-0.2.0.tar"],
        File.exists?(Path.join(src, rel)) do
      File.cp!(Path.join(src, rel), Path.join(home, rel))
    end

    home
  end

  defp child_env(base, hex_home) do
    [
      {"MIX_ENV", "dev"},
      {"MIX_TARGET", nil},
      {"MIX_BUILD_ROOT", nil},
      {"MIX_BUILD_PATH", nil},
      {"MIX_DEPS_PATH", nil},
      {"MIX_TEST_PARTITION", nil},
      {"PRECOMPILED", nil},
      {"PRECOMPILED_HOME", Path.join(base, "precompiled-home")},
      {"HEX_HOME", hex_home},
      {"HEX_OFFLINE", "1"}
    ]
  end

  # Offline first; a cache another Hex version wrote reads as empty, and
  # then the command runs once online, into the same private HEX_HOME.
  defp mix!(proj, args, env) do
    {out, status} = System.cmd("mix", args, cd: proj, stderr_to_stdout: true, env: env)

    {out, status} =
      if status != 0 and out =~ "is not cached locally" do
        online = List.keystore(env, "HEX_OFFLINE", 0, {"HEX_OFFLINE", nil})
        System.cmd("mix", args, cd: proj, stderr_to_stdout: true, env: online)
      else
        {out, status}
      end

    assert status == 0, "mix #{Enum.join(args, " ")} exited #{status}:\n" <> out
    out
  end

  # A child project; with `config`, one that runs the client before Mix
  # loads its dependencies, as a user's project does.
  defp project!(dir, deps, config \\ nil) do
    File.mkdir_p!(Path.join(dir, "config"))

    aliases =
      if config,
        do:
          ~s(["deps.loadpaths": ["deps.compile precompiled", "precompiled.deps", "deps.loadpaths"]]),
        else: "[]"

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule RelocE2E.MixProject do
      use Mix.Project

      def project do
        [app: :reloc_e2e, version: "0.1.0", deps: #{deps}, aliases: #{aliases}]
      end
    end
    """)

    File.write!(Path.join(dir, "config/config.exs"), "import Config\n" <> (config || ""))
    dir
  end

  defp slots(proj),
    do: %{"deps" => Path.join(proj, "deps"), "build" => Path.join(proj, "_build/dev")}

  defp fine_beam(proj),
    do: File.read!(Path.join(proj, "_build/dev/lib/fine/ebin/Elixir.Fine.beam"))

  # `beam` with its CInf `source` set to `source`.
  defp with_source(beam, source) do
    {:ok, _module, chunks} = :beam_lib.all_chunks(beam)
    {~c"CInf", cinf} = List.keyfind(chunks, ~c"CInf", 0)

    info =
      cinf
      |> :erlang.binary_to_term()
      |> List.keystore(:source, 0, {:source, String.to_charlist(source)})

    chunks = List.keystore(chunks, ~c"CInf", 0, {~c"CInf", :erlang.term_to_binary(info)})
    {:ok, bytes} = :beam_lib.build_module(chunks)
    bytes
  end

  defp stripped(beam) do
    {:ok, {_, plain}} = :beam_lib.strip(beam)
    {:ok, _, chunks} = :beam_lib.all_chunks(plain)
    {:ok, _, all} = :beam_lib.all_chunks(beam)
    chunks ++ [List.keyfind(all, ~c"Attr", 0)]
  end

  defp blob(bytes), do: {Base.encode16(:crypto.hash(:sha256, bytes), case: :lower), bytes}

  defp entry(path, {sha, bytes}),
    do: %{"path" => path, "sha256" => sha, "size" => byte_size(bytes), "mode" => 33_188}

  test "a relocated build at the real roots installs, relocated to the user's paths", ctx do
    %{base: base, client: client, port: port} = ctx

    if String.to_integer(System.otp_release()) < 28,
      do: flunk("relocated builds need OTP 28 or later")

    hex_home = hex_home!(base)
    env = child_env(base, hex_home)

    # The builder: fine compiled from source.
    builder = project!(Path.join(base, "builder"), ~s([{:fine, "== 0.2.0"}]))
    mix!(builder, ["deps.get"], env)
    mix!(builder, ["deps.compile", "fine"], env)
    {:ok, lock} = File.read(Path.join(builder, "mix.lock"))
    {%{fine: {:hex, :fine, "0.2.0", _inner, _, _, "hexpm", outer}}, _} = Code.eval_string(lock)

    # Moved to the worker's first root, as the worker's compile there writes it.
    first = Relocation.first_root()
    built = fine_beam(builder)
    {:ok, occs} = Relocation.occurrences(built, slots(builder))
    {:ok, moved} = Relocation.relocate(built, occs, slots(builder), first)
    served = with_source(moved, Path.join(first["deps"], "fine/lib/fine.ex"))
    {:ok, [occ]} = Relocation.occurrences(served, first)
    assert occ["parts"] == ["", "deps", "/fine/c_include"]

    record =
      7
      |> Relocation.pinned_record()
      |> Map.put("files", [%{"path" => "ebin/Elixir.Fine.beam", "occurrences" => [occ]}])

    assert Relocation.pinned_problem(record) == nil

    beam = blob(served)
    app = blob(File.read!(Path.join(builder, "_build/dev/lib/fine/ebin/fine.app")))
    files = Path.join(base, "files")
    File.mkdir_p!(files)
    for {sha, bytes} <- [beam, app], do: File.write!(Path.join(files, sha), bytes)

    result = %{
      "scope" => "toolchain",
      "finished_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "package" => %{"name" => "fine", "version" => "0.2.0"},
      "systems" => %{},
      "toolchain_build" => %{
        "status" => "pass",
        "reason" => nil,
        "elixir" => System.version(),
        "otp" => System.otp_release(),
        "deps_lock" => %{},
        "package_checksum" => outer,
        "compile_env" => [],
        "compile_env_rule" => 1,
        "config_variant" => "default",
        "relocation" => record,
        "relocated_file_manifest" => %{
          "ebin" => [entry("ebin/Elixir.Fine.beam", beam), entry("ebin/fine.app", app)],
          "priv" => []
        },
        "file_manifest" => nil
      }
    }

    assert {:ok, %{status: :pass, relocation: ^record}} =
             Ingestion.ingest_toolchain(result, %{
               package: "fine",
               version: "0.2.0",
               run_id: "e2e-reloc-#{System.unique_integer([:positive])}",
               image_digest: "sha256:e2e",
               files_dir: files,
               output_dir: files,
               toolchain: Portal.Toolchains.from_versions(System.version(), System.otp_release()),
               builder_version: 1,
               config_variant: "default"
             })

    assert {:ok, _batch} = Batches.build_and_sign()

    # The user's project, on the builder's lock, with this portal and root.
    config = """
    config :precompiled,
      source: "http://127.0.0.1:#{port}/api/precompiled",
      root: #{inspect(ctx.root_path)}
    """

    deps = ~s([{:fine, "== 0.2.0"}, {:precompiled, path: #{inspect(client)}, runtime: false}])
    user = project!(Path.join(base, "home/someone/projects/app"), deps, config)
    File.write!(Path.join(user, "mix.lock"), lock)
    mix!(user, ["deps.get"], env)

    out = mix!(user, ["compile"], env)
    assert out =~ ~r/precompiled: fine 0\.2\.0\s+HIT/, out
    refute out =~ ~r/==> fine\n/, out

    include =
      mix!(user, ["run", "--no-start", "-e", ~s|IO.puts("include=" <> Fine.include_dir())|], env)

    assert include =~ "include=" <> Path.join(user, "deps/fine/c_include")

    # The proof: Mix's own compile of fine at the same paths.
    installed = fine_beam(user)
    refute installed == served
    File.rm_rf!(Path.join(user, "_build/dev/lib/fine"))

    mix!(
      user,
      ["deps.compile", "fine"],
      List.keystore(env, "PRECOMPILED", 0, {"PRECOMPILED", "0"})
    )

    own = fine_beam(user)
    assert stripped(installed) == stripped(own)
    assert :beam_lib.md5(installed) == :beam_lib.md5(own)
  end
end
