# Database and Models

Your app talks to SQLite or PostgreSQL through plain model classes. You declare the table once, and the inherited queries and writes work over it — no ORM layer between you and the SQL.

## Declare a model

A model names its table and nothing else — the columns come from `db/schema.sql`:

```ruby
class Comment < Sqlx::Base
  def self.table_name = "comments"
end
```

Readers and the column list are generated from the schema into `gen/model_columns.rb`, so you never declare them in the model. When the schema changes, re-run the migration flow and they follow (see [Migrations](08-migrations.md)).

## Read and write

Conditions and attributes are plain hashes with symbol keys:

```ruby
Post.create!({ title: "hello", body: "world" })   # returns the stored row
Post.find_by({ title: "hello" })                  # the first match, or nil
Post.count                                         # every row
Post.count({ title: "hello" })                    # matching rows
```

`create!` raises if the database refuses it — there is no silent-failure path on writes. An empty hash is not a question you can ask: `find_by({})` refuses, because a blank condition would quietly match everything.

## Query across tables

Two records that belong together use the same entries — the second query is scoped by the first one's id:

```ruby
post = Post.find_by({ title: "hello" })
post.comments                              # this post's comments
Comment.fetch_many({ post_id: post.id }, order: :asc)
```

`fetch_many` takes the same conditions as `find_by` and returns every match — here, one post's comments oldest first.

## Define the reads your app needs

The scaffold's `Post` shows the pattern — class methods built on the same entries:

```ruby
class Post < Sqlx::Base
  def self.table_name = "posts"

  def self.all
    find_by_sql("SELECT " + projection + " FROM \"posts\" ORDER BY \"id\" DESC")
  end
end
```

`all` is newest-first here because a whole-table read with an order is your decision to make, not the framework's.

## Write and remove

```ruby
Post.update!(@post.id, { title: "new title" })   # returns the updated row
Post.delete!(@post.id)                           # removes it
```

`update!` answers `RecordNotFound` for an id that does not exist — the unknown id becomes a 404 through the controller's rescue (see [Routes and Controllers](06-routes-and-controllers.md)), not a silent insert. The scaffold's `Post.delete!` is also where a cascade lives — parent and child rows removed in one method you can read.

## See it work

```text
ok   adapter_test.rb
ok   comments_test.rb
ok   post_form_test.rb
ok   posts_test.rb
ok   up_test.rb
5/5 passed
```
