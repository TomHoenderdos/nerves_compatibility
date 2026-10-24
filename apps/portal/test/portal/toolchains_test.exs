defmodule Portal.ToolchainsTest do
  # Not async: the `images/0` tests swap the application environment.
  use ExUnit.Case, async: false

  alias Portal.Toolchains

  describe "parse/1" do
    test "reads `toolchain=image` pairs in order" do
      assert Toolchains.parse("1.20/29=ncc-worker:local,1.19/28=ncc-worker:elixir-1.19-otp-28") ==
               [
                 %{toolchain: "1.20/29", image: "ncc-worker:local"},
                 %{toolchain: "1.19/28", image: "ncc-worker:elixir-1.19-otp-28"}
               ]
    end

    test "tolerates whitespace and a trailing comma" do
      assert Toolchains.parse(" 1.19/28 = ncc-worker:elixir-1.19-otp-28 ,") ==
               [%{toolchain: "1.19/28", image: "ncc-worker:elixir-1.19-otp-28"}]
    end

    test "an image tag with a registry port keeps everything after the first `=`" do
      assert Toolchains.parse("1.19/28=registry:5000/ncc:1.19") ==
               [%{toolchain: "1.19/28", image: "registry:5000/ncc:1.19"}]
    end

    test "a pair without `=` raises naming the pair" do
      assert_raise ArgumentError, ~r/"1\.19\/28"/, fn ->
        Toolchains.parse("1.20/29=ncc-worker:local,1.19/28")
      end
    end

    test "a pair with an empty image raises naming the pair" do
      assert_raise ArgumentError, ~r/"1\.19\/28="/, fn ->
        Toolchains.parse("1.19/28=")
      end
    end

    test "a malformed toolchain raises naming the pair" do
      for bad <- ["1.19=img", "1.19/28.1=img", "v1.19/28=img", "1/28=img"] do
        assert_raise ArgumentError, ~r/#{Regex.escape(inspect(bad))}/, fn ->
          Toolchains.parse(bad)
        end
      end
    end

    test "a toolchain listed twice raises" do
      assert_raise ArgumentError, ~r/1\.19\/28/, fn ->
        Toolchains.parse("1.19/28=a,1.19/28=b")
      end
    end

    test "an empty list raises" do
      assert_raise ArgumentError, fn -> Toolchains.parse(" , ") end
    end
  end

  describe "config readers" do
    setup do
      original = Application.get_env(:portal, Toolchains)
      on_exit(fn -> Application.put_env(:portal, Toolchains, original) end)
      :ok
    end

    test "the shipped config lists both toolchains" do
      assert Toolchains.images() == [
               %{toolchain: "1.20/29", image: "ncc-worker:local"},
               %{toolchain: "1.19/28", image: "ncc-worker:elixir-1.19-otp-28"}
             ]

      assert Toolchains.builder_version() == 1
      assert Toolchains.max_per_run() == 300
    end

    test "images/0 and builder_version/0 read the application environment" do
      Application.put_env(:portal, Toolchains,
        images: [%{toolchain: "1.18/27", image: "x:y"}],
        builder_version: 4
      )

      assert Toolchains.images() == [%{toolchain: "1.18/27", image: "x:y"}]
      assert Toolchains.builder_version() == 4
    end

    test "max_per_run/0 defaults to 300 when unset" do
      Application.put_env(:portal, Toolchains, images: [], builder_version: 1)
      assert Toolchains.max_per_run() == 300

      Application.put_env(:portal, Toolchains, images: [], builder_version: 1, max_per_run: 7)
      assert Toolchains.max_per_run() == 7
    end
  end
end
