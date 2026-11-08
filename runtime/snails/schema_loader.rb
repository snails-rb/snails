# Schema loader — the harness gate compiles this entry (sharing the app
# manifest) and runs it before the server boots. It applies the app's
# conventional schema file, read relative to the spin root:
#
#   db/schema.sql    tables/indexes/views — `;`-terminated statements,
#                    any layout (multi-line, `--` comments) a SQL client
#                    accepts
#
# The adapter's official client executes it — sqlite3 over stdin, psql
# with -f — the same executables `migrate apply` runs: a schema file is
# provisioning input, and the validated client is its executor, not the
# app's SQL driver. The server itself never runs DDL. Files left at the
# legacy `config/` layout raise rather than load: a silent skip would
# boot on stub tables and pass every non-DB case.
require_relative "../boot"

module Snails
  module SchemaLoader
    # refuse to load while the legacy `config/` schema layout is still on disk.
    # A silent skip would boot on stub tables and pass every non-DB case, so the
    # leftover files raise.
    #
    # @return [void]
    # @raise [RuntimeError] `config/schema.sql` or `config/views` exists
    def self.reject_legacy_layout
      stale = []
      stale << "config/schema.sql" if File.exist?("config/schema.sql")
      stale << "config/views" if Dir.exist?("config/views")
      return if stale.empty?

      raise "stale schema layout (#{stale.join(", ")}) — snails loads db/schema.sql; move the files"
    end

    # apply `db/schema.sql` through the adapter's official client; a tree with
    # no snapshot loads nothing.
    #
    # @return [void]
    # @raise [RuntimeError] the client exits non-zero — its output is the message
    def self.load_tables
      return unless File.exist?("db/schema.sql")

      apply_file("db/schema.sql")
    end

    # --- private helpers -----------------------------------------------------
    # The client pair and the target resolution below are private on purpose:
    # they serve the two entries above and are free to change without notice.

    # run a SQL file through the adapter's official client: sqlite3 reads it on
    # stdin, psql takes -f.
    def self.apply_file(path)
      if Sqlx::Database.owns_schema?
        run_client(["sqlite3", "-bail", sqlite_target], path)
      else
        run_client(["psql", pg_target, "-v", "ON_ERROR_STOP=1", "-X", "-q", "-f", path])
      end
    end

    # run the official client and return its stdout. Stdout and stderr share one
    # pipe so the child can never block on a full pipe while this side waits for
    # the other; a non-zero exit raises with that combined output (the runner's
    # log keeps it), and a missing binary names the requirement instead of
    # leaking an OS error.
    def self.run_client(argv, stdin_path = nil)
      reader, writer = IO.pipe
      input = stdin_path.nil? ? nil : File.open(stdin_path, "r")
      options = { out: writer, err: writer }
      options[:in] = input unless input.nil?
      begin
        pid = Process.spawn(*argv, options)
      rescue Errno::ENOENT
        raise "#{argv[0]} is not on PATH — install it"
      end
      input.close unless input.nil?
      writer.close
      output = reader.read
      reader.close
      _, status = Process.wait2(pid)
      unless status.success?
        raise "schema load failed (exit #{status.exitstatus}): #{stdin_path || argv.join(" ")}\n#{output.rstrip}"
      end
      output
    end

    # the file sqlite3 opens, mirroring the adapter's `configure_default!` (env,
    # else the conventional dev path).
    def self.sqlite_target
      path = ENV["DATABASE_PATH"]
      path.nil? || path.empty? ? "storage/development.sqlite3" : path
    end

    # the conninfo `configure_default!` already required.
    def self.pg_target
      ENV["PG_URL"]
    end

    private_class_method :apply_file, :run_client, :sqlite_target, :pg_target
  end

  SchemaLoader.reject_legacy_layout
  Sqlx::Database.configure_default!
  SchemaLoader.load_tables
end
