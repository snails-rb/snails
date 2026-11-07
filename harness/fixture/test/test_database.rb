require_relative "test_helper"

# Adapter-aware setup for the common database contracts. The pg workspace
# sets PG_URL; the sqlite workspace leaves it unset. The test contract stays
# one file; only the connection and the DDL types change per adapter.
module TestDatabase
  # Configure for the selected adapter. setup calls this per case: another
  # case file's top-level configure may have run first in the bundle, and
  # the selected file's pool size must win.
  def self.configure!(name, pool_size: 8)
    # A connection or pool index from the previous configure belongs to the
    # old file/pool; the selected file must start on the new pool.
    Thread.current[:db_conn] = nil
    Thread.current[:db_pool] = nil
    # Close the old pool before deleting its sqlite file. macOS SQLite
    # answers SQLITE_IOERR (10) when a table operation reaches a connection
    # whose file was removed underneath it; Linux tolerated the same order.
    Sqlx::Database.close
    if pg?
      Sqlx::Database.configure(ENV["PG_URL"].to_s, pool_size: pool_size)
    else
      path = "/tmp/snails_#{name}.sqlite3"
      File.delete(path) if File.exist?(path)
      Sqlx::Database.configure(path, pool_size: pool_size)
    end
  end

  # The pg gate sets PG_URL; the sqlite gate does not.
  def self.pg?
    !ENV["PG_URL"].to_s.empty?
  end

  # Run setup SQL under a lease. The lease is required after a case calls
  # `require_leases!`, and harmless before it.
  def self.exec(sql)
    sql = translate_ddl(sql) if pg? && ddl?(sql)
    Sqlx::Database.with_connection { Sqlx::Database.exec(sql) }
  end

  # The pg scratch database is shared by every case file in one run, so a
  # file that reuses a table name must drop it first. sqlite files are
  # fresh per run; the drop is harmless there.
  def self.drop_tables!(*names)
    return if names.empty?

    suffix = pg? ? " CASCADE" : ""
    Sqlx::Database.with_connection do
      names.each { |name| Sqlx::Database.exec("DROP TABLE IF EXISTS #{name}#{suffix}") }
    end
  end

  # Load the queue DDL for the selected adapter, after clearing the two
  # shared queue tables.
  def self.load_queue_schema!
    drop_tables!("snails_queue_jobs", "snails_queue_occurrences")
    path = "scaffold/queue/create_snails_queue"
    path += ".pg" if pg?
    exec(File.read(path + ".sql"))
  end

  # Translate the SQLite DDL types the common cases spell. The pg adapter
  # gets a real sequence for the id and native timestamp/float columns.
  def self.translate_ddl(sql)
    sql
      .gsub("INTEGER PRIMARY KEY", "BIGSERIAL PRIMARY KEY")
      .gsub("DATETIME", "TIMESTAMP")
      .gsub(/\bREAL\b/, "DOUBLE PRECISION")
  end

  def self.ddl?(sql)
    head = sql.lstrip
    head.start_with?("CREATE TABLE", "ALTER TABLE")
  end

  private_class_method :translate_ddl, :ddl?
end
