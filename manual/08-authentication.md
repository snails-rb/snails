# Authentication

Snails gives you HTTP authentication, not the user model. The controller reads a token or a username and password from the request, and your app decides whether it belongs to a user. The helper returns 401 when it doesn't. No session store and no token table are built in. The `cookies` jar reads and writes cookies.

## Read a token

`authenticate_with_http_token` yields the token and its options to a block. It sends no challenge of its own, and a request without a token doesn't run the block and returns `nil`:

```ruby
class Api::TokensController < Api::ApplicationController
  def show
    account = authenticate_with_http_token do |token, options|
      Account.find_by({ api_token: token })
    end

    if account.nil?
      head(:unauthorized, content_type: JSON_TYPE)
    else
      render(json: { "account" => account.name })
    end
  end
end
```

The client sends either scheme, with optional `key=value` pairs after the token:

```text
Authorization: Token abc123
Authorization: Bearer abc123
Authorization: Token abc123, scope=read, region=us
```

The token is the first value. The pairs after it arrive as `options`, keyed by strings. Separate pairs with commas or semicolons — a space-separated `scope=read` is part of the token value, not an option.

## Send the 401 in one call

The `or_request` form does the challenge for you. When the block returns `nil` or `false`, or when the scheme is missing, the controller sends a 401 with a `WWW-Authenticate` header and stops the filter chain:

```ruby
class Api::TokensController < Api::ApplicationController
  before_action :authenticate

  def show
    render(json: { "account" => @account.name })
  end

  private

  def authenticate
    @account = authenticate_or_request_with_http_token("Snails API") do |token, options|
      Account.find_by({ api_token: token })
    end
  end
end
```

```text
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Token realm="Snails API"
Content-Type: text/plain; charset=utf-8

HTTP Token: Access denied.
```

`realm` names the protection space in the challenge. The default is `"Application"`. Pass `message:` to replace the default body. The render marks the response performed, so neither the rest of the action nor any later `before_action` runs.

The two helpers are separate operations — a block that renders a body still needs a truthy return value. Use the non-challenge form and send the 401 yourself when the block owns the response.

## Basic authentication

`authenticate_with_http_basic` yields the decoded username and password, split at the first colon:

```ruby
def authenticate
  @account = authenticate_or_request_with_http_basic("Admin") do |username, password|
    Account.find_by({ email: username, password_digest: digest(password) })
  end
end
```

The challenge header is `Basic realm="Admin"` and the default body is `HTTP Basic: Access denied.`. A password may contain colons; the username may not. Basic credentials travel in clear text inside the header, so use Basic auth over TLS or not at all.

## Challenge without a helper

The challenge renderers are public, so a custom flow can send them directly:

```ruby
request_http_token_authentication("Snails API", "Token expired.\n")
request_http_basic_authentication("Admin")
```

Each writes the `WWW-Authenticate` header, a 401 status, and a plain-text body. Call one from an action or a filter after your own lookup fails.

## Signed tokens

`Snails::MessageVerifier` signs a String with `SECRET_KEY_BASE` and a purpose:

```ruby
verifier = Snails::MessageVerifier.new
token = verifier.generate("account:42", purpose: "reset")
verifier.verified(token, purpose: "reset")  # "account:42"
```

A tampered token, a token for another purpose, and a token signed with another secret read `nil`. Signing prevents tampering, not reading: the payload is Base64-encoded, not encrypted. The verifier has no expiry; the payload format, expiry, and refresh rotation are app code. [Requests and Parameters](07-requests-and-parameters.md) covers `cookies.signed`.

## Check the Origin on state-changing requests

Cross-Origin Resource Sharing (CORS) decides which origins can read a response. It does not stop another origin from sending a request. The app checks the `Origin` header on a state-changing request against the origins it trusts:

```ruby
before_action :require_trusted_origin, only: [:create, :update, :destroy]

private

def require_trusted_origin
  policy = Snails.cors
  origin = request.headers["Origin"]
  if policy.nil? || !policy.origin_allowed?(origin)
    render(json: { "error" => "forbidden" }, status: :forbidden)
  end
end
```

`origin_allowed?` matches the header against the policy's origins. The match is exact: a trailing slash or different casing does not count. It returns `false` for a missing or empty origin, so allow that case explicitly when non-browser clients must write. `Snails.cors` is `nil` when CORS is off. The check above then rejects every write, so configure the policy or keep the trust list in the app.

A browser sends `Origin` on cross-origin requests and on same-origin POST requests. A same-origin GET usually has no `Origin`, so check only the actions that change state. `SameSite` cookies limit when the browser sends the cookie. The `Origin` check decides whether the request may change state.

CORS and the check decide different things. CORS says which origins can read a response; the check says which origins can change state. Reusing the CORS policy is correct only when both sets are the same.

A `"*"` policy allows every origin and is not a trust list for state changes. `"null"` is the serialized null origin. List it only when a sandboxed or local context must write.

## What the framework owns

The framework owns the header parsing and the 401 response format. Your app owns the credential store and the comparison. A token lookup is a model query like any other:

```ruby
def current_account
  authenticate_with_http_token do |token, options|
    Account.find_by({ api_token: token, revoked_at: nil })
  end
end
```

`find_by` is enough when the token column is unique. A token table with an expiry or scope column is your schema. The framework does not store sessions or rotate tokens. `Snails::Security.secure_compare` compares two equal-length Strings in constant time; a length mismatch returns immediately.

The signing key for tokens you issue yourself comes from `Snails.app.secret_key_base`. [Configuration](16-configuration.md) covers that setting.
