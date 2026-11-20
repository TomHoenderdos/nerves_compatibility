defmodule NccWorker.Portability.ForeignPrivEventsTest do
  use ExUnit.Case, async: true

  alias Compatibility.Portability, as: Reasons
  alias NccWorker.KinoFixtures, as: K
  alias NccWorker.Portability.{Context, Events, ForeignPriv}

  @moduletag :tmp_dir

  @rm_rf %{
    "module" => "Elixir.Kino.JS",
    "function" => "MACRO-__before_compile__",
    "arity" => 2,
    "file" => "lib/kino/js.ex",
    "line" => 368
  }
  @mkdir_p %{@rm_rf | "line" => 369}
  @archive %{
    "module" => "Elixir.Kino.JS",
    "function" => "package_assets!",
    "arity" => 2,
    "file" => "lib/kino/js.ex",
    "line" => 435
  }
  @h "uxwh53kfq2wszgf23hqwgkuiza"
  @toolchain %{"caller_kind" => "toolchain"}

  setup %{tmp_dir: dir} do
    f = K.project(dir)
    scope = MapSet.new(Context.closure_of(f.ctx, f.ctx.package))
    on = %{f.ctx | foreign_priv: ForeignPriv.gate(f.ctx, scope, foreign_priv: true)}
    assert on.foreign_priv
    %{f: f, on: on, off: f.ctx, a: f.assets}
  end

  defp ev(channel, mfa, path, user, extra \\ %{}) do
    Map.merge(
      %{
        "ts" => 150,
        "pid" => "<0.200.0>",
        "channel" => channel,
        "mfa" => mfa,
        "arg" => %{"path" => path},
        "extent" => if(user, do: "frame", else: "lineage"),
        "first" => %{"module" => "Elixir.File"},
        "user" => user
      },
      extra
    )
  end

  defp f1(path), do: ev("file_read", "file:read_link_info/2", path, @rm_rf, @toolchain)

  defp mkdir(path),
    do:
      ev(
        "file_write",
        "file:make_dir/1",
        path,
        @mkdir_p,
        Map.put(@toolchain, "caller", %{
          "module" => "Elixir.File",
          "function" => "do_mkdir_p",
          "arity" => 1
        })
      )

  defp dir?(path),
    do:
      ev(
        "file_read",
        "file:read_file_info/2",
        path,
        @mkdir_p,
        Map.put(@toolchain, "caller", %{
          "module" => "elixir_utils",
          "function" => "read_file_type",
          "arity" => 2
        })
      )

  defp f3(path), do: ev("file_write", "file:open/2", path, @archive, @toolchain)
  defp f4(path), do: ev("file_write", "prim_file:open/2", path, nil)

  defp archive_path(a, d), do: Path.join([a, d, @h <> ".tar.gz"])

  test "each row of the table is accepted in the writer's window", %{on: on, a: a, f: f} do
    vl = Path.join(a, "Kino_VegaLite")

    assert {:observe, "foreign_priv",
            %{"call" => "rm_rf", "dir" => "Kino_VegaLite", "path" => "priv/assets/Kino_VegaLite"}} =
             Events.decide(f1(vl), on, "kino_vega_lite")

    for path <- [vl, a, Path.dirname(a), f.kino_build, Path.dirname(f.kino_build), "/"] do
      assert {:observe, "foreign_priv", %{"call" => "mkdir_p"}} =
               Events.decide(mkdir(path), on, "kino_vega_lite"),
             path

      assert {:observe, "foreign_priv", %{"call" => "mkdir_p"}} =
               Events.decide(dir?(path), on, "kino_vega_lite"),
             path
    end

    assert {:observe, "foreign_priv",
            %{"call" => "archive", "dir" => "Kino_VegaLite", "hash" => @h}} =
             Events.decide(f3(archive_path(a, "Kino_VegaLite")), on, "kino_vega_lite")

    assert {:observe, "foreign_priv", %{"call" => "stream", "dir" => "Kino_VegaLite"}} =
             Events.decide(f4(archive_path(a, "Kino_VegaLite")), on, "kino_vega_lite")
  end

  test "kino's own window writes its own directories, never a writer's", %{on: on, a: a} do
    assert {:observe, "foreign_priv", %{"call" => "archive", "dir" => "Kino_HTML"}} =
             Events.decide(f3(archive_path(a, "Kino_HTML")), on, "kino")

    assert {:refuse, "compile-time write outside ebin: " <> _} =
             Events.decide(f3(archive_path(a, "Kino_VegaLite")), on, "kino")
  end

  test "refused: a wrong line, function or module", %{on: on, a: a} do
    vl = Path.join(a, "Kino_VegaLite")

    for user <- [
          %{@rm_rf | "line" => 367},
          %{@rm_rf | "function" => "__before_compile__"},
          %{@rm_rf | "module" => "Elixir.KinoVegaLite.Hook"}
        ] do
      assert {:refuse, "compile-time read of kino's asset archives: " <> _} =
               Events.decide(%{f1(vl) | "user" => user}, on, "kino_vega_lite")
    end

    for user <- [
          %{@archive | "line" => 436},
          %{@archive | "function" => "package_assets"},
          @rm_rf
        ] do
      assert {:refuse, "compile-time write outside ebin: file:open/2 " <> _} =
               Events.decide(
                 %{f3(archive_path(a, "Kino_VegaLite")) | "user" => user},
                 on,
                 "kino_vega_lite"
               )
    end
  end

  test "refused: the package's own frame, a dir that is not a writer module, a kino dir",
       %{on: on, a: a} do
    own = %{
      "module" => "Elixir.Kino.VegaLite",
      "function" => "__MODULE__",
      "arity" => 1,
      "file" => "lib/kino/vega_lite.ex",
      "line" => 3
    }

    assert {:refuse, "compile-time write outside ebin: " <> _} =
             Events.decide(
               %{f3(archive_path(a, "Kino_VegaLite")) | "user" => own},
               on,
               "kino_vega_lite"
             )

    assert {:refuse, "compile-time write outside ebin: " <> _} =
             Events.decide(f3(archive_path(a, "Kino_Other")), on, "kino_vega_lite")

    assert {:refuse, "compile-time write outside ebin: " <> _} =
             Events.decide(f3(archive_path(a, "Kino_HTML")), on, "kino_vega_lite")
  end

  test "refused: a write in kino's ebin, a delete or rename under A, a mix.exs frame",
       %{on: on, a: a, f: f} do
    assert {:refuse, "compile-time write outside ebin: " <> _} =
             Events.decide(f3(Path.join(f.kino_build, "ebin/x.beam")), on, "kino_vega_lite")

    file = archive_path(a, "Kino_VegaLite")

    for mfa <-
          ~w(file:delete/1 file:del_dir/1 file:del_dir_r/1 file:change_mode/2 file:change_time/2 file:rename/2) do
      assert {:refuse, "compile-time write outside ebin: " <> _} =
               Events.decide(%{f3(file) | "mfa" => mfa}, on, "kino_vega_lite"),
             mfa
    end

    in_mix_exs = %{@archive | "file" => Path.join(f.proj, "deps/kino_vega_lite/mix.exs")}

    assert {:refuse, "compile-time write outside ebin: " <> _} =
             Events.decide(%{f3(file) | "user" => in_mix_exs}, on, "kino_vega_lite")
  end

  test "refused: a listing of A itself, outside the reviewed mkdir_p frame", %{on: on, a: a} do
    e = ev("file_read", "file:list_dir/1", a, %{@archive | "module" => "Elixir.Other"})

    assert {:refuse, "compile-time read of kino's asset archives: file:list_dir/1 " <> _} =
             Events.decide(e, on, "kino_vega_lite")
  end

  test "refused: a read, listing or stat under A, by anyone", %{on: on, a: a} do
    file = Path.join([a, "Kino_HTML", @h <> ".tar.gz"])
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "x")

    for owner <- ["kino_vega_lite", "kino", :outside],
        mfa <-
          ~w(file:read_file/1 file:open/2 file:read_file_info/2 prim_file:read_file_info/2 file:list_dir/1) do
      e = ev("file_read", mfa, file, %{@archive | "module" => "Elixir.Other"})

      assert {:refuse, "compile-time read of kino's asset archives: " <> rest} =
               Events.decide(e, on, owner)

      assert rest =~ mfa
    end
  end

  # Spec 9 A3: a closed gate gives today's decisions, byte for byte.
  test "gate off: today's decisions", %{off: off, a: a} do
    assert off.foreign_priv == nil
    vl = Path.join(a, "Kino_VegaLite")

    assert {:refuse, "compile-time host read: file:read_link_info/2 " <> _} =
             Events.decide(f1(vl), off, "kino_vega_lite")

    assert {:refuse, "compile-time write outside ebin: file:open/2 " <> _} =
             Events.decide(f3(archive_path(a, "Kino_VegaLite")), off, "kino_vega_lite")

    existing = Path.join([a, "Kino_HTML", @h <> ".tar.gz"])
    File.mkdir_p!(Path.dirname(existing))
    File.write!(existing, "x")

    assert :ignore =
             Events.decide(
               ev("file_read", "file:read_file/1", existing, @archive),
               off,
               "kino_vega_lite"
             )

    assert ForeignPriv.decide(f3(archive_path(a, "Kino_VegaLite")), off, "kino_vega_lite") ==
             :pass
  end

  # Spec 3.2 row F5: the real-VM fixture on Elixir 1.19 and 1.20 shows no
  # frameless stat after an accepted call, so none is in the rule.
  test "a frameless stat of A/<d> refuses as a read", %{on: on, a: a} do
    vl = Path.join(a, "Kino_VegaLite")

    for mfa <- ~w(prim_file:read_file_info/2 prim_file:read_link_info/2) do
      assert {:refuse, "compile-time read of kino's asset archives: " <> rest} =
               Events.decide(ev("file_read", mfa, vl, nil), on, "kino_vega_lite")

      assert rest =~ mfa
    end
  end

  test "an accepted event keeps the refusal it would have been", %{on: on, a: a} do
    assert {:observe, "foreign_priv",
            %{"refusal" => "compile-time write outside ebin: file:open/2 " <> _}} =
             Events.decide(f3(archive_path(a, "Kino_VegaLite")), on, "kino_vega_lite")

    _ = Reasons
  end
end
