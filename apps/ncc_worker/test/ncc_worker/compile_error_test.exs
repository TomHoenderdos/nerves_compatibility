defmodule NccWorker.CompileErrorTest do
  use ExUnit.Case, async: true

  alias NccWorker.CompileError

  @proj "/work/proj"
  @marker "==> the traced host compile is not the build (exit_1); " <>
            "compiling untraced from a clean _build/host\n"

  # The logs below are the untraced compiles of real toolchain builds
  # (Elixir 1.19.3/OTP 28 and 1.20.3/OTP 29), trimmed.

  test "an Elixir diagnostic, with the file and line it names, relative to the project" do
    log = """
    ==> prom_ex
    Compiling 40 files (.ex)
        error: module Plug.Conn is not loaded and could not be found
        │
     44 │   import Plug.Conn
        │   ^
        │
        └─ lib/prom_ex/plug.ex:44:3: PromEx.Plug (module)


    == Compilation error in file lib/prom_ex/plug.ex ==
    ** (CompileError) lib/prom_ex/plug.ex: cannot compile module PromEx.Plug (errors have been logged)

    could not compile dependency :prom_ex, "mix compile" failed. Errors may have been logged above.
    """

    assert CompileError.first(log, @proj) ==
             "error: module Plug.Conn is not loaded and could not be found (lib/prom_ex/plug.ex:44)"

    log = """
        error: undefined variable "package"
        │
     11 │      package: package,
        │               ^^^^^^^
        │
        └─ /work/proj/deps/pkcs7/mix.exs:11:15: PKCS7.Mixfile.project/0

        error: undefined variable "deps"
        │
        └─ /work/proj/deps/pkcs7/mix.exs:12:12: PKCS7.Mixfile.project/0

    Error while loading project :pkcs7 at /work/proj/deps/pkcs7
    ** (CompileError) deps/pkcs7/mix.exs: cannot compile module PKCS7.Mixfile (errors have been logged)
    """

    assert CompileError.first(log, @proj) ==
             ~s|error: undefined variable "package" (deps/pkcs7/mix.exs:11)|
  end

  test "an Erlang or C compiler error, its warnings left out" do
    log = """
    ==> khepri_mnesia_migration
    Compiling 13 files (.erl)
    src/m2k_table_copy.erl:662:33: Warning: variable 'MigrationId' is unused
    %  662| clear_migration_marker(StoreId, MigrationId, Pid, Tables) ->
    %     |                                 ^

    src/m2k_cluster_sync.erl:17:14: can't find include lib "khepri/include/khepri.hrl"
    %   17| -include_lib("khepri/include/khepri.hrl").
    src/m2k_cluster_sync.erl:498:22: undefined macro 'khepri_error/2'
    could not compile dependency :khepri_mnesia_migration, "mix compile" failed.
    """

    assert CompileError.first(log, @proj) ==
             ~s|src/m2k_cluster_sync.erl:17: can't find include lib "khepri/include/khepri.hrl"|

    log = """
    ===> Analyzing applications...
    ===> Compiling p1_utils
    ===> Compiling /work/proj/deps/fast_tls/c_src/fast_tls.c
    ===> /work/proj/deps/fast_tls/c_src/fast_tls.c:21:10: fatal error: openssl/err.h: No such file or directory
       21 | #include <openssl/err.h>
    compilation terminated.

    ** (Mix) Could not compile dependency :fast_tls, "/home/nerves/.mix/elixir/1-19-otp-28/rebar3 bare compile --paths /work/proj/_build/host/lib/*/ebin" command failed. Errors may have been logged above.
    """

    assert CompileError.first(log, @proj) ==
             "deps/fast_tls/c_src/fast_tls.c:21: fatal error: openssl/err.h: No such file or directory"
  end

  test "a warning's or a stacktrace's location is not an error" do
    log = """
    ==> telemetry_metrics_prometheus_core
    Compiling 9 files (.ex)
    warning: first..last inside match is deprecated, you must always match on the step
      lib/core/registry.ex:87: TelemetryMetricsPrometheus.Core.Registry.validate_distribution_buckets!/1

    ==> prom_ex
        error: module Plug.Conn is not loaded and could not be found
        │
        └─ lib/prom_ex/plug.ex:44:3: PromEx.Plug (module)
    """

    assert CompileError.first(log, @proj) ==
             "error: module Plug.Conn is not loaded and could not be found (lib/prom_ex/plug.ex:44)"

    log = """
    == Compilation error in file lib/git_hooks.ex ==
    ** (RuntimeError) git_hooks: /work/proj/deps/git_hooks is not inside a git working tree.
        lib/git/git_path.ex:55: GitHooks.Git.GitPath.git_toplevel/0
        (stdlib 6.2) erl_eval.erl:919: :erl_eval.do_apply/7
        src/rebar_core.erl:12: rebar_core:process/2
    """

    assert CompileError.first(log, @proj) ==
             "** (RuntimeError) git_hooks: deps/git_hooks is not inside a git working tree."
  end

  test "a build program the shell could not find" do
    log = """
    sh: 1: exec: cargo: not found
    ===> Hook for compile failed!

    ** (Mix) Could not compile dependency :multihash, "/home/nerves/.mix/elixir/1-19-otp-28/rebar3 bare compile --paths /work/proj/_build/host/lib/*/ebin" command failed.
    """

    assert CompileError.first(log, @proj) == "sh: 1: exec: cargo: not found"

    assert CompileError.first("/bin/sh: line 1: cmake: command not found\n", @proj) ==
             "/bin/sh: line 1: cmake: command not found"
  end

  test "rebar3's failed file, with the first error under it, not a warning above it" do
    log = """
    ===> Compiling gen_smtp
         ┌─ src/gen_smtp_server_session.erl:
         │
     574 │                              crypto:start(),
         │                              ╰── Warning: crypto:start/0 is deprecated; use application:start(crypto) instead


    ===> Compiling src/smtp_server_example.erl failed
         ┌─ src/smtp_server_example.erl:
         │
     296 │      {ok, State} | {stop, any(), State}.
         │           ╰── type variable 'State' is only used once (is unbound)


    ** (Mix) Could not compile dependency :gen_smtp, "/home/nerves/.mix/elixir/1-19-otp-28/rebar3 bare compile --paths /work/proj/_build/host/lib/*/ebin" command failed.
    """

    assert CompileError.first(log, @proj) ==
             "Compiling src/smtp_server_example.erl failed: " <>
               "type variable 'State' is only used once (is unbound)"
  end

  test "an exception, past Mix's own summary lines and terminal colours" do
    log = """
    ==> git_hooks
    Compiling 15 files (.ex)
    \e[34m↗ Installing git hooks...
    \e[39m
    == Compilation error in file lib/git_hooks.ex ==
    ** (RuntimeError) git_hooks: /work/proj/deps/git_hooks is not inside a git working tree.
    fatal: not a git repository (or any parent up to mount point /)
    could not compile dependency :git_hooks, "mix compile" failed.
    """

    assert CompileError.first(log, @proj) ==
             "** (RuntimeError) git_hooks: deps/git_hooks is not inside a git working tree."

    log = """
    ==> fresh
    could not compile dependency :fresh, "mix compile" failed. Errors may have been logged above.
    ==> nerves_compatibility_test
    ** (Mix) :elixirc_paths should be a list of string paths, got: [~c"lib"]
    """

    assert CompileError.first(log, @proj) ==
             ~s|** (Mix) :elixirc_paths should be a list of string paths, got: [~c"lib"]|
  end

  test "Mix's account of a dependency it could not build" do
    log = """
    ===> Compiling hpack
    Unchecked dependencies for environment prod:
    * hpack_erl (Hex package)
      could not find an app file at "_build/host/lib/hpack_erl/ebin/hpack_erl.app". Another app file was found in the same directory "_build/host/lib/hpack_erl/ebin/hpack.app", try changing the dependency name to :hpack
    ** (Mix) Can't continue due to errors on dependencies
    """

    assert CompileError.first(log, @proj) ==
             ~s|could not find an app file at "_build/host/lib/hpack_erl/ebin/hpack_erl.app". | <>
               ~s|Another app file was found in the same directory | <>
               ~s|"_build/host/lib/hpack_erl/ebin/hpack.app", try changing the dependency name to :hpack|
  end

  test "only Mix's generic line when nothing names the error" do
    log = """
    ==> websockex
    could not compile dependency :websockex, "mix compile" failed. Errors may have been logged above. You can recompile this dependency with "mix deps.compile websockex --force"
    """

    assert CompileError.first(log, @proj) ==
             ~s|could not compile dependency :websockex, "mix compile" failed|
  end

  test "the untraced compile's error when the log holds the traced one's too" do
    log =
      "    error: from the traced compile\n" <>
        @marker <>
        "** (ArgumentError) could not load module Scrivener.Paginater due to reason :nofile\n"

    assert CompileError.first(log, @proj) ==
             "** (ArgumentError) could not load module Scrivener.Paginater due to reason :nofile"
  end

  test "nil when the log names no error, or there is no log" do
    assert CompileError.first("==> sample\nCompiling 1 file (.ex)\n", @proj) == nil
    assert CompileError.first("", @proj) == nil
    assert CompileError.first(nil, @proj) == nil
  end

  test "bytes that are not UTF-8 never raise" do
    log = <<0x94, 0x80, "\nsrc/x.erl:3: syntax error before: ", 0xFF, "\n">>
    assert CompileError.first(log, @proj) == "src/x.erl:3: syntax error before: \uFFFD"
  end

  test "an overlong line is cut to whole code points" do
    line = "    error: " <> String.duplicate("é", 2000) <> "\n"
    error = CompileError.first(line, @proj)
    assert byte_size(error) <= 1000
    assert String.valid?(error)
    assert String.starts_with?(error, "error: é")
  end
end
