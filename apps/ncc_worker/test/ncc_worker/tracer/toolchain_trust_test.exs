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
        file_md5: fn _path -> :error end,
        old_code: fn _module -> false end
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

  describe "old code" do
    # A process can keep running a module's old code after a reload, under
    # the same name: whatever the current code is, the module is not the
    # toolchain's while old code of it exists.
    test "a module with old code is not the toolchain's, even when its current code is",
         %{tmp_dir: dir} do
      module = :"fx_old_code_#{System.unique_integer([:positive])}"

      forms = [
        {:attribute, 1, :module, module},
        {:attribute, 1, :export, [f: 0]},
        {:function, 1, :f, 0, [{:clause, 1, [], [], [{:atom, 1, :ok}]}]}
      ]

      {:ok, ^module, bin} = :compile.forms(forms, [:binary])
      path = root_path(dir, "#{module}.beam")
      on_exit(fn -> for _ <- 1..2, do: :code.purge(module) || :code.delete(module) end)

      {:module, ^module} = :code.load_binary(module, path, bin)
      md5 = md5(module)

      env =
        env(dir, %{
          file_md5: fn ^path -> {:ok, {module, md5}} end,
          old_code: &:erlang.check_old_code/1
        })

      assert :ncc_tracer.object_verdict(module, path, md5, env)

      # Loaded a second time: the first load's code is old code now.
      {:module, ^module} = :code.load_binary(module, path, bin)
      assert :erlang.check_old_code(module)
      assert md5(module) == md5
      refute :ncc_tracer.object_verdict(module, path, md5, env)

      # A preloaded or tracer-owned name is no exception.
      refute :ncc_tracer.object_verdict(module, :preloaded, md5, %{
               env
               | preloaded_md5: %{module => md5}
             })

      refute :ncc_tracer.object_verdict(module, ~c"/x", md5, %{env | owned_md5: %{module => md5}})

      # Purged: no old code, the current code is judged again.
      true = :code.soft_purge(module)
      assert :ncc_tracer.object_verdict(module, path, md5, env)
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

  describe "code swaps" do
    # The toolchain's code for :lists, and other code under that name.
    defp real, do: File.read!(:code.which(:lists))

    defp other(tag) do
      forms = [
        {:attribute, 1, :module, :lists},
        {:attribute, 1, :export, [tag: 0]},
        {:function, 1, :tag, 0, [{:clause, 1, [], [], [{:integer, 1, tag}]}]}
      ]

      {:ok, :lists, bin} = :compile.forms(forms, [:binary])
      bin
    end

    defp prepared(bin, ts), do: :ncc_tracer.code_prepared(:lists, bin, ts)
    defp judged, do: :ncc_tracer.toolchain_code(:lists, md5(:lists))

    test "the toolchain's code loaded back after other code fails, in any order seen" do
      steps = [
        fn -> prepared(other(1), 10) end,
        fn -> prepared(real(), 20) end,
        &judged/0
      ]

      for order <- [[0, 1, 2], [1, 0, 2], [2, 1, 0], [2, 0, 1], [1, 2, 0], [0, 2, 1]] do
        task =
          Task.async(fn ->
            for i <- order, do: Enum.at(steps, i).()
            Process.get(:code_swap)
          end)

        assert Task.await(task) == :lists, inspect(order)
      end
    end

    test "other code after the toolchain's (protocol consolidation), or never replaced, passes" do
      for steps <- [
            [fn -> prepared(real(), 10) end, fn -> prepared(other(1), 20) end, &judged/0],
            [&judged/0, fn -> prepared(other(1), 20) end],
            [fn -> prepared(other(1), 10) end, fn -> prepared(other(2), 20) end]
          ] do
        task =
          Task.async(fn ->
            Enum.each(steps, & &1.())
            Process.get(:code_swap)
          end)

        assert Task.await(task) == nil
      end
    end

    # The toolchain's code prepared before other code and finished after it:
    # the finish (erlang:finish_loading/1) may reach the collector before or
    # after the prepare's return names its reference.
    test "the toolchain's code prepared first and finished after other code fails, either way round" do
      for finish_first <- [false, true] do
        task =
          Task.async(fn ->
            ref = make_ref()
            entry = prepared(real(), 10)
            prepared(other(1), 20)

            if finish_first do
              :ncc_tracer.code_finished([ref], 30)
              :ncc_tracer.prepared_ref(entry, ref)
            else
              :ncc_tracer.prepared_ref(entry, ref)
              :ncc_tracer.code_finished([ref], 30)
            end

            judged()
            Process.get(:code_swap)
          end)

        assert Task.await(task) == :lists, inspect(finish_first)
      end
    end

    test "the toolchain's code finished before other code is prepared passes" do
      task =
        Task.async(fn ->
          ref = make_ref()
          :ncc_tracer.prepared_ref(prepared(real(), 10), ref)
          :ncc_tracer.code_finished([ref], 15)
          prepared(other(1), 20)
          judged()
          Process.get(:code_swap)
        end)

      assert Task.await(task) == nil
    end

    test "other code's on_load run under the name fails, in any order seen; the toolchain's own passes" do
      on_load = fn -> :ncc_tracer.on_load_ran(:lists, 15) end

      for order <- [[0, 1, 2], [2, 0, 1], [1, 2, 0], [2, 1, 0]] do
        steps = [fn -> prepared(other(1), 10) end, on_load, &judged/0]

        task =
          Task.async(fn ->
            for i <- order, do: Enum.at(steps, i).()
            Process.get(:code_swap)
          end)

        assert Task.await(task) == :lists, inspect(order)
      end

      task =
        Task.async(fn ->
          prepared(real(), 10)
          on_load.()
          judged()
          prepared(other(1), 20)
          Process.get(:code_swap)
        end)

      assert Task.await(task) == nil
    end

    test "past the kept versions, a module ever taken for the toolchain's fails" do
      task =
        Task.async(fn ->
          for tag <- 1..17, do: prepared(other(tag), tag)
          before = Process.get(:code_swap)
          judged()
          {before, Process.get(:code_swap)}
        end)

      assert Task.await(task) == {nil, :lists}
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
