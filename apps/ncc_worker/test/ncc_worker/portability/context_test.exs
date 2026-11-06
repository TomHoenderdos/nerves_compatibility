defmodule NccWorker.Portability.ContextTest do
  use ExUnit.Case, async: true

  alias NccWorker.Portability.Context
  alias NccWorker.Tracer.Report

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    proj = Path.join(dir, "proj")
    pkg = Path.join([proj, "deps", "pkg"])
    nat = Path.join([proj, "deps", "nat"])

    for d <- [
          Path.join(pkg, "lib/sub"),
          Path.join(pkg, "priv"),
          Path.join(nat, "priv"),
          Path.join(proj, "_build/host/lib/pkg/ebin"),
          Path.join(proj, "_build/host/lib/nat/ebin")
        ],
        do: File.mkdir_p!(d)

    for f <- [
          Path.join(pkg, "lib/sub/a.ex"),
          Path.join(pkg, "README.md"),
          Path.join(pkg, "gen.hrl"),
          Path.join(pkg, "priv/data.txt"),
          Path.join(nat, "priv/x.so"),
          Path.join(nat, "mix.exs"),
          Path.join(proj, "mix.exs")
        ],
        do: File.write!(f, "")

    File.ln_s!(Path.join(pkg, "README.md"), Path.join(proj, "_build/host/lib/pkg/readme"))
    File.ln_s!(Path.join(pkg, "priv"), Path.join(proj, "_build/host/lib/pkg/priv"))

    # What deps/<d> claims is ignored: an untraced build step can rewrite it.
    File.write!(
      Path.join(pkg, "hex_metadata.config"),
      ~s({<<"files">>,[<<"lib">>,<<"README.md">>,<<"priv">>,<<"gen.hrl">>]}.\n)
    )

    report = report(dir, proj, ["pkg"])
    ctx = build(dir, proj, "pkg", report)
    %{dir: dir, proj: proj, report: report, ctx: ctx}
  end

  @metas %{
    "pkg" => ~s({<<"files">>,[<<"lib">>,<<"README.md">>,<<"priv">>]}.\n),
    "nat" => ~s({<<"files">>,[<<"priv/x.so">>,<<"mix.exs">>]}.\n)
  }

  # Lays out a HEX_HOME with one tarball per app (Hex name `<app>_hex`) and
  # the lock entries that verify them, then builds the context.
  defp build(dir, proj, package, report, opts \\ []) do
    metas = Map.merge(@metas, Keyword.get(opts, :metas, %{}))
    home = Path.join(dir, "hex-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "packages/hexpm"))

    releases =
      Map.new(metas, fn {app, meta} ->
        bytes = tarball([{"VERSION", "3"}, {"metadata.config", meta}])
        File.write!(Path.join(home, "packages/hexpm/#{app}_hex-1.0.0.tar"), bytes)
        sum = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
        {app, %{name: "#{app}_hex", version: "1.0.0", checksum: sum}}
      end)

    releases = Map.merge(releases, Keyword.get(opts, :releases, %{}))

    Context.build(proj, package, report, Keyword.get(opts, :native, ["nat"]),
      hex_home: home,
      releases: releases
    )
  end

  defp tarball(members) do
    path = Path.join(System.tmp_dir!(), "ncc-ctx-#{System.unique_integer([:positive])}.tar")
    :ok = :erl_tar.create(String.to_charlist(path), for({n, b} <- members, do: {~c"#{n}", b}))
    bytes = File.read!(path)
    File.rm!(path)
    bytes
  end

  defp report(dir, proj, packages) do
    %Report{
      start: %{"otp_root" => Path.join(dir, "otp"), "elixir_root" => nil, "home" => nil},
      closure: %{
        "packages" => packages,
        "deps" => [
          %{
            "app" => "nat",
            "dest" => Path.join(proj, "deps/nat"),
            "build" => Path.join(proj, "_build/host/lib/nat"),
            "manager" => "mix",
            "children" => []
          },
          %{
            "app" => "pkg",
            "dest" => Path.join(proj, "deps/pkg"),
            "build" => Path.join(proj, "_build/host/lib/pkg"),
            "manager" => "mix",
            "children" => ["nat"]
          }
        ]
      },
      windows: [
        %{app: "nat", open: 10, close: 20, depth_ok: true},
        %{app: "pkg", open: 30, close: 40, depth_ok: true}
      ],
      quiet: [%{open: 21, close: 22}]
    }
  end

  defp readable?(ctx, path, owner), do: Context.readable?(ctx, Context.resolve(ctx, path, owner))

  test "files the Hex tarball lists are readable, listed directories included", %{ctx: ctx} do
    assert readable?(ctx, "lib/sub/a.ex", "pkg")
    assert readable?(ctx, "README.md", "pkg")
    assert readable?(ctx, "lib", "pkg")
    refute readable?(ctx, "gen.hrl", "pkg")
    refute readable?(ctx, "../../mix.exs", "pkg")
    refute readable?(ctx, "/etc/hosts", "pkg")
  end

  test "a build-dir symlink resolves into the dependency's files", %{ctx: ctx, proj: proj} do
    link = Path.join(proj, "_build/host/lib/pkg/readme")

    assert Context.resolve(ctx, link, :outside) ==
             Context.realpath(Path.join(proj, "deps/pkg/README.md"))

    assert Context.readable?(ctx, Context.resolve(ctx, link, :outside))
  end

  test "a symlinked _build priv resolves to deps priv and is readable when listed",
       %{ctx: ctx, proj: proj} do
    path = Path.join(proj, "_build/host/lib/pkg/priv/data.txt")

    assert Context.resolve(ctx, path, :outside) ==
             Context.realpath(Path.join(proj, "deps/pkg/priv/data.txt"))

    assert readable?(ctx, path, :outside)
  end

  test "a native dependency's priv and build dir are not readable", %{ctx: ctx, proj: proj} do
    refute readable?(ctx, "priv/x.so", "nat")
    refute readable?(ctx, Path.join(proj, "_build/host/lib/nat/ebin"), :outside)
    assert readable?(ctx, "mix.exs", "nat")
    assert readable?(ctx, Path.join(proj, "_build/host/lib/pkg/ebin"), :outside)
  end

  test "a write is allowed only into the window's own ebin", %{ctx: ctx, proj: proj} do
    assert Context.writable?(ctx, Path.join(proj, "_build/host/lib/pkg/ebin/x.txt"), "pkg")
    refute Context.writable?(ctx, Path.join(proj, "_build/host/lib/pkg/ebin/x.txt"), "nat")

    refute Context.writable?(
             ctx,
             Path.join(proj, "_build/host/phoenix-colocated/pkg/a.js"),
             "pkg"
           )

    refute Context.writable?(ctx, Path.join(proj, "_build/host/lib/pkg/ebin/x.txt"), :outside)
    refute Context.writable?(ctx, nil, "pkg")
  end

  test "events belong to the window or quiet interval their timestamp falls in", %{ctx: ctx} do
    assert Context.owner(ctx, %{"ts" => 15}) == "nat"
    assert Context.owner(ctx, %{"ts" => 21}) == :quiet
    assert Context.owner(ctx, %{"ts" => 35}) == "pkg"
    assert Context.owner(ctx, %{"ts" => 50}) == :outside
    assert Context.owner(ctx, %{}) == :outside
  end

  test "a frame in a mix.exs belongs to its dependency, or to the wrapper",
       %{ctx: ctx, proj: proj} do
    nat_mix = %{"ts" => 50, "user" => %{"file" => Path.join(proj, "deps/nat/mix.exs")}}
    assert Context.owner(ctx, nat_mix) == "nat"

    assert Context.mix_exs(ctx, nat_mix, "nat") ==
             Context.realpath(Path.join(proj, "deps/nat/mix.exs"))

    wrapper = %{"ts" => 50, "user" => %{"file" => Path.join(proj, "mix.exs")}}
    assert Context.owner(ctx, wrapper) == :wrapper
    assert Context.mix_exs(ctx, wrapper, :wrapper) == nil

    relative = %{"ts" => 15, "user" => %{"file" => "mix.exs"}}

    assert Context.mix_exs(ctx, relative, "nat") ==
             Context.realpath(Path.join(proj, "deps/nat/mix.exs"))

    assert Context.mix_exs(ctx, relative, :outside) == nil
    assert Context.mix_exs(ctx, %{"user" => %{"file" => "../nat/mix.exs"}}, "pkg") == nil
  end

  test "closure_of follows children; closure_file? takes only regular closure files",
       %{ctx: ctx, proj: proj} do
    assert Context.closure_of(ctx, "pkg") == ["nat", "pkg"]
    assert Context.closure_of(ctx, "nat") == ["nat"]
    assert Context.closure_of(ctx, "other") == []
    assert Context.closure_file?(ctx, Path.join(proj, "deps/pkg/README.md"))
    refute Context.closure_file?(ctx, Path.join(proj, "deps/pkg"))
    refute Context.closure_file?(ctx, "lib/x.ex")
    refute Context.closure_file?(ctx, Path.join(proj, "mix.exs"))
    refute Context.closure_file?(ctx, :not_a_string)
  end

  test "accessors answer nil for an app outside the closure", %{ctx: ctx, proj: proj} do
    assert Context.dest(ctx, "pkg") == Context.realpath(Path.join(proj, "deps/pkg"))

    assert Context.ebin(ctx, "pkg") ==
             Context.realpath(Path.join(proj, "_build/host/lib/pkg/ebin"))

    assert Context.manager(ctx, "pkg") == "mix"
    assert Context.cwd(ctx, "pkg") == Context.realpath(Path.join(proj, "deps/pkg"))
    assert Context.cwd(ctx, :outside) == nil
    assert Context.dest(ctx, "other") == nil
    assert Context.ebin(ctx, "other") == nil
    assert Context.manager(ctx, "other") == nil
    refute Context.dep?(ctx, :outside)
  end

  describe "the package as an OTP app" do
    test "a Hex name that is not the app name resolves through the closure's packages",
         %{dir: dir, proj: proj} do
      ctx = build(dir, proj, "pkg_hex", report(dir, proj, ["pkg"]), native: [])
      assert ctx.package == "pkg"
      assert Context.dep?(ctx, ctx.package)
    end

    test "a package the closure does not name is no dependency", %{dir: dir, proj: proj} do
      ctx = build(dir, proj, "pkg_hex", report(dir, proj, ["pkg", "nat"]), native: [])
      assert ctx.package == nil
      refute Context.dep?(ctx, ctx.package)

      ctx = build(dir, proj, "pkg", %Report{}, native: [])
      assert ctx.package == nil
      assert ctx.deps == %{}
    end

    test "a package named by app keeps its name", %{ctx: ctx} do
      assert ctx.package == "pkg"
    end
  end

  describe "path safety" do
    test "a sibling whose name extends a dependency's is not that dependency",
         %{ctx: ctx, proj: proj} do
      evil = Path.join(proj, "deps/pkg-evil/lib")
      File.mkdir_p!(evil)
      File.write!(Path.join(evil, "a.ex"), "")
      File.mkdir_p!(Path.join(proj, "_build/host/lib/pkg-evil/ebin"))

      refute readable?(ctx, Path.join(evil, "a.ex"), :outside)
      refute readable?(ctx, Path.join(proj, "_build/host/lib/pkg-evil/ebin"), :outside)

      refute Context.writable?(ctx, Path.join(proj, "_build/host/lib/pkg/ebin-evil/x"), "pkg")
      refute Context.under?(Path.join(proj, "deps/pkg-evil"), Path.join(proj, "deps/pkg"))
      assert Context.under?(Path.join(proj, "deps/pkg/x"), Path.join(proj, "deps/pkg/"))
    end

    test ".. applies after the symlink before it is followed, as the OS does",
         %{ctx: ctx, proj: proj} do
      outside = Path.join(proj, "outside")
      File.mkdir_p!(Path.join(outside, "sub"))
      File.mkdir_p!(Path.join(outside, "lib/sub"))
      File.write!(Path.join(outside, "lib/sub/a.ex"), "")
      File.ln_s!(Path.join(outside, "sub"), Path.join(proj, "deps/pkg/lnk"))

      assert Context.resolve(ctx, "lnk/../lib/sub/a.ex", "pkg") ==
               Context.realpath(Path.join(outside, "lib/sub/a.ex"))

      refute readable?(ctx, "lnk/../lib/sub/a.ex", "pkg")
      assert readable?(ctx, "lib/../lib/sub/a.ex", "pkg")
    end

    test "a relative symlink is resolved against its own directory", %{ctx: ctx, proj: proj} do
      File.ln_s!("../../../mix.exs", Path.join(proj, "deps/pkg/lib/escape"))

      assert Context.resolve(ctx, "lib/escape", "pkg") ==
               Context.realpath(Path.join(proj, "mix.exs"))

      refute readable?(ctx, "lib/escape", "pkg")
    end

    test "a symlink loop resolves to nothing and is neither readable nor writable",
         %{ctx: ctx, proj: proj} do
      File.ln_s!("loop_b", Path.join(proj, "deps/pkg/lib/loop_a"))
      File.ln_s!("loop_a", Path.join(proj, "deps/pkg/lib/loop_b"))
      assert Context.resolve(ctx, "lib/loop_a", "pkg") == nil
      refute readable?(ctx, "lib/loop_a", "pkg")

      File.ln_s!("loop", Path.join(proj, "_build/host/lib/pkg/ebin/loop"))
      refute Context.writable?(ctx, Path.join(proj, "_build/host/lib/pkg/ebin/loop"), "pkg")
    end

    test "a missing file is judged by its path", %{ctx: ctx, proj: proj} do
      assert readable?(ctx, "lib/missing.ex", "pkg")
      refute readable?(ctx, "missing.ex", "pkg")
      refute readable?(ctx, Path.join(proj, "config/config.exs"), :outside)
      assert Context.resolve(ctx, "/nonexistent/x", "pkg") == "/nonexistent/x"
      refute readable?(ctx, "", "pkg")
    end

    test "a write through ebin that leaves it is refused", %{ctx: ctx, proj: proj} do
      ebin = Path.join(proj, "_build/host/lib/pkg/ebin")
      File.ln_s!(Path.join(proj, "outside/x"), Path.join(ebin, "dangling"))

      refute Context.writable?(ctx, Path.join(ebin, "dangling"), "pkg")
      refute Context.writable?(ctx, Path.join(ebin, "../priv/x"), "pkg")
      refute Context.writable?(ctx, ebin <> "/../../pkg-ebin/x", "pkg")
      assert Context.writable?(ctx, Path.join(ebin, "sub/../y"), "pkg")
    end

    test "a relative path outside every dependency window is unresolvable",
         %{ctx: ctx, proj: proj} do
      for owner <- [:outside, :quiet, :wrapper, "other"] do
        assert Context.resolve(ctx, "mix.exs", owner) == nil
        assert Context.cwd(ctx, owner) == nil
        refute readable?(ctx, "deps/pkg/lib/sub/a.ex", owner)
      end

      assert readable?(ctx, Path.join(proj, "deps/pkg/lib/sub/a.ex"), :quiet)
      assert Context.realpath("relative/x") == nil
      refute Context.writable?(ctx, "ebin/x", :outside)
    end

    test "a relative path in a window that changed directory is unresolvable",
         %{dir: dir, proj: proj, report: report} do
      cd = &%{"kind" => "event", "channel" => "cwd", "ts" => &1, "arg" => %{"path" => "/"}}

      ctx = build(dir, proj, "pkg", %{report | events: [cd.(35)]})
      assert Context.resolve(ctx, "lib/sub/a.ex", "pkg") == nil
      refute readable?(ctx, "lib/sub/a.ex", "pkg")
      refute Context.writable?(ctx, "../../_build/host/lib/pkg/ebin/x", "pkg")
      assert readable?(ctx, Path.join(proj, "deps/pkg/lib/sub/a.ex"), "pkg")
      assert readable?(ctx, "mix.exs", "nat")

      # A cd from the wrapper's mix.exs counts against the window it ran in.
      wrapper = Map.put(cd.(15), "user", %{"file" => Path.join(proj, "mix.exs")})
      ctx = build(dir, proj, "pkg", %{report | events: [wrapper]})
      assert Context.resolve(ctx, "mix.exs", "nat") == nil
      assert readable?(ctx, "lib/sub/a.ex", "pkg")

      # A cd in a dependency's child VM counts against that dependency.
      child = %{start: nil, sentinel?: true, compiles: [], events: [cd.(1)], problems: []}
      ctx = build(dir, proj, "pkg", %{report | children: %{"nat" => child}})
      assert Context.resolve(ctx, "mix.exs", "nat") == nil
      assert readable?(ctx, "lib/sub/a.ex", "pkg")

      # Other channels change nothing.
      read = %{cd.(35) | "channel" => "file_read"}
      ctx = build(dir, proj, "pkg", %{report | events: [read]})
      assert readable?(ctx, "lib/sub/a.ex", "pkg")
    end

    test "case variants do not match", %{ctx: ctx, proj: proj} do
      refute readable?(ctx, Path.join(proj, "DEPS/pkg/lib/sub/a.ex"), :outside)
      refute readable?(ctx, "LIB/sub/a.ex", "pkg")
      refute readable?(ctx, "Priv/x.so", "nat")
    end

    test "the project reached through a symlink resolves to the same real paths",
         %{dir: dir, proj: proj} do
      alias_dir = Path.join(dir, "alias")
      File.ln_s!(proj, alias_dir)
      ctx = build(dir, alias_dir, "pkg", report(dir, alias_dir, ["pkg"]))

      assert ctx.project_dir == Context.realpath(proj)
      assert readable?(ctx, Path.join(proj, "deps/pkg/lib/sub/a.ex"), :outside)
      assert readable?(ctx, Path.join(alias_dir, "deps/pkg/lib/sub/a.ex"), :outside)
      assert Context.writable?(ctx, Path.join(proj, "_build/host/lib/pkg/ebin/x"), "pkg")
    end

    test "hostile Hex file list entries do not widen the list", %{dir: dir, proj: proj} do
      meta =
        ~s({<<"files">>,[<<"..">>,<<"/">>,<<"">>,<<"../../mix.exs">>,<<".">>,{x},<<"./lib/">>]}.\n)

      ctx = build(dir, proj, "pkg", report(dir, proj, ["pkg"]), metas: %{"pkg" => meta})
      assert readable?(ctx, "lib/sub/a.ex", "pkg")
      refute readable?(ctx, "README.md", "pkg")
      refute readable?(ctx, "gen.hrl", "pkg")
      refute readable?(ctx, "../../mix.exs", "pkg")
    end

    test "the list comes from the verified tarball, never from deps/<d>", %{ctx: ctx} do
      # deps/pkg/hex_metadata.config lists gen.hrl; the tarball does not.
      refute readable?(ctx, "gen.hrl", "pkg")
      assert readable?(ctx, "lib/sub/a.ex", "pkg")
    end

    test "a tarball that is missing or does not match the lock allows no source file",
         %{dir: dir, proj: proj, report: report} do
      cases = [
        %{"pkg" => %{name: "pkg_hex", version: "1.0.0", checksum: String.duplicate("0", 64)}},
        %{"pkg" => %{name: "pkg_hex", version: "9.9.9", checksum: String.duplicate("0", 64)}},
        %{"pkg" => %{name: "../pkg_hex", version: "1.0.0", checksum: String.duplicate("0", 64)}}
      ]

      for releases <- cases do
        ctx = build(dir, proj, "pkg", report, releases: releases)
        refute readable?(ctx, "lib/sub/a.ex", "pkg")
        refute readable?(ctx, "README.md", "pkg")
        assert readable?(ctx, Path.join(proj, "_build/host/lib/pkg/ebin"), :outside)
        assert readable?(ctx, "mix.exs", "nat")
      end
    end

    test "no lock entry or no Hex home allows no source file", %{proj: proj, report: report} do
      ctx = Context.build(proj, "pkg", report, ["nat"], hex_home: nil, releases: %{})
      refute readable?(ctx, "lib/sub/a.ex", "pkg")
      refute readable?(ctx, "mix.exs", "nat")

      ctx =
        Context.build(proj, "pkg", report, ["nat"], hex_home: "/nonexistent", releases: :error)

      refute readable?(ctx, "lib/sub/a.ex", "pkg")
    end

    test "the install roots allow reads, but never the filesystem root", %{dir: dir, proj: proj} do
      otp = Path.join(dir, "otp/lib/kernel/ebin")
      File.mkdir_p!(otp)
      ctx = build(dir, proj, "pkg", report(dir, proj, ["pkg"]))
      assert readable?(ctx, Path.join(otp, "kernel.app"), :outside)
      refute readable?(ctx, Path.join(dir, "otp-evil/x"), :outside)

      root = %{
        report(dir, proj, ["pkg"])
        | start: %{"otp_root" => "/", "elixir_root" => "relative"}
      }

      ctx = build(dir, proj, "pkg", root)
      assert ctx.otp_root == nil
      assert ctx.elixir_root == nil
      refute readable?(ctx, "/etc/hosts", :outside)
      refute Context.under?("/etc/hosts", "/")
    end
  end
end
