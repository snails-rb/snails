# Testing

`bin/test` builds the app and runs your test harness against a real HTTP server — no mocks. The suite is a set of files under `harness/test/`, and one fresh server serves them.

## Run everything

```text
[snails] pins ok (spinel=92e3f26be snails=d38ad49)
[snails] /tmp/tmp.J5f17hOwsM/demo2 snails-core in sync
build demo2 (up to date)
ok   adapter_test.rb
ok   comments_test.rb
ok   post_form_test.rb
ok   posts_test.rb
ok   up_test.rb
5/5 passed
```

Every file reports `ok` or `FAIL` on its own line, and the last line is the count. A failing file prints its expected and actual output right there.

## Run one file

Pass the file's path under `harness/` while you are iterating on it:

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

A test file loads the harness boot, declares a class, and drives the real server. The scaffold's posts test shows the two pieces every file can use:

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

    test "count answers with and without conditions" do
      Post.create!({ title: "first", body: "body one" })
      Post.create!({ title: "second", body: "body two" })
      assert_equal 2, Post.count
      assert_equal 1, Post.count({ title: "first" })
    end
  end
end
```

The `file_selected?` guard keeps a bundle run from defining every file's class at once. `def tables` declares which tables this file resets between tests, so each test starts from its own rows. Requests go over real HTTP — `post("/posts", params: …, as: :json)` is the same call your client would make.

Each file has a `.expected` sibling holding its `ok` lines — the runner diffs against it, so an intentional change means updating that file alongside the test.
