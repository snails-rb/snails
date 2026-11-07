# /up smoke — the snails app contract: GET /up answers 200.
#
# Cases run against a live server (`APP_BASE_URL`), one fresh instance each.
# Put app cases beside this file; in a bundle process only the selected file's
# class is defined (`Snails::Harness.file_selected?`).
require_relative "../boot"

if Snails::Harness.file_selected?
  class UpSmokeTest < Snails::Harness::IntegrationTest
    test "GET /up returns 200" do
      get("/up")
      assert_response(:ok)
    end

    # The app is API-only: an unknown path answers the app's own JSON error,
    # not an HTML page.
    test "an unknown route answers a JSON 404" do
      get("/no-such-route")
      assert_response(:not_found)
      assert_equal("not_found", @response.parsed_body["error"])
    end
  end
end
