defmodule Portal.Precompiled.ContentTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Portal.Precompiled.Content

  setup do
    old = Application.get_env(:portal, :precompiled_content_origins)
    on_exit(fn -> Application.put_env(:portal, :precompiled_content_origins, old) end)
  end

  test "unset or blank is no origins" do
    assert Content.parse(nil) == {:ok, []}
    assert Content.parse("") == {:ok, []}
    assert Content.parse(" , ,") == {:ok, []}
  end

  test "https origins, trimmed, with an optional path, deduplicated in order" do
    assert Content.parse(
             " https://cdn.example , https://mirror.example/precompiled,https://cdn.example"
           ) ==
             {:ok, ["https://cdn.example", "https://mirror.example/precompiled"]}
  end

  for bad <- [
        "http://cdn.example",
        "https://cdn.example/",
        "https://cdn.example/precompiled/",
        "https://cdn.example?x=1",
        "https://cdn.example#frag",
        "https://user:pw@cdn.example",
        "https://",
        "cdn.example",
        "https://cdn example"
      ] do
    test "refuses #{inspect(bad)}, naming it" do
      assert {:error, msg} = Content.parse("https://ok.example," <> unquote(bad))
      assert msg =~ inspect(unquote(bad))
    end
  end

  test "two bad entries are both named in the one error" do
    assert {:error, msg} =
             Content.parse("https://ok.example,http://portal.example,https://cdn.example/")

    assert msg =~ inspect("http://portal.example")
    assert msg =~ inspect("https://cdn.example/")
  end

  test "refuses more than eight" do
    raw = Enum.map_join(1..9, ",", &"https://cdn#{&1}.example")
    assert {:error, _} = Content.parse(raw)
  end

  test "origins/0: an invalid setting is no origins and one error line" do
    Application.put_env(:portal, :precompiled_content_origins, "https://cdn.example/")
    {origins, log} = with_log(fn -> Content.origins() end)
    assert origins == []
    assert log =~ "[error]"
    assert log =~ "NCC_PRECOMPILED_CONTENT_ORIGINS"
  end

  test "origins/0: a valid setting" do
    Application.put_env(:portal, :precompiled_content_origins, "https://cdn.example")
    assert Content.origins() == ["https://cdn.example"]
  end
end
