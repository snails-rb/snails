# process entry — configure the database, parse the CLI, and hand the process to
# the server. Loaded by `runtime/snails/main.rb` after `main/dispatch.rb`.
module Snails
  module Main
    # configure the process-wide `Sqlx::Database` from the app's
    # `config/database.rb`. Adapter-neutral: the selected backend reads its own
    # source. No DDL here; schema is applied by an explicit step (the core
    # `Snails::SchemaLoader` in the harness gate, or the app's own script).
    #
    # @return [void]
    def self.configure_database!
      Sqlx::Database.configure_default!
    end

    # parse the CLI/env, configure the database, require connection leases (the
    # SQLite adapter refuses a database access with no lease from here on; the
    # PostgreSQL adapter has one shared connection, so this is a no-op),
    # register the job executor, and run the green-thread-per-connection server.
    #
    # @return [void]
    def self.start
      port = (ENV["PORT"] || "3000").to_i
      workers = (ENV["WORKERS"] || "1").to_i
      i = 0
      while i < ARGV.length
        arg = ARGV[i]
        if arg == "--help" || arg == "-h"
          puts "usage: " + $PROGRAM_NAME + " [options]"
          puts ""
          puts "  -p, --port N     listen port (default 3000; PORT env)"
          puts "  -w, --workers N  prefork N processes (default 1; WORKERS env)"
          puts "  -h, --help       show this help and exit"
          puts ""
          puts "  OS workers per process: one per core; SPINEL_WORKERS=N caps it"
          exit(0)
        elsif (arg == "--port" || arg == "-p") && i + 1 < ARGV.length
          port = ARGV[i + 1].to_i
          i += 2
        elsif (arg == "--workers" || arg == "-w") && i + 1 < ARGV.length
          workers = ARGV[i + 1].to_i
          i += 2
        else
          $stderr.puts "unknown option: " + arg + " (try --help)"
          exit(1)
        end
      end
      # 1.0 runs one server process; multi-process is a 2.0 feature. The env
      # and flag parsing above stays so 2.0 can lift the clamp without
      # rebuilding it.
      workers = 1
      if port <= 0 || port > 65535
        $stderr.puts "invalid port: " + port.to_s
        exit(1)
      end
      Snails::Main.configure_database!
      Sqlx::Database.require_leases!
      ActiveJob.register_executor
      Tep::APP.name = Snails.app.app_name
      Tep::Server::Threaded.new.run(port, workers, false)
    end
  end
end
