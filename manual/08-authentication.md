# Authentication

Snails gives you the HTTP handshake, not the user model: the controller reads a token or a username and password from the request, your app decides whether it belongs to a user, and the helper answers 401 when it does not. No session store, no cookie middleware, and no token table are built in.

## Read a token

`authenticate_with_http_token` yields the token and its options to a block. It sends no challenge of its own, and a request without a token leaves the block unrun and answers `nil`:

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

The token is the first value; the pairs after it arrive as `options`, keyed by strings. Separate pairs with commas or semicolons — a space-separated `scope=read` is part of the token value, not an option.

## Answer the 401 in one call

The `or_request` form does the challenge for you. When the block answers `nil` or `false`, or when the scheme is missing, the controller sends a 401 with a `WWW-Authenticate` header and stops the filter chain:

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

`realm` names the protection space in the challenge; the default is `"Application"`. Pass `message:` to replace the default body. The render marks the response performed, so neither the rest of the action nor any later `before_action` runs.

The two helpers are separate operations — a block that renders a body still needs a truthy return value. Use the non-challenge form and answer the 401 yourself when the block owns the response.

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

## What the framework owns

The runtime owns the header parsing and the 401 response shape. Your app owns the credential store and the comparison. A token lookup is a model query like any other:

```ruby
def current_account
  authenticate_with_http_token do |token, options|
    Account.find_by({ api_token: token, revoked_at: nil })
  end
end
```

`find_by` is enough when the token column is unique; a token table with an expiry or scope column is your schema. Nothing in the runtime stores sessions, rotates tokens, or compares secrets in constant time.

The signing key for tokens you issue yourself comes from `Snails.app.secret_key_base`; [Configuration](16-configuration.md) covers that setting.
