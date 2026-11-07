# Validates the input for a post before the controller writes it.
#
# A form holds no persistence: it projects the request hash onto its declared
# fields, runs the rules in declaration order, and answers the ordered message
# list a 422 body carries.
class PostForm < Snails::Form
  FIELDS = %w[title body].each { |n| define_method(n) { read_attribute(n) } }

  validates :title, presence: true
  validates :title, length: { minimum: 3, maximum: 120 }, allow_blank: true
  validates :body, presence: true
  validate :title_cannot_contain_html

  # The scaffold stores plain text, so a title carrying markup is refused
  # before it reaches the row.
  def title_cannot_contain_html
    errors.add(:title, "must not contain HTML") if title.to_s.include?("<")
  end
end
