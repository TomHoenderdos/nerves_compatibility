defmodule Portal.Precompiled.SystemAbiTest do
  use ExUnit.Case, async: true

  alias Portal.Precompiled.SystemAbi

  describe "series_from_requirement/1" do
    test "a ~> X.Y.Z requirement is the X.Y series" do
      assert SystemAbi.series_from_requirement("~> 15.3.0") == "15.3"
      assert SystemAbi.series_from_requirement("~> 15.3.2") == "15.3"
    end

    test "every other requirement shape is nil" do
      for requirement <- [
            "~> 15.3",
            ">= 15.3.0",
            "== 15.3.1",
            "15.3.1",
            "~> 15.3.0 or ~> 15.4.0",
            "",
            "~> 15.3.0-rc.0"
          ] do
        assert SystemAbi.series_from_requirement(requirement) == nil, requirement
      end
    end

    test "a non-string is nil" do
      assert SystemAbi.series_from_requirement(nil) == nil
      assert SystemAbi.series_from_requirement(15.3) == nil
      assert SystemAbi.series_from_requirement(%{"requirement" => "~> 15.3.0"}) == nil
    end
  end
end
