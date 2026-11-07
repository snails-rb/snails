# Routes and Controllers

You declare routes in `config/routes.rb` and point them at controllers that subclass `ActionController::API`. A controller reads the request and renders a response — JSON, a redirect, or a status with no body.

## Declare routes

The route table is a list of helper calls. The scaffold's two resources look like this:

```ruby
module Snails
  module RouteTable
    def self.table
      [
        get("/up", Snails::HealthController, :show),
        *resources("/posts", Api::PostsController, :json),
        *resources("/posts/:post_id/comments", Api::CommentsController, :json)
      ]
    end
  end
end
```

`resources` expands to the whole set — `GET /posts`, `GET /posts/:id`, `POST`, `PUT`, `DELETE` — so one row can stand for five. A nested path like `/posts/:post_id/comments` scopes the child resource to its parent.

Rows in one list need commas between them — a newline is not a separator. When two hand-written `get` rows derive the same helper name (`/posts` and `/posts/:id` both want `posts`), give one a `# as: name` marker:

```ruby
get("/posts", Api::PostsController, :index),
get("/posts/:id", Api::PostsController, :show), # as: post
```

## Write the controller

A resource controller keeps the shape the scaffold uses — resolve the record once, then let each action answer:

```ruby
module Api
  class PostsController < Api::ApplicationController
    before_action :set_post, only: [:show, :update, :destroy]

    def index
      render(json: Post.all.map { |post| post_json(post) })
    end

    def show
      render(json: post_json(@post))
    end

    def create
      form = PostForm.new(params)
      if form.valid?
        post = Post.create!({ title: form.title, body: form.body })
        render(json: post_json(post), status: :created)
      else
        render_form_errors(form)
      end
    end

    private

    def set_post
      @post = Post.find(params["id"].to_i)
    end

    def post_json(post)
      { "id" => post.id, "title" => post.title, "body" => post.body }
    end
  end
end
```

`create` runs the submitted fields through `PostForm` before it writes; [Forms and Validation](09-forms.md) covers that part.

Four things to copy from this shape:

- `params` is a hash keyed by strings — `params["title"]`, not `params[:title]`.
- `status:` takes a symbol — `:created`, not `201`.
- The path capture arrives as a String, so `to_i` before it meets the id column.
- `before_action` runs before the listed actions — `set_post` runs for `show` but not for `index`.

## Answer 404 from one place

An unknown id should not reach the action body. The scaffold's base class rescues the raising finder for every action and filter at once:

```ruby
class ApplicationController < ActionController::API
  def process_action(action_name)
    super
  rescue Sqlx::RecordNotFound
    head(:not_found, content_type: JSON_TYPE)
  end
end
```

`Post.find` raises `Sqlx::RecordNotFound` for a missing row, and this one rescue turns it into a 404 — instead of each action checking for nil.

## See it work

```text
ok   adapter_test.rb
ok   comments_test.rb
ok   post_form_test.rb
ok   posts_test.rb
ok   up_test.rb
5/5 passed
```
