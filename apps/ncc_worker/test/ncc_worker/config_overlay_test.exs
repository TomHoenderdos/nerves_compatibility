defmodule NccWorker.ConfigOverlayTest do
  use ExUnit.Case, async: true

  alias NccWorker.ConfigOverlay

  @moduletag :tmp_dir

  test "a named variant writes its overlay as config/config.exs", %{tmp_dir: dir} do
    assert :ok = ConfigOverlay.write(dir, "phx_prod")
    config = Config.Reader.read!(Path.join(dir, "config/config.exs"), env: :prod)
    assert config[:phoenix_live_view][:root_tag_attribute] == "phx-r"
    assert config[:phoenix][:json_library] == Jason
  end

  test "default writes nothing", %{tmp_dir: dir} do
    assert :ok = ConfigOverlay.write(dir, "default")
    refute File.exists?(Path.join(dir, "config"))
  end

  test "an existing config file is never overwritten", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "config"))
    File.write!(Path.join(dir, "config/config.exs"), "import Config\n")
    assert {:error, :config_exists} = ConfigOverlay.write(dir, "phx_dev")
    assert File.read!(Path.join(dir, "config/config.exs")) == "import Config\n"
  end

  test "a dangling link at config/config.exs is never written through", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "config"))
    target = Path.join(dir, "elsewhere.exs")
    File.ln_s!(target, Path.join(dir, "config/config.exs"))
    assert {:error, :config_exists} = ConfigOverlay.write(dir, "phx_dev")
    refute File.exists?(target)
  end

  test "an unknown variant is an error", %{tmp_dir: dir} do
    assert {:error, {:unknown_config_variant, "nope"}} = ConfigOverlay.write(dir, "nope")
  end
end
