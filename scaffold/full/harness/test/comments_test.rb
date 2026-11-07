# Comments CRUD — the scaffold's nested comments resource, driven over real
# HTTP.
require_relative "../boot"

if Snails::Harness.file_selected?
  class CommentsTest < Snails::Harness::IntegrationTest
    def tables
      ["posts", "comments"]
    end

    test "comments create persists the submitted comment" do
      created = Post.create!({ title: "post", body: "body" })
      post("/posts/" + created.id.to_s + "/comments", params: { "body" => "nice" }, as: :json)
      assert_response(:success)
      saved = Comment.find_by({ post_id: created.id })
      assert_equal "nice", saved.body
    end

    test "comments index lists the post's comments oldest first" do
      created = Post.create!({ title: "post", body: "body" })
      other = Post.create!({ title: "other", body: "body" })
      Comment.create!({ post_id: created.id, body: "one" })
      Comment.create!({ post_id: created.id, body: "two" })
      Comment.create!({ post_id: other.id, body: "three" })
      get("/posts/" + created.id.to_s + "/comments")
      assert_response(:ok)
      data = JSON.parse(@response.body)
      assert_equal 2, data.length
      assert_equal "one", data[0]["body"]
      assert_equal "two", data[1]["body"]
    end

    test "comments show returns the stored comment" do
      created = Post.create!({ title: "post", body: "body" })
      comment = Comment.create!({ post_id: created.id, body: "text" })
      get("/posts/" + created.id.to_s + "/comments/" + comment.id.to_s)
      assert_response(:ok)
      data = JSON.parse(@response.body)
      assert_equal "text", data["body"]
      assert_equal comment.id, data["id"]
    end

    test "comments update changes the stored comment" do
      created = Post.create!({ title: "post", body: "body" })
      comment = Comment.create!({ post_id: created.id, body: "old" })
      put("/posts/" + created.id.to_s + "/comments/" + comment.id.to_s, params: { "body" => "new" }, as: :json)
      assert_response(:ok)
      assert_equal "new", Comment.find(comment.id).body
    end

    test "comments destroy removes the comment" do
      created = Post.create!({ title: "post", body: "body" })
      comment = Comment.create!({ post_id: created.id, body: "body" })
      delete("/posts/" + created.id.to_s + "/comments/" + comment.id.to_s)
      assert_response(:no_content)
      assert_equal nil, Comment.find_by({ id: comment.id })
    end

    test "comments create on an unknown post is a 404" do
      post("/posts/999999/comments", params: { "body" => "ghost" }, as: :json)
      assert_response(:not_found)
    end

    test "comments destroy with their post" do
      created = Post.create!({ title: "doomed", body: "body" })
      Comment.create!({ post_id: created.id, body: "one" })
      Comment.create!({ post_id: created.id, body: "two" })
      delete("/posts/" + created.id.to_s)
      assert_response(:no_content)
      assert_equal nil, Comment.find_by({ post_id: created.id })
    end
  end
end
