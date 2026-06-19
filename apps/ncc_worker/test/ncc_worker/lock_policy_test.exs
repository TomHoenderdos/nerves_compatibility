defmodule NccWorker.LockPolicyTest do
  use ExUnit.Case, async: true

  alias NccWorker.LockPolicy

  describe "validate/1" do
    test "accepts Hex-only dependencies" do
      # Create a temporary directory with a valid mix.lock
      tmp_dir = System.tmp_dir!() |> Path.join("ncc_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp_dir)

      lock_content = """
      %{
        jason: {:hex, :jason, "1.4.1", "af1504e35f629ddcdd6addb3513c3853991f694921b1b9368b0bd32beb9f1b63", [:mix], [{:decimal, "~> 1.0", [hex: :decimal, repo: "hexpm", optional: true]}], "hexpm", "fbb01ecdfd565b56261302f7e1fcc27c4fb8f546d6c03f1e1e26fbd8a0e3000f"},
        decimal: {:hex, :decimal, "2.1.1", "5611dca5d4b2c3dd497dec8f68751f1f1a54755e8ed2a966c2633cf885973ad6", [:mix], [], "hexpm", "d899c4e8f2f2f4b5b6c7e91e4c8c9b0d0e5d5d5c4e5d0e5d5d5d5d5d5d5d5d5d"}
      }
      """

      File.write!(Path.join(tmp_dir, "mix.lock"), lock_content)

      assert :ok = LockPolicy.validate(tmp_dir)

      File.rm_rf!(tmp_dir)
    end

    test "rejects git dependencies" do
      tmp_dir = System.tmp_dir!() |> Path.join("ncc_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp_dir)

      lock_content = """
      %{
        jason: {:hex, :jason, "1.4.1", "af1504e35f629ddcdd6addb3513c3853991f694921b1b9368b0bd32beb9f1b63", [:mix], [{:decimal, "~> 1.0", [hex: :decimal, repo: "hexpm", optional: true]}], "hexpm", "fbb01ecdfd565b56261302f7e1e26fbd8a0e3000f"},
        my_dep: {:git, "https://github.com/user/repo.git", "abc123", []}
      }
      """

      File.write!(Path.join(tmp_dir, "mix.lock"), lock_content)

      assert {:error, :policy_violation} = LockPolicy.validate(tmp_dir)

      File.rm_rf!(tmp_dir)
    end

    test "returns ok when mix.lock does not exist" do
      tmp_dir = System.tmp_dir!() |> Path.join("ncc_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp_dir)

      assert :ok = LockPolicy.validate(tmp_dir)

      File.rm_rf!(tmp_dir)
    end
  end
end
