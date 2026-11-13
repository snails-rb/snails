# Posts CRUD — the scaffold's posts JSON resource, driven over real HTTP.
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

    test "posts index lists the stored posts" do
      Post.create!({ title: "first", body: "body one" })
      Post.create!({ title: "second", body: "body two" })
      get("/posts")
      assert_response(:ok)
      data = JSON.parse(@response.body)
      assert_equal 2, data.length
      assert_equal "second", data[0]["title"]
    end

    test "count answers with and without conditions" do
      Post.create!({ title: "first", body: "body one" })
      Post.create!({ title: "second", body: "body two" })
      assert_equal 2, Post.count
      assert_equal 1, Post.count({ title: "first" })
    end

    test "posts show returns the stored post" do
      created = Post.create!({ title: "shown", body: "body text" })
      get("/posts/" + created.id.to_s)
      assert_response(:ok)
      data = JSON.parse(@response.body)
      assert_equal "shown", data["title"]
      assert_equal created.id, data["id"]
    end

    # The JSON time columns use the ext's ISO8601 format: the model returns
    # Time and `render json:` formats it, with no controller formatter in the
    # scaffold.
    test "posts show renders the time columns as ISO8601" do
      created = Post.create!({ title: "stamped", body: "body" })
      get("/posts/" + created.id.to_s)
      assert_response(:ok)
      data = JSON.parse(@response.body)
      assert_equal created.created_at.to_fs(:iso8601), data["created_at"]
      assert_equal created.updated_at.to_fs(:iso8601), data["updated_at"]
    end

    test "posts update changes the stored post" do
      created = Post.create!({ title: "before", body: "old body" })
      put("/posts/" + created.id.to_s, params: { "title" => "after", "body" => "new body" }, as: :json)
      assert_response(:ok)
      assert_equal "after", Post.find(created.id).title
    end

    test "a write with RETURNING answers its rows and count" do
      created = Post.create!({ title: "before", body: "body" })
      result = Sqlx::Database.exec_write(
        'UPDATE "posts" SET "title" = ? WHERE "id" = ? RETURNING "id", "title"',
        [ "after", created.id ]
      )
      assert_equal 1, result["count"]
      assert_equal 1, result["rows"].length
      assert_equal created.id, result["rows"][0]["id"]
      assert_equal "after", result["rows"][0]["title"]
    end

    test "posts destroy removes the post" do
      created = Post.create!({ title: "doomed", body: "body" })
      delete("/posts/" + created.id.to_s)
      assert_response(:no_content)
      assert_equal nil, Post.find_by({ id: created.id })
    end
  end
end
