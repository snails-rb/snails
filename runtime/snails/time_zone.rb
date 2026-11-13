# frozen_string_literal: true

# Zone vocabulary and TZif reader: a zone name to `TimeZoneData` through
# `ZONE_NAMES` and `/usr/share/zoneinfo`, and an instant rendered in that zone.
#
# `Snails.time_zone` is pinned once at boot and `in_time_zone` never swaps it,
# so concurrent requests can render in different zones.
module Snails
  # the IANA identifier for a zone name in the runtime's zone vocabulary
  # ("Seoul" → "Asia/Seoul"), or an IANA identifier passed through as-is. The
  # identifier must name a zone file under `TZDIR`: a typo in the app's pin
  # raises here instead of letting libc fall back to UTC silently.
  #
  # @param name [String] the configured zone name
  # @return [String] the IANA identifier
  # @raise [ArgumentError] the name is neither a registered zone name nor an
  #   IANA identifier with a zone file
  # @example
  #   Snails.iana_zone("Seoul") # => "Asia/Seoul"
  def self.iana_zone(name)
    iana = TimeZone::ZONE_NAMES.fetch(name, name)
    dir = ENV["TZDIR"] || "/usr/share/zoneinfo"
    path = "#{dir}/#{iana}"
    unless iana.is_a?(String) && iana.match?(/\A[A-Za-z0-9_+\-]+(\/[A-Za-z0-9_+\-]+)*\z/) && File.file?(path)
      raise ArgumentError, "unknown time zone #{iana.inspect}: no zone file at #{path}; check the zone name and tzdata"
    end
    iana
  end

  # the process zone every local-time presentation uses, as an IANA identifier.
  # The app sets it once from config/environment.rb with
  # `Snails.time_zone = "<zone>"`; before that line runs, the slot reads as
  # "UTC".
  #
  # @return [String] the IANA identifier ("UTC" when nothing was set)
  def self.time_zone
    zone = @time_zone
    return "UTC" if zone.nil?
    zone
  end

  # pin the process zone. The name may be a zone vocabulary name or an IANA
  # identifier; `Snails.iana_zone` resolves and validates it before the slot
  # changes, and `ENV["TZ"]` is set for libc.
  #
  # @param name [String] the zone name or IANA identifier
  # @return [void]
  # @raise [ArgumentError] the name has no zone file
  # @example
  #   Snails.time_zone = "Seoul"
  def self.time_zone=(name)
    resolved = iana_zone(name)
    @time_zone = resolved
    ENV["TZ"] = resolved
  end

  module TimeZone
    # The zone-name vocabulary (`ActiveSupport::TimeZone::MAPPING`) maps to
    # IANA identifiers; an IANA identifier passes through. Read by
    # `Snails.iana_zone` (the `Snails.time_zone` setter) and by the runtime's
    # TZif lookup.
    ZONE_NAMES = {
      "International Date Line West" => "Etc/GMT+12",
      "Midway Island" => "Pacific/Midway",
      "American Samoa" => "Pacific/Pago_Pago",
      "Hawaii" => "Pacific/Honolulu",
      "Alaska" => "America/Juneau",
      "Pacific Time (US & Canada)" => "America/Los_Angeles",
      "Tijuana" => "America/Tijuana",
      "Mountain Time (US & Canada)" => "America/Denver",
      "Arizona" => "America/Phoenix",
      "Chihuahua" => "America/Chihuahua",
      "Mazatlan" => "America/Mazatlan",
      "Central Time (US & Canada)" => "America/Chicago",
      "Saskatchewan" => "America/Regina",
      "Guadalajara" => "America/Mexico_City",
      "Mexico City" => "America/Mexico_City",
      "Monterrey" => "America/Monterrey",
      "Central America" => "America/Guatemala",
      "Eastern Time (US & Canada)" => "America/New_York",
      "Indiana (East)" => "America/Indiana/Indianapolis",
      "Bogota" => "America/Bogota",
      "Lima" => "America/Lima",
      "Quito" => "America/Lima",
      "Atlantic Time (Canada)" => "America/Halifax",
      "Caracas" => "America/Caracas",
      "La Paz" => "America/La_Paz",
      "Santiago" => "America/Santiago",
      "Asuncion" => "America/Asuncion",
      "Newfoundland" => "America/St_Johns",
      "Brasilia" => "America/Sao_Paulo",
      "Buenos Aires" => "America/Argentina/Buenos_Aires",
      "Montevideo" => "America/Montevideo",
      "Georgetown" => "America/Guyana",
      "Puerto Rico" => "America/Puerto_Rico",
      "Greenland" => "America/Nuuk",
      "Mid-Atlantic" => "Atlantic/South_Georgia",
      "Azores" => "Atlantic/Azores",
      "Cape Verde Is." => "Atlantic/Cape_Verde",
      "Dublin" => "Europe/Dublin",
      "Edinburgh" => "Europe/London",
      "Lisbon" => "Europe/Lisbon",
      "London" => "Europe/London",
      "Casablanca" => "Africa/Casablanca",
      "Monrovia" => "Africa/Monrovia",
      # Plain "UTC", not "Etc/UTC": both name the same zone, and the
      # plain one keeps the slot's answer identical — "UTC" whether the app set
      # it that way or never set one at all.
      "UTC" => "UTC",
      "Belgrade" => "Europe/Belgrade",
      "Bratislava" => "Europe/Bratislava",
      "Budapest" => "Europe/Budapest",
      "Ljubljana" => "Europe/Ljubljana",
      "Prague" => "Europe/Prague",
      "Sarajevo" => "Europe/Sarajevo",
      "Skopje" => "Europe/Skopje",
      "Warsaw" => "Europe/Warsaw",
      "Zagreb" => "Europe/Zagreb",
      "Brussels" => "Europe/Brussels",
      "Copenhagen" => "Europe/Copenhagen",
      "Madrid" => "Europe/Madrid",
      "Paris" => "Europe/Paris",
      "Amsterdam" => "Europe/Amsterdam",
      "Berlin" => "Europe/Berlin",
      "Bern" => "Europe/Zurich",
      "Zurich" => "Europe/Zurich",
      "Rome" => "Europe/Rome",
      "Stockholm" => "Europe/Stockholm",
      "Vienna" => "Europe/Vienna",
      "West Central Africa" => "Africa/Algiers",
      "Bucharest" => "Europe/Bucharest",
      "Cairo" => "Africa/Cairo",
      "Helsinki" => "Europe/Helsinki",
      "Kyiv" => "Europe/Kiev",
      "Riga" => "Europe/Riga",
      "Sofia" => "Europe/Sofia",
      "Tallinn" => "Europe/Tallinn",
      "Vilnius" => "Europe/Vilnius",
      "Athens" => "Europe/Athens",
      "Istanbul" => "Europe/Istanbul",
      "Minsk" => "Europe/Minsk",
      "Jerusalem" => "Asia/Jerusalem",
      "Harare" => "Africa/Harare",
      "Pretoria" => "Africa/Johannesburg",
      "Kaliningrad" => "Europe/Kaliningrad",
      "Moscow" => "Europe/Moscow",
      "St. Petersburg" => "Europe/Moscow",
      "Volgograd" => "Europe/Volgograd",
      "Samara" => "Europe/Samara",
      "Kuwait" => "Asia/Kuwait",
      "Riyadh" => "Asia/Riyadh",
      "Nairobi" => "Africa/Nairobi",
      "Baghdad" => "Asia/Baghdad",
      "Tehran" => "Asia/Tehran",
      "Abu Dhabi" => "Asia/Muscat",
      "Muscat" => "Asia/Muscat",
      "Baku" => "Asia/Baku",
      "Tbilisi" => "Asia/Tbilisi",
      "Yerevan" => "Asia/Yerevan",
      "Kabul" => "Asia/Kabul",
      "Ekaterinburg" => "Asia/Yekaterinburg",
      "Islamabad" => "Asia/Karachi",
      "Karachi" => "Asia/Karachi",
      "Tashkent" => "Asia/Tashkent",
      "Chennai" => "Asia/Kolkata",
      "Kolkata" => "Asia/Kolkata",
      "Mumbai" => "Asia/Kolkata",
      "New Delhi" => "Asia/Kolkata",
      "Kathmandu" => "Asia/Kathmandu",
      "Dhaka" => "Asia/Dhaka",
      "Sri Jayawardenepura" => "Asia/Colombo",
      "Almaty" => "Asia/Almaty",
      "Astana" => "Asia/Almaty",
      "Novosibirsk" => "Asia/Novosibirsk",
      "Rangoon" => "Asia/Rangoon",
      "Bangkok" => "Asia/Bangkok",
      "Hanoi" => "Asia/Bangkok",
      "Jakarta" => "Asia/Jakarta",
      "Krasnoyarsk" => "Asia/Krasnoyarsk",
      "Beijing" => "Asia/Shanghai",
      "Chongqing" => "Asia/Chongqing",
      "Hong Kong" => "Asia/Hong_Kong",
      "Urumqi" => "Asia/Urumqi",
      "Kuala Lumpur" => "Asia/Kuala_Lumpur",
      "Singapore" => "Asia/Singapore",
      "Taipei" => "Asia/Taipei",
      "Perth" => "Australia/Perth",
      "Irkutsk" => "Asia/Irkutsk",
      "Ulaanbaatar" => "Asia/Ulaanbaatar",
      "Seoul" => "Asia/Seoul",
      "Osaka" => "Asia/Tokyo",
      "Sapporo" => "Asia/Tokyo",
      "Tokyo" => "Asia/Tokyo",
      "Yakutsk" => "Asia/Yakutsk",
      "Darwin" => "Australia/Darwin",
      "Adelaide" => "Australia/Adelaide",
      "Canberra" => "Australia/Canberra",
      "Melbourne" => "Australia/Melbourne",
      "Sydney" => "Australia/Sydney",
      "Brisbane" => "Australia/Brisbane",
      "Hobart" => "Australia/Hobart",
      "Vladivostok" => "Asia/Vladivostok",
      "Guam" => "Pacific/Guam",
      "Port Moresby" => "Pacific/Port_Moresby",
      "Magadan" => "Asia/Magadan",
      "Srednekolymsk" => "Asia/Srednekolymsk",
      "Solomon Is." => "Pacific/Guadalcanal",
      "New Caledonia" => "Pacific/Noumea",
      "Fiji" => "Pacific/Fiji",
      "Kamchatka" => "Asia/Kamchatka",
      "Marshall Is." => "Pacific/Majuro",
      "Auckland" => "Pacific/Auckland",
      "Wellington" => "Pacific/Auckland",
      "Nuku'alofa" => "Pacific/Tongatapu",
      "Tokelau Is." => "Pacific/Fakaofo",
      "Chatham Is." => "Pacific/Chatham",
      "Samoa" => "Pacific/Apia",
    }.freeze

    # Not ENV["TZ"] swapped for the block: that is process-wide, and a
    # concurrent request would render in this one's zone.
    class TimeZoneData
      attr_reader :name

      def initialize(name, transitions, offsets, initial_offset, rule)
        @name = name
        @transitions = transitions
        @offsets = offsets
        @initial_offset = initial_offset
        @rule = rule
      end

      # the UTC offset in seconds that applies at that instant. Transitions
      # decide up to the last one; past it the zone file's POSIX DST rule takes
      # over, and a zone with no transitions keeps its initial offset.
      #
      # @param epoch [Integer] the instant, as a Unix timestamp
      # @return [Integer] the offset in seconds
      def offset_at(epoch)
        n = @transitions.length
        return rule_or(epoch, @initial_offset) if n == 0
        return @initial_offset if epoch < @transitions[0]
        return rule_or(epoch, @offsets[n - 1]) if epoch >= @transitions[n - 1]
        lo = 0
        hi = n - 1
        while lo < hi
          mid = (lo + hi + 1) / 2
          if @transitions[mid] <= epoch
            lo = mid
          else
            hi = mid - 1
          end
        end
        @offsets[lo]
      end

      # Resolve the offset past the last transition: a slim TZif file
      # leaves DST to its POSIX footer: [std, dst, m, w, d, secs, m, w, d, secs].
      # A footer the parser cannot read — a `Jn` / `n` form, or none at
      # all — leaves the rule empty, and `fallback` stands.
      def rule_or(epoch, fallback)
        return fallback if @rule.empty?
        return @rule[0] if @rule.length == 1
        std = @rule[0]
        dst = @rule[1]
        year = Time.at(epoch + std).utc.year
        start_at = rule_instant(year, @rule[2], @rule[3], @rule[4], @rule[5]) - std
        end_at = rule_instant(year, @rule[6], @rule[7], @rule[8], @rule[9]) - dst
        in_dst = start_at < end_at ? (epoch >= start_at && epoch < end_at) : !(epoch >= end_at && epoch < start_at)
        in_dst ? dst : std
      end

      def rule_instant(year, month, week, wday, secs)
        first = Snails::DateAndTime::Calculations.civil_days(year, month, 1)
        day = 1 + (wday - (first + 4) % 7 + 7) % 7 + (week - 1) * 7
        last = Snails::DateAndTime::Calculations.days_in_month(year, month)
        day = day - 7 while day > last
        (first + day - 1) * 86_400 + secs
      end
      private :rule_instant
    end

    # the instant `t` presented in `zone` as a fixed-offset `Time` (the same
    # value as `getlocal(offset)`); the date helpers keep that offset. nil
    # selects the app zone — the process TZ pinned by config/environment.rb.
    #
    # @param t [Time] the instant to render
    # @param zone [String, nil] the zone NAME; nil selects the app zone
    # @return [Time] `t` shifted to that zone's offset
    def self.in_time_zone(t, zone)
      return t.getlocal if zone.nil?
      t.getlocal(find_zone!(zone).offset_at(t.to_i))
    end

    def self.be32(b, i)
      v = (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]
      v >= 2_147_483_648 ? v - 4_294_967_296 : v
    end

    # One parsed value per zone name for the process's lifetime: the zone file
    # set does not change while a process runs, and every render of the same
    # zone should not pay the file read and parse again. A tzdata or TZDIR
    # change after the first load needs a process restart. The lock covers
    # hits too — the server's green threads share no VM lock, so an
    # unsynchronized read could race a miss's write.
    @zone_data = {}
    @zone_data_lock = Mutex.new

    # the parsed zone data for `zone`, loading the TZif file on the first use of
    # that name. A name with no zone file raises through `Snails.iana_zone`;
    # failures are not cached.
    def self.find_zone!(zone)
      raw = zone.to_s
      data = nil
      @zone_data_lock.synchronize do
        data = @zone_data[raw]
        if data.nil?
          data = load_zone!(raw)
          @zone_data[raw] = data
        end
      end
      data
    end

    # Resolve through the public vocabulary entry, then read the TZif file —
    # the boot pin and this reader share one validity rule. The caller holds
    # the cache lock, so a second thread waits instead of parsing again.
    def self.load_zone!(raw)
      iana = Snails.iana_zone(raw)
      dir = ENV["TZDIR"] || "/usr/share/zoneinfo"
      path = "#{dir}/#{iana}"
      b = File.binread(path).bytes
      raise ArgumentError, "Invalid Timezone: #{raw}" unless b.length > 44 && b[0] == 84 && b[1] == 90 && b[2] == 105 && b[3] == 102
      base = 0
      width = 4
      if b[4] >= 50
        base = 44 + be32(b, 32) * 5 + be32(b, 36) * 6 + be32(b, 40) + be32(b, 28) * 8 + be32(b, 24) + be32(b, 20)
        width = 8
      end
      leapcnt = be32(b, base + 28)
      timecnt = be32(b, base + 32)
      typecnt = be32(b, base + 36)
      charcnt = be32(b, base + 40)
      at = base + 44
      transitions = []
      i = 0
      while i < timecnt
        transitions << (width == 8 ? be32(b, at + i * 8) * 4_294_967_296 + (be32(b, at + i * 8 + 4) & 0xffffffff) : be32(b, at + i * 4))
        i = i + 1
      end
      idx_at = at + timecnt * width
      types_at = idx_at + timecnt
      offsets = []
      i = 0
      while i < timecnt
        offsets << be32(b, types_at + b[idx_at + i] * 6)
        i = i + 1
      end
      rule = []
      if width == 8
        footer_at = types_at + typecnt * 6 + charcnt + leapcnt * 12 + be32(b, base + 24) + be32(b, base + 20)
        rule = parse_tz_rule(File.binread(path)[footer_at..].to_s.strip)
      end
      TimeZoneData.new(iana, transitions, offsets, be32(b, types_at), rule)
    end

    # Only the `Mm.w.d` rule form: a `Jn` / `n` footer yields no rule, and
    # the last transition's offset stands.
    def self.parse_tz_rule(spec)
      m = /\A(?:<[^>]+>|[A-Za-z]+)([+-]?\d+(?::\d+){0,2})(?:(?:<[^>]+>|[A-Za-z]+)([+-]?\d+(?::\d+){0,2})?,M(\d+)\.(\d)\.(\d)(?:\/([+-]?\d+(?::\d+){0,2}))?,M(\d+)\.(\d)\.(\d)(?:\/([+-]?\d+(?::\d+){0,2}))?)?\z/.match(spec)
      return [] if m.nil?
      std = -posix_seconds(m[1])
      return [std] if m[3].nil?
      dst = m[2] ? -posix_seconds(m[2]) : std + 3600
      start_secs = m[6] ? posix_seconds(m[6]) : 7200
      end_secs = m[10] ? posix_seconds(m[10]) : 7200
      [std, dst, m[3].to_i, m[4].to_i, m[5].to_i, start_secs, m[7].to_i, m[8].to_i, m[9].to_i, end_secs]
    end

    def self.posix_seconds(text)
      sign = text.start_with?("-") ? -1 : 1
      parts = text.delete("+-").split(":")
      h = parts[0].to_i
      mi = parts.length > 1 ? parts[1].to_i : 0
      s = parts.length > 2 ? parts[2].to_i : 0
      sign * (h * 3600 + mi * 60 + s)
    end

    # Private on purpose: `in_time_zone` is the entry; the TZif reader
    # helpers are free to change without notice.
    private_class_method :be32, :find_zone!, :load_zone!, :parse_tz_rule, :posix_seconds
  end
end
