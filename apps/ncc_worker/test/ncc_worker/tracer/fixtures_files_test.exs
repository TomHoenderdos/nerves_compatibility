defmodule NccWorker.Tracer.FixturesFilesTest do
  # Fixture suite B (spec section 9): files, writes, install locations,
  # native code and R2. Independent path dependencies of one project,
  # compiled once under the real tracer and judged one by one. Expected
  # verdicts come from the spec and the controller's rulings; a publishable
  # fixture that refuses is a finding about the tracer, not a test to loosen.
  #
  # Every refusal is matched to its owner (ruling M7), so a verdict cannot
  # pass on an observation from another fixture's window.
  use ExUnit.Case, async: true

  alias NccWorker.{Portability, TracerFixtures}

  import NccWorker.TracerFixtures, only: [lib: 2, lib: 3, attr_module: 2, erl_module: 1]

  @moduletag timeout: 600_000

  @cnj "portability could not be judged"
  @write "compile-time write outside ebin: "

  # Every kind of write a compile can make outside its own ebin. The first
  # is the shape Phoenix.LiveView.ColocatedAssets writes (Task 19 runs the
  # real one).
  @writes %{
    "fx_w_colocated" =>
      ~S|(dir = Path.join([Mix.Project.build_path(), "phoenix-colocated", "fx_w_colocated"]); File.mkdir_p!(dir); File.write!(Path.join(dir, "hooks.js"), "x"))|,
    "fx_w_write" => ~S|File.write!(Path.join(__DIR__, "../out.txt"), "x")|,
    "fx_w_ln" => ~S|File.ln_s(Path.join(__DIR__, "fx_w_ln.ex"), Path.join(__DIR__, "../link"))|,
    "fx_w_cp" => ~S|File.cp!(Path.join(__DIR__, "fx_w_cp.ex"), Path.join(__DIR__, "../copy.ex"))|,
    "fx_w_rename" =>
      ~S|(File.write!(Path.join([Mix.Project.app_path(), "ebin", "r.txt"]), "x"); File.rename(Path.join([Mix.Project.app_path(), "ebin", "r.txt"]), Path.join(__DIR__, "../moved.txt")))|,
    "fx_w_touch" => ~S|File.touch!(Path.join(__DIR__, "../touched"))|,
    "fx_w_append" =>
      ~S|(f = String.to_charlist(Path.join(__DIR__, "../appended")); {:ok, io} = :file.open(f, [:append]); :file.close(io))|
  }

  @deps Map.merge(
          %{
            "fx_hosts" => lib("fx_hosts", attr_module("FxHosts", ~S|File.read!("/etc/hosts")|)),
            "fx_lock" =>
              lib(
                "fx_lock",
                attr_module("FxLock", ~S|File.read!(Path.expand("../../../mix.lock", __DIR__))|)
              ),
            "fx_cfg" =>
              lib(
                "fx_cfg",
                attr_module(
                  "FxCfg",
                  ~S|File.read!(Path.expand("../../../config/config.exs", __DIR__))|
                )
              ),
            "fx_link" =>
              lib(
                "fx_link",
                attr_module("FxLink", ~S|File.read!(Path.join(__DIR__, "hosts_link"))|),
                %{links: %{"lib/hosts_link" => "/etc/hosts"}}
              ),
            "fx_assets" => %{
              files: %{
                "priv/static/a.js" => "// asset\n",
                "lib/fx_assets.ex" => "defmodule FxAssets do\nend\n"
              }
            },
            "fx_app_dir" =>
              lib(
                "fx_app_dir",
                attr_module(
                  "FxAppDir",
                  ~S|File.read!(Application.app_dir(:fx_assets, "priv/static/a.js"))|
                ),
                %{deps: ["fx_assets"]}
              ),
            "fx_app_dir_other" =>
              lib(
                "fx_app_dir_other",
                attr_module("FxAppDirOther", ~S|:code.lib_dir(:not_a_real_app)|)
              ),
            "fx_prim" =>
              lib("fx_prim", attr_module("FxPrim", ~S|:prim_file.read_file("/etc/hosts")|)),
            "fx_loader" =>
              lib(
                "fx_loader",
                attr_module("FxLoader", ~S|:erl_prim_loader.get_file(~c"/etc/hosts")|)
              ),
            "fx_crypto" => lib("fx_crypto", attr_module("FxCrypto", ~S|:crypto.info_lib()|)),
            "fx_nif" =>
              lib(
                "fx_nif",
                attr_module(
                  "FxNif",
                  ~S|(try do :erlang.load_nif(~c"/nonexistent/nif", 0) rescue _ -> :error end)|
                )
              ),
            "fx_w_ebin" =>
              lib(
                "fx_w_ebin",
                attr_module(
                  "FxWEbin",
                  ~S|File.write!(Path.join([Mix.Project.app_path(), "ebin", "extra.txt"]), "x")|
                )
              ),
            # Task 6 ruling: a link made inside the package's own ebin, read
            # through and removed again, leaves only a read of an ebin path
            # for the judge to resolve after the build. The link refuses.
            "fx_ebin_link" =>
              lib(
                "fx_ebin_link",
                attr_module(
                  "FxEbinLink",
                  ~S|(l = Path.join([Mix.Project.app_path(), "ebin", "h"]); File.ln_s!("/etc/hosts", l); v = File.read!(l); File.rm!(l); v)|
                )
              ),
            # Task 6 ruling: a user set_cwd refuses, even one Mix-style
            # File.cd!/2 puts back.
            "fx_cd" =>
              lib(
                "fx_cd",
                attr_module("FxCd", ~S|File.cd!(Path.join(__DIR__, ".."), fn -> 1 end)|)
              ),
            "fx_r2" => lib("fx_r2", attr_module("FxR2", ~S|Path.expand("..", __DIR__)|)),
            # Task 9 ruling: a bare literal that is a closure source file's
            # real path is an observation; under priv/ or test/ it refuses,
            # and a _build/<env>/lib/<d>/priv spelling is allowed only as an
            # @external_resource.
            "fx_r2_src" => lib("fx_r2_src", attr_module("FxR2Src", "__ENV__.file")),
            "fx_r2_priv" => %{
              files: %{
                "priv/data.ex" => "# data\n",
                "lib/fx_r2_priv.ex" =>
                  attr_module("FxR2Priv", ~S|Path.expand("../priv/data.ex", __DIR__)|)
              }
            },
            "fx_r2_test" => %{
              files: %{
                "test/helper.exs" => "# helper\n",
                "lib/fx_r2_test.ex" =>
                  attr_module("FxR2Test", ~S|Path.expand("../test/helper.exs", __DIR__)|)
              }
            },
            "fx_r2_ext" => %{
              files: %{
                "priv/data.txt" => "data\n",
                "lib/fx_r2_ext.ex" => """
                defmodule FxR2Ext do
                  @external_resource Path.join([Mix.Project.app_path(), "priv", "data.txt"])
                  def x, do: :ok
                end
                """
              }
            },
            "fx_r2_build_priv" => %{
              files: %{
                "priv/data.txt" => "data\n",
                "lib/fx_r2_build_priv.ex" =>
                  attr_module(
                    "FxR2BuildPriv",
                    ~S|Path.join([Mix.Project.app_path(), "priv", "data.txt"])|
                  )
              }
            },
            # Task 9 ruling: an ebin that is gone by the time R2 reads it
            # could not be judged (setup removes it after the compile).
            "fx_no_ebin" => lib("fx_no_ebin", "defmodule FxNoEbin do\nend\n"),
            # Task 8 ruling: running a program from a dependency's mix.exs
            # refuses, whatever key the result reaches.
            "fx_mix_exec" =>
              lib("fx_mix_exec", "defmodule FxMixExec do\nend\n", %{
                mix_exs: """
                defmodule FxMixExec.MixProject do
                  use Mix.Project
                  def project, do: [app: :fx_mix_exec, version: "0.1.0", description: describe()]
                  defp describe, do: elem(System.cmd("true", []), 0)
                end
                """
              }),
            "fx_nat" => %{
              files: %{
                "lib/fx_nat.ex" => "defmodule FxNat do\n  def value, do: 42\nend\n",
                "Makefile" => "all:\n\t@true\n",
                "c_src/fx_nat.c" => "int fx_nat;\n"
              }
            },
            "fx_nat_compile" =>
              lib("fx_nat_compile", attr_module("FxNatCompile", "FxNat.value()"), %{
                deps: ["fx_nat"]
              }),
            "fx_nat_runtime" =>
              lib(
                "fx_nat_runtime",
                "defmodule FxNatRuntime do\n  def v, do: FxNat.value()\nend\n",
                %{deps: ["fx_nat"]}
              ),
            # A rebar3-built native dependency (c_src): rebar3 compiles in
            # its own VM, the call into it happens in the Mix package's.
            "fx_r3_nat" => %{
              manager: :rebar3,
              files: %{
                "src/fx_r3_nat.erl" => erl_module("fx_r3_nat"),
                "c_src/fx_r3_nat.c" => "int fx_r3_nat;\n"
              }
            },
            "fx_r3_nat_compile" =>
              lib("fx_r3_nat_compile", attr_module("FxR3NatCompile", ":fx_r3_nat.f()"), %{
                deps: ["fx_r3_nat"]
              })
          },
          Map.new(@writes, fn {app, expr} ->
            {app, lib(app, attr_module(Macro.camelize(app), expr))}
          end)
        )

  setup_all do
    # The real path of the temp dir: on macOS it sits under the /var ->
    # /private/var link, where Mix writes a dependency's _build priv link
    # with one `..` too many, and the priv fixtures read through it. The
    # worker's work dir is a real path.
    tmp = Portability.Context.realpath(System.tmp_dir!())
    root = Path.join(tmp, "ncc-fixtures-files-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)

    # Without a verified Hex file list no source file of a dependency is
    # readable (spec R1 "Files", Task 6 ruling), so the dependencies whose
    # files are read get the release a Hex dependency would have.
    hex_home = Path.join(root, "hex")

    releases =
      Map.new([
        TracerFixtures.hex_release(hex_home, "fx_assets", ["lib", "mix.exs", "priv"])
      ])

    apps = Map.keys(@deps)
    proj = TracerFixtures.project(root, apps, @deps)
    File.write!(Path.join(proj, "mix.lock"), "%{}\n")
    File.mkdir_p!(Path.join(proj, "config"))
    File.write!(Path.join(proj, "config/config.exs"), "import Config\n")
    native = Portability.native_deps(proj)
    traced = TracerFixtures.trace(proj, apps, native: native)
    File.rm_rf!(Path.join(proj, "_build/host/lib/fx_no_ebin/ebin"))

    %{
      proj: proj,
      native: native,
      traced: traced,
      judge_opts: [releases: releases, hex_home: hex_home]
    }
  end

  defp verdict(ctx, app),
    do: TracerFixtures.judge(ctx.proj, app, ctx.traced, ctx.native, ctx.judge_opts)

  defp refusals(ctx, app),
    do:
      for(%{"owner" => ^app, "reason" => r} <- verdict(ctx, app).observations["refusals"], do: r)

  # A refusal of `app` whose reason is one of `app`'s own refusals (ruling M7).
  defp refused(ctx, app) do
    assert %{status: :skip, reason: reason, observations: %{"refusals" => refusals}} =
             v = verdict(ctx, app)

    assert Enum.any?(refusals, &(&1 == %{"owner" => app, "reason" => reason})),
           "#{app}: #{inspect(v, pretty: true)}"

    reason
  end

  # A refusal through R2 or the closure, which is not an event refusal: no
  # event refusal of `app` may stand behind it.
  defp skipped(ctx, app) do
    assert %{status: :skip, reason: reason} = v = verdict(ctx, app)
    assert refusals(ctx, app) == [], "#{app}: #{inspect(v, pretty: true)}"
    {reason, v}
  end

  # The events of an MFA starting with `mfa` in `app`'s window whose argument path ends with `suffix`:
  # a pass is only worth something when the call it allows was traced.
  defp seen(ctx, app, mfa, suffix) do
    windows = Enum.filter(ctx.traced.report.windows, &(&1.app == app))

    Enum.filter(ctx.traced.report.events, fn e ->
      is_binary(e["mfa"]) and String.starts_with?(e["mfa"], mfa) and is_binary(e["arg"]["path"]) and
        String.ends_with?(e["arg"]["path"], suffix) and
        Enum.any?(windows, &(e["ts"] >= &1.open and e["ts"] <= &1.close))
    end)
  end

  defp passes(ctx, app) do
    v = verdict(ctx, app)
    assert %{status: :pass} = v, "#{app}: #{inspect(v.observations, pretty: true)}"
    v
  end

  test "the traced compile completed and found the native fixtures", ctx do
    assert {:ok, 0} = ctx.traced.result, ctx.traced.log
    assert %{"status" => "ok"} = ctx.traced.report.ending
    assert ctx.traced.report.problems == []
    assert "fx_nat" in ctx.native
    assert "fx_r3_nat" in ctx.native
    refute "fx_assets" in ctx.native
  end

  test "reads outside the closure refuse: host files, the consumer's lock and config, a symlink out",
       ctx do
    for app <- ["fx_hosts", "fx_lock", "fx_cfg", "fx_link"] do
      assert "compile-time host read: file:read_file/" <> _ = refused(ctx, app)
    end
  end

  test "reads below file, the loader and the crypto build refuse", ctx do
    assert "compile-time host read: prim_file:read_file/1" <> _ = refused(ctx, "fx_prim")
    assert "compile-time host read: erl_prim_loader:get_file/1" <> _ = refused(ctx, "fx_loader")
    assert "compile-time host read: crypto:info_lib/0" <> _ = refused(ctx, "fx_crypto")
  end

  # FINDING (Task 12): erlang:load_nif/2 is never traced. No call trace
  # pattern on it fires, global or local, called directly or through a
  # dynamic M:F call, on OTP 28 and 29 (the emulator handles it specially).
  # The dlopen of a host library (C code running on the host at compile
  # time) leaves no event and fx_nif passes. The controller decides the fix;
  # until then this pins the spec's verdict.
  @tag skip: "finding: erlang:load_nif/2 is untraceable (Task 12 report)"
  test "loading a NIF at compile time refuses", ctx do
    assert "compile-time host read: erlang:load_nif/2" <> _ = refused(ctx, "fx_nif")
  end

  test "Application.app_dir of a closure app is allowed; another app's lib dir refuses", ctx do
    passes(ctx, "fx_app_dir")
    assert [_ | _] = seen(ctx, "fx_app_dir", "file:read_file/", "fx_assets/priv/static/a.js")
    assert "compile-time host read: code:lib_dir/1" <> _ = refused(ctx, "fx_app_dir_other")
  end

  test "without its verified Hex file list, the closure app's priv file refuses", ctx do
    v = TracerFixtures.judge(ctx.proj, "fx_app_dir", ctx.traced, ctx.native, releases: %{})
    assert %{status: :skip, reason: "compile-time host read: file:read_file/" <> _ = reason} = v
    assert %{"owner" => "fx_app_dir", "reason" => reason} in v.observations["refusals"]
    assert reason =~ "fx_assets/priv/static/a.js"
  end

  test "every kind of write outside the package's own ebin refuses", ctx do
    for app <- Map.keys(@writes) do
      assert %{status: :skip} = verdict(ctx, app), app
      assert Enum.any?(refusals(ctx, app), &String.starts_with?(&1, @write)), app
    end

    assert Enum.any?(refusals(ctx, "fx_w_colocated"), &(&1 =~ "phoenix-colocated/fx_w_colocated"))
    assert Enum.any?(refusals(ctx, "fx_w_ln"), &(&1 =~ "(a link)"))
  end

  test "a write into the package's own ebin is allowed", ctx do
    passes(ctx, "fx_w_ebin")
    assert [_ | _] = seen(ctx, "fx_w_ebin", "file:write_file/", "fx_w_ebin/ebin/extra.txt")
  end

  test "a link made, read through and removed inside the package's own ebin refuses", ctx do
    assert @write <> "file:make_symlink/2 " <> rest = refused(ctx, "fx_ebin_link")
    assert rest =~ "fx_ebin_link/ebin/h (a link)"
  end

  test "changing the working directory refuses", ctx do
    # File.cd!/2 reads the directory first, and a window with a user
    # set_cwd resolves no relative path (Context.cwd/2), so that get_cwd
    # refuses first; the set_cwd refuses on its own.
    assert "compile-time host read: file:get_cwd/0" <> _ = refused(ctx, "fx_cd")

    assert Enum.any?(
             refusals(ctx, "fx_cd"),
             &String.starts_with?(&1, "compile-time host read: file:set_cwd/1 ")
           )
  end

  test "a directory baked into a literal refuses through R2", ctx do
    assert {"bakes the build path: Elixir.FxR2 " <> _, _} = skipped(ctx, "fx_r2")
  end

  test "a bare closure source path is observed, not refused (R2)", ctx do
    v = passes(ctx, "fx_r2_src")

    assert [%{"owner" => "fx_r2_src", "path" => path}] =
             v.observations["build_root_source_path"]

    assert path =~ "deps/fx_r2_src/lib/fx_r2_src.ex"
  end

  test "a source path under priv/ or test/ refuses (R2)", ctx do
    assert {"bakes the build path: Elixir.FxR2Priv " <> _, _} = skipped(ctx, "fx_r2_priv")
    assert {"bakes the build path: Elixir.FxR2Test " <> _, _} = skipped(ctx, "fx_r2_test")
  end

  test "a _build priv spelling is allowed as @external_resource, nowhere else (R2)", ctx do
    passes(ctx, "fx_r2_ext")

    assert {"bakes the build path: Elixir.FxR2BuildPriv " <> _, _} =
             skipped(ctx, "fx_r2_build_priv")
  end

  test "an ebin R2 cannot read could not be judged", ctx do
    assert {@cnj, v} = skipped(ctx, "fx_no_ebin")
    assert Enum.any?(v.observations["problems"], &String.starts_with?(&1, "fx_no_ebin: R2: "))
  end

  test "running a program from a dependency's mix.exs refuses", ctx do
    assert "compile-time host read: erlang:open_port/2" <> _ =
             reason = refused(ctx, "fx_mix_exec")

    assert reason =~ "mix.exs"
  end

  test "calling a natively built dependency at compile time refuses; at runtime it does not",
       ctx do
    assert "calls natively built dependency at compile time: FxNat.value/0" =
             refused(ctx, "fx_nat_compile")

    passes(ctx, "fx_nat_runtime")
  end

  test "calling a rebar3-built native dependency at compile time refuses", ctx do
    assert "calls natively built dependency at compile time: fx_r3_nat:f/0" =
             refused(ctx, "fx_r3_nat_compile")
  end
end
