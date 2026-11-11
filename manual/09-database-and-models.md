# Database and Models

Your app talks to SQLite or PostgreSQL through plain model classes. A model names its table, and the inherited reads and writes operate on the table — there is no ORM layer, no association graph, and no callback chain between you and the SQL.

## Declare a model

A model names its table and nothing else; the columns come from `db/schema.sql` and the generated `gen/model_columns.rb`:

```ruby
class Comment < Sqlx::Base
  def self.table_name = "comments"
end
```

Put model files under `app/models/` (subfolders are fine). The generator reads the schema and attaches column readers, `only_columns`, and the type lists; a model outside that folder is reported and skipped. When the schema changes, re-run the migration flow and the next build regenerates the readers — see [Columns and Types](11-columns-and-types.md).

A model may add class methods and instance methods for its own domain. It does not declare columns, associations, callbacks, or validations. Validation belongs to [Forms and Validation](13-forms.md); the schema constraint is the model layer's last line.

## Read and write

Conditions and attributes are plain hashes with Symbol keys:

```ruby
Post.create!({ title: "hello", body: "world" })   # returns the stored row
Post.find_by({ title: "hello" })                  # the first match, or nil
Post.count                                         # every row
Post.count({ title: "hello" })                     # matching rows
```

`create!` returns the stored record and fills a declared `created_at`/`updated_at` the caller left out. It raises when the database refuses the row — there is no silent-failure path on writes.

```ruby
Post.update!(@post.id, { title: "new title" })   # returns the re-read row
Post.delete!(@post.id)                           # returns the deleted-row count
```

`update!` raises `Sqlx::RecordNotFound` for an id that does not exist — the unknown id becomes a 404 through the controller's rescue (see [Error Handling](20-error-handling.md)), never a silent insert. `delete!` answers `0` for an unknown id; the caller's lookup decides whether that is a 404.

An empty conditions hash is not a question you can ask: `find_by({})` refuses because a blank condition would quietly match everything. The bulk entries use `nil` to mean the whole table. [Querying](10-querying.md) covers every condition form.

## Query across tables

Two records that belong together use the same entries — the second query is scoped by the first one's id:

```ruby
post = Post.find_by({ title: "hello" })
post.comments                              # this post's comments
Comment.fetch_many({ post_id: post.id }, order: :asc)
```

`fetch_many` takes the same conditions as `find_by` and returns every match. The association reader is an ordinary method; there is no generated association and no lazy loading.

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

`all` is newest-first here because a whole-table read with an order is your decision, not the framework's. `projection` is the model's quoted column list, so a raw read and the inherited reads share one spelling.

## Remove a parent and its children

There are no cascading associations. A cascade is app SQL, written where you can read it:

```ruby
class Post < Sqlx::Base
  def self.table_name = "posts"

  def self.delete!(id)
    Comment.delete_all!({ post_id: id })
    Sqlx::Database.exec_write('DELETE FROM "posts" WHERE "id" = ?', [ id ])["count"]
  end
end
```

The child half uses the inherited `delete_all!`; the parent half writes its own DELETE because an override cannot reach the core body through `super` on the extend chain. A foreign key in the schema is still the stronger guarantee when the adapter enforces it.

## Enums and transactions

An integer column with a fixed label set uses `enum`; a multi-statement unit uses a transaction. Both are covered where they belong: [Columns and Types](11-columns-and-types.md) for the enum declaration, [Querying](10-querying.md) for `Sqlx::Base.transaction`.

## See it work

With the scaffold, the posts and comments cases cover the model path:

```text
ok   adapter_test.rb
ok   comments_test.rb
ok   post_form_test.rb
ok   posts_test.rb
ok   up_test.rb
5/5 passed
```
