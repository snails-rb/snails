# Requests and Parameters

A controller reads one request object and one params hash. The hash is built from the request body, the query string, and the route's path captures, in that order — so a query value wins over a body field with the same name, and a path capture wins over both.

## How params are built

JSON, urlencoded, and multipart bodies all reach the controller as the same String-keyed hash. Nested fields keep their shape:

```ruby
# POST /posts/42/comments?page=2, body: {"comment": {"body": "hello"}}
params["page"]          # => "2"        from the query string
params["comment"]       # => {"body" => "hello"}
params["comment"]["body"] # => "hello"
params["post_id"]       # => "42"       from the route
```

A JSON object is flattened by field name and nested back the same way, so `{"user": {"name": "Sue"}}` and an urlencoded `user[name]=Sue` build the same tree. A JSON array has no slot in the body reader, so its elements are folded into the same `[]` key and the last one wins; send a nested object when every element must survive.

Request params are mutable and String-keyed. `params[:id]` is always `nil`; read `params["id"]`.

Path captures arrive as Strings. The generated model declares its integer columns, so the model casts the value when it builds the condition:

```ruby
@post = Post.find(params["id"])
```

A non-decimal value such as `"1-welcome"` raises `Sqlx::CastError`, which the dispatcher answers as `400 Bad Request`. A TEXT or UUID primary key is not declared as an integer column, so it stays an exact string lookup.

A route can carry a format extension. `GET /posts.json` matches the `/posts` route and sets `params["format"]` to `"json"`; the extension is not part of the path captures.

## Read the request

The request object exposes the pieces a controller usually needs:

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

Do not read the body in a `before_action` unless the action is done with it. Parsing already consumed it into `params`, and a second read from a rewound cursor sees the same bytes.

## Shape input before it reaches a model

`ActionController::Params` is the narrowing surface over the plain hash. Call it at the controller boundary, where a bad request is still cheap to reject:

```ruby
class SignupForm
  def initialize(raw)
    @name = ActionController::Params.require_key(raw, "name")
    @email = ActionController::Params.str(raw, "email", "")
  end
end
```

`require_key` raises `ActionController::ParameterMissing` when the key is absent or its value is a blank string. The dispatcher turns that exception into a 400 with `{"error":"bad_request"}`, so a missing field never reaches the model as `nil`. `sub` and `str` are the forgiving half: an absent key answers `{}` or the fallback you passed.

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

The result is Symbol-keyed at the top level; nested hashes keep the keys the request carried. A Symbol filter keeps a scalar value when it is truthy. `{}` keeps a nested Hash as-is. An Array of Symbols keeps only those keys of a nested Hash, and maps each Hash element of an array through the same list. Unknown fields do not raise — they are dropped, which is the point of a permit list. `provided` asks the narrower question: did the request carry a usable scalar for this key? A blank string counts; `nil` and a nested value do not.

## Uploads

A `multipart/form-data` body puts text parts in `params` and file parts under the same nested key, as `ActionDispatch::Http::UploadedFile`:

```ruby
file = params["avatar"]                  # the uploaded file
file.original_filename                   # "portrait.jpg"
file.content_type                        # "image/jpeg"
file.size                                # bytes
file.read                                # the bytes, in memory
```

A file input nobody filled has an empty filename and is dropped, so `params["avatar"]` is `nil`. Uploaded bytes stay in memory until your storage code writes them; there is no disk-backed upload path. A body over 8 MiB is refused before it is read with a 413; a body that stops arriving within 30 seconds gets a 408, and a body that ends early or does not parse is a 400.

## Limits

The request parser enforces its limits before the action runs:

| Limit | Value | Response |
|---|---:|---|
| Request body | 8 MiB | 413 |
| Whole-body read | 30 seconds | 408 |
| Nesting depth | 100 levels | 400 |
| Malformed %-escape, invalid UTF-8, mixed array/hash name | — | 400 |

A JSON body that is not an object, or that does not parse, is also a 400. Those answers are JSON, like every other route response.

When a job or another caller needs the current request outside a controller instance, `ActionController::Current.request` and `.controller` hold it for the duration of the action.

Authentication reads the same `Authorization` header. [Authentication](08-authentication.md) covers that path.
