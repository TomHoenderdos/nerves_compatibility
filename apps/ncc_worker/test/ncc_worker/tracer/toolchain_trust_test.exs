defmodule NccWorker.Tracer.ToolchainTrustTest do
  # Which loaded code the tracer takes for the toolchain's: never by a
  # module's name or the file the code server recorded for it alone, only
  # by the code loaded for it (its md5) against the beam under a read-only
  # root, a preloaded module's or a tracer module's start md5.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defp md5(module), do: :erlang.get_module_info(module, :md5)

  defp env(dir, overrides) do
    Map.merge(
      %{
        roots: [String.to_charlist(Path.join(dir, "root"))],
        preloaded_md5: %{},
        owned_md5: %{},
        realpath: & &1,
        file_md5: fn _path -> :error end
      },
      overrides
    )
  end

  defp root_path(dir, name), do: String.to_charlist(Path.join([dir, "root", "ebin", name]))

  describe "object_verdict/4" do
    test "a beam under a root holding exactly the loaded code is the toolchain's",
         %{tmp_dir: dir} do
      path = root_path(dir, "lists.beam")
      env = env(dir, %{file_md5: fn ^path -> {:ok, {:lists, md5(:lists)}} end})
      assert :ncc_tracer.object_verdict(:lists, path, md5(:lists), env)
    end

    test "a beam under a root whose md5 is not the loaded code's is not", %{tmp_dir: dir} do
      path = root_path(dir, "lists.beam")
      other = :crypto.hash(:md5, "other code")

      for on_disk <- [{:ok, {:lists, other}}, {:ok, {:maps, md5(:lists)}}, :error] do
        env = env(dir, %{file_md5: fn _ -> on_disk end})
        refute :ncc_tracer.object_verdict(:lists, path, md5(:lists), env), inspect(on_disk)
      end
    end

    test "a recorded file outside every root is not, whatever the beam there holds",
         %{tmp_dir: dir} do
      env = env(dir, %{file_md5: fn _ -> {:ok, {:lists, md5(:lists)}} end})

      for path <- [
            Path.join([dir, "elsewhere", "lists.beam"]),
            Path.join([dir, "rootx", "lists.beam"]),
            Path.join(dir, "root")
          ] do
        refute :ncc_tracer.object_verdict(
                 :lists,
                 String.to_charlist(path),
                 md5(:lists),
                 env
               ),
               path
      end
    end

    test "the real path decides: a path that resolves outside the roots is not",
         %{tmp_dir: dir} do
      path = root_path(dir, "lists.beam")
      outside = String.to_charlist(Path.join(dir, "elsewhere/lists.beam"))

      env =
        env(dir, %{
          realpath: fn ^path -> outside end,
          file_md5: fn _ -> {:ok, {:lists, md5(:lists)}} end
        })

      refute :ncc_tracer.object_verdict(:lists, path, md5(:lists), env)
    end

    test "preloaded holds only for a module preloaded at start, with its start md5",
         %{tmp_dir: dir} do
      pre = %{prim_file: md5(:prim_file)}
      env = env(dir, %{preloaded_md5: pre})

      assert :ncc_tracer.object_verdict(:prim_file, :preloaded, md5(:prim_file), env)
      refute :ncc_tracer.object_verdict(:prim_file, :preloaded, md5(:lists), env)
      refute :ncc_tracer.object_verdict(:fx_not_preloaded, :preloaded, md5(:lists), env)
    end

    test "a tracer module holds only with its start md5, wherever it was loaded from",
         %{tmp_dir: dir} do
      start = :crypto.hash(:md5, "tracer at start")
      other = :crypto.hash(:md5, "other code")

      env =
        env(dir, %{
          owned_md5: %{ncc_tracer: start},
          file_md5: fn _ -> {:ok, {:ncc_tracer, other}} end
        })

      path = root_path(dir, "ncc_tracer.beam")

      assert :ncc_tracer.object_verdict(:ncc_tracer, ~c"/anywhere", start, env)
      refute :ncc_tracer.object_verdict(:ncc_tracer, path, other, env)
    end

    test "no loaded code, no file or a cover-compiled one is never the toolchain's",
         %{tmp_dir: dir} do
      path = root_path(dir, "lists.beam")
      env = env(dir, %{file_md5: fn _ -> {:ok, {:lists, md5(:lists)}} end})

      refute :ncc_tracer.object_verdict(:lists, path, :undefined, env)

      for which <- [~c"", :non_existing, :cover_compiled, :undefined] do
        refute :ncc_tracer.object_verdict(:lists, which, md5(:lists), env), inspect(which)
      end
    end
  end

  describe "cache_hit/2" do
    test "a kept verdict holds only for the code it was taken for" do
      a = md5(:lists)
      b = md5(:maps)

      assert {:ok, true} = :ncc_tracer.cache_hit({a, true}, a)
      assert {:ok, false} = :ncc_tracer.cache_hit({a, false}, a)
      assert :miss = :ncc_tracer.cache_hit({a, true}, b)
      assert :miss = :ncc_tracer.cache_hit({:undefined, true}, :undefined)
      assert :miss = :ncc_tracer.cache_hit(:undefined, a)
      assert :miss = :ncc_tracer.cache_hit(true, a)
    end
  end

  describe "installed_app/3" do
    test "names an installed application only for verified toolchain code" do
      path = :code.which(:public_key)
      assert :ncc_tracer.installed_app(:public_key, path, true) == "public_key"
      assert :ncc_tracer.installed_app(:public_key, path, false) == :null
    end
  end
end

defmodule NccWorker.Tracer.ToolchainTrustVmTest do
  # A real tracer in a real VM: a benign module whose recorded file lies
  # outside every read-only root is package code to the tracer.
  use ExUnit.Case, async: true, group: :real_vm

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  defp ebin, do: :ncc_tracer |> :code.which() |> List.to_string() |> Path.dirname()

  test "code recorded under a path outside the roots is the user frame", %{tmp_dir: dir} do
    src = Path.join(dir, "fx_benign.erl")

    File.write!(src, """
    -module(fx_benign).
    -export([f/0]).
    f() -> V = os:getenv("NCC_FX_BENIGN"), {V}.
    """)

    recorded = Path.join([dir, "elsewhere", "ebin", "fx_benign.beam"])
    script = Path.join(dir, "script.exs")

    File.write!(script, """
    {:ok, :fx_benign, bin} = :compile.file(#{inspect(String.to_charlist(src))}, [:binary])
    {:ok, tok} = :ncc_tracer.start_main()
    {:module, :fx_benign} =
      :code.load_binary(:fx_benign, #{inspect(String.to_charlist(recorded))}, bin)
    _ = :fx_benign.f()
    :ok = :ncc_tracer.finish(tok, "ok")
    """)

    {out, 0} =
      System.cmd("elixir", ["-pa", ebin(), script],
        env: [{"NCC_TRACE_DIR", dir}],
        stderr_to_stdout: true
      )

    events =
      dir
      |> Path.join("trace-main.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Enum.filter(&(&1["kind"] == "event" and &1["arg"]["name"] == "NCC_FX_BENIGN"))

    assert [%{"extent" => "frame", "user" => %{"module" => "fx_benign"}}] = events,
           inspect({events, out})
  end
end
