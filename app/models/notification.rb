class Notification < ApplicationRecord
  UID_PREFIX = "ntf_"
  UID_RANDOM_LENGTH = 16
  UID_FORMAT = /\A#{UID_PREFIX}[A-Za-z0-9]{#{UID_RANDOM_LENGTH}}\z/
  UID_RETRY_LIMIT = 10
  UID_UNIQUE_INDEX_NAME = "index_notifications_on_uid"

  KINDS = %w[
    receipt_completed
    receipt_review_needed
    receipt_failed
  ].freeze

  belongs_to :user
  belongs_to :notifiable, polymorphic: true, optional: true

  before_validation :assign_uid, on: :create

  validates :uid,
            presence: true,
            uniqueness: true,
            length: { maximum: 32 },
            format: { with: UID_FORMAT }
  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :title, presence: true

  scope :unread, -> { where(read_at: nil) }
  scope :read, -> { where.not(read_at: nil) }
  scope :recent, -> { order(created_at: :desc) }

  DROPDOWN_LIMIT = 5
  INDEX_LIMIT = 50
  DEFAULT_READ_RETENTION_DAYS = 30
  READ_RETENTION_DAYS = DEFAULT_READ_RETENTION_DAYS
  DEFAULT_MAX_NOTIFICATIONS_PER_USER = 100
  MAX_NOTIFICATIONS_PER_USER = DEFAULT_MAX_NOTIFICATIONS_PER_USER

  after_create_commit :broadcast_realtime_surfaces_after_create
  after_create_commit :prune_user_notifications_after_create
  after_update_commit :broadcast_realtime_surfaces_after_read_change, if: :saved_change_to_read_at?
  after_destroy_commit :broadcast_realtime_surfaces_after_destroy

  def save(*args, **kwargs, &block)
    save_with_uid_retry { super(*args, **kwargs, &block) }
  end

  def save!(*args, **kwargs, &block)
    save_with_uid_retry { super(*args, **kwargs, &block) }
  end

  class << self
    def broadcast_realtime_surfaces_for(user)
      return unless user

      unread_count = user.notifications.unread.count
      dropdown_notifications = user.notifications.recent.limit(DROPDOWN_LIMIT).to_a
      index_notifications = user.notifications.recent.limit(INDEX_LIMIT).to_a

      broadcast_unread_badge_for(user, unread_count:)
      broadcast_dropdown_content_for(user, notifications: dropdown_notifications)
      broadcast_index_header_for(user, unread_count:)
      broadcast_index_list_for(user, notifications: index_notifications)
    end

    def preload_known_notifiables(notifications)
      records = Array(notifications)
      preloadable_records = records.select { |notification| preloadable_notifiable?(notification) }
      ActiveRecord::Associations::Preloader.new(records: preloadable_records, associations: :notifiable).call if preloadable_records.any?

      records
    end

    def cleanup_old!(now: Time.current)
      threshold = now - read_retention_days.days
      affected_user_ids = read.where("read_at < ?", threshold).distinct.pluck(:user_id)
      deleted_count = read.where("read_at < ?", threshold).delete_all

      distinct.pluck(:user_id).each do |user_id|
        pruned_count = prune_for_user!(user_id, broadcast: false)
        next if pruned_count.zero?

        deleted_count += pruned_count
        affected_user_ids << user_id
      end

      broadcast_cleanup_for(affected_user_ids.uniq)
      deleted_count
    end

    def prune_for_user!(user_or_id, broadcast: true)
      user = user_or_id.is_a?(User) ? user_or_id : User.find_by(id: user_or_id)
      return 0 unless user

      protected_ids = user.notifications.recent.limit(notifications_per_user_limit).pluck(:id)
      deletable_scope = user.notifications.read
      deletable_scope = deletable_scope.where.not(id: protected_ids) if protected_ids.any?
      deleted_count = deletable_scope.delete_all

      broadcast_realtime_surfaces_for(user) if broadcast && deleted_count.positive?
      deleted_count
    end

    def notifications_per_user_limit
      SystemSettings.limit_for("limits.notifications_per_user")
    rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
      DEFAULT_MAX_NOTIFICATIONS_PER_USER
    end

    def read_retention_days
      SystemSettings.limit_for("retention.notifications_read_days")
    rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
      DEFAULT_READ_RETENTION_DAYS
    end

    private

    def preloadable_notifiable?(notification)
      return false if notification.notifiable_type.blank? || notification.notifiable_id.blank?

      klass = notification.notifiable_type.safe_constantize
      klass && klass < ActiveRecord::Base
    end

    def broadcast_cleanup_for(user_ids)
      User.where(id: user_ids).find_each do |user|
        broadcast_realtime_surfaces_for(user)
      end
    end

    def broadcast_unread_badge_for(user, unread_count:)
      Turbo::StreamsChannel.broadcast_replace_later_to(
        [ user, :notifications ],
        target: "notifications_unread_badge",
        partial: "shared/notifications/badge",
        locals: { unread_count: unread_count }
      )
    end

    def broadcast_dropdown_content_for(user, notifications:)
      Turbo::StreamsChannel.broadcast_replace_later_to(
        [ user, :notifications ],
        target: "notifications_dropdown_content",
        partial: "shared/notifications/dropdown_content",
        locals: { notifications: notifications }
      )
    end

    def broadcast_index_header_for(user, unread_count:)
      Turbo::StreamsChannel.broadcast_replace_later_to(
        [ user, :notifications ],
        target: "notifications_index_header",
        partial: "notifications/header",
        locals: { unread_count: unread_count }
      )
    end

    def broadcast_index_list_for(user, notifications:)
      Turbo::StreamsChannel.broadcast_replace_later_to(
        [ user, :notifications ],
        target: "notifications_list",
        partial: "notifications/list",
        locals: { notifications: notifications }
      )
    end
  end

  def read?
    read_at.present?
  end

  def unread?
    !read?
  end

  def mark_as_read!
    return true if read?

    update!(read_at: Time.current)
  end

  def stale_notifiable?
    return false if notifiable_type.blank? || notifiable_id.blank?

    notifiable.blank?
  rescue NameError
    true
  end

  def action_available?
    internal_action_path? && !stale_notifiable?
  end

  def to_param
    uid
  end

  private

  def assign_uid
    self.uid ||= generate_unique_uid
  end

  def generate_unique_uid
    UID_RETRY_LIMIT.times do
      candidate = "#{UID_PREFIX}#{SecureRandom.base58(UID_RANDOM_LENGTH)}"
      return candidate unless self.class.unscoped.exists?(uid: candidate)
    end

    raise ActiveRecord::RecordNotUnique, "Could not generate unique notification uid"
  end

  def save_with_uid_retry
    retry_count = 0

    begin
      yield
    rescue ActiveRecord::RecordNotUnique => e
      raise unless new_record? && uid_collision_error?(e)

      retry_count += 1
      raise if retry_count > UID_RETRY_LIMIT

      self.uid = generate_unique_uid
      retry
    end
  end

  def uid_collision_error?(error)
    error.message.to_s.include?(UID_UNIQUE_INDEX_NAME)
  end

  def internal_action_path?
    path = action_path.to_s

    path.start_with?("/") && !path.start_with?("//")
  end

  def broadcast_realtime_surfaces_after_create
    broadcast_realtime_surfaces
  end

  def broadcast_realtime_surfaces_after_read_change
    broadcast_realtime_surfaces
  end

  def broadcast_realtime_surfaces_after_destroy
    broadcast_realtime_surfaces
  end

  def broadcast_realtime_surfaces
    self.class.broadcast_realtime_surfaces_for(user)
  end

  def prune_user_notifications_after_create
    self.class.prune_for_user!(user)
  end
end
