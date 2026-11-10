defmodule NccWorker.NervesCodeTest do
  use ExUnit.Case, async: true

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
            ~s(defmodule A do\n  def s, do: "nerves"\nend\n),
            ~s|defmodule A do\n  def c, do: ~c"nerves"\n  def w, do: ~w(nerves)a\nend\n|
          ] do
        refute NervesCode.elixir_mention?(source), source
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
      refute NervesCode.erlang_mention?(~s|-module(a).\nf() -> "nerves".\n|)
      refute NervesCode.erlang_mention?(~s|-module(a).\nf() -> "50% nerves".\n|)
      assert NervesCode.erlang_mention?("-module(a).\nf() -> nerves_runtime:reboot().\n")
      assert NervesCode.erlang_mention?("-module(a).\nf() -> 'Nerves'.\n")
      # `$%` is a character, not a comment; `$"` is not a string.
      assert NervesCode.erlang_mention?(~s|-module(a).\nf() -> {$%, $", nerves}.\n|)
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
