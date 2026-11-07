require_relative "../snails-core/snails/harness"

# Assertion surface (core) — the shared assertions in
# snails-core/snails/harness.rb are pinned by their pass path and their
# failure path. A failing assertion raises, and the runner treats an
# uncaught raise as a case failure, so each failure mode is caught inside
# the case and its message is asserted — that message is the one-line
# contract a real failure prints.
class HarnessAssertTest < Snails::Harness::IntegrationTest
  # assert_raises — the block raising the named class passes; reaching
  # the next line is the pass signal.
  test "assert_raises passes when the block raises the class" do
    assert_raises(ArgumentError) { raise ArgumentError, "boom" }
  end

  # assert_raises — a subclass of the named class counts (is_a? semantics).
  test "assert_raises accepts a subclass of the named class" do
    assert_raises(StandardError) { raise ArgumentError, "boom" }
  end

  # assert_raises — an empty block fails, naming the class it wanted.
  test "assert_raises fails when nothing is raised" do
    raised = nil
    begin
      assert_raises(ArgumentError) { }
    rescue RuntimeError => e
      raised = e
    end
    assert_equal true, !raised.nil?
    assert_equal "assert_raises: ArgumentError not raised", raised.message
  end

  # assert_raises — a different exception fails, naming what came instead.
  test "assert_raises fails on a different exception" do
    raised = nil
    begin
      assert_raises(ArgumentError) { raise TypeError, "boom" }
    rescue RuntimeError => e
      raised = e
    end
    assert_equal true, !raised.nil?
    assert_equal "assert_raises: expected ArgumentError, got TypeError: boom", raised.message
  end

  # assert_match — a Regexp pattern matching anywhere in the value passes.
  test "assert_match passes on a regexp" do
    assert_match(/\d{4}/, "order 1234 shipped")
  end

  # assert_match — a String pattern is a literal substring, never a
  # regexp source: "1+2" must not match the text "112".
  test "assert_match treats a string pattern as a literal" do
    assert_match("1+2", "sum: 1+2")
  end

  # assert_match — no match fails, naming both sides.
  test "assert_match fails when the pattern does not match" do
    raised = nil
    begin
      assert_match(/\d{4}/, "no digits here")
    rescue RuntimeError => e
      raised = e
    end
    assert_equal true, !raised.nil?
    assert_equal 'assert_match: expected "no digits here" to match /\d{4}/', raised.message
  end

  # assert_includes — array membership and string substring both pass.
  test "assert_includes passes when the collection holds the object" do
    assert_includes [ "a", "b" ], "b"
    assert_includes "order created", "created"
  end

  # assert_includes — a missing object fails, naming both sides.
  test "assert_includes fails when the object is missing" do
    raised = nil
    begin
      assert_includes [ "a", "b" ], "z"
    rescue RuntimeError => e
      raised = e
    end
    assert_equal true, !raised.nil?
    assert_equal 'assert_includes: "z" not included in ["a", "b"]', raised.message
  end

  # assert_response — an integer compares as-is, so a status outside the
  # symbol table (415) is assertable without extending the table.
  test "assert_response accepts an integer status code" do
    @response = Snails::Harness::Response.new(415, '{"error":"unsupported"}', nil)
    assert_response 415
  end

  # assert_response — the symbol table keeps answering beside the
  # integer branch.
  test "assert_response keeps matching status symbols" do
    @response = Snails::Harness::Response.new(200, "", nil)
    assert_response :ok
    assert_response :success
  end

  # assert_response — a wrong integer fails with the same one-line shape
  # as the symbol path, body excerpt included.
  test "assert_response fails on a status mismatch" do
    @response = Snails::Harness::Response.new(415, '{"error":"too_large"}', nil)
    raised = nil
    begin
      assert_response 413
    rescue RuntimeError => e
      raised = e
    end
    assert_equal true, !raised.nil?
    assert_equal 'assert_response 413: got 415 — {"error":"too_large"}', raised.message
  end

  # assert_response — a status symbol resolves through the shared table,
  # so every symbol the controller's `status:` accepts works here too,
  # including the rename aliases.
  test "assert_response resolves a status symbol through the shared table" do
    @response = Snails::Harness::Response.new(400, '{"error":"bad_request"}', nil)
    assert_response :bad_request
    @response = Snails::Harness::Response.new(415, "", nil)
    assert_response :unsupported_media_type
    @response = Snails::Harness::Response.new(422, "", nil)
    assert_response :unprocessable_content
  end

  # assert_response — category symbols follow the response
  # predicates: ranges for :redirect/:error, exact 404 for :missing (a
  # 410 gone is not :missing).
  test "assert_response category symbols follow the response ranges" do
    @response = Snails::Harness::Response.new(302, "", nil)
    assert_response :redirect
    @response = Snails::Harness::Response.new(500, "", nil)
    assert_response :error
    @response = Snails::Harness::Response.new(404, "", nil)
    assert_response :missing
    @response = Snails::Harness::Response.new(410, '{"error":"gone"}', nil)
    raised = nil
    begin
      assert_response :missing
    rescue RuntimeError => e
      raised = e
    end
    assert_equal true, !raised.nil?
    assert_equal 'assert_response missing: got 410 — {"error":"gone"}', raised.message
  end

  # assert_response — a symbol outside the shared table fails loudly at
  # the call instead of comparing against nothing.
  test "assert_response rejects a symbol outside the table" do
    @response = Snails::Harness::Response.new(418, "", nil)
    raised = nil
    begin
      assert_response :not_a_status
    rescue RuntimeError => e
      raised = e
    end
    assert_equal true, !raised.nil?
    assert_equal "unknown response type: not_a_status", raised.message
  end

  # assert — a truthy value passes; a falsy one fails with the optional
  # message on the line.
  test "assert passes on truthy and fails on falsy" do
    assert true
    assert 1, "counted"
    raised = nil
    begin
      assert nil, "user present"
    rescue RuntimeError => e
      raised = e
    end
    assert_equal true, !raised.nil?
    assert_equal "assert failed: user present", raised.message
  end

  # assert_nil — nil passes; anything else fails naming what was there.
  test "assert_nil passes on nil and fails on a value" do
    assert_nil nil
    raised = nil
    begin
      assert_nil 5
    rescue RuntimeError => e
      raised = e
    end
    assert_equal true, !raised.nil?
    assert_equal "assert_nil failed got=5", raised.message
  end

  # assert_not_nil — the inverse of assert_nil.
  test "assert_not_nil passes on a value and fails on nil" do
    assert_not_nil "x"
    raised = nil
    begin
      assert_not_nil nil
    rescue RuntimeError => e
      raised = e
    end
    assert_equal true, !raised.nil?
    assert_equal "assert_not_nil failed", raised.message
  end

  # assert_not — falsy passes; a truthy value fails naming what was there.
  test "assert_not passes on falsy and fails on truthy" do
    assert_not false
    assert_not nil
    raised = nil
    begin
      assert_not 1, "expected zero"
    rescue RuntimeError => e
      raised = e
    end
    assert_equal true, !raised.nil?
    assert_equal "assert_not failed: expected zero got=1", raised.message
  end

  # assert_not_equal — differing values pass; equal ones fail naming
  # both sides.
  test "assert_not_equal passes on a difference and fails on a match" do
    assert_not_equal 1, 2
    raised = nil
    begin
      assert_not_equal "same", "same"
    rescue RuntimeError => e
      raised = e
    end
    assert_equal true, !raised.nil?
    assert_equal 'assert_not_equal failed: both were "same"', raised.message
  end

  # assert_operator — a held comparison passes; a broken one prints the
  # comparison, and an unknown operator is rejected at the call.
  test "assert_operator passes on a held comparison and rejects a bad operator" do
    assert_operator 3, :>=, 3
    raised = nil
    begin
      assert_operator 3, :<, 2
    rescue RuntimeError => e
      raised = e
    end
    assert_equal true, !raised.nil?
    assert_equal "assert_operator failed 3 < 2", raised.message
    bad = nil
    begin
      assert_operator 1, :==, 1
    rescue ArgumentError => e
      bad = e
    end
    assert_equal true, !bad.nil?
    assert_equal "assert_operator expects :>=, :<=, :> or :<, got :==", bad.message
  end
end
