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
    {:ok, e} = Payload.validate(%{body() | "lock" => Enum.reverse(body()["lock"])})

    assert Payload.hash(a) == Payload.hash(b)
    assert Payload.hash(a) == Payload.hash(c)
    assert Payload.hash(a) == Payload.hash(e)
    refute Payload.hash(a) == Payload.hash(d)
    assert Payload.hash(a) =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "known codes are the shared table" do
    assert length(Payload.known_codes()) == 30
    assert "not_built_target" in Payload.known_codes()
    refute "unknown" in Payload.known_codes()
  end

  describe "type confusion" do
    test "floats and huge integers are not integers in range" do
      assert errors(%{body() | "format" => 1.0}) =~ "format"
      assert errors(%{body() | "otp" => 29.0}) =~ "otp"
      assert errors(%{body() | "format" => 10 ** 40}) =~ "format"
      assert errors(%{body() | "otp" => -(10 ** 40)}) =~ "otp"
    end

    test "a list or a map where a string is expected is refused" do
      assert errors(%{body() | "client" => ["0.4.0"]}) =~ "client"
      assert errors(%{body() | "target" => %{"a" => "b"}}) =~ "target"
      assert errors(%{body() | "system" => ["nerves_system_rpi4"]}) =~ "system"
      assert errors(Map.put(body(), "contact", %{"x" => 1})) =~ "contact"
      assert errors(%{body() | "built_at" => [1]}) =~ "built_at"
      assert errors(%{body() | "os" => %{"family" => ["unix"], "arch" => "x"}}) =~ "os.family"
      assert errors(%{body() | "lines" => %{"0" => 1}}) =~ "lines"

      bad = %{line("jason", "1.4.5", "miss", "fetch_failed", []) | "name" => ["jason"]}
      assert errors(%{body() | "lines" => [bad]}) =~ "lines[0].name"
      bad = %{line("jason", "1.4.5", "miss", "fetch_failed", []) | "reason" => ["x"]}
      assert errors(%{body() | "lines" => [bad]}) =~ "lines[0].reason"
    end

    test "a reason_code that is not a string is refused" do
      for code <- [5, nil, ["fetch_failed"], %{}] do
        bad = %{line("jason", "1.4.5", "miss", "fetch_failed", []) | "reason_code" => code}
        assert errors(%{body() | "lines" => [bad]}) =~ "lines[0].reason_code"
      end
    end
  end

  test "the os.family error names the field once" do
    message = errors(%{body() | "os" => %{"family" => "darwin", "arch" => "x"}})
    assert message =~ "os.family: must be unix or win32"
    refute message =~ "os: os."
  end

  test "contact refuses bidi overrides, zero-width and other unprintable characters" do
    for bad <- ["a\u202Eb", "a\u200Bb", "a\u2028b", "a\u2029b", "a\uE000b", "a\u0378b"] do
      assert errors(Map.put(body(), "contact", bad)) =~ "contact"
    end
  end

  test "the reason has unprintable characters replaced" do
    l = %{
      line("jason", "1.4.5", "miss", "fetch_failed", [])
      | "reason" => "a\nb\u202Ec\u200Bd\te"
    }

    assert {:ok, %{lines: [line]}} = Payload.validate(%{body() | "lines" => [l]})
    assert line.reason == "a b c d e"
  end

  test "an unknown reason code keeps its text, cut at 300 characters" do
    l = %{
      line("jason", "1.4.5", "miss", "brand_new", [])
      | "reason" => String.duplicate("y", 400)
    }

    assert {:ok, %{lines: [line]}} = Payload.validate(%{body() | "lines" => [l]})
    assert line.reason_code == "unknown"
    assert line.reason == String.duplicate("y", 300)
  end

  test "checksums must be exactly 64 hex characters" do
    for bad <- [
          String.duplicate("a", 63),
          String.duplicate("a", 65),
          "g" <> String.duplicate("a", 63)
        ] do
      lock = %{"name" => "jason", "version" => "1.4.5", "checksum" => bad}
      assert errors(%{body() | "lock" => [lock]}) =~ "lock[0].checksum"
    end
  end

  test "a lock version that does not parse is refused" do
    lock = %{lock("jason", "1.4.5") | "version" => "1.4"}
    assert errors(%{body() | "lock" => [lock]}) =~ "lock[0].version"
  end

  describe "bounded error output" do
    test "a long unknown key is cut and its control characters stripped" do
      key = "evil\r\nkey\u202E" <> String.duplicate("k", 10_000)
      message = errors(Map.put(body(), key, 1))
      assert message =~ "evilkey" <> String.duplicate("k", 33) <> ": unknown field"
      refute message =~ String.duplicate("k", 34)
      refute message =~ ~r/[\r\n\x{202E}]/u
    end

    test "many unknown top-level keys name five and count the rest" do
      extra = Map.new(1..20_000, &{"x#{&1}", 1})
      assert {:error, errors} = Payload.validate(Map.merge(body(), extra))
      assert length(errors) == 6
      assert List.last(errors) =~ "and 19995 more unknown fields"
      assert byte_size(Enum.join(errors, "\n")) < 1_000
    end

    test "many unknown keys in many entries stay bounded" do
      extra = Map.new(1..1_000, &{"x#{&1}", 1})
      bad_line = Map.merge(line("jason", "1.4.5", "miss", "fetch_failed", []), extra)
      bad_lock = Map.merge(lock("jason", "1.4.5"), extra)
      long = String.duplicate("z", 200)

      bad_os =
        Map.merge(%{"family" => "unix", "arch" => "x"}, Map.new(1..1_000, &{"#{long}#{&1}", 1}))

      body =
        Map.merge(body(), %{
          "lines" => List.duplicate(bad_line, 500),
          "lock" => List.duplicate(bad_lock, 1_000),
          "os" => bad_os
        })

      assert {:error, errors} = Payload.validate(body)
      message = Enum.join(errors, "\n")
      assert message =~ "lines: and 495 more refused entries"
      assert message =~ "lock: and 995 more refused entries"
      assert message =~ "os.*: and 995 more unknown fields"
      assert byte_size(message) < 8_000
    end
  end
end
