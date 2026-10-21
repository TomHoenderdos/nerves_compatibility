defmodule NccWorker.AppFileTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias NccWorker.AppFile

  defp write_app(dir, name, props) do
    path = Path.join([dir, "ebin", "#{name}.app"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :io_lib.format("~p.~n", [{:application, String.to_atom(name), props}]))
    path
  end

  test "reads compile_env triples into JSON-safe maps", %{tmp_dir: dir} do
    path =
      write_app(dir, "sample", [
        {:vsn, ~c"1.0.0"},
        {:compile_env, [{:sample, [:backend], {:ok, SomeBackend}}, {:sample, [:missing], :error}]}
      ])

    assert [
             %{app: "sample", path: ["backend"], value: v1},
             %{app: "sample", path: ["missing"], value: v2}
           ] = AppFile.read_compile_env(path)

    assert :erlang.binary_to_term(Base.url_decode64!(v1, padding: false)) == {:ok, SomeBackend}
    assert :erlang.binary_to_term(Base.url_decode64!(v2, padding: false)) == :error
  end

  test "tuple value round-trips", %{tmp_dir: dir} do
    path =
      write_app(dir, "sample", [{:compile_env, [{:sample, [:opts], {:ok, {~c"chars", %{a: 1}}}}]}])

    [%{value: v}] = AppFile.read_compile_env(path)

    assert :erlang.binary_to_term(Base.url_decode64!(v, padding: false)) ==
             {:ok, {~c"chars", %{a: 1}}}
  end

  test "an app without compile_env gives an empty list", %{tmp_dir: dir} do
    path = write_app(dir, "sample", [{:vsn, ~c"1.0.0"}])
    assert AppFile.read_compile_env(path) == []
  end

  test "a missing or unparseable app file gives nil", %{tmp_dir: dir} do
    assert AppFile.read_compile_env(Path.join(dir, "nope.app")) == nil
    bad = Path.join(dir, "bad.app")
    File.write!(bad, "{application")
    assert AppFile.read_compile_env(bad) == nil
  end

  test "find_app_in_build locates the release copy", %{tmp_dir: dir} do
    app = Path.join([dir, "rel", "firmware", "lib", "sample-1.0.0", "ebin", "sample.app"])
    File.mkdir_p!(Path.dirname(app))
    File.write!(app, "{application, sample, []}.\n")
    assert AppFile.find_app_in_build(dir, "sample") == app
    assert AppFile.find_app_in_build(dir, "other") == nil
  end
end
