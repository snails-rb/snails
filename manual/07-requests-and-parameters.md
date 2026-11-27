# Requests and Parameters

A controller reads one request object and one params hash. The hash is built from the request body, the query string, and the route's path captures, in that order. A query value wins over a body field with the same name, and a path capture wins over both.

## How params are built

JSON, urlencoded, and multipart bodies all reach the controller as the same String-keyed hash. A body counts as JSON when its media type is `application/json` or ends with `+json` (`application/vnd.api+json`). Nested fields keep their structure:

```ruby
# POST /posts/42/comments?page=2, body: {"comment": {"body": "hello"}}
params["page"]          # => "2"        from the query string
params["comment"]       # => {"body" => "hello"}
params["comment"]["body"] # => "hello"
params["post_id"]       # => "42"       from the route
```

A JSON object keeps its nesting, so `{"user": {"name": "Sue"}}` and an urlencoded `user[name]=Sue` build the same tree. A JSON array keeps every element, the same way an urlencoded `tags[]=red&tags[]=blue` does. Scalar values are Strings, as in the other body types: JSON numbers and booleans become `"3"` and `"true"`, and `null` becomes `""`. Read an array directly, or filter the keys of its objects with `ActionController::Params.permit`; `str` is for scalar fields. When you need the JSON values with their own types, parse `request.raw_post`.

To read only the body, use `request.request_parameters`. It holds the body's fields and nothing else; the query string and the path captures are not merged in. A JSON body keeps its arrays and nested objects there too, and scalar values are Strings there as well. Inside a controller, `params` and `request.params` are the same hash.

Request params are mutable and String-keyed. `params[:id]` is always `nil`. Read `params["id"]`.

Path captures arrive as Strings. The generated model declares its integer columns, so the model casts the value when it builds the condition:

```ruby
@post = Post.find(params["id"])
```

A non-decimal value such as `"1-welcome"` raises `Sqlx::CastError`, which the framework turns into `400 Bad Request`. A TEXT or UUID primary key isn't declared as an integer column, so it stays an exact string lookup.

A route can carry a format extension. `GET /posts.json` matches the `/posts` route and sets `params["format"]` to `"json"`. The extension isn't part of the path captures.

## Read the request

The request object exposes the methods a controller usually reads:

```ruby
request.request_method   # "GET"
request.path             # "/posts/42"
request.fullpath         # "/posts/42?page=2"
request.host             # "example.com"
request.url              # "https://example.com/posts/42?page=2"
request.protocol         # "https://"
request.remote_ip        # "203.0.113.7"
request.user_agent
request.referer
request.get?             # true for GET
request.head?            # true for HEAD
request.xhr?             # true when X-Requested-With is XMLHttpRequest
request.ssl?             # true behind a TLS terminator that sets X-Forwarded-Proto
request.content_type     # "application/json; charset=utf-8", or nil when absent
request.media_type       # "application/json", without parameters
request.content_length   # bytes, 0 when the request has no body
request.json?            # true for application/json and +json media types
```

Headers are a read-only, case-insensitive view. Both the wire name and the internal env key are accepted:

```ruby
request.headers["Authorization"]       # "Bearer …"
request.headers["HTTP_AUTHORIZATION"]  # same value
request.headers.fetch("X-Request-Id", "none")
request.headers.to_h                   # all headers, lowercase names
request.headers.each_header { |name, value| ... }
```

The raw body is an IO, because a parser may need to read it more than once:

```ruby
request.body.rewind
request.body.read        # the whole body
request.raw_post         # the same text without touching the cursor
```

The parser has already consumed the body into `params`. Don't read it again in a `before_action`. `request.raw_post` returns the bytes without moving the cursor.

## Cookies

The request's parsed cookies are a String-keyed hash on `request.cookies`:

```ruby
request.cookies["session"]       # the value, or nil when the cookie is absent
```

The controller's `cookies` jar reads the same values and records writes:

```ruby
cookies[:session]                  # the value, or "" when absent
cookies[:session] = "abc123"       # Set-Cookie: session=abc123; Path=/; SameSite=Lax
cookies[:session] = {
  value: "abc123",
  httponly: true,
  secure: true,
  same_site: :strict,
  path: "/",
  max_age: 3600
}
cookies.delete(:session, path: "/")
```

A write records a `Set-Cookie` line. Several writes in one request produce several lines. The defaults are `path: "/"` and `same_site: :lax`. `secure` and `httponly` stay false until you set them. A nil value deletes the cookie.

Options are `expires:` (a `Time`), `max_age:` (seconds), `path:`, `domain:`, `secure:`, `httponly:`, and `same_site:` (`:lax`, `:strict`, `:none`, or `nil`). An unknown key raises `ArgumentError`. An invalid name, path, or domain raises `ArgumentError` too. A name must be an RFC 6265 token: visible ASCII without separators. A path or domain must be header-safe; a `;`, a control byte, or CR/LF raises. `same_site: :none` needs `secure: true`. A `__Host-` name needs `secure: true`, `path: "/"`, and no `domain:`. A `__Secure-` name needs `secure: true`.

`cookies[:missing]` returns `""`, not `nil`. Read `request.cookies` when you need to tell an absent cookie from an empty value. `cookies.permanent[:name] = "value"` adds a 20-year expiry.

`cookies.to_h` returns the inbound cookies with this request's pending writes. `cookies.each` walks that snapshot. The `permanent` and `signed` wrappers read and write individual keys; they do not provide a whole-jar read.

`cookies.signed[:name]` signs the value with a cookie-specific key derived from `SECRET_KEY_BASE` and verifies it on read. A tampered value, or a value signed for another cookie name, reads `nil`:

```ruby
cookies.signed[:token] = {
  value: "abc",
  httponly: true,
  secure: true,
  same_site: :strict
}
cookies.signed[:token]             # "abc", or nil when the signature does not verify
cookies.signed.permanent[:token] = "abc"
```

`cookies.signed` accepts the same options Hash as the plain jar. Signing prevents tampering, not reading: the value is Base64-encoded, not encrypted. Signing does not expire a token; the cookie's `max_age` or `expires` controls browser retention, and the app checks its own timestamp when it needs a validity window.

The jar is the supported write path. Do not set `Set-Cookie` through `response.headers`. That hash holds one value per header and cannot hold several cookies.

The framework does not provide sessions. If you need sessions, implement them in your app.

## Narrow input before it reaches a model

`ActionController::Params` narrows the plain hash before it reaches a model. Call it in the controller, where a bad request is still cheap to reject:

```ruby
class SignupForm
  def initialize(raw)
    @name = ActionController::Params.require_key(raw, "name")
    @email = ActionController::Params.str(raw, "email", "")
  end
end
```

`require_key` raises `ActionController::ParameterMissing` when the key is absent or its value is a blank string. The framework turns that exception into a 400 with `{"error":"bad_request"}`, so a missing field never reaches the model as `nil`. `sub` and `str` are the lenient alternatives: an absent key returns `{}` or the fallback you passed.

`permit` keeps a declared subset and drops everything else:

```ruby
ActionController::Params.permit(params, [
  :title,
  :body,
  { author: [ :name, :email ] },
  { tags: [] }
])
# => { title: "…", body: "…", author: { "name" => "…" }, tags: [...] }
```

The result is Symbol-keyed at the top level. Nested hashes keep the keys the request carried. A Symbol filter keeps a scalar value when it is truthy. `{}` keeps a nested Hash as-is. An Array of Symbols keeps only those keys of a nested Hash, and maps each Hash element of an array through the same list. Unknown fields don't raise — they are dropped, which is the point of a permit list. `provided` asks the narrower question: did the request carry a usable scalar for this key? A blank string counts. `nil` and a nested value do not.

## Uploads

A `multipart/form-data` body puts text parts in `params` and file parts under the same nested key, as `ActionDispatch::Http::UploadedFile`:

```ruby
file = params["avatar"]                  # the uploaded file
file.original_filename                   # "portrait.jpg"
file.content_type                        # "image/jpeg"
file.size                                # bytes
file.read                                # the bytes, in memory
```

An empty file input is dropped, so `params["avatar"]` is `nil`. Uploaded bytes stay in memory until your storage code writes them. There's no disk-backed upload path. A body over 8 MiB is refused before it is read with a 413. A body that hasn't finished arriving after 30 seconds gets a 408, and a body that ends early or doesn't parse is a 400.

## Limits

The request parser enforces its limits before the action runs:

| Limit | Value | Response |
|---|---:|---|
| Request body | 8 MiB | 413 |
| Whole-body read | 30 seconds | 408 |
| Nesting depth | 100 levels | 400 |
| Malformed %-escape, invalid UTF-8, mixed array/hash name | — | 400 |

A JSON body that isn't an object, or that doesn't parse, is also a 400. Those responses are JSON, like every other route response.

When a job or another caller needs the current request outside a controller instance, `ActionController::Current.request` and `.controller` hold it for the duration of the action.

Authentication reads the same `Authorization` header. [Authentication](08-authentication.md) covers that path.
