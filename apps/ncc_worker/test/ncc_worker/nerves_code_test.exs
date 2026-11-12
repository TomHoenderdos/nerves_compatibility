defmodule NccWorker.NervesCodeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias NccWorker.{BuildSelection, NervesCode}

  @moduletag :tmp_dir

  defp pkg(dir, files) do
    root = Path.join(dir, "pkg#{System.unique_integer([:positive])}")

    Enum.each(files, fn {path, body} ->
      File.mkdir_p!(Path.dirname(Path.join(root, path)))
      File.write!(Path.join(root, path), body)
    end)

    root
  end

  describe "Elixir" do
    test "prose does not count: docs, comments, strings, charlists, sigils" do
      for source <- [
            ~s(defmodule Fledex do\n  @moduledoc "Drive LED strips, also on Nerves devices"\nend\n),
            "# Works with Nerves.Runtime\ndefmodule A do end\n",
            ~s(defmodule A do\n  def s, do: "steady nerves"\nend\n),
            ~s|defmodule A do\n  def c, do: ~c"runs on Nerves"\n  def w, do: ~w(steady-nerves)a\nend\n|,
            ~s(defmodule A do\n  def s, do: "Nerves devices"\n  def t, do: "nerves-y"\nend\n),
            ~s(defmodule A do\n  def s, do: "Elixir.Nerves.runtime"\nend\n)
          ] do
        refute NervesCode.elixir_mention?(source), source
      end
    end

    test "a literal interpolated into an atom counts" do
      assert NervesCode.elixir_mention?(~S|def f(x), do: :"Elixir.Nerves.#{x}"|)
      assert NervesCode.elixir_mention?(~S|def f(x), do: ["nerves_#{x}": 1]|)
      refute NervesCode.elixir_mention?(~S|def f(x), do: :"plain_#{x}"|)
    end

    # Ruled in review: a literal whose whole content is a module or app name
    # is code that builds that name; a sentence is still prose.
    test "a string, charlist or ~w word that is a whole module or app name counts" do
      for source <- [
            ~S|def f, do: String.to_atom("Elixir.Nerves.Runtime").serial_number()|,
            ~S|def f, do: Module.concat(["Nerves", "Runtime"])|,
            ~S|def f, do: Module.concat("Nerves.Runtime")|,
            ~S|def f, do: ~w(nerves_runtime)a|,
            ~S|def f, do: ~w(foo nerves)a|,
            ~S|def f, do: :erlang.list_to_atom(~c"Elixir.Nerves.Runtime")|,
            "def f, do: :erlang.list_to_atom('Elixir.Nerves.Runtime')\n",
            ~S|def f, do: Application.spec(String.to_atom("NERVES_runtime"))|,
            # A name prefix, completed by concatenation or interpolation.
            ~S|def f(x), do: String.to_atom("Elixir.Nerves." <> x)|,
            ~S|def f(x), do: String.to_atom("nerves_" <> x)|,
            ~S|def f(x), do: String.to_atom("Elixir.Nerves.#{x}")|,
            ~S|def f(x), do: String.to_atom("nerves_#{x}")|
          ] do
        assert NervesCode.elixir_mention?(source), source
      end
    end

    test "code counts: an alias, an atom, an identifier, a dep, interpolation" do
      for source <- [
            "defmodule A do\n  alias Nerves.Runtime\nend\n",
            "defmodule A do\n  def f, do: :nerves_runtime\nend\n",
            "defmodule A do\n  def f(nerves_count), do: nerves_count\nend\n",
            ~s(defp deps, do: [{:nerves, "~> 1.10", runtime: false}]\n),
            ~S'''
            defmodule A do
              @moduledoc "on #{Nerves.Runtime.serial_number()}"
            end
            ''',
            ~s(defmodule A do\n  def q, do: :"some nerves"\nend\n)
          ] do
        assert NervesCode.elixir_mention?(source), source
      end
    end

    test "an alias segment counts only when it starts with Nerves" do
      refute NervesCode.elixir_mention?("defmodule MyNervesless.Thing do end\n")
      assert NervesCode.elixir_mention?("defmodule My.NervesThing do end\n")
    end

    test "a file that does not parse falls back to the raw search" do
      assert NervesCode.elixir_mention?("defmodule A do\n  <%= Nerves %>\n")
      refute NervesCode.elixir_mention?("defmodule A do\n  <%= x %>\n")
      # Not valid UTF-8, and a BOM: the fallback still sees code that names Nerves.
      assert NervesCode.elixir_mention?(<<0xFF, 0xFE>> <> "alias Nerves.Runtime\n")
      assert NervesCode.elixir_mention?(<<0xEF, 0xBB, 0xBF>> <> "alias Nerves.Runtime\n")
      refute NervesCode.elixir_mention?(<<0xEF, 0xBB, 0xBF>> <> "# nerves\ndefmodule A do end\n")
    end
  end

  describe "Erlang" do
    test "comments, strings and character literals do not count; atoms and calls do" do
      refute NervesCode.erlang_mention?("% nerves\n-module(a).\n")
      refute NervesCode.erlang_mention?(~s|-module(a).\nf() -> "steady nerves".\n|)
      refute NervesCode.erlang_mention?(~s|-module(a).\nf() -> io:format("~p nerves~n", []).\n|)
      refute NervesCode.erlang_mention?(~s|-module(a).\nf() -> "50% nerves".\n|)
      assert NervesCode.erlang_mention?("-module(a).\nf() -> nerves_runtime:reboot().\n")
      assert NervesCode.erlang_mention?("-module(a).\nf() -> 'Nerves'.\n")
      # `$%` is a character, not a comment; `$"` is not a string.
      assert NervesCode.erlang_mention?(~s|-module(a).\nf() -> {$%, $", nerves}.\n|)
    end

    test "a string that is a whole module or app name counts" do
      assert NervesCode.erlang_mention?(~s|-module(a).\nf() -> list_to_atom("nerves_runtime").\n|)
      assert NervesCode.erlang_mention?(~s|-module(a).\nf() -> binary_to_atom(<<"nerves">>).\n|)

      assert NervesCode.erlang_mention?(
               ~s|-module(a).\nf() -> list_to_atom("Elixir.Nerves.Runtime").\n|
             )

      assert NervesCode.erlang_mention?(~s|-module(a).\nf(X) -> list_to_atom("nerves_" ++ X).\n|)
    end

    # OTP 27+ sigils and triple-quoted strings: the lexer does not model them,
    # so their files keep the raw verdict instead of hiding code as string.
    test "sigils and triple-quoted strings keep the raw verdict" do
      for source <- [
            # ev1, ev2, ev5 from the review: all compile on OTP 28.
            ~s|-module(ev1).\nf() -> {~S"\\", nerves_runtime:serial_number(), "x"}.\n|,
            ~s|-module(ev2).\nf() -> {"""\n  a " b\n  """, nerves_runtime:serial_number(), "c"}.\n|,
            ~s|-module(ev5).\nf() -> {~s{a"b}, nerves_runtime:serial_number(), "c"}.\n|,
            # The raw verdict also refuses prose, which is today's rule.
            ~s|-module(a).\nf() -> ~"steady nerves".\n|
          ] do
        assert NervesCode.erlang_mention?(source), source
      end

      # A `~` in a comment or a string is not a sigil.
      refute NervesCode.erlang_mention?(~s|-module(a).\n% ~p nerves\nf() -> "~p".\n|)
    end

    # `\^X` is a three-byte control escape; ev11 and ev12 from the second review.
    test "a control escape does not swallow the code after it" do
      assert NervesCode.erlang_mention?(
               ~s|-module(ev11).\nf() -> {"\\^\\", nerves_runtime:serial_number(), "\\"", ok}.\n|
             )

      assert NervesCode.erlang_mention?(
               ~s|-module(ev12).\nf() -> {'\\^\\', nerves_runtime:serial_number(), '\\'', ok}.\n|
             )
    end

    test "the lexer is linear on unterminated escapes" do
      for unit <- [~s|"\\|, ~s|'\\|, ~s|$\\|] do
        source = "% nerves\nf() -> ok.\n" <> String.duplicate(unit, 80_000)
        {us, _} = :timer.tc(fn -> NervesCode.erlang_mention?(source) end)
        assert us < 2_000_000, "#{inspect(unit)} took #{div(us, 1000)} ms"
      end
    end
  end

  describe "mention/1" do
    test "priv is skipped; a missing dir is :missing", %{tmp_dir: dir} do
      root =
        pkg(dir, %{
          "lib/a.ex" => "defmodule A do end\n",
          "priv/templates/phx.gen.x/context.ex" => "<%= Nerves.Runtime %>\n"
        })

      assert NervesCode.mention(root) == :none
      assert NervesCode.mention(Path.join(dir, "absent")) == :missing
    end

    test "a symlinked source is not followed", %{tmp_dir: dir} do
      outside = pkg(dir, %{"x.ex" => "alias Nerves.Runtime\n"})
      root = pkg(dir, %{"lib/a.ex" => "defmodule A do end\n"})
      File.ln_s!(Path.join(outside, "x.ex"), Path.join(root, "lib/link.ex"))
      assert NervesCode.mention(root) == :none
    end

    test "a file over 2 MB uses the raw search", %{tmp_dir: dir} do
      big = "# nerves\n" <> String.duplicate("# padding line\n", 150_000)
      assert NervesCode.mention(pkg(dir, %{"lib/big.ex" => big})) == :found
    end

    test "a file over 2 MB without the word is :none", %{tmp_dir: dir} do
      big = String.duplicate("# padding line nerve s\n", 150_000)
      assert NervesCode.mention(pkg(dir, %{"lib/big.ex" => big})) == :none
    end

    test "past the time budget, files use the raw search", %{tmp_dir: dir} do
      root = pkg(dir, %{"lib/a.ex" => "# runs on Nerves\ndefmodule A do end\n"})
      assert NervesCode.mention(root) == :none
      assert NervesCode.mention(root, budget_ms: 0) == :found
    end

    # Packages the plain grep refused as "nerves-specific source": Nerves
    # named only in prose, in shapes taken from their Hex releases.
    test "a mention only in README.md is :none", %{tmp_dir: dir} do
      root =
        pkg(dir, %{
          "README.md" => "Runs on Nerves; set `MIX_TARGET` and see nerves_livebook.\n",
          "lib/a.ex" => "defmodule A do\n  def f, do: :ok\nend\n"
        })

      assert NervesCode.mention(root) == :none
    end

    test "elixir_make 0.10.1: Nerves in a Mix task's @moduledoc heredoc is :none",
         %{tmp_dir: dir} do
      root =
        pkg(dir, %{
          "lib/mix/tasks/compile.elixir_make.ex" => ~S'''
          defmodule Mix.Tasks.Compile.ElixirMake do
            @moduledoc """
            Copy the artifacts to `$MIX_APP_PATH/priv/$MIX_TARGET`. This is relevant for
            projects like Nerves that build for several targets and may involve
            cross-compilation.
            """

            use Mix.Task

            def run(args), do: ElixirMake.Compiler.compile(Mix.Project.config(), args)
          end
          '''
        })

      assert NervesCode.mention(root) == :none
    end

    test "fledex 0.8.1: Nerves in mix.exs's description and the README is :none",
         %{tmp_dir: dir} do
      root =
        pkg(dir, %{
          "README.md" =>
            "Written for a RaspberryPi Zero W running [Nerves](https://nerves-project.org/).\n",
          "mix.exs" => ~S'''
          defmodule Fledex.MixProject do
            use Mix.Project

            def project do
              [app: :fledex, version: "0.8.1", description: description(), deps: []]
            end

            defp description do
              "A small library to easily control an LED strip with nerves (or nerves-livebook)"
            end
          end
          '''
        })

      assert NervesCode.mention(root) == :none
    end

    test "nerves_time 0.4.8: a package that calls Nerves code is :found", %{tmp_dir: dir} do
      root =
        pkg(dir, %{
          "README.md" => "# nerves_time\n",
          "lib/nerves_time/application.ex" => ~S'''
          defmodule NervesTime.Application do
            @moduledoc false
            use Application

            def start(_type, _args) do
              children = [NervesTime.SystemTime, NervesTime.Ntpd]
              Supervisor.start_link(children, strategy: :one_for_one, name: NervesTime.Supervisor)
            end
          end
          '''
        })

      assert NervesCode.mention(root) == :found
    end
  end

  describe "bounded/2" do
    test "a result comes back" do
      assert NervesCode.bounded(fn -> {:ok, true} end) == {:ok, true}
    end

    test "a timeout falls back" do
      assert NervesCode.bounded(fn -> Process.sleep(:infinity) end, timeout_ms: 50) == :fallback
    end

    test "the heap cap falls back" do
      grow = fn -> {:ok, List.last(Enum.to_list(1..5_000_000)) > 0} end
      assert NervesCode.bounded(grow, max_heap_words: 100_000) == :fallback
    end

    test "a crash falls back" do
      capture_log(fn ->
        assert NervesCode.bounded(fn -> raise "boom" end) == :fallback
      end)
    end

    # Monotone: over real packages, every new refusal is an old one.
    test "over the umbrella's deps, new refusals are a subset of the grep's" do
      deps = Path.expand("../../../../deps", __DIR__)
      assert File.dir?(deps), "run `mix deps.get` from the repo root first"

      for name <- File.ls!(deps), dir = Path.join(deps, name), File.dir?(dir) do
        if NervesCode.mention(dir) == :found, do: assert(old_grep(dir) == :found, name)
      end
    end
  end

  test "rule 1 and the Nerves classification keep the grep", %{tmp_dir: dir} do
    root = Path.join(dir, "proj")
    source = Path.join([root, "deps", "sample"])
    File.mkdir_p!(Path.join(source, "lib"))

    File.write!(
      Path.join(source, "lib/a.ex"),
      "# runs on Nerves.Runtime too\ndefmodule A do end\n"
    )

    assert NervesCode.mention(source) == :none
    assert old_grep(source) == :found

    scan = %{
      beam_count: 1,
      languages: [:elixir],
      errors: [],
      nif_calls?: false,
      shell_calls?: false,
      os_exec_calls?: false,
      executable_lookup_calls?: false,
      footprint: %{priv: %{file_count: 0}}
    }

    assert BuildSelection.portable?(root, "sample", scan) == {:skip, "nerves-specific source"}
  end

  defp old_grep(dir) do
    args = ~w(-r -q -i --include=*.ex --include=*.exs --include=*.erl -e nerves --) ++ [dir]

    case System.cmd("grep", args, stderr_to_stdout: true) do
      {_, 0} -> :found
      {_, 1} -> :none
      _ -> :error
    end
  end
end

defmodule NccWorker.NervesCodeAtomTest do
  # Synchronous: async test modules create atoms of their own while they run,
  # and those would show up in the count.
  use ExUnit.Case, async: false

  alias NccWorker.NervesCode

  # The first parse loads the tokenizer and parser modules, which brings in
  # their atoms; that happens once per VM, not per input.
  defp warm_up do
    NervesCode.elixir_mention?("defmodule W do\n  def f(x), do: :w\nend\n")
    NervesCode.erlang_mention?("-module(w).\nf() -> w.\n")
  end

  test "Elixir parsing creates no atoms" do
    source =
      Enum.map_join(1..10_000, "\n", fn i ->
        "def ncc_never_ident_#{i}(a), do: :ncc_never_atom_#{i}"
      end)

    warm_up()
    before = :erlang.system_info(:atom_count)
    refute NervesCode.elixir_mention?(source)
    assert :erlang.system_info(:atom_count) == before
  end

  test "Erlang lexing creates no atoms" do
    source = Enum.map_join(1..10_000, "\n", &"f#{&1}() -> ncc_never_erl_atom_#{&1}.")
    warm_up()
    before = :erlang.system_info(:atom_count)
    refute NervesCode.erlang_mention?(source)
    assert :erlang.system_info(:atom_count) == before
  end
end
