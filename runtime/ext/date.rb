# Date — the stored DATE column codec.
#
# The `date` package is not part of this file's default load: requiring it
# compiles the package's class bodies into every binary, so the runtime keeps
# this file out of `runtime/ext.rb`. Apps with DATE columns load it from the
# generated `gen/model_columns.rb`; an app that names `Date` itself requires
# it in its own config.
require "date"

class String
  # `"2024-01-02"` → the civil date a stored DATE column holds. The parse is the
  # stored form's fixed width, not a general date parser: the first ten
  # characters are the date and shorter text reads nil, so a datetime text and a
  # date text do not answer through one parser. A well-width text that is not a
  # real calendar date raises through `Date.new` instead of turning into nil.
  #
  # @return [Date?] the parsed date, or nil when the text is shorter than
  #   the stored form
  # @raise [Date::Error] the text is ten characters or longer but not a
  #   real calendar date
  # @example
  #   "2024-01-02".to_date   # => Date.new(2024, 1, 2)
  #   "2024-01-0".to_date    # => nil
  def to_date
    return nil if length < 10
    Date.new(self[0, 4].to_i, self[5, 2].to_i, self[8, 2].to_i)
  end
end
