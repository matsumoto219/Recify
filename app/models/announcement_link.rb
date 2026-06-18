class AnnouncementLink < ApplicationRecord
  MAX_LINKS_PER_ANNOUNCEMENT = 3
  ALLOWED_EXTERNAL_SCHEMES = %w[http https].freeze
  CONTROL_CHARACTER_PATTERN = /[[:cntrl:]]/

  belongs_to :announcement

  before_validation :assign_external

  validates :label, presence: true, length: { maximum: 80 }
  validates :url, presence: true, length: { maximum: 2048 }
  validates :position,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0
            }
  validates :external, inclusion: { in: [ true, false ] }
  validate :safe_url
  validate :links_per_announcement_limit

  private

  def assign_external
    self.external = external_url?(url)
  end

  def safe_url
    value = url.to_s
    return if value.blank?

    if unsafe_url_characters?(value)
      errors.add(:url, :invalid)
      return
    end

    return validate_internal_path(value) if value.start_with?("/")

    validate_external_url(value)
  end

  def unsafe_url_characters?(value)
    value.match?(CONTROL_CHARACTER_PATTERN) || value.include?("\\")
  end

  def validate_internal_path(value)
    return unless value.start_with?("//")

    errors.add(:url, :invalid)
  end

  def validate_external_url(value)
    uri = URI.parse(value)

    unless uri.is_a?(URI::HTTP) &&
        ALLOWED_EXTERNAL_SCHEMES.include?(uri.scheme) &&
        uri.host.present? &&
        uri.userinfo.blank?
      errors.add(:url, :invalid)
    end
  rescue URI::InvalidURIError
    errors.add(:url, :invalid)
  end

  def external_url?(value)
    uri = URI.parse(value.to_s)
    uri.is_a?(URI::HTTP) &&
      ALLOWED_EXTERNAL_SCHEMES.include?(uri.scheme) &&
      uri.host.present? &&
      uri.userinfo.blank?
  rescue URI::InvalidURIError
    false
  end

  def links_per_announcement_limit
    return unless announcement

    count = announcement_link_count
    errors.add(:base, :too_many_announcement_links) if count > MAX_LINKS_PER_ANNOUNCEMENT
  end

  def announcement_link_count
    if announcement.association(:announcement_links).loaded?
      links = announcement.announcement_links.reject(&:marked_for_destruction?)
      links.include?(self) ? links.size : links.size + 1
    elsif new_record?
      announcement.announcement_links.where.not(id: id).count + 1
    else
      announcement.announcement_links.where.not(id: id).count + 1
    end
  end
end
