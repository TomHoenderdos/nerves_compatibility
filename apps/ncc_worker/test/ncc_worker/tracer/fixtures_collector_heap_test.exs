defmodule NccWorker.Tracer.FixturesCollectorHeapTest do
  # The collector's heap on real traced compiles (`NCC_TRACE_MAX_HEAP_WORDS`).
  #
  # A trace message carries a copy of its call's arguments, and a spawn's
  # of its fun with everything in the fun's environment. The compiler
  # spawns the checker of every module it compiles with that module in the
  # environment, tens of MB for a large generated module (date_time_parser,
  # poison, beamlab_countries): production lost some 290 toolchain builds
  # to "trace collector died: killed" that way, each copy one the collector
  # had already handled. Here a package spawns with a large list in the
  # fun's environment, under a cap that holds a few copies but not every
  # copy one compile makes: the collector must not die of garbage.
  #
  # And `:erl_tar.extract({:binary, bytes}, ...)` opens a RAM file whose
  # "path" is the archive's bytes (material_symbols): the collector died
  # JSON-encoding it into an event.
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  @moduletag :tmp_dir
  @moduletag timeout: 600_000

  # 2^20 list cells: 2^21 words a copy.
  @cells 1_048_576

  @spawns """
  defmodule FxSpawns do
    big = Enum.to_list(1..#{@cells})

    for _ <- 1..16 do
      {pid, ref} = spawn_monitor(fn -> exit({:len, length(big)}) end)

      receive do
        {:DOWN, ^ref, :process, ^pid, {:len, #{@cells}}} -> :ok
      end
    end

    def ok, do: :ok
  end
  """

  # 4 MB of bytes JSON escapes one by one.
  @ram """
  defmodule FxRam do
    data = :binary.copy(<<0, 1, 2, 3>>, 1_048_576)
    {:ok, fd} = :file.open(data, [:ram, :binary, :read])
    {:ok, <<0, 1>>} = :file.read(fd, 2)
    :ok = :file.close(fd)

    def ok, do: :ok
  end
  """

  defp project(dir, app, source),
    do: TracerFixtures.project(dir, [app], %{app => TracerFixtures.lib(app, source)})

  defp trace(proj, app, cap),
    do:
      TracerFixtures.trace(proj, [app],
        extra_env: [{"NCC_TRACE_MAX_HEAP_WORDS", Integer.to_string(cap)}]
      )

  test "large trace messages already handled never add up to the heap cap", %{tmp_dir: dir} do
    proj = project(dir, "fx_spawns", @spawns)
    traced = trace(proj, "fx_spawns", 16 * @cells)

    assert {:ok, 0} = traced.result, traced.log
    assert traced.report.problems == [], inspect(traced.report.problems)
    assert %{"status" => "ok"} = traced.report.ending
    assert [%{app: "fx_spawns", close: close}] = traced.report.windows
    assert is_integer(close)
  end

  # The cap still holds: one copy past it kills the collector, and the
  # trace is not judged (`FixturesClosureTest`'s heap cap too).
  test "one message past the cap still kills the collector", %{tmp_dir: dir} do
    proj = project(dir, "fx_spawns", @spawns)
    traced = trace(proj, "fx_spawns", @cells)

    assert "trace collector died: killed" in traced.report.problems,
           inspect(traced.report.problems)

    assert traced.report.ending == nil
  end

  # Its open refuses as it did while the bytes were taken for a path.
  test "a RAM file's bytes never reach an event", %{tmp_dir: dir} do
    proj = project(dir, "fx_ram", @ram)
    traced = trace(proj, "fx_ram", 4 * @cells)

    assert {:ok, 0} = traced.result, traced.log
    assert traced.report.problems == [], inspect(traced.report.problems)

    assert %{
             status: :skip,
             reason: "compile-time host read: file:open/2 (an in-memory file)" <> _
           } =
             TracerFixtures.judge(proj, "fx_ram", traced)
  end
end
