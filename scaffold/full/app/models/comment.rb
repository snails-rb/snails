# The scaffold's second resource: comments over the comments table, linked to
# posts by post_id.
#
# Reads and writes use the inherited Sqlx entries with no model-local
# wrappers. Column readers and COLUMNS are generated from db/schema.sql —
# do not declare them here.
class Comment < Sqlx::Base
  def self.table_name = "comments"

  # No from_row — the default hydration copies the columns and converts the
  # declared time columns.
end
