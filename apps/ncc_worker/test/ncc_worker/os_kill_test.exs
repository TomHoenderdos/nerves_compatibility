defmodule NccWorker.OsKillTest do
  use ExUnit.Case, async: true

  alias NccWorker.OsKill

  defp sleeper do
    port =
      Port.open({:spawn_executable, System.find_executable("sleep")}, [:binary, args: ["60"]])

    {:os_pid, pid} = Port.info(port, :os_pid)
    {port, Integer.to_string(pid)}
  end

  defp alive?(pid),
    do: match?({_, 0}, System.cmd("sh", ["-c", "kill -0 #{pid}"], stderr_to_stdout: true))

  defp wait_dead(pid, n \\ 50)
  defp wait_dead(_pid, 0), do: false

  defp wait_dead(pid, n) do
    # A killed port child stays a zombie until the port notices; ask ps.
    {state, _} = System.cmd("ps", ["-o", "stat=", "-p", pid], stderr_to_stdout: true)

    if state == "" or String.starts_with?(state, "Z") do
      true
    else
      Process.sleep(20)
      wait_dead(pid, n - 1)
    end
  end

  test "kills with the kill binary" do
    {_port, pid} = sleeper()
    assert :ok = OsKill.kill([pid])
    assert wait_dead(pid)
  end

  test "without a kill binary on the PATH, kills through the shell's builtin" do
    {_port, pid} = sleeper()

    find = fn
      "kill" -> nil
      name -> System.find_executable(name)
    end

    assert :ok = OsKill.kill([pid], find)
    assert wait_dead(pid)
  end

  test "with neither, reports it and never raises" do
    {port, pid} = sleeper()
    assert {:error, :no_kill} = OsKill.kill([pid], fn _ -> nil end)
    assert alive?(pid)
    Port.close(port)
    OsKill.kill([pid])
  end

  test "a group id is passed as a negative pid" do
    assert OsKill.argv({:group, "42"}) == ["-KILL", "--", "-42"]
    assert OsKill.argv(["1", "2"]) == ["-KILL", "--", "1", "2"]
  end

  test "group members are read from /proc stat, zombies left out" do
    stat = fn
      "10" -> "10 (sleep) S 1 7 7 0"
      "11" -> "11 (a) b) c) R 1 7 7 0"
      "12" -> "12 (sh) Z 1 7 7 0"
      "13" -> "13 (sh) S 1 8 8 0"
    end

    assert OsKill.group_members("7", ~w(10 11 12 13), stat) == ~w(10 11)
  end
end
