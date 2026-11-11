# Forms and Validation

When a request brings user input, `Snails::Form` projects it onto declared fields, runs your rules in declaration order, and collects the errors in that order. The controller writes the row only when `valid?` passes; the 422 body is the ordered message list.

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

`FIELDS` is the list input is projected onto. A key outside it never reaches a rule; a missing field reads `nil`. The form accepts a Hash and raises `ArgumentError` for anything else. `write_attribute` is the only writer; there are no generated setters. `normalize` runs once after projection when you need to trim or canonicalize input:

```ruby
def normalize
  write_attribute(:title, title.to_s.strip)
end
```

`valid?` clears the error list, runs the rules in declaration order, and answers `true` when none failed. Calling it again starts fresh.

## The rules

| Rule | Options | What it checks |
|---|---|---|
| `presence: true` | — | the value is not nil and not blank |
| `length` | `minimum:`, `maximum:`, `is:`, `within: Range` | string size (Array/Hash size for collections) |
| `format` | `with: Regexp` or `without: Regexp` | the whole string matches, or does not match |
| `inclusion` | `in: collection` | the value is in the collection |
| `exclusion` | `in: collection` | the value is not in the collection |
| `uniqueness` | `model:`, `column:`, `scope:` | no other row holds this value |
| `confirmation: true` | — | the `*_confirmation` sibling matches |
| `validate :method` | `if:`, `unless:` | your own rule, reported with `errors.add` |

`length` takes `minimum:`/`maximum:`/`is:` or one `within:` Range, not both. `is:` is exact. `inclusion` and `exclusion` compare with the collection's own `include?`; an Array value asks every element, which is the collection-field case. `uniqueness` reads `model.find_by` with the column (the attribute name by default) and any `scope:` fields; it does not write a lock, so a concurrent insert can still win the race and surface as `Sqlx::RecordNotUnique`.

`confirmation: true` belongs on the field being confirmed, not on the confirmation field. For `validates :password, confirmation: true`, the form must also declare `password_confirmation`; the rule compares `password` with that sibling.

A custom rule is an instance method that calls `errors.add`; a name that does not exist raises on the first `valid?` instead of skipping silently.

## Options that soften a rule

`allow_blank: true` skips a rule when the value is blank; `allow_nil: true` skips it when the value is nil. `if:` and `unless:` take a Symbol method name and run the rule only when that method says so:

```ruby
validates :password, length: { minimum: 8 }, allow_blank: true
validates :password, confirmation: true, if: :password_length_ok?
validates :email, presence: true, if: :email_required?
```

The common options can sit at the `validates` call level and apply to every rule in that call:

```ruby
validates :nickname, length: { maximum: 40 }, format: { with: /\A[a-z_]+\z/ }, allow_blank: true
```

A rule-level value wins over the call-level default. `presence` refuses `allow_blank` and `allow_nil` — a rule that can never fail is a declaration bug. `message:` belongs inside the rule's option hash, not at the call level; a String is used as written, a Symbol is resolved through the message scope.

## Collect the errors

```ruby
form = PostForm.new({ "title" => "", "body" => "" })
form.valid?            # => false
form.errors.size       # => 2
form.errors.full_messages
# => ["Title can't be blank", "Body can't be blank"]
```

Messages come from the default English table, or from `I18n` under the form's scope when the app has registered a locale. `message_scope` points at a locale subtree:

```ruby
class SignupForm < Snails::Form
  message_scope "activemodel.errors.models.signup.attributes"
end
```

Without `message_scope`, keys resolve under `activemodel.errors.models.<form_name>.attributes`. A custom String message is never looked up; a Symbol key with no built-in default and no `I18n` raises rather than rendering an empty line.

The errors object answers `full_messages`, `join(separator)`, `on(:field)`, `empty?`, `any?`, and `size`. `errors.add(:base, "...")` records a message not tied to a field.

## Save it yourself

A form knows nothing about saving. When validation passes, the controller writes the row:

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

The scaffold's `render_form_errors` turns `form.errors.full_messages` into `{"errors": [...]}` with a 422 status. The form never touches the database except for `uniqueness`'s read.

## See it work

```text
ok   adapter_test.rb
ok   comments_test.rb
ok   post_form_test.rb
ok   posts_test.rb
ok   up_test.rb
5/5 passed
```

[Requests and Parameters](07-requests-and-parameters.md) covers the raw params tree the form receives; [Error Handling](20-error-handling.md) covers the status mapping around a failed write.
