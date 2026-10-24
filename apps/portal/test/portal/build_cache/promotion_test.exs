defmodule Portal.BuildCache.PromotionTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Compatibility.BuildCacheKey
  alias Portal.BuildCache.Promotion

  @outer "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30684"

  setup do
    tmp = Path.join(System.tmp_dir!(), "promo-#{System.unique_integer([:positive])}")
    out = Path.join(tmp, "out")
    cache = Path.join(tmp, "cache/sha256_x")
    File.mkdir_p!(out)
    File.mkdir_p!(cache)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp, out: out, cache: cache}
  end

  defp inputs(overrides) do
    Map.merge(
      %{
        "dep" => "jason",
        "dep_lock" =>
          "1.4.5 2e3a008590b0b8d7388c20293e9dcc9cf3e5d642fd2a114e4cbbb52e595d940a #{@outer}",
        "target" => "host",
        "elixir" => "1.20.3",
        "otp" => "29",
        "closure" => [%{"name" => "decimal", "lock" => "2.3.0 aa bb"}]
      },
      overrides
    )
  end

  defp key_of(c) do
    {:ok, key} =
      BuildCacheKey.key(%{
        elixir: c["elixir"],
        otp: c["otp"],
        target: c["target"],
        dep: c["dep"],
        dep_lock: c["dep_lock"],
        closure: Enum.map(c["closure"], &{&1["name"], &1["lock"]})
      })

    key
  end

  defp candidate(out, overrides \\ %{}) do
    c = inputs(overrides)
    c = Map.put_new(c, "key", key_of(c))
    dir = Path.join([out, "build-cache", c["key"], "ebin"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "Elixir.Jason.beam"), "beam")
    c
  end

  defp result(cands), do: %{"cache" => %{"candidates" => cands}}
  defp hex_ok(_name, _version), do: {:ok, @outer}

  test "promotes the package's own candidate under the recomputed key", ctx do
    c = candidate(ctx.out)

    assert %{promoted: 1, refused: 0} =
             Promotion.promote(result([c]), ctx.out, ctx.cache, "jason", "1.4.5",
               release_checksum: &hex_ok/2
             )

    assert File.regular?(Path.join([ctx.cache, c["key"], "ebin/Elixir.Jason.beam"]))
  end

  test "ignores candidates for any other dependency", ctx do
    c = candidate(ctx.out, %{"dep" => "plug"})

    assert %{promoted: 0} =
             Promotion.promote(result([c]), ctx.out, ctx.cache, "jason", "1.4.5",
               release_checksum: &hex_ok/2
             )

    assert File.ls!(ctx.cache) == []
  end

  # The attack this module exists for: a build names the slot of a popular
  # dependency it does not own, under its own package's label.
  test "refuses a reported key that is not the recomputed one, without touching it", ctx do
    victim = String.duplicate("d", 64)
    c = candidate(ctx.out, %{"key" => victim})

    assert %{promoted: 0, refused: 1} =
             Promotion.promote(result([c]), ctx.out, ctx.cache, "jason", "1.4.5",
               release_checksum: &hex_ok/2
             )

    assert File.ls!(ctx.cache) == []
    assert File.dir?(Path.join([ctx.out, "build-cache", victim]))
  end

  test "requires the exact version, not a prefix", ctx do
    c = candidate(ctx.out, %{"dep_lock" => "1.4.50 x #{@outer}"})

    assert %{promoted: 0} =
             Promotion.promote(result([c]), ctx.out, ctx.cache, "jason", "1.4.5",
               release_checksum: &hex_ok/2
             )
  end

  test "requires the outer checksum Hex has for the release", ctx do
    c = candidate(ctx.out)

    assert %{promoted: 0, refused: 1} =
             Promotion.promote(result([c]), ctx.out, ctx.cache, "jason", "1.4.5",
               release_checksum: fn _, _ -> {:ok, String.duplicate("0", 64)} end
             )
  end

  test "refuses a lock entry with no outer checksum", ctx do
    c = candidate(ctx.out, %{"dep_lock" => "1.4.5 2e3a008590b0"})

    assert %{promoted: 0, refused: 1} =
             Promotion.promote(result([c]), ctx.out, ctx.cache, "jason", "1.4.5",
               release_checksum: &hex_ok/2
             )
  end

  test "promotes nothing and does not raise when Hex is unreachable", ctx do
    c = candidate(ctx.out)

    assert %{promoted: 0} =
             Promotion.promote(result([c]), ctx.out, ctx.cache, "jason", "1.4.5",
               release_checksum: fn _, _ -> {:error, :hex_api_unavailable} end
             )
  end

  test "refuses a line break smuggled into an input", ctx do
    c = inputs(%{"target" => "host\ndep=plug 1.0.0"}) |> Map.put("key", String.duplicate("e", 64))
    File.mkdir_p!(Path.join([ctx.out, "build-cache", c["key"]]))

    assert %{promoted: 0, refused: 1} =
             Promotion.promote(result([c]), ctx.out, ctx.cache, "jason", "1.4.5",
               release_checksum: &hex_ok/2
             )
  end

  test "keeps Mix's own priv and include links", ctx do
    c = candidate(ctx.out)
    entry = Path.join([ctx.out, "build-cache", c["key"]])
    File.ln_s!("../../../../deps/jason/priv", Path.join(entry, "priv"))
    File.ln_s!("../../../../deps_rpi4/jason/include", Path.join(entry, "include"))

    assert %{promoted: 1} =
             Promotion.promote(result([c]), ctx.out, ctx.cache, "jason", "1.4.5",
               release_checksum: &hex_ok/2
             )
  end

  test "refuses any other symlink", ctx do
    # The one that matters is the second: right name, wrong package. The
    # fourth has the right package but its own name differs from the
    # target's last segment.
    for {name, target} <- [
          {"priv", "/etc"},
          {"priv", "../../../../deps/plug/priv"},
          {"ebin/x.beam", "/etc/passwd"},
          {"include", "../../../../deps/jason/priv"}
        ] do
      out = Path.join(ctx.tmp, "out-#{System.unique_integer([:positive])}")
      c = candidate(out)
      link = Path.join([out, "build-cache", c["key"], name])
      File.rm_rf!(link)
      File.ln_s!(target, link)

      assert %{promoted: 0, refused: 1} =
               Promotion.promote(result([c]), out, ctx.cache, "jason", "1.4.5",
                 release_checksum: &hex_ok/2
               ),
             "accepted #{name} -> #{target}"
    end
  end

  test "refuses a hardlinked file", ctx do
    c = candidate(ctx.out)
    beam = Path.join([ctx.out, "build-cache", c["key"], "ebin/Elixir.Jason.beam"])
    File.ln!(beam, Path.join(ctx.tmp, "elsewhere"))

    assert %{promoted: 0, refused: 1} =
             Promotion.promote(result([c]), ctx.out, ctx.cache, "jason", "1.4.5",
               release_checksum: &hex_ok/2
             )
  end

  # What a crafted candidate would actually do: both names inside the tree.
  test "refuses a hardlink whose two names are both inside the candidate", ctx do
    c = candidate(ctx.out)
    entry = Path.join([ctx.out, "build-cache", c["key"]])
    File.ln!(Path.join(entry, "ebin/Elixir.Jason.beam"), Path.join(entry, "ebin/Copy.beam"))

    assert %{promoted: 0, refused: 1} =
             Promotion.promote(result([c]), ctx.out, ctx.cache, "jason", "1.4.5",
               release_checksum: &hex_ok/2
             )
  end

  test "leaves an existing entry alone", ctx do
    c = candidate(ctx.out)
    File.mkdir_p!(Path.join(ctx.cache, c["key"]))
    File.write!(Path.join([ctx.cache, c["key"], "marker"]), "old")

    assert %{promoted: 0} =
             Promotion.promote(result([c]), ctx.out, ctx.cache, "jason", "1.4.5",
               release_checksum: &hex_ok/2
             )

    assert File.read!(Path.join([ctx.cache, c["key"], "marker"])) == "old"
  end

  # The lookup raises: a nil cache dir, or a result with nothing to promote,
  # must return before anything reaches Hex.
  test "a nil cache dir or a result without candidates is a no-op", ctx do
    boom = fn _, _ -> raise "must not be called" end

    assert %{promoted: 0, refused: 0} =
             Promotion.promote(result([candidate(ctx.out)]), ctx.out, nil, "jason", "1.4.5",
               release_checksum: boom
             )

    assert %{promoted: 0, refused: 0} =
             Promotion.promote(%{}, ctx.out, ctx.cache, "jason", "1.4.5", release_checksum: boom)
  end

  # `BuildCacheKey.key/1` turns each closure entry into a tuple; a closure the
  # container shaped any other way must be refused here, not raise there.
  test "refuses a malformed closure without raising", ctx do
    for closure <- [
          "decimal 2.3.0 aa bb",
          ["decimal 2.3.0 aa bb"],
          [%{"name" => "decimal"}],
          [%{"name" => "decimal", "lock" => 230}],
          [%{"name" => :decimal, "lock" => "2.3.0 aa bb"}],
          [{"decimal", "2.3.0 aa bb"}],
          nil
        ] do
      c = inputs(%{"closure" => closure}) |> Map.put("key", String.duplicate("f", 64))
      File.mkdir_p!(Path.join([ctx.out, "build-cache", c["key"]]))

      assert %{promoted: 0, refused: 1} =
               Promotion.promote(result([c]), ctx.out, ctx.cache, "jason", "1.4.5",
                 release_checksum: &hex_ok/2
               ),
             "accepted closure #{inspect(closure)}"
    end
  end

  test "refuses a candidate whose build-cache directory is a symlink", ctx do
    c = candidate(Path.join(ctx.tmp, "real-out"))
    File.ln_s!(Path.join([ctx.tmp, "real-out", "build-cache"]), Path.join(ctx.out, "build-cache"))

    assert %{promoted: 0, refused: 1} =
             Promotion.promote(result([c]), ctx.out, ctx.cache, "jason", "1.4.5",
               release_checksum: &hex_ok/2
             )

    assert File.ls!(ctx.cache) == []
  end

  test "asks Hex once per call, however many candidates", ctx do
    c1 = candidate(ctx.out)
    c2 = candidate(ctx.out, %{"target" => "rpi4"})
    me = self()

    lookup = fn _, _ ->
      send(me, :asked)
      {:ok, @outer}
    end

    assert %{promoted: 2} =
             Promotion.promote(result([c1, c2]), ctx.out, ctx.cache, "jason", "1.4.5",
               release_checksum: lookup
             )

    assert_received :asked
    refute_received :asked
  end
end
