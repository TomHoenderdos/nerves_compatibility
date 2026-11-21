defmodule Compatibility.PortabilityTest do
  use ExUnit.Case, async: true

  alias Compatibility.Portability

  test "every trace refusal starts with a shared prefix" do
    for reason <- [
          "compile-time host read: os:type/0 in elixir_compiler_1.__MODULE__/1 (lib/x.ex:2)",
          "compile-time host read in mix.exs: os:getenv/1 sets elixirc_options (/p/mix.exs:9)",
          "compile-time write outside ebin: file:make_dir/1 /p/_build/host/phoenix-colocated/x",
          "compile-time tracing or system flag: erlang:system_flag/2",
          "calls natively built dependency at compile time: circuits_gpio:open/2",
          "bakes the build path: Elixir.X \"/p/deps/x\"",
          "closure dependency observed the host: d (compile-time host read: os:type/0)",
          "rebar3 build runs pre_hooks",
          "compile-time native library load: /tmp/evil.so",
          "compile-time priv write not reproducible: priv/assets/x.tar.gz differs",
          "foreign priv write refused: two writers of kino priv/assets/X",
          "compile-time read of kino's asset archives: file:read_file/1 /x",
          "compile-time probe of an OTP application outside the closure: wx via Code.ensure_loaded?/1",
          "compile-time probe of a dependency outside the closure: phoenix_html via Application.spec/2",
          "compile-time probe of whether a module is loaded: Elixir.X via erlang:function_exported/3"
        ] do
      assert Portability.refusal?(reason), reason
    end
  end

  # Only R1 (the package's own compile observed the host, or read the Elixir
  # version in a way that differs between patches) and R2 (a baked build
  # path) withdraw an earlier publication.
  test "the withdrawing prefixes are the R1 and R2 subset of the refusal prefixes" do
    assert Portability.withdrawing_prefixes() -- Portability.refusal_prefixes() == []

    assert Enum.sort(Portability.withdrawing_prefixes()) ==
             Enum.sort([
               "compile-time host read: ",
               "compile-time host read in mix.exs: ",
               "compile-time write outside ebin: ",
               "compile-time tracing or system flag: ",
               "compile-time Elixir patch dependence: ",
               "compile-time priv write not reproducible: ",
               "bakes the build path: ",
               "compile-time read of kino's asset archives: ",
               "compile-time probe of an OTP application outside the closure: ",
               "compile-time probe of a dependency outside the closure: ",
               "compile-time probe of whether a module is loaded: "
             ])

    for reason <- [
          "closure dependency observed the host: d (compile-time host read: os:type/0)",
          "calls natively built dependency at compile time: circuits_gpio:open/2",
          "rebar3 build runs pre_hooks",
          "compile-time native library load: /tmp/evil.so",
          "foreign priv write refused: two writers of kino priv/assets/X",
          "portability could not be judged"
        ] do
      refute Portability.withdraws?(reason), reason
    end

    assert Portability.withdraws?("compile-time host read: os:type/0")
    assert Portability.withdraws?("bakes the build path: Elixir.X \"<root>\"")

    assert Portability.withdraws?(
             Portability.priv_not_reproduced() <> "priv/assets/x.tar.gz differs"
           )

    refute Portability.withdraws?(nil)
  end

  test "could-not-judge, rule 1 reasons and non-strings are not refusals" do
    refute Portability.refusal?(Portability.could_not_judge())
    refute Portability.refusal?("calls System.cmd/2")
    refute Portability.refusal?("OS-specific (lib/x.ex: :os.type()")
    refute Portability.refusal?(nil)
  end

  test "the could-not-judge reason is the one portable?/4 already writes" do
    assert Portability.could_not_judge() == "portability could not be judged"
  end

  test "a compile-time config read refusal is a refusal that withdraws nothing" do
    reason = "compile-time config read: application:get_all_env/1 (x) has no key to match on"
    assert Portability.refusal?(reason)
    refute Portability.withdraws?(reason)
  end

  test "an Elixir patch dependence refusal is an R1 refusal that withdraws" do
    reason = "compile-time Elixir patch dependence: System.build_info/0 in X (lib/x.ex:1)"
    assert Portability.refusal?(reason)
    assert Portability.withdraws?(reason)
  end

  test "a manager mismatch is a refusal that withdraws nothing" do
    reason = Compatibility.Portability.manager_mismatch() <> "ranch (trace make, tarball rebar3)"
    assert reason == "manager mismatch: ranch (trace make, tarball rebar3)"
    assert Compatibility.Portability.refusal?(reason)
    refute Compatibility.Portability.withdraws?(reason)
  end

  test "a tree that differs from its tarball is a refusal that withdraws nothing" do
    reason = Compatibility.Portability.tree_differs() <> "kino (extra file lib/x.js)"
    assert reason == "dependency tree differs from its tarball: kino (extra file lib/x.js)"
    assert Compatibility.Portability.refusal?(reason)
    refute Compatibility.Portability.withdraws?(reason)
  end

  test "a native side not set apart is a refusal that withdraws nothing" do
    reason =
      Compatibility.Portability.native_side() <> "source tree is not its verified tarball's"

    assert reason == "native build not set apart: source tree is not its verified tarball's"
    assert Compatibility.Portability.refusal?(reason)
    refute Compatibility.Portability.withdraws?(reason)
  end

  describe "with_cause/2" do
    # S8 review R5: the worker names the window of each unjudged probe
    # (`"<app>: "`, `"outside: "`); the reason's cause stays the probe
    # itself, so reasons, and the admin tab's groups, do not split by owner.
    test "a probe problem's owner is not part of the cause" do
      for owner <- ["fx_probe", "outside"] do
        problems = [owner <> ": compile-time probe of a module the trace loaded: httpc (inets)"]

        assert Portability.with_cause(Portability.could_not_judge(), problems) ==
                 "portability could not be judged " <>
                   "(compile-time probe of a module the trace loaded: httpc (inets))"
      end

      # Any other app-prefixed problem keeps its app, as before.
      assert Portability.with_cause(Portability.could_not_judge(), [
               "dep: rebar3 build dir cannot be read"
             ]) ==
               "portability could not be judged (dep: rebar3 build dir cannot be read)"
    end

    test "names the trace break, not the lines missing because of it" do
      problems = [
        "no end line",
        "stats missing or unjudged events",
        "trace collector died: killed",
        "no stats line",
        "date_time_parser's window was never closed"
      ]

      assert Portability.with_cause(Portability.could_not_judge(), problems) ==
               "portability could not be judged (trace collector died: killed)"
    end

    test "a child VM's collector and the read budget are trace breaks too" do
      assert Portability.with_cause(Portability.could_not_judge(), [
               "rebar3 app has no verified Hex tarball",
               "child trace of dns_erlang: trace collector died: killed"
             ]) ==
               "portability could not be judged (child trace of dns_erlang: trace collector died: killed)"

      assert Portability.with_cause(Portability.could_not_judge(), [
               "no start line",
               "the host build is not the traced compile",
               "the trace files exceed the report's read budget"
             ]) ==
               "portability could not be judged (the trace files exceed the report's read budget)"
    end

    test "a failed traced compile comes before what follows from it" do
      assert Portability.with_cause(Portability.could_not_judge(), [
               "the host build is not the traced compile",
               "traced compile exited 1"
             ]) == "portability could not be judged (traced compile exited 1)"
    end

    test "otherwise the first problem, unwrapped when it is a could-not-judge itself" do
      assert Portability.with_cause(Portability.could_not_judge(), [
               "unreviewed toolchain config read: elixir dbg_callback from Elixir.Kernel",
               "compile-time probe of a module the trace loaded: httpc (inets)"
             ]) ==
               "portability could not be judged " <>
                 "(unreviewed toolchain config read: elixir dbg_callback from Elixir.Kernel)"

      assert Portability.with_cause(Portability.could_not_judge(), [
               "portability could not be judged (dependency tree changed after the check: " <>
                 "gpb (read descr_src/gpb_descriptor.erl))"
             ]) ==
               "portability could not be judged (dependency tree changed after the check: " <>
                 "gpb (read descr_src/gpb_descriptor.erl))"
    end

    test "keeps the portal's transient count after the cause" do
      reason = Portability.could_not_judge() <> " (transient 5 times)"

      assert Portability.with_cause(reason, ["tracer: :timeout", "no end line"]) ==
               "portability could not be judged (tracer: :timeout) (transient 5 times)"
    end

    defp cause(problems) do
      Portability.could_not_judge()
      |> Portability.with_cause(problems)
      |> Portability.cause_of()
    end

    test "never stores a path, absolute or under ~, spaces and all" do
      assert cause([
               "built outside the trace: kino (digest failed now: {:enoent, ~c\"/work/proj/_build/host/lib/kino/ebin\"})"
             ]) == "built outside the trace: kino (digest failed now: {:enoent, ~c\"…\"})"

      assert cause(["could not read /home/nerves/my secret dir/key.pem"]) ==
               "could not read …"

      assert cause(["could not read ~/.ssh/id_rsa (enoent)"]) == "could not read … (enoent)"

      assert cause(["/etc/x: refused, then ~/a b/c, d"]) == "…: refused, then …, d"

      assert cause(["file:make_dir/1 /work/proj/_build (a link)"]) ==
               "file:make_dir/1 … (a link)"

      # A path's line number is not part of it; relative paths and MFAs stay.
      assert cause(["read /work/proj/deps/x/mix.exs:12 in Mix.Project.deps/0"]) ==
               "read …:12 in Mix.Project.deps/0"

      assert cause([
               "dependency tree changed after the check: gpb (read descr_src/gpb_descriptor.erl)"
             ]) ==
               "dependency tree changed after the check: gpb (read descr_src/gpb_descriptor.erl)"
    end

    test "never stores a value an exception, a tracer or a dead process quotes" do
      assert cause([
               "judge failed: no match of right hand side value: %{\"value\" => \"s3cr3t\"}"
             ]) ==
               "judge failed: no match of right hand side value"

      assert cause(["tracer: {:install_failed, \"could not write /home/me/x\"}"]) ==
               "tracer: :install_failed"

      assert cause(["tracer: SECRET=abc"]) == "tracer: SECRET"
      assert cause(["tracer: :timeout"]) == "tracer: :timeout"
      assert cause(["trace collector died: killed"]) == "trace collector died: killed"

      assert cause(["trace collector died: {badarg,[{m,f,[<<\"SECRET=abc\">>],[]}]}"]) ==
               "trace collector died: badarg"

      assert cause(["trace watcher died: {{nocatch,\"s3cr3t\"},[]}"]) ==
               "trace watcher died:"

      assert cause(["child trace of x: tracer: {:install_failed, \"SECRET=abc\"}"]) ==
               "child trace of x: tracer: :install_failed"

      assert cause(["child trace of dns_erlang: trace collector died: killed"]) ==
               "child trace of dns_erlang: trace collector died: killed"
    end

    test "is one line of at most 200 bytes" do
      long = "windows [" <> Enum.join(List.duplicate("plug_crypto", 100), ", ") <> "]"
      long_cause = cause([long])
      assert byte_size(long_cause) <= 200
      assert byte_size(long_cause) > 190
      assert String.ends_with?(long_cause, "…")
      assert String.valid?(long_cause)

      # One grapheme of 5,000 combining marks is 10 KB.
      marks = "e" <> String.duplicate("\u0301", 5_000)
      marked = cause([marks])
      assert byte_size(marked) <= 200
      assert String.valid?(marked)

      wide = cause([String.duplicate("ü", 300)])
      assert byte_size(wide) <= 200
      assert String.valid?(wide)

      assert cause(["one\nline\ttwo\u2028three\u2029four\u0085five\u202Esix"]) ==
               "one line two three four five six"
    end

    test "a bare could-not-judge problem names no cause" do
      assert Portability.with_cause(Portability.could_not_judge(), [
               Portability.could_not_judge()
             ]) == Portability.could_not_judge()

      assert cause([Portability.could_not_judge(), "trace overflowed: queue"]) ==
               "trace overflowed: queue"
    end

    test "leaves every other reason, and a could-not-judge with no problems, as it is" do
      for reason <- [
            "compile-time host read: os:type/0",
            "portability could not be judged (unknown variant)",
            nil
          ] do
        assert Portability.with_cause(reason, ["trace collector died: killed"]) == reason
      end

      for problems <- [[], nil, [""], [1, :x]] do
        assert Portability.with_cause(Portability.could_not_judge(), problems) ==
                 Portability.could_not_judge()
      end
    end

    test "cause_of/1 reads the cause back" do
      for problems <- [
            ["trace collector died: killed"],
            ["built outside the trace: quicer (digest failed at window close: outside_tree)"]
          ],
          suffix <- ["", " (transient 5 times)"] do
        reason = Portability.with_cause(Portability.could_not_judge() <> suffix, problems)
        assert Portability.cause_of(reason) == hd(problems), reason
      end

      for reason <- [
            Portability.could_not_judge(),
            Portability.could_not_judge() <> " (transient 5 times)",
            "compile-time host read: os:type/0 (x)",
            nil
          ] do
        assert Portability.cause_of(reason) == nil, inspect(reason)
      end
    end

    test "a compile failure's reason is never given a could-not-judge cause" do
      reason = "compile failed: host compile failed: mix compile exited with code 1"
      assert Portability.with_cause(reason, ["trace collector died: killed"]) == reason
    end

    test "a reason with its cause is still a could-not-judge and no refusal" do
      reason =
        Portability.with_cause(Portability.could_not_judge(), [
          "compile-time host read: os:type/0"
        ])

      assert Portability.could_not_judge?(reason)
      refute Portability.refusal?(reason)
      refute Portability.withdraws?(reason)
      refute Portability.could_not_judge?("compile-time host read: os:type/0")
      refute Portability.could_not_judge?(nil)
    end
  end

  describe "with_compile_error/2" do
    @failed "compile failed: host compile failed: mix compile exited with code 1"

    test "names the compiler error of a compile that exited with an error code" do
      assert Portability.with_compile_error(
               @failed,
               "error: module Plug.Conn is not loaded and could not be found (lib/prom_ex/plug.ex:44)"
             ) ==
               @failed <>
                 " (error: module Plug.Conn is not loaded and could not be found (lib/prom_ex/plug.ex:44))"

      assert Portability.with_compile_error(
               "compile failed: host compile failed: mix command exited with code 2",
               ~s|** (Mix) :elixirc_paths should be a list of string paths, got: [~c"lib"]|
             ) ==
               "compile failed: host compile failed: mix command exited with code 2 " <>
                 ~s|(** (Mix) :elixirc_paths should be a list of string paths, got: [~c"lib"])|
    end

    test "one line, every absolute path cut out whole, at most 200 bytes" do
      assert Portability.with_compile_error(
               @failed,
               "** (RuntimeError) git_hooks: /work/proj/deps/git_hooks is not inside\na git working tree."
             ) == @failed <> " (** (RuntimeError) git_hooks: … is not inside a git working tree.)"

      long = "error: " <> String.duplicate("é", 300)
      reason = Portability.with_compile_error(@failed, long)
      cause = String.replace_prefix(reason, @failed <> " (", "") |> String.replace_suffix(")", "")
      assert byte_size(cause) <= 200
      assert String.ends_with?(cause, "…")
      assert String.valid?(cause)
    end

    test "a compile a signal ended, one out of time, any other reason or no error stays as it is" do
      for reason <- [
            "compile failed: host compile failed: mix compile exited with code 137",
            "compile failed: host compile failed: mix compile exited with code 128",
            "compile failed: host compile failed: the untraced host compile timed out",
            "compile failed: host compile failed: no time left for the host compile",
            "portability could not be judged",
            "compile failed: host compile failed: mix compile exited with code 1 (x)",
            nil
          ] do
        assert Portability.with_compile_error(reason, "error: boom") == reason, inspect(reason)
      end

      for error <- [nil, "", "  \n ", 1, ["error: boom"], <<0xFF>>] do
        assert Portability.with_compile_error(@failed, error) == @failed, inspect(error)
      end
    end

    test "compile_error_of/1 reads the error back" do
      for error <- ["error: boom", ~s|error: undefined variable "package" (deps/x/mix.exs:9)|] do
        assert @failed |> Portability.with_compile_error(error) |> Portability.compile_error_of() ==
                 error
      end

      for reason <- [
            @failed,
            "compile failed: host compile failed: mix compile exited with code 137",
            "portability could not be judged (tracer: :timeout)",
            nil
          ] do
        assert Portability.compile_error_of(reason) == nil, inspect(reason)
      end
    end

    test "the named reason is still a compile failure that the signal rule does not match" do
      reason = Portability.with_compile_error(@failed, "error: boom")
      assert String.starts_with?(reason, "compile failed: ")
      refute Regex.match?(~r/exited with code (12[89]|1[3-9][0-9]|2[0-5][0-9])$/, reason)
      refute Portability.could_not_judge?(reason)
      refute Portability.refusal?(reason)
    end
  end
end
