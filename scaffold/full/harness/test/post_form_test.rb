# Post form validation — the scaffold's PostForm at the input boundary,
# exercised directly and through the posts JSON resource.
require_relative "../boot"

if Snails::Harness.file_selected?
  class PostFormTest < Snails::Harness::IntegrationTest
    def tables
      ["posts"]
    end

    # The form collects every blank-field error in declaration order: title
    # before body, while the length rule skips the blank title.
    test "the form collects blank errors in declaration order" do
      form = PostForm.new({ "title" => "", "body" => "" })
      assert_equal false, form.valid?
      assert_equal 2, form.errors.size
      assert_equal ["Title can't be blank", "Body can't be blank"], form.errors.full_messages
    end

    # A title shorter than three characters fails the length rule, and the
    # controller writes no row.
    test "posts create rejects a short title" do
      post("/posts", params: { "title" => "ab", "body" => "body text" }, as: :json)
      assert_response(:unprocessable_entity)
      assert_equal ["Title is too short (minimum is 3 characters)"],
                   JSON.parse(@response.body)["errors"]
      assert_equal 0, Post.count
    end

    # The custom rule reports its own message when the title carries markup.
    test "posts create rejects HTML in the title" do
      post("/posts", params: { "title" => "<b>hello</b>", "body" => "body text" }, as: :json)
      assert_response(:unprocessable_entity)
      assert_equal ["Title must not contain HTML"], JSON.parse(@response.body)["errors"]
      assert_equal 0, Post.count
    end

    # A valid submission reaches the row the form projected.
    test "posts create writes a valid form" do
      post("/posts", params: { "title" => "hello", "body" => "world" }, as: :json)
      assert_response(:created)
      data = JSON.parse(@response.body)
      assert_equal "hello", data["title"]
      assert_equal "world", data["body"]
      assert_equal "hello", Post.find(data["id"]).title
    end

    # Update runs the same form: an invalid title is a 422 and the stored
    # row keeps its previous values.
    test "posts update rejects an invalid title" do
      created = Post.create!({ title: "kept", body: "body text" })
      put("/posts/" + created.id.to_s, params: { "title" => "", "body" => "new body" }, as: :json)
      assert_response(:unprocessable_entity)
      stored = Post.find(created.id)
      assert_equal "kept", stored.title
      assert_equal "body text", stored.body
    end
  end
end
