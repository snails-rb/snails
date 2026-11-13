module Api
  # The scaffold's posts resource — JSON CRUD over Post.
  class PostsController < Api::ApplicationController
    # The `:id` actions hang off one post, so resolve it once; an unknown
    # id raises here (the base's rescue answers 404) before the action body
    # runs. `index`/`create` carry no `:id`, so the filter skips them.
    before_action :set_post, only: [:show, :update, :destroy]

    # GET /posts — every post, newest first.
    def index
      render(json: Post.all.map { |post| post_json(post) })
    end

    # GET /posts/:id — the post; an unknown id is a 404.
    def show
      render(json: post_json(@post))
    end

    # POST /posts — validate the submitted post, store it, answer 201 with
    # it; an invalid input answers 422 with the form's message list.
    def create
      form = PostForm.new(params)
      if form.valid?
        post = Post.create!({ title: form.title, body: form.body })
        render(json: post_json(post), status: :created)
      else
        render_form_errors(form)
      end
    end

    # PUT /posts/:id — validate the submitted post, rewrite it, answer 200
    # with it; an unknown id is a 404 rather than a silent insert, and an
    # invalid input leaves the stored row untouched.
    def update
      form = PostForm.new(params)
      if form.valid?
        post = Post.update!(@post.id, { title: form.title, body: form.body })
        render(json: post_json(post))
      else
        render_form_errors(form)
      end
    end

    # DELETE /posts/:id — remove the post, answer 204; unknown id is a 404.
    def destroy
      Post.delete!(@post.id)
      head(:no_content, content_type: JSON_TYPE)
    end

    private

    # Resolve the post the `:id` actions address. Sets `@post`; an unknown
    # id raises here so no action body runs. The generated model declares
    # `id` as an integer column, so `find` casts the path capture.
    def set_post
      @post = Post.find(params["id"])
    end

    # A failed form answers its ordered messages as 422 — the same response
    # every invalid request gets, whether create or update.
    def render_form_errors(form)
      render(json: { errors: form.errors.full_messages }, status: :unprocessable_entity)
    end

    def post_json(post)
      {
        "id" => post.id,
        "title" => post.title,
        "body" => post.body,
        "created_at" => post.created_at,
        "updated_at" => post.updated_at
      }
    end
  end
end
