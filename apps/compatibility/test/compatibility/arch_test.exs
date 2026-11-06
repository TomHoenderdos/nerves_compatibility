defmodule Compatibility.ArchTest do
  use ExUnit.Case, async: true

  alias Compatibility.Arch

  test "names an Erlang system architecture the way images.json does" do
    assert Arch.normalize(~c"x86_64-pc-linux-gnu") == "x86_64"
    assert Arch.normalize("x86_64-unknown-linux-musl") == "x86_64"
    assert Arch.normalize("aarch64-unknown-linux-gnu") == "aarch64"
    assert Arch.normalize("aarch64-apple-darwin24.6.0") == "aarch64"
    assert Arch.normalize("amd64-portbld-freebsd14.1") == "x86_64"
    assert Arch.normalize("arm64-apple-darwin") == "aarch64"
  end

  test "an architecture without a worker image keeps its own name" do
    assert Arch.normalize("armv7l-unknown-linux-gnueabihf") == "armv7l"
    assert Arch.normalize("riscv64") == "riscv64"
  end

  test "only x86_64 and aarch64 are supported" do
    assert Arch.supported?("x86_64")
    assert Arch.supported?("aarch64")
    refute Arch.supported?("armv7l")
    refute Arch.supported?(nil)
    assert Arch.supported() == ["x86_64", "aarch64"]
  end

  test "this VM's architecture is normalised" do
    assert Arch.current() == Arch.normalize(:erlang.system_info(:system_architecture))
  end
end
