# The scaffold's example resource: a table-oriented model over the posts table.
#
# Reads go through the Sqlx lookup entries and writes through `create!` /
# `update!`; `delete!` cascades to the post's comments at the class level.
# Column readers and COLUMNS are generated from db/schema.sql — do not
# declare them here.
class Post < Sqlx::Base
  def self.table_name = "posts"

  # No from_row — the default hydration copies the columns and converts the
  # declared time columns.

  # Every post, newest first. The conditions-hash entries refuse an empty hash
  # (that question belongs to `all`), so the whole-table read lives here.
  def self.all
    find_by_sql("SELECT " + projection + " FROM \"posts\" ORDER BY \"id\" DESC")
  end

  # The post's comments, oldest first — the association reader the nested
  # comments controller calls. The conditions-hash entry keeps the post scope
  # explicit (the whole-table read belongs to `all`).
  def comments
    Comment.fetch_many({ post_id: id }, order: :asc)
  end

  # Remove a post and its comments — this scaffold's cascade. The sqlite adapter
  # enforces no foreign keys, so the cascade is app SQL: the child half rides
  # the inherited `Comment.delete_all!`, and the parent half writes its own
  # DELETE (an override cannot reach the core body through `super` on the
  # extend chain). Silent on an unknown id — the caller's lookup decides
  # whether that is a 404.
  def self.delete!(id)
    Comment.delete_all!({ post_id: id })
    Sqlx::Database.exec_write('DELETE FROM "posts" WHERE "id" = ?', [ id ])["count"]
  end
end
