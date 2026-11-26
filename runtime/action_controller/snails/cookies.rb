# Controller-level cookie access: the `cookies` jar. A read returns the
# request's inbound value; a write records one `Set-Cookie` line for the
# dispatcher to emit after the action. The jar is the app-facing API; the
# HTTP formatter stays in `Tep::Response#set_cookie`.
#
# The jar is defined in this file rather than in `api.rb` so
# `runtime/action_controller.rb` controls the load order and the controller
# class file stays focused on request state.
module ActionController
  # One pending cookie write: the name, the stored value, and canonical
  # `Set-Cookie` attributes (`Path`, `Expires`, `Max-Age`, `Domain`,
  # `Secure`, `HttpOnly`, `SameSite`). A flag attribute carries an empty
  # value because `Tep::Response#set_cookie` writes an empty value as a
  # bare attribute.
  #
  # Not app API: the jar creates these and the dispatcher reads them.
  #
  # @api internal
  class Cookie
    attr_reader :name, :value, :options

    def initialize(name, value, options)
      @name = name
      @value = value
      @options = options
    end
  end

  # The cookie jar a controller reads and writes through `cookies`.
  # Writes are pending until the dispatcher copies them onto the response,
  # so a filter and the action share one jar for the request.
  #
  # A missing cookie reads as `""`, not `nil`, so a read can be used without
  # a nil check. The spinel compiler rejects a `nil`-returning String read
  # in the common `cookies[:name].to_s.split(...)` call form. Callers that
  # need to tell an absent cookie from an empty value read `request.cookies`
  # and check `key?`.
  #
  # The write forms are:
  #
  #   cookies[:name] = "value"
  #   cookies[:name] = { value: "value", httponly: true, secure: true,
  #                      same_site: :strict, path: "/", max_age: 3600 }
  #   cookies.delete(:name, path: "/")
  #   cookies.permanent[:name] = "value"
  #
  # Unknown option keys raise. So do names, paths, and domains that would
  # make an invalid `Set-Cookie` header, and values that break the browser's
  # `__Host-`/`__Secure-`/`SameSite=None` rules. A silently dropped
  # `HttpOnly` or a browser-rejected cookie is worse than an immediate
  # `ArgumentError` at the call site.
  class CookieJar
    # @param inbound [Hash{String => String}] the request's parsed cookie
    #   hash (`ActionDispatch::Request#cookies`)
    # @return [void]
    def initialize(inbound = {})
      # The dispatcher copies the transport hash into `request.cookies`
      # first, so this store is already a plain String-to-String hash.
      # Copying it again here is unnecessary.
      @inbound = inbound
      @writes = []
    end

    # Returns the cookie value, or `""` when absent. A pending write takes
    # precedence over the inbound value, including a cleared write, so a read
    # after `cookies.delete` does not see the deleted value.
    #
    # @param key [Object] the cookie name
    # @return [String] the value, `""` when absent
    # @example
    #   cookies[:session]
    def [](key)
      raw(key)
    end

    # Records a cookie write. A plain value writes the cookie with defaults;
    # a Hash carries `value:` plus any cookie attributes. A nil value (plain
    # or under `value:`) deletes the cookie.
    #
    # @param key [Object] the cookie name
    # @param value [Object] the value, or the options Hash
    # @return [String] the stored value
    # @raise [ArgumentError] the name is empty or not an RFC 6265 token, the
    #   options carry an unknown key, the path or domain has an invalid
    #   character, or the attributes break a cookie prefix rule
    def []=(key, value)
      write_from(key, value, false)
    end

    # The shared write path for the plain jar and `cookies.permanent`. It
    # parses a plain value or an options Hash, then records the write.
    # `permanent` only supplies the 20-year expiry the wrapper promises.
    #
    # @api internal
    # @param key [Object] the cookie name
    # @param value [Object] the value, or the options Hash
    # @param permanent [Boolean] add a 20-year expiry when none is given
    # @return [String] the stored value
    def write_from(key, value, permanent)
      if value.nil?
        return delete(key)
      end
      if !value.is_a?(Hash)
        return raw_set(key, value, {}, permanent)
      end
      if !value.key?(:value)
        raise ArgumentError, "cookies[:#{key}] needs a value: key"
      end
      stored = value[:value]
      return delete(key) if stored.nil?
      raw_set(key, stored, value, permanent)
    end

    # The `cookies.permanent` wrapper: every write expires in 20 years. A
    # read and a delete go through the same jar.
    #
    # @return [PermanentCookieJar] the permanent-write wrapper
    def permanent
      PermanentCookieJar.new(self)
    end

    # Returns the latest stored value for a key without the option parsing
    # in `[]=`. The signed wrapper reads through this method.
    #
    # @api internal
    # @param key [Object] the cookie name
    # @return [String] the value, `""` when absent
    def raw(key)
      name = key.to_s
      i = @writes.length - 1
      while i >= 0
        write = @writes[i]
        return write.value if write.name == name
        i -= 1
      end
      return @inbound[name] if @inbound.key?(name)
      ""
    end

    # Records one write with normalized attributes. The signed wrapper writes
    # through this method. Internal: the jar and its wrappers call it; apps
    # use `[]=`.
    #
    # @api internal
    # @param key [Object] the cookie name
    # @param value [Object] the value coerced to a String
    # @param options [Hash{Symbol => Object}] the app's option Hash
    # @param permanent [Boolean] add a 20-year expiry when none is given
    # @return [String] the stored value
    def raw_set(key, value, options = {}, permanent = false)
      name = cookie_name(key)
      text = value.to_s
      if text.include?("\r") || text.include?("\n")
        raise ArgumentError, "cookie value must not contain CR or LF"
      end
      canonical = canonical_options(name, options, permanent)
      @writes.push(Cookie.new(name, text, canonical))
      text
    end

    # remove a cookie: a cleared value with `Max-Age=0` and an epoch
    # `Expires`, plus the path and domain the browser matches on. Pass the
    # same path and domain the cookie was set with, or the browser keeps the
    # old cookie.
    #
    # @param key [Object] the cookie name
    # @param options [Hash{Symbol => Object}] `path:` and `domain:` used to
    #   match the cookie, plus optional `secure:`/`httponly:` flags
    # @return [String] `""`
    def delete(key, **options)
      options[:max_age] = 0
      options[:expires] = Time.at(0)
      raw_set(key, "", options)
      ""
    end

    # Returns the writes recorded during this request for the dispatcher's
    # `Set-Cookie` lines. This is not `to_h`: a cookie that was only read
    # from the request must not emit a header.
    #
    # @api internal
    # @return [Array<Cookie>] the pending writes
    def pending
      @writes
    end

    # the whole jar: inbound values overlaid by this request's pending
    # writes. A cleared write appears as `""`.
    #
    # @return [Hash{String => String}] the merged cookie store
    def to_h
      merged = {}
      @inbound.each { |k, v| merged[k] = v }
      i = 0
      while i < @writes.length
        write = @writes[i]
        merged[write.name] = write.value
        i += 1
      end
      merged
    end

    # `to_h` under its Hash-style name, for code that rebuilds a jar from
    # stored values.
    #
    # @return [Hash{String => String}] the merged cookie store
    def to_hash
      to_h
    end

    # iterate the merged store. A write during the block is allowed: the
    # block walks the snapshot `to_h` builds, not the live stores.
    #
    # @yieldparam name [String] the cookie name
    # @yieldparam value [String] the cookie value
    # @return [CookieJar] self
    def each
      to_h.each { |k, v| yield k, v }
      self
    end

    # Name validation and attribute normalization share one path for every
    # write (plain, signed, permanent, delete), so a prefix rule cannot be
    # skipped by one form. An empty attribute value is written as a bare
    # flag.
    def canonical_options(name, options, permanent)
      path = "/"
      domain = ""
      secure = false
      httponly = false
      same_site = "Lax"
      expires = ""
      max_age = -1
      options.each do |key, value|
        if key == :value
          next
        elsif key == :path
          path = path_value(value)
        elsif key == :domain
          domain = domain_value(value)
        elsif key == :secure
          secure = boolean_value(value, :secure)
        elsif key == :httponly
          httponly = boolean_value(value, :httponly)
        elsif key == :same_site
          same_site = same_site_value(value)
        elsif key == :expires
          expires = expires_value(value)
        elsif key == :max_age
          max_age = max_age_value(value)
        else
          raise ArgumentError, "unknown cookie option #{key}"
        end
      end
      if permanent && expires.empty?
        expires = http_date(Time.now + 630720000)
      end
      if name.start_with?("__Host-")
        if !secure || path != "/" || !domain.empty?
          raise ArgumentError, "__Host- cookies need secure: true, path: \"/\", and no domain"
        end
      elsif name.start_with?("__Secure-")
        if !secure
          raise ArgumentError, "__Secure- cookies need secure: true"
        end
      end
      if same_site == "None" && !secure
        raise ArgumentError, "SameSite=None needs secure: true"
      end
      out = {}
      out["Path"] = path
      out["Expires"] = expires unless expires.empty?
      out["Max-Age"] = max_age.to_s if max_age >= 0
      out["Domain"] = domain unless domain.empty?
      out["Secure"] = "" if secure
      out["HttpOnly"] = "" if httponly
      out["SameSite"] = same_site unless same_site.empty?
      out
    end

    private :canonical_options

    def cookie_name(key)
      name = key.to_s
      if name.empty?
        raise ArgumentError, "cookie name must not be empty"
      end
      i = 0
      while i < name.bytesize
        byte = name.getbyte(i)
        if !cookie_name_byte?(byte)
          raise ArgumentError, "cookie name contains an invalid character"
        end
        i += 1
      end
      name
    end

    # RFC 6265 cookie-name is a token: visible ASCII without separators.
    def cookie_name_byte?(byte)
      return false if byte < 0x21 || byte > 0x7E
      return false if byte == 0x28 || byte == 0x29 || byte == 0x3C || byte == 0x3E
      return false if byte == 0x40 || byte == 0x2C || byte == 0x3B || byte == 0x3A
      return false if byte == 0x5C || byte == 0x22 || byte == 0x2F || byte == 0x5B
      return false if byte == 0x5D || byte == 0x3F || byte == 0x3D || byte == 0x7B
      return false if byte == 0x7D
      true
    end

    def path_value(value)
      if !value.is_a?(String) || value.empty? || !value.start_with?("/")
        raise ArgumentError, "cookie path must be a String starting with \"/\""
      end
      i = 0
      while i < value.bytesize
        byte = value.getbyte(i)
        if byte < 0x20 || byte > 0x7E || byte == 0x3B
          raise ArgumentError, "cookie path contains an invalid character"
        end
        i += 1
      end
      value
    end

    def domain_value(value)
      if !value.is_a?(String) || value.empty?
        raise ArgumentError, "cookie domain must be a non-empty String"
      end
      start = 0
      if value.getbyte(0) == 0x2E
        start = 1
      end
      if start == value.bytesize
        raise ArgumentError, "cookie domain must not be empty"
      end
      label_start = start
      i = start
      while i < value.bytesize
        byte = value.getbyte(i)
        if byte == 0x2E
          if i == label_start
            raise ArgumentError, "cookie domain has an empty label"
          end
          label_start = i + 1
        elsif !domain_byte?(byte)
          raise ArgumentError, "cookie domain contains an invalid character"
        elsif byte == 0x2D &&
              (i == label_start || i + 1 == value.bytesize || value.getbyte(i + 1) == 0x2E)
          raise ArgumentError, "cookie domain label must not start or end with a hyphen"
        end
        i += 1
      end
      if label_start == value.bytesize
        raise ArgumentError, "cookie domain has an empty label"
      end
      value
    end

    def domain_byte?(byte)
      return true if byte >= 0x41 && byte <= 0x5A
      return true if byte >= 0x61 && byte <= 0x7A
      return true if byte >= 0x30 && byte <= 0x39
      return true if byte == 0x2D || byte == 0x2E
      false
    end

    def boolean_value(value, name)
      return true if value == true
      return false if value == false
      raise ArgumentError, "cookie #{name} must be true or false"
    end

    def same_site_value(value)
      return "" if value.nil?
      text = value.to_s.downcase
      return "Lax" if text == "lax"
      return "Strict" if text == "strict"
      return "None" if text == "none"
      raise ArgumentError, "cookie same_site must be :lax, :strict, :none, or nil"
    end

    def expires_value(value)
      if !value.is_a?(Time)
        raise ArgumentError, "cookie expires must be a Time"
      end
      http_date(value)
    end

    def max_age_value(value)
      if !value.is_a?(Integer) || value < 0
        raise ArgumentError, "cookie max_age must be a non-negative Integer"
      end
      value
    end

    # Formats an RFC 6265 cookie date in UTC: `Wdy, DD Mon YYYY HH:MM:SS GMT`.
    # `Time#strftime` in this build does not expand `%a`/`%b` on every path,
    # so the weekday and month tables are explicit.
    def http_date(value)
      utc = value.utc
      weekdays = [ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" ]
      months = [ "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" ]
      weekdays[utc.wday] + ", " + pad_number(utc.mday) + " " +
        months[utc.mon - 1] + " " + utc.year.to_s + " " +
        pad_number(utc.hour) + ":" + pad_number(utc.min) + ":" +
        pad_number(utc.sec) + " GMT"
    end

    def pad_number(value)
      value < 10 ? "0" + value.to_s : value.to_s
    end

    private :cookie_name, :cookie_name_byte?, :path_value, :domain_value
    private :domain_byte?, :boolean_value, :same_site_value, :expires_value
    private :max_age_value, :http_date, :pad_number
  end

  # The `cookies.permanent` wrapper: every write gets a 20-year `expires`
  # unless the caller passes one. It delegates to the jar instead of setting
  # a flag, so a later plain write in the same request is not affected.
  class PermanentCookieJar
    def initialize(jar)
      @jar = jar
    end

    def [](key)
      @jar[key]
    end

    def []=(key, value)
      @jar.write_from(key, value, true)
    end

    def delete(key, **options)
      @jar.delete(key, **options)
    end

    def to_h
      @jar.to_h
    end

    def each
      @jar.each { |k, v| yield k, v }
      self
    end
  end

  class API
    # The request's cookie jar. The dispatcher assigns it before the action;
    # a controller without an assigned jar gets an empty one.
    #
    # @return [CookieJar] the request's cookie jar
    # @example
    #   cookies[:session] = { value: token, httponly: true }
    def cookies
      @cookies = ActionController::CookieJar.new if @cookies.nil?
      @cookies
    end

    # Assigns the request jar. Internal: the dispatcher calls this before the
    # action; apps read the jar through `cookies`.
    #
    # @api internal
    # @param value [CookieJar] the jar the dispatcher assigns
    # @return [CookieJar] the assigned jar
    def cookies=(value)
      @cookies = value
      value
    end
  end
end
