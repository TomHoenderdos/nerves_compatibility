defmodule Compatibility.HostTripleTest do
  use ExUnit.Case, async: true

  alias Compatibility.HostTriple

  test "a glibc Linux system architecture on x86_64 or aarch64 is a triple" do
    assert HostTriple.normalize(~c"x86_64-pc-linux-gnu") == {:ok, "x86_64-linux-gnu"}
    assert HostTriple.normalize("x86_64-unknown-linux-gnu") == {:ok, "x86_64-linux-gnu"}
    assert HostTriple.normalize("x86_64-redhat-linux-gnu") == {:ok, "x86_64-linux-gnu"}
    assert HostTriple.normalize("x86_64-linux-gnu") == {:ok, "x86_64-linux-gnu"}
    assert HostTriple.normalize("aarch64-unknown-linux-gnu") == {:ok, "aarch64-linux-gnu"}
    assert HostTriple.normalize("arm64-unknown-linux-gnu") == {:ok, "aarch64-linux-gnu"}
    assert HostTriple.normalize("amd64-pc-linux-gnu") == {:ok, "x86_64-linux-gnu"}
  end

  test "musl, darwin, other ABIs and other architectures are no triple" do
    for arch <- [
          "x86_64-pc-linux-musl",
          "aarch64-alpine-linux-musl",
          "aarch64-apple-darwin24.6.0",
          "x86_64-apple-darwin23.4.0",
          "armv7l-unknown-linux-gnueabihf",
          "x86_64-pc-linux-gnux32",
          "riscv64-unknown-linux-gnu",
          "x86_64-portbld-freebsd14.1",
          "x86_64-pc-linux-gnu-extra",
          "",
          "gnu"
        ] do
      assert HostTriple.normalize(arch) == :error, arch
    end

    assert HostTriple.normalize(nil) == :error
    assert HostTriple.normalize(42) == :error
  end

  test "a triple names the ELF machine its files must have" do
    assert HostTriple.elf_machine("x86_64-linux-gnu") == {:ok, :x86_64}
    assert HostTriple.elf_machine("aarch64-linux-gnu") == {:ok, :aarch64}
    assert HostTriple.elf_machine("armv7l-linux-gnu") == :error
    assert HostTriple.elf_machine("x86_64-linux-musl") == :error
  end

  test "only normalised triples are valid" do
    assert HostTriple.valid?("x86_64-linux-gnu")
    assert HostTriple.valid?("aarch64-linux-gnu")
    refute HostTriple.valid?("x86_64-pc-linux-gnu")
    refute HostTriple.valid?(nil)
    assert HostTriple.all() == ["x86_64-linux-gnu", "aarch64-linux-gnu"]
  end

  test "this VM's triple is its own system architecture's" do
    assert HostTriple.current() == HostTriple.normalize(:erlang.system_info(:system_architecture))
  end
end
