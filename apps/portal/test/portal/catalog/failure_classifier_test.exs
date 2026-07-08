defmodule Portal.Catalog.FailureClassifierTest do
  use ExUnit.Case, async: true

  alias Portal.Catalog.FailureClassifier, as: FC

  test "pass and skipped classify to nil" do
    assert FC.classify(%{"status" => "pass", "log_tail" => "anything"}) == nil
    assert FC.classify(%{"status" => "skipped"}) == nil
  end

  test "wrong-architecture NIF" do
    assert FC.classify(%{"status" => "fail", "log_tail" => "sh: cannot execute binary file: Exec format error"}) ==
             "NIF built for wrong architecture"
  end

  test "missing precompiled NIF" do
    assert FC.classify(%{"status" => "fail", "log_tail" => "could not find precompiled NIF for target rpi0"}) ==
             "Precompiled NIF missing for target"
  end

  test "dependency resolution failure" do
    assert FC.classify(%{"status" => "error", "log_tail" => "Failed to use \"foo\" because no matching version"}) ==
             "Dependency resolution failed"
  end

  test "compilation error" do
    assert FC.classify(%{"status" => "fail", "log_tail" => "** (CompileError) lib/foo.ex:3: undefined function bar/0"}) ==
             "Compilation error"
  end

  test "unmatched non-pass falls back to Other" do
    assert FC.classify(%{"status" => "fail", "log_tail" => "mysterious teapot failure"}) ==
             "Other / unclassified"
  end

  test "reads the error field too and tolerates missing keys" do
    assert FC.classify(%{"status" => "fail", "error" => "Exec format error"}) ==
             "NIF built for wrong architecture"
  end
end
