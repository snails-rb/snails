# Routes and Controllers

You declare routes in `config/routes.rb` and point them at controllers that subclass `ActionController::API`. A controller reads the request and renders a response — JSON, a redirect, a header-only status, or bytes.

## Declare routes

The route table is a list of helper calls. The scaffold's resources look like this:

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

`resources` expands to five rows — `GET` and `POST` on the collection, `GET`, `PUT`, and `DELETE` on the member. A nested path such as `/posts/:post_id/comments` scopes the child to its parent.

Rows in one list need commas between them; a newline is not a separator. When two hand-written `get` rows derive the same helper name (`/posts` and `/posts/:id` both want `posts`), give one a `# as: name` marker:

```ruby
get("/posts", Api::PostsController, :index),
get("/posts/:id", Api::PostsController, :show), # as: post
```

`resources` takes two more positional arguments: a format and a subset of actions. The subset is an Array, not a keyword:

```ruby
resources("/devices", Api::DevicesController, :json, [:create, :show])
# GET /devices, POST /devices, GET /devices/:id
```

An action outside `:index`, `:create`, `:show`, `:update`, and `:destroy` raises at boot, so a typo cannot silently drop a row. The format argument forces the request format for every row; the common `:json` value matches the API default.

A route matches the GET row for a HEAD request too. The action sees `request.head?` and the server sends the status and headers without the body. A known extension on the last path segment — `/posts.json` — matches the `/posts` row and arrives as `params["format"]`.

## Path helpers

`gen/route_helpers.rb` turns the table into literal path methods:

```ruby
RouteHelpers.posts_path              # "/posts"
RouteHelpers.post_path(42)           # "/posts/42"
RouteHelpers.comments_path(42)       # "/posts/42/comments"
RouteHelpers.comment_path(42, 7)     # "/posts/42/comments/7"
```

A path with a dynamic segment takes one argument per segment. The generator refuses two rows that derive the same helper name from different patterns and tells you to add a `# as:` marker. A `resources` row cannot carry a marker; name a hand-written row instead when its helper name must differ.

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
      @post = Post.find(params["id"])
    end

    def post_json(post)
      { "id" => post.id, "title" => post.title, "body" => post.body }
    end
  end
end
```

The pieces to copy:

- `params` is a hash keyed by strings — `params["title"]`, not `params[:title]`.
- `status:` takes a symbol (`:created`) or an integer code; anything else raises.
- A path capture arrives as a String. The generated model declares its integer columns and casts the value; a TEXT/UUID key stays a string.
- `before_action` runs before the listed actions. A filter that renders a response halts the chain and the action.
- An action that renders nothing answers `204 No Content`; the default is not a bare 200 with no body.

`before_action` is per controller class. Registration does not propagate to subclasses — a filter added to a shared base class does not run on its subclasses. Declare it on each controller that needs it, or override a method the parent defines.

## Render a response

```ruby
render(json: value, status: :created)           # JSON body
render("plain text", content_type: "text/plain") # pre-encoded body
render(json: value, location: "/posts/42")      # 201 plus Location
redirect_to("/login", status: :see_other)      # 303
head(:no_content)                               # status only
send_data(bytes, type: "application/pdf")      # binary body
```

`render` takes either a positional body or `json:`, never both and never neither. `json:` encodes the value (see [Time, Dates, and JSON](17-time-dates-and-json.md)); a positional body is already encoded text. `redirect_to` sets `Location` and a 3xx status. `head` sets a status and no body. `send_data` sets a body and a content type; its `disposition:` argument is accepted but not written to a header, so set `Content-Disposition` yourself when a client needs it.

Extra response headers are set on the controller and copied to the response:

```ruby
headers["Cache-Control"] = "public, max-age=60"
headers["X-Request-Id"] = "abc"
```

## Filters and the action context

`before_action` accepts `only:` and `except:`, each a Symbol or an Array of Symbols. A conditional filter reads `action_name`, which `process_action` sets before it runs:

```ruby
before_action :mark_create, only: :create
before_action :mark_all, except: [:show, :index]
```

A filter may render, redirect, or `head`; the request then stops before the action. An action named in a route with no method raises `NoMethodError` instead of answering an empty 200.

`process_action` is the place for app-wide handling around every action. A subclass may override it to wrap the preamble or rescue one error for every action:

```ruby
def process_action(action_name)
  super
rescue Sqlx::RecordNotFound
  head(:not_found, content_type: JSON_TYPE)
end
```

Call `super` to keep the filters, the action, and the implicit 204. An override that replaces the dispatch must call `send_action(action_name)` instead. [Error Handling](20-error-handling.md) covers the rescue patterns.

A route's forced format lands on `controller.request_format`; a path extension lands on `params["format"]`. With no route choice, `request_format` is `:json`.

[Requests and Parameters](07-requests-and-parameters.md) covers the request object and the params hash in detail.
