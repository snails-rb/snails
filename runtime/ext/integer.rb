# Integer — the time units.
#
# Each unit returns `Snails::Duration`, which carries the arithmetic:
# `7.days.ago`, `2.years.from_now`.
class Integer
  def seconds
    Snails::Duration.seconds(self)
  end

  def second
    Snails::Duration.second(self)
  end

  def minutes
    Snails::Duration.minutes(self)
  end

  def minute
    Snails::Duration.minute(self)
  end

  def hours
    Snails::Duration.hours(self)
  end

  def hour
    Snails::Duration.hour(self)
  end

  def days
    Snails::Duration.days(self)
  end

  def day
    Snails::Duration.day(self)
  end

  def weeks
    Snails::Duration.weeks(self)
  end

  def week
    Snails::Duration.week(self)
  end

  def fortnights
    Snails::Duration.fortnights(self)
  end

  def fortnight
    Snails::Duration.fortnight(self)
  end

  def months
    Snails::Duration.months(self)
  end

  def month
    Snails::Duration.month(self)
  end

  def years
    Snails::Duration.years(self)
  end

  def year
    Snails::Duration.year(self)
  end
end
