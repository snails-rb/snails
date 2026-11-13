module Api
  # The scaffold's comments resource — JSON CRUD for comments nested under a
  # post.
  class CommentsController < Api::ApplicationController
    # Every nested action hangs off the post, so resolve it first; an
    # unknown post raises before the action body runs (the filter halts the
    # chain and the base's rescue answers 404).
    before_action :set_post

    # GET /posts/:post_id/comments — the post's comments, oldest first.
    def index
      render(json: @post.comments.map { |comment| comment_json(comment) })
    end

    # POST /posts/:post_id/comments — store the submitted comment, answer
    # 201 with it.
    def create
      comment = Comment.create!({ post_id: @post.id, body: params["body"] })
      render(json: comment_json(comment), status: :created)
    end

    # GET /posts/:post_id/comments/:id — the post's comment; an id that
    # names none of that post's comments is a 404.
    def show
      comment = find_comment
      render(json: comment_json(comment))
    end

    # PUT /posts/:post_id/comments/:id — rewrite the comment, answer 200;
    # an unknown id is a 404 rather than a silent insert.
    def update
      comment = find_comment
      updated = Comment.update!(comment.id, { body: params["body"] })
      render(json: comment_json(updated))
    end

    # DELETE /posts/:post_id/comments/:id — remove the comment, answer 204.
    def destroy
      comment = find_comment
      Comment.delete!(comment.id)
      head(:no_content, content_type: JSON_TYPE)
    end

    private

    # Resolve the post the nested routes hang off. Sets `@post` for the
    # action; an unknown post raises here so no action body runs. The
    # generated model declares `id` as an integer column, so `find` casts
    # the path capture.
    def set_post
      @post = Post.find(params["post_id"])
    end

    # The comment scoped to its post — an id from another post is a miss,
    # so the nested route cannot read or write across posts. The generated
    # model declares `id` and `post_id` as integer columns, so the condition
    # values are cast without a controller conversion.
    def find_comment
      Comment.find_by!({ id: params["id"], post_id: params["post_id"] })
    end

    def comment_json(comment)
      {
        "id" => comment.id,
        "post_id" => comment.post_id,
        "body" => comment.body,
        "created_at" => comment.created_at,
        "updated_at" => comment.updated_at
      }
    end
  end
end
