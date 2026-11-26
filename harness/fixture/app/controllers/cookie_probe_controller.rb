# Cookie probe for the core contract tests: a read action exposes both the
# request hash and the controller jar; a write action records two cookies
# with different option sets; delete and permanent exercise the two Rails
# helpers the jar owns.
class HarnessCookieController < ApplicationController
  def read
    render(json: {
      "request" => request.cookies["session"].to_s,
      "jar" => cookies["session"].to_s,
      "missing" => cookies["missing"].to_s
    })
  end

  def write
    cookies["session"] = {
      value: "abc 123;",
      httponly: true,
      secure: true,
      same_site: :strict,
      path: "/",
      max_age: 3600
    }
    cookies["second"] = "two"
    head(:no_content)
  end

  def delete
    cookies.delete("session")
    head(:no_content)
  end

  def permanent
    cookies.permanent["session"] = "forever"
    head(:no_content)
  end

end
