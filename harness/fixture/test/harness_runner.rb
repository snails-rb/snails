# Snapshot runner for the fixture's contract cases — the minimal
# execute + `.expected` compare. spinel has no autorun, so the caller
# names the cases (the declaration IS the list). Each case gets a fresh
# instance for failure isolation; the summary line closes the snapshot.
#
# The name is deliberately not `FixtureRunner` (snails-core/snails/harness.rb): the
# bundle runner compiles every case file into one program, and a second
# definition of the same module in that graph makes one body shadow the
# other — the dispatch gate below would never run and every process
# would execute the first file's cases. This runner is the fixture's own
# (it calls `setup` per case); apps use `Snails::Harness::IntegrationTest`.
module FixtureRunner
  # Bundle dispatch: the runner starts one binary per case file with
  # SPIN_TEST_INDEX set; only the file being required right now (its
  # index is in `$spin_test_file`) executes. Without the bundle env — a
  # plain `spin test <file>` — every file runs, which is that path.
  def self.file_selected?
    return true if ENV["SPIN_TEST_BUNDLE"].to_s == ""

    file = $spin_test_file
    file = 0 if file.nil?
    file == ENV["SPIN_TEST_INDEX"].to_i
  end

  def self.run(klass, names)
    return unless file_selected?

    failed = 0
    names.each do |m|
      t = klass.new
      begin
        t.setup
        t.send(m)
        puts "ok #{m}"
      rescue Exception => e
        failed += 1
        puts "FAIL #{m}: #{e.message}"
      end
    end
    if failed.zero?
      puts "#{klass.name}: #{names.size} tests passed"
      exit 0
    else
      puts "#{klass.name}: #{failed} of #{names.size} tests failed"
      exit 1
    end
  end
end
