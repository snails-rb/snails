require_relative "test_helper"
require_relative "harness_runner"

# Zone data is parsed once per process. The proof removes the copied zone file
# after the first render: a second render still answers, so it read the cached
# value instead of the file.
class TimeZoneCacheTest < TestBase
  def assert_equal(expected, actual, msg = nil)
    raise(msg || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def test_zone_data_is_reused_after_the_source_file_disappears
    dir = "/tmp/snails_zone_cache_test"
    zone = "#{dir}/Asia/Seoul"
    source = "/usr/share/zoneinfo/Asia/Seoul"
    Dir.mkdir(dir) unless Dir.exist?(dir)
    Dir.mkdir("#{dir}/Asia") unless Dir.exist?("#{dir}/Asia")
    File.open(zone, "w") { |file| file.write(File.binread(source)) }
    old = ENV["TZDIR"]
    ENV["TZDIR"] = dir
    t = Time.utc(2024, 1, 2, 3, 4, 5)
    first = t.in_time_zone("Asia/Seoul")
    File.delete(zone)
    second = t.in_time_zone("Asia/Seoul")
    assert_equal first.to_i, second.to_i
    assert_equal 32400, second.utc_offset
  ensure
    if old.nil?
      ENV.delete("TZDIR")
    else
      ENV["TZDIR"] = old
    end
    File.delete(zone) if File.exist?(zone)
    Dir.rmdir("#{dir}/Asia") if Dir.exist?("#{dir}/Asia")
    Dir.rmdir(dir) if Dir.exist?(dir)
  end
end

FixtureRunner.run(TimeZoneCacheTest, [
  "test_zone_data_is_reused_after_the_source_file_disappears"
])
