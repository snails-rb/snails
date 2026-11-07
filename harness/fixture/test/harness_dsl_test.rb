require_relative "../snails-core/snails/harness"

if ENV.fetch("RUN_DSL", "1") == "1"
  class DslTest < Snails::Harness::IntegrationTest
    test "a registered case runs and prints its description" do
      assert_equal 1, 1
    end

    test "another case keeps its own description" do
      assert_equal 2, 2
    end
  end
end
