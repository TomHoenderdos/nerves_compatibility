defmodule Portal.BuilderTest do
  use ExUnit.Case, async: false

  alias Portal.Builder

  @job %{
    run_id: "11111111-2222-3333-4444-555555555555",
    image_name: "ncc-worker",
    image_digest: "sha256:deadbeef"
  }

  setup do
    previous = Application.get_env(:portal, Portal.Builder, [])
    on_exit(fn -> Application.put_env(:portal, Portal.Builder, previous) end)
    {:ok, previous: previous}
  end

  defp put_builder(overrides, previous) do
    Application.put_env(:portal, Portal.Builder, Keyword.merge(previous, overrides))
  end

  defp args, do: Builder.build_docker_args(@job, "/work", "/out", "/files")

  test "tells the runtimes how much CPU the container actually has", %{previous: previous} do
    put_builder([cpus: "2"], previous)

    # `--cpus` is a quota; `nproc` inside the container still reports the host's
    # cores, so without these the BEAM starts a scheduler per host core and
    # busy-waits through a quota it does not have.
    assert "ERL_FLAGS=+S 2:2 +sbwt none +sbwtdcpu none +sbwtdio none" in args()
    assert "ELIXIR_ERL_OPTIONS=+S 2:2 +sbwt none +sbwtdcpu none +sbwtdio none" in args()
    assert "MAKEFLAGS=-j2" in args()
  end

  test "a fractional cap still gets one whole scheduler", %{previous: previous} do
    put_builder([cpus: "1.5"], previous)

    assert "MAKEFLAGS=-j1" in args()
    assert "ERL_FLAGS=+S 1:1 +sbwt none +sbwtdcpu none +sbwtdio none" in args()
  end

  test "an uncapped build is left alone", %{previous: previous} do
    put_builder([cpus: nil], previous)

    refute Enum.any?(args(), &String.starts_with?(&1, "ERL_FLAGS="))
    refute Enum.any?(args(), &String.starts_with?(&1, "MAKEFLAGS="))
  end
end
