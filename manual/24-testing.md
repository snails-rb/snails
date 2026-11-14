# Testing

`bin/test` builds the app and runs your test harness against a real HTTP server — no mocks. The suite is a set of files under `harness/test/`, and one fresh server serves them.

The harness runs against a real server on purpose. Stubs and mocks are easier to write; a coding agent left to choose will often produce a suite that describes the system instead of exercising it. Booting the real server makes the integration path the default; a passing suite runs against the real HTTP server. See [The Snails Design](https://snails-rb.org/blog/the-snails-design/#integration-tests-against-a-real-server) for the design choice.

## Run everything

```text
[snails] pins ok (spinel=858dde41b snails=v0.48.0)
[snails] /tmp/manual-demo/.spinel/toolchain in sync (spinel 858dde41b)
[snails] /tmp/manual-demo snails-core in sync
build manual-demo (up to date)
ok   adapter_test.rb
ok   comments_test.rb
ok   post_form_test.rb
ok   posts_test.rb
ok   up_test.rb
5/5 passed
```

Each file reports `ok`, `skip`, or `FAIL` on its own line, and the last line counts case files. A failing case prints its expected and actual output on the `FAIL` line; `--verbose` prints the full server log.

## Run one file

Pass the file's path under `harness/` while you iterate:

```sh
bin/test -- harness/test/posts_test.rb
```

```text
[snails] running 1 of 5 case files
ok   posts_test.rb (cached)
1/1 passed
```

A wrong path is refused loudly — it prints the list of case files and exits non-zero instead of quietly running everything.

## Write a test

A test file loads the harness boot, declares a class, and drives the real server:

```ruby
require_relative "../boot"

if Snails::Harness.file_selected?
  class PostsTest < Snails::Harness::IntegrationTest
    def tables
      ["posts"]
    end

    test "posts create persists the submitted post" do
      post("/posts", params: { "title" => "hello", "body" => "world" }, as: :json)
      assert_response(:success)
      saved = Post.find_by({ title: "hello" })
      assert_equal "world", saved.body
    end
  end
end
```

The `file_selected?` guard prevents a bundle run from defining every file's class at once. `tables` declares which tables are emptied before each case, so every case starts from its own rows. `setup` runs after that reset and before the case body; use it for fixtures or a signed-in state.

`default_host` sets the Host header for every request when your routes depend on it. A per-request `headers:` hash is also available:

```ruby
def default_host = "api.example.test"

get("/posts", headers: { "Authorization" => "Token abc123" })
```

Requests go over real HTTP. `get` takes `params:` (query) and `headers:`; `post`, `put`, and `delete` take a body `params:`, `headers:`, and `as: :json`.

## Assertions

| Assertion | Passes when |
|---|---|
| `assert_response(type)` | status matches; `:success` is 2xx, `:redirect` 3xx, `:error` 5xx, `:missing` 404, a status symbol or Integer is exact |
| `assert_equal(expected, actual)` | the values are equal |
| `assert_not_equal(expected, actual)` | they differ |
| `assert(value, message = nil)` | the value is truthy |
| `assert_not(value)` | the value is false or nil |
| `assert_nil(value)` | the value is nil |
| `assert_not_nil(value)` | the value is not nil |
| `assert_includes(collection, object)` | the collection includes the object |
| `assert_match(pattern, actual)` | a String pattern is a substring; a Regexp matches |
| `assert_operator(left, operator, right)` | `>=`, `<=`, `>`, or `<` holds |
| `assert_raises(error_class) { ... }` | the block raises that class or a subclass |
| `assert_emails(count) { ... }` | the block adds exactly `count` lines to the mail capture |

`response` is the last response; `response.status`, `response.body`, `response.headers`, and `response.parsed_body` are the usual reads. `assert_emails` and `emails` use the server's `tmp/mail-capture.jsonl`; see [Email](14-email.md). Without a live server, `assert_emails` skips rather than passing silently.

End a case early with `skip("reason")`; the runner prints `skip` and does not fail the file.

## The `.expected` sibling

Each case file has a `.expected` sibling holding its `ok` lines. The runner diffs against it, so an intentional change to a case's name or output means updating that file in the same change. A new file gets an `.expected` beside it.

The test process does not start a job worker loop, so a job enqueued from a case runs at the call site. `ActiveJob.schedule` needs a worker loop and raises in that process; schedule work from a server action instead.

`harness/test.env` holds server-only environment for the gate. Put a test-only `SECRET_KEY_BASE` there when the app signs values; never a production key. The test process keeps its own environment.

A failed build or boot keeps the server log and names its path. `bin/test --verbose` prints the full log. [Troubleshooting](27-troubleshooting.md) covers the common failure lines.

[Local Development](22-local-development.md) covers the server loop; [Deploying](25-deploying.md) covers the image that runs the same binary.
