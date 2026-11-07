# Forms and Validation

When a request brings user input, `Snails::Form` projects it onto declared fields, runs your rules in order, and collects the errors in order — the 422 body your client reads.

## Declare a form

A form declares its fields once, then adds rules to them. The scaffold's `PostForm` checks the posts input before the controller writes it:

```ruby
class PostForm < Snails::Form
  FIELDS = %w[title body].each { |n| define_method(n) { read_attribute(n) } }

  validates :title, presence: true
  validates :title, length: { minimum: 3, maximum: 120 }, allow_blank: true
  validates :body, presence: true
  validate :title_cannot_contain_html

  def title_cannot_contain_html
    errors.add(:title, "must not contain HTML") if title.to_s.include?("<")
  end
end
```

`FIELDS` is the list your input is projected onto — anything outside it never reaches a rule. Rules run in the order you declare them, and errors come back in that same order.

## The rules

| Rule | What it does |
|---|---|
| `presence: true` | the field must be present and not blank |
| `length: { minimum:, maximum:, within: }` | string size, with `within:` for an inclusive range |
| `format: { with: /…/ }` | the whole string must match the pattern |
| `uniqueness: { model:, column:, scope: }` | no other row may hold this value |
| `confirmation: true` | a second field (`*_confirmation`) must match |
| `validate :method` | your own rule — a method that calls `errors.add` |

Options that soften a rule apply per declaration: `allow_blank: true` skips the rule when the value is blank, `allow_nil: true` when it is missing, and `if: :method_name` runs the rule only when your method says so. `presence` refuses `allow_blank` — a rule that can never fail is a bug, not a setting.

## Collect the errors

```ruby
form = PostForm.new({ "title" => "", "body" => "" })
form.valid?            # => false
form.errors.size       # => 2
form.errors.full_messages
# => ["Title can't be blank", "Body can't be blank"]
```

Messages come from your locale when one is registered and fall back to plain English otherwise. `errors.full_messages` is what a 422 response carries to the client.

## Save it yourself

A form knows nothing about saving — when validation passes, you write the row from the controller:

```ruby
def create
  form = PostForm.new(params)
  if form.valid?
    post = Post.create!({ title: form.title, body: form.body })
    render(json: post_json(post), status: :created)
  else
    render_form_errors(form)
  end
end
```

The scaffold's `render_form_errors` helper turns `form.errors.full_messages` into `{"errors": [...]}` with a 422 status.

## See it work

```text
ok   adapter_test.rb
ok   comments_test.rb
ok   post_form_test.rb
ok   posts_test.rb
ok   up_test.rb
5/5 passed
```
