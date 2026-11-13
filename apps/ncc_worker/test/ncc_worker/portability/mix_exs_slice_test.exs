defmodule NccWorker.Portability.MixExsSliceTest do
  use ExUnit.Case, async: true

  alias NccWorker.Portability.MixExsSlice

  # The observation is on the line marked `# <-`.
  defp judge(source) do
    line =
      source
      |> String.split("\n")
      |> Enum.find_index(&String.contains?(&1, "# <-"))
      |> Kernel.+(1)

    MixExsSlice.judge(source, line)
  end

  test "a read used only for deps is allowed (the dashboard's LIVE_VIEW_PATH)" do
    assert :ok =
             judge("""
             defmodule D.MixProject do
               use Mix.Project
               def project, do: [app: :d, version: "0.8.7", deps: deps()]
               defp deps, do: [{:phoenix_live_view, live_view_opts()}]
               defp live_view_opts do
                 if path = System.get_env("LIVE_VIEW_PATH") do # <-
                   [path: path]
                 else
                   "~> 1.0"
                 end
               end
             end
             """)
  end

  test "a read in test_paths is allowed (sentry's SENTRY_INTEGRATION)" do
    assert :ok =
             judge("""
             defmodule S.MixProject do
               use Mix.Project
               def project do
                 [
                   app: :sentry,
                   version: "14.0.1",
                   test_paths: if(System.get_env("SENTRY_INTEGRATION"), do: ["i"], else: ["test"]), # <-
                   deps: []
                 ]
               end
             end
             """)
  end

  test "a module-body conditional choosing a dependency's version is allowed (plug)" do
    assert :ok =
             judge("""
             defmodule P.MixProject do
               use Mix.Project
               if System.get_env("PLUG_CRYPTO_2_0", "true") == "true" do # <-
                 defp plug_crypto_version, do: "~> 2.0"
               else
                 defp plug_crypto_version, do: "~> 1.1"
               end
               def project, do: [app: :plug, version: "1.0.0", deps: deps()]
               defp deps, do: [{:plug_crypto, plug_crypto_version()}]
             end
             """)
  end

  test "a read in elixirc_options refuses" do
    assert {:refuse, "sets elixirc_options"} =
             judge("""
             defmodule E.MixProject do
               use Mix.Project
               def project do
                 [app: :e, version: "1.0.0", elixirc_options: [debug_info: System.get_env("D") == "1"]] # <-
               end
             end
             """)
  end

  test "erlc_options chosen by :os.type() refuses through a module attribute" do
    assert {:refuse, "sets erlc_options"} =
             judge("""
             defmodule W.MixProject do
               use Mix.Project
               @defines if match?({:win32, _}, :os.type()), do: [{:d, :WIN}], else: [] # <-
               def project, do: [app: :w, version: "1.0.0", erlc_options: @defines]
             end
             """)
  end

  test "a version derived from git refuses through a helper" do
    assert {:refuse, "sets version"} =
             judge("""
             defmodule G.MixProject do
               use Mix.Project
               def project, do: [app: :g, version: version()]
               defp version do
                 {v, 0} = System.cmd("git", ["describe"]) # <-
                 String.trim(v)
               end
             end
             """)
  end

  test "a read that reaches application/0 refuses" do
    assert {:refuse, "reaches application/0"} =
             judge("""
             defmodule A.MixProject do
               use Mix.Project
               def project, do: [app: :a, version: "1.0.0"]
               def application, do: [env: [host: System.get_env("HOST")]] # <-
             end
             """)
  end

  test "a compile alias makes aliases compile-relevant; others are not" do
    assert {:refuse, "sets aliases"} =
             judge("""
             defmodule C.MixProject do
               use Mix.Project
               def project, do: [app: :c, version: "1.0.0", aliases: [compile: [System.get_env("X")]]] # <-
             end
             """)

    assert :ok =
             judge("""
             defmodule C.MixProject do
               use Mix.Project
               def project, do: [app: :c, version: "1.0.0", aliases: [docs: [System.get_env("X")]]] # <-
             end
             """)
  end

  test "keyword literals joined with ++ local calls are followed" do
    assert {:refuse, "sets compilers"} =
             judge("""
             defmodule J.MixProject do
               use Mix.Project
               def project, do: [app: :j, version: "1.0.0"] ++ extra()
               defp extra, do: [compilers: [System.get_env("C")]] # <-
             end
             """)
  end

  test "a project/0 that is not a keyword literal refuses whatever the read" do
    assert {:refuse, "project/0 is not a keyword list literal"} =
             judge("""
             defmodule K.MixProject do
               use Mix.Project
               def project, do: Keyword.merge(base(), deps: deps())
               defp base, do: [app: :k, version: "1.0.0"]
               defp deps, do: [{:x, System.get_env("V")}] # <-
             end
             """)
  end

  test "an unparsable file refuses" do
    assert {:refuse, "mix.exs does not parse"} = MixExsSlice.judge("defmodule (", 1)
  end

  describe "fail closed" do
    test "a defp defined twice under a host conditional taints its callers" do
      assert {:refuse, "sets erlc_options"} =
               judge("""
               defmodule T.MixProject do
                 use Mix.Project
                 case :os.type() do # <-
                   {:win32, _} -> defp defines, do: [{:d, :WIN}]
                   _ -> defp defines, do: []
                 end
                 def project, do: [app: :t, version: "1.0.0", erlc_options: defines()]
               end
               """)
    end

    test "an attribute assigned inside a host conditional is tainted" do
      assert {:refuse, "sets erlc_options"} =
               judge("""
               defmodule T.MixProject do
                 use Mix.Project
                 if match?({:win32, _}, :os.type()) do # <-
                   @defines [{:d, :WIN}]
                 else
                   @defines []
                 end
                 def project, do: [app: :t, version: "1.0.0", erlc_options: @defines]
               end
               """)
    end

    test "default arguments and captures do not hide a tainted helper" do
      assert {:refuse, "sets version"} =
               judge("""
               defmodule T.MixProject do
                 use Mix.Project
                 def project, do: [app: :t, version: version()]
                 defp version(prefix \\\\ "") do
                   prefix <> System.get_env("V") # <-
                 end
               end
               """)

      assert {:refuse, "sets compilers"} =
               judge("""
               defmodule T.MixProject do
                 use Mix.Project
                 def project, do: [app: :t, version: "1.0.0", compilers: Enum.map([:a], &pick/1)]
                 defp pick(c), do: if(System.get_env("C"), do: c, else: :b) # <-
               end
               """)
    end

    test "a self-qualified call is followed like a local one" do
      assert {:refuse, "sets version"} =
               judge("""
               defmodule T.MixProject do
                 use Mix.Project
                 def project, do: [app: :t, version: __MODULE__.version()]
                 def version, do: System.get_env("V") # <-
               end
               """)
    end

    test "an observation outside every definition refuses" do
      assert {:refuse, "observation outside every definition"} =
               judge("""
               defmodule T.MixProject do
                 use Mix.Project
                 Process.put(:v, System.get_env("V")) # <-
                 def project, do: [app: :t, version: "1.0.0", deps: []]
               end
               """)

      assert {:refuse, "observation outside every definition"} =
               judge("""
               v = System.get_env("V") # <-
               defmodule T.MixProject do
                 use Mix.Project
                 def project, do: [app: :t, version: "1.0.0", deps: []]
               end
               """)
    end

    test "a line the file does not have refuses" do
      source = """
      defmodule T.MixProject do
        use Mix.Project
        def project, do: [app: :t, version: "1.0.0"]
      end
      """

      assert {:refuse, "observation outside every definition"} = MixExsSlice.judge(source, 99)
    end

    test "a store read back in a compile-relevant key refuses" do
      assert {:refuse, "sets version"} =
               judge("""
               defmodule T.MixProject do
                 use Mix.Project
                 def project, do: [app: :t, version: Process.get(:v), deps: deps()]
                 defp deps do
                   Process.put(:v, System.get_env("V")) # <-
                   []
                 end
               end
               """)

      assert {:refuse, "sets version"} =
               judge("""
               defmodule T.MixProject do
                 use Mix.Project
                 def project, do: [app: :t, version: :persistent_term.get(:v), deps: deps()]
                 defp deps, do: [{:x, System.get_env("V")}] # <-
               end
               """)
    end

    test "an unknown local or remote call in a compile-relevant key refuses" do
      assert {:refuse, "sets version"} =
               judge("""
               defmodule T.MixProject do
                 use Mix.Project
                 import Helper
                 def project, do: [app: :t, version: helper_version(), deps: deps()]
                 defp deps, do: [{:x, System.get_env("V")}] # <-
               end
               """)

      assert {:refuse, "reaches application/0"} =
               judge("""
               defmodule T.MixProject do
                 use Mix.Project
                 def project, do: [app: :t, version: "1.0.0", deps: deps()]
                 def application, do: [env: Helper.env()]
                 defp deps, do: [{:x, System.get_env("V")}] # <-
               end
               """)
    end

    test "a tainted value handed to a module-body statement refuses" do
      assert {:refuse, "reaches a module-body statement"} =
               judge("""
               defmodule T.MixProject do
                 use Mix.Project
                 defp v, do: System.get_env("V") # <-
                 System.put_env("W", v())
                 def project, do: [app: :t, version: "1.0.0", deps: []]
               end
               """)
    end

    test "dynamic evaluation anywhere in mix.exs refuses" do
      for snippet <- [
            ~s|@version Code.eval_string("1")|,
            ~s|Module.register_attribute(__MODULE__, :x, accumulate: true)|,
            ~s|defmacro m, do: quote(do: 1)|,
            ~s|@cfg Mix.Project.config()|
          ] do
        assert {:refuse, "mix.exs evaluates code dynamically"} =
                 judge("""
                 defmodule T.MixProject do
                   use Mix.Project
                   #{snippet}
                   def project, do: [app: :t, version: "1.0.0", deps: deps()]
                   defp deps, do: [{:x, System.get_env("V")}] # <-
                 end
                 """)
      end
    end

    test "a typical mix.exs with ordinary helpers stays allowed" do
      assert :ok =
               judge("""
               defmodule T.MixProject do
                 use Mix.Project
                 @version "1.2.3"
                 @source_url "https://example.com/t"
                 def project do
                   [
                     app: :t,
                     version: @version,
                     elixir: "~> 1.14",
                     elixirc_paths: elixirc_paths(Mix.env()),
                     compilers: Mix.compilers(),
                     start_permanent: Mix.env() == :prod,
                     deps: deps(),
                     docs: [source_url: @source_url]
                   ]
                 end
                 def application, do: [extra_applications: [:logger], mod: {T.Application, []}]
                 defp elixirc_paths(:test), do: ["lib", "test/support"]
                 defp elixirc_paths(_), do: ["lib"]
                 defp deps do
                   [{:jason, System.get_env("JASON_VERSION", "~> 1.0")}] # <-
                 end
               end
               """)
    end

    test "a project/0 defined twice refuses" do
      assert {:refuse, "project/0 is not one plain definition"} =
               judge("""
               defmodule T.MixProject do
                 use Mix.Project
                 if System.get_env("X") do # <-
                   def project, do: [app: :t, version: "1.0.0"]
                 else
                   def project, do: [app: :t, version: "2.0.0"]
                 end
               end
               """)
    end
  end

  describe "what the slice cannot read" do
    test "a definition the slice cannot name refuses instead of raising" do
      assert {:refuse, "mix.exs defines a function the slice cannot name"} =
               judge("""
               defmodule T.MixProject do
                 use Mix.Project
                 def Foo.bar, do: 1
                 def project, do: [app: :t, version: "1.0.0", deps: deps()]
                 defp deps, do: [{:x, System.get_env("V")}] # <-
               end
               """)
    end

    test "an unexpected failure inside the analysis refuses, never raises" do
      assert {:refuse, "mix.exs could not be analysed"} =
               MixExsSlice.judge(%MixExsSlice{index: :garbage}, 1)
    end

    test "the module that uses Mix.Project is the one judged" do
      assert :ok =
               judge("""
               defmodule Helper do
                 def project, do: :not_this_one
               end
               defmodule T.MixProject do
                 use Mix.Project
                 def project, do: [app: :t, version: "1.0.0", deps: deps()]
                 defp deps, do: [{:x, System.get_env("V")}] # <-
               end
               """)

      assert {:refuse, "observation outside every definition"} =
               judge("""
               defmodule T.MixProject do
                 use Mix.Project
                 def project, do: [app: :t, version: Helper.v()]
               end
               defmodule Helper do
                 def v, do: System.get_env("V") # <-
               end
               """)
    end

    test "no or several Mix.Project modules refuse" do
      assert {:refuse, "mix.exs defines no Mix.Project module"} =
               judge("""
               defmodule T.MixProject do
                 def project, do: [app: :t, version: "1.0.0", deps: deps()]
                 defp deps, do: [{:x, System.get_env("V")}] # <-
               end
               """)

      assert {:refuse, "mix.exs defines several Mix.Project modules"} =
               judge("""
               defmodule A.MixProject do
                 use Mix.Project
                 def project, do: [app: :a, version: "1.0.0"]
               end
               defmodule T.MixProject do
                 use Mix.Project
                 def project, do: [app: :t, version: "1.0.0", deps: deps()]
                 defp deps, do: [{:x, System.get_env("V")}] # <-
               end
               """)
    end

    test "Application reads in a compile-relevant key do not refuse an unrelated observation" do
      assert :ok =
               judge("""
               defmodule E.MixProject do
                 use Mix.Project
                 def project do
                   [app: :e, version: "1.0.0", make_force_build: Application.get_env(:e, :force, false), deps: deps()]
                 end
                 defp deps, do: [{:x, System.get_env("V")}] # <-
               end
               """)
    end

    test "an oversized source refuses" do
      source =
        "defmodule T.MixProject do\n  use Mix.Project\n  def project, do: [app: :t]\nend\n" <>
          String.duplicate("# padding\n", 30_000)

      assert {:refuse, "mix.exs is too large"} = MixExsSlice.judge(source, 3)
    end

    test "a too deeply nested source refuses" do
      nested = String.duplicate("[", 400) <> String.duplicate("]", 400)

      source = """
      defmodule T.MixProject do
        use Mix.Project
        def project, do: [app: :t, version: "1.0.0", deps: deps()]
        defp deps, do: #{nested}
      end
      """

      assert {:refuse, "mix.exs is too deeply nested"} = MixExsSlice.judge(source, 4)
    end

    test "one analysis judges many observations" do
      source = """
      defmodule T.MixProject do
        use Mix.Project
        def project, do: [app: :t, version: version(), deps: deps()]
        defp version, do: System.get_env("V")
        defp deps, do: [{:x, System.get_env("X")}]
      end
      """

      assert {:ok, %MixExsSlice{} = analysis} = MixExsSlice.analyse(source)
      assert {:refuse, "sets version"} = MixExsSlice.judge(analysis, 4)
      assert :ok = MixExsSlice.judge(analysis, 5)
      assert {:refuse, "mix.exs does not parse"} = MixExsSlice.analyse("defmodule (")
    end
  end

  describe "direct_version_line?/3" do
    # Credo's shape: a module-body conditional on the Elixir version that
    # picks which helper project/0 joins, so the slice itself refuses.
    @credo """
    defmodule C.MixProject do
      use Mix.Project
      def project, do: [app: :c, version: "1.0.0", deps: []] ++ cli_entry()
      if Version.match?(System.version(), ">= 1.19.0-dev") do
        defp cli_entry, do: []
      else
        defp cli_entry, do: [preferred_cli_env: []]
      end
      defp opts do
        if Version.compare(System.version(), "1.20.0-dev") == :lt, do: [a: 1], else: []
      end
      defp multi do
        Version.match?(
          System.version(),
          "~> 1.15"
        )
      end
      defp other, do: System.version() |> String.split(".")
      defp both, do: Version.match?(System.version(), ">= 1.0.0") and System.version() > "1"
      defp req, do: Version.match?(System.version(), @req)
      defp three, do: Version.match?(System.version(), "~> 1.0", allow_pre: false)
      defp info, do: Version.match?(System.version(), "~> 1.0") and System.build_info()
    end
    """

    defp direct?(source, line, mfa) do
      {:ok, analysis} = MixExsSlice.analyse(source)
      MixExsSlice.direct_version_line?(analysis, line, mfa)
    end

    test "System.version() as a direct argument of a literal Version.match?/compare" do
      assert {:refuse, _} = MixExsSlice.judge(@credo, 4)

      for line <- [4, 10] do
        assert direct?(@credo, line, "System.version/0")
      end

      assert direct?(@credo, 4, "Version.match?/2")
      assert direct?(@credo, 10, "Version.compare/2")
      refute direct?(@credo, 4, "Version.compare/2")
      refute direct?(@credo, 10, "Version.match?/2")
      refute direct?(@credo, 4, "System.build_info/0")
      refute direct?(@credo, 4, "Version.match?/3")

      # Over several lines: the read's line and the call's line each pass.
      assert direct?(@credo, 13, "Version.match?/2")
      assert direct?(@credo, 14, "System.version/0")
      refute direct?(@credo, 15, "System.version/0")
    end

    test "any other use of the version on the line refuses" do
      for line <- 19..22 do
        for mfa <- ["System.version/0", "Version.match?/2"] do
          refute direct?(@credo, line, mfa), "line #{line} #{mfa}"
        end
      end

      refute direct?(@credo, 18, "System.version/0")
      refute direct?(@credo, 3, "System.version/0")
      refute direct?(@credo, 999, "System.version/0")
    end

    test "a file that can rename Version or System refuses" do
      for header <- [
            "alias Foo.Version",
            "alias Foo.Bar, as: System",
            "import Version",
            "alias Foo.{Version, Bar}",
            "defmodule Version do\n  def match?(_, _), do: true\nend"
          ] do
        source = String.replace(@credo, "  use Mix.Project\n", "  use Mix.Project\n  #{header}\n")
        line = @credo |> String.split("\n") |> Enum.find_index(&(&1 =~ "1.19.0-dev"))
        shift = header |> String.split("\n") |> length()

        refute direct?(source, line + 1 + shift, "System.version/0"), header
      end

      # An unrelated alias does not.
      source =
        String.replace(@credo, "  use Mix.Project\n", "  use Mix.Project\n  alias Foo.Bar\n")

      assert direct?(source, 5, "System.version/0")
    end

    test "a qualified Elixir.Version or a capture is no direct call" do
      source = """
      defmodule C.MixProject do
        use Mix.Project
        def project, do: [app: :c, version: "1.0.0", deps: []]
        defp a, do: Elixir.Version.match?(System.version(), "~> 1.0")
        defp b, do: Enum.map([System.version()], &Version.match?(&1, "~> 1.0"))
        defp c, do: Version.match?(System.version(), ~S"~> 1.0")
      end
      """

      for line <- 4..6, mfa <- ["System.version/0", "Version.match?/2"] do
        refute direct?(source, line, mfa), "line #{line} #{mfa}"
      end
    end
  end
end
