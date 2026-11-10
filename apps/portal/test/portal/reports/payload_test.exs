defmodule Portal.Reports.PayloadTest do
  use ExUnit.Case, async: true

  import Portal.Test.ReportFixtures

  alias Portal.Reports.Payload

  defp errors(body, opts \\ []) do
    assert {:error, errors} = Payload.validate(body, opts)
    Enum.join(errors, "\n")
  end

  test "a valid body normalises" do
    assert {:ok, p} = Payload.validate(body())

    assert p.format == 1 and p.otp == 29 and
             p.os == %{family: "unix", arch: "aarch64-apple-darwin"}

    assert [%{status: :hit}, %{status: :miss, reason_code: "not_built_version"}, _] = p.lines
    assert p.built_at == ~U[2026-11-10 12:00:00Z]
  end

  test "an unknown field at any level is refused" do
    assert errors(Map.put(body(), "project", "x")) =~ "project: unknown field"
    assert errors(put_in(body(), ["os", "kernel"], "x")) =~ "os.kernel: unknown field"

    [first | rest] = body()["lines"]
    assert errors(%{body() | "lines" => [Map.put(first, "path", "/x") | rest]}) =~ "lines[0].path"

    [lock | rest] = body()["lock"]
    assert errors(%{body() | "lock" => [Map.put(lock, "repo", "x") | rest]}) =~ "lock[0].repo"
  end

  test "a body that is not an object is refused" do
    assert {:error, _} = Payload.validate(["a"])
    assert {:error, _} = Payload.validate("a")
    assert {:error, _} = Payload.validate(%{"_json" => [1]})
  end

  test "format must be an integer from 1 to the current format" do
    assert errors(%{body() | "format" => 2}) =~ "format"
    assert errors(%{body() | "format" => 0}) =~ "format"
    assert errors(%{body() | "format" => "1"}) =~ "format"
  end

  test "format 1 stays accepted after the current format is bumped" do
    assert Payload.current_format() == 1
    assert {:ok, %{format: 1}} = Payload.validate(body(), current_format: 2)
    assert {:ok, %{format: 2}} = Payload.validate(%{body() | "format" => 2}, current_format: 2)
  end

  test "a custom system named by the Hex package rule is accepted" do
    assert {:ok, %{system: "acme_board_system"}} =
             Payload.validate(%{body() | "system" => "acme_board_system"})
  end

  test "versions, otp, os, target and system are checked" do
    assert errors(%{body() | "client" => "latest"}) =~ "client"
    assert errors(%{body() | "elixir" => "1.20"}) =~ "elixir"
    assert errors(%{body() | "otp" => 19}) =~ "otp"
    assert errors(%{body() | "otp" => 100}) =~ "otp"
    assert errors(%{body() | "os" => %{"family" => "darwin", "arch" => "x"}}) =~ "os"
    assert errors(%{body() | "os" => %{"family" => "unix", "arch" => "Apple Silicon"}}) =~ "os"
    assert errors(%{body() | "target" => "RPi4"}) =~ "target"
    assert errors(%{body() | "system" => "Nerves-RPi4"}) =~ "system"
    assert errors(%{body() | "system_version" => "x"}) =~ "system_version"
  end

  test "optional fields may be absent or null" do
    for key <- ["system", "system_version", "contact", "built_at"] do
      assert {:ok, p} = Payload.validate(Map.delete(body(), key))
      assert {:ok, ^p} = Payload.validate(Map.put(body(), key, nil))
    end
  end

  test "package names follow Hex rules and versions parse" do
    bad = line("Jason", "1.4.5", "miss", "not_built_version", ["1.4.5"])
    assert errors(%{body() | "lines" => [bad]}) =~ "lines[0].name"
    bad = line("jason", "one", "miss", "not_built_version", [])
    assert errors(%{body() | "lines" => [bad]}) =~ "lines[0].version"
    bad = line("jason", "1.4.5", "skip", "not_built_version", [])
    assert errors(%{body() | "lines" => [bad]}) =~ "lines[0].status"
  end

  test "checksums are 64 hex in any case and stored lowercase" do
    upper = String.duplicate("AB", 32)
    lock = %{"name" => "jason", "version" => "1.4.5", "checksum" => upper}
    assert {:ok, %{lock: [entry]}} = Payload.validate(%{body() | "lock" => [lock]})
    assert entry["checksum"] == String.downcase(upper)

    assert errors(%{body() | "lock" => [%{lock | "checksum" => "abc"}]}) =~ "lock[0].checksum"
  end

  test "an unknown reason code is stored as unknown with its text kept" do
    l = %{line("jason", "1.4.5", "miss", "brand_new", []) | "reason" => "something new"}
    assert {:ok, %{lines: [line]}} = Payload.validate(%{body() | "lines" => [l]})
    assert line.reason_code == "unknown" and line.reason == "something new"
  end

  test "reason args are bounded, the reason is cut at 300 characters" do
    many = line("jason", "1.4.5", "miss", "compile_env_differs", Enum.map(1..9, &"a#{&1}"))
    assert errors(%{body() | "lines" => [many]}) =~ "reason_args"
    long = line("jason", "1.4.5", "miss", "compile_env_differs", [String.duplicate("a", 65)])
    assert errors(%{body() | "lines" => [long]}) =~ "reason_args"
    path = line("jason", "1.4.5", "miss", "fetch_failed", ["/home/me/x"])
    assert errors(%{body() | "lines" => [path]}) =~ "reason_args"

    l = %{line("jason", "1.4.5", "miss", "internal", []) | "reason" => String.duplicate("x", 400)}
    assert {:ok, %{lines: [line]}} = Payload.validate(%{body() | "lines" => [l]})
    assert String.length(line.reason) == 300
  end

  test "eight short args are accepted and a line that is not an object is refused" do
    eight = line("jason", "1.4.5", "miss", "compile_env_differs", Enum.map(1..8, &"a#{&1}"))

    assert {:ok, %{lines: [%{reason_args: args}]}} =
             Payload.validate(%{body() | "lines" => [eight]})

    assert length(args) == 8

    assert errors(%{body() | "lines" => ["x"]}) =~ "lines[0]: must be an object"
    assert errors(%{body() | "lock" => [nil]}) =~ "lock[0]: must be an object"
  end

  test "contact is at most 100 printable characters" do
    assert {:ok, %{contact: "@tester"}} = Payload.validate(Map.put(body(), "contact", "@tester"))
    assert errors(Map.put(body(), "contact", String.duplicate("a", 101))) =~ "contact"
    assert errors(Map.put(body(), "contact", "a\nb")) =~ "contact"
    assert errors(Map.put(body(), "contact", "a\u0000b")) =~ "contact"
  end

  test "at most 500 lines and 1000 lock entries" do
    lines = for i <- 1..501, do: line("p#{i}", "1.0.0", "miss", "not_in_batch", [])
    assert errors(%{body() | "lines" => lines}) =~ "at most 500"
    locks = for i <- 1..1001, do: lock("p#{i}", "1.0.0")
    assert errors(%{body() | "lock" => locks}) =~ "at most 1000"
  end

  test "the hash ignores contact and built_at, and line and lock order" do
    {:ok, a} = Payload.validate(body())
    {:ok, b} = Payload.validate(Map.merge(body(), %{"contact" => "x", "built_at" => nil}))
    {:ok, c} = Payload.validate(%{body() | "lines" => Enum.reverse(body()["lines"])})
    {:ok, d} = Payload.validate(%{body() | "target" => "rpi5"})

    assert Payload.hash(a) == Payload.hash(b)
    assert Payload.hash(a) == Payload.hash(c)
    refute Payload.hash(a) == Payload.hash(d)
    assert Payload.hash(a) =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "known codes are the shared table" do
    assert length(Payload.known_codes()) == 30
    assert "not_built_target" in Payload.known_codes()
    refute "unknown" in Payload.known_codes()
  end
end
