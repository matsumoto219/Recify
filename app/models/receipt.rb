class Receipt < ApplicationRecord
  PAYMENT_METHODS = %w[
    cash
    credit_card
    e_money
    qr_payment
    debit_card
    other
  ].freeze

  IMAGE_ERROR_CODES = %w[
    image_missing
    image_invalid_format
    image_corrupted
    input_invalid
  ].freeze

  ALLOWED_IMAGE_CONTENT_TYPES = %w[
    image/jpeg
    image/png
    image/bmp
    image/tiff
    image/heif
    image/heic
  ].freeze

  MAX_FILE_SIZE = 20.megabytes
  MIN_IMAGE_DIMENSION = 100
  MAX_IMAGE_DIMENSION = 10_000
  NOTIFICATION_SOURCE_STATUSES = %w[
    uploaded
    processing
  ].freeze
  STATUS_NOTIFICATION_KINDS = {
    "completed" => "receipt_completed",
    "review_needed" => "receipt_review_needed",
    "failed" => "receipt_failed"
  }.freeze
  MODERATION_STATUS_ACTIVE = "active".freeze
  MODERATION_STATUS_QUARANTINED = "quarantined".freeze
  MODERATION_STATUSES = [
    MODERATION_STATUS_ACTIVE,
    MODERATION_STATUS_QUARANTINED
  ].freeze
  PUBLIC_ID_PREFIX = "rcpt_"
  PUBLIC_ID_RANDOM_LENGTH = 16
  PUBLIC_ID_FORMAT = /\A#{PUBLIC_ID_PREFIX}[A-Za-z0-9]{#{PUBLIC_ID_RANDOM_LENGTH}}\z/
  DISPLAY_ID_PREFIX = "R-"
  DISPLAY_ID_RANDOM_LENGTH = 6
  DISPLAY_ID_FORMAT = /\A#{DISPLAY_ID_PREFIX}[0-9A-Z]{#{DISPLAY_ID_RANDOM_LENGTH}}\z/
  UNIQUE_ID_RETRY_LIMIT = 10
  UNIQUE_ID_INDEX_NAMES = %w[
    index_receipts_on_public_id
    index_receipts_on_user_id_and_display_id
  ].freeze
  AMOUNT_CALCULATION_PROFILE_SCHEMA_VERSION = 1
  AMOUNT_RECEIPT_TAX_BASES = %w[
    tax_added_to_subtotal
    total_includes_tax
  ].freeze
  AMOUNT_ITEM_BASES = %w[
    line_total_as_net
    line_total_as_recorded
    mixed_by_tax_rate_group
  ].freeze
  AMOUNT_TAX_DETAIL_BASES = %w[
    gross
    net
    unknown
  ].freeze
  LEGACY_AMOUNT_SOURCE_SEMANTICS = {
    "external_tax_from_receipt" => {
      "receipt_tax_basis" => "tax_added_to_subtotal",
      "item_amount_basis" => "line_total_as_net",
      "tax_detail_amount_basis" => "net"
    },
    "items_as_tax_excluded" => {
      "receipt_tax_basis" => "total_includes_tax",
      "item_amount_basis" => "line_total_as_recorded"
    },
    "items_as_tax_included" => {
      "receipt_tax_basis" => "total_includes_tax",
      "item_amount_basis" => "line_total_as_recorded"
    },
    "mixed_by_tax_rate_group" => {
      "receipt_tax_basis" => "total_includes_tax",
      "item_amount_basis" => "line_total_as_recorded",
      "tax_detail_amount_basis" => "gross"
    },
    "printed_tax_details_gross" => {
      "receipt_tax_basis" => "total_includes_tax",
      "item_amount_basis" => "line_total_as_recorded",
      "tax_detail_amount_basis" => "gross"
    }
  }.freeze

  OCR_ERROR_CODES = %w[
    ocr_unreadable
    ocr_timeout
    ocr_api_error
  ].freeze
  IMAGE_PURGED_REASON_MANUAL_DELETE = "manual_delete".freeze
  IMAGE_PURGED_REASON_SYSTEM_PURGE = "system_purge".freeze
  IMAGE_PURGED_REASONS = [
    IMAGE_PURGED_REASON_MANUAL_DELETE,
    IMAGE_PURGED_REASON_SYSTEM_PURGE
  ].freeze

  enum :payment_method, PAYMENT_METHODS.index_with { |v| v }

  enum :status, {
    uploaded: "uploaded",
    processing: "processing",
    review_needed: "review_needed",
    completed: "completed",
    failed: "failed"
  }
  enum :moderation_status, MODERATION_STATUSES.index_with { |value| value }, prefix: :moderation

  def self.image_max_file_size
    SystemSettings.limit_for("limits.receipt_image_max_file_size_bytes")
  rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
    MAX_FILE_SIZE
  end

  def self.image_min_dimension
    SystemSettings.limit_for("limits.receipt_image_min_dimension_px")
  rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
    MIN_IMAGE_DIMENSION
  end

  def self.image_max_dimension
    SystemSettings.limit_for("limits.receipt_image_max_dimension_px")
  rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
    MAX_IMAGE_DIMENSION
  end

  belongs_to :user
  belongs_to :quarantined_by,
             class_name: "User",
             optional: true
  belongs_to :quarantine_released_by,
             class_name: "User",
             optional: true
  belongs_to :quarantine_source_security_event,
             class_name: "SecurityEvent",
             optional: true
  has_many :notifications, as: :notifiable, dependent: :destroy
  has_many :receipt_analysis_runs, dependent: :destroy, inverse_of: :receipt
  has_many :receipt_adjustments, dependent: :destroy
  has_many :receipt_items, dependent: :destroy
  has_many :receipt_payments, dependent: :destroy
  has_many :receipt_tax_details, dependent: :destroy
  has_one_attached :image

  accepts_nested_attributes_for :receipt_items, allow_destroy: true
  accepts_nested_attributes_for :receipt_payments, allow_destroy: true
  accepts_nested_attributes_for :receipt_tax_details, allow_destroy: true
  accepts_nested_attributes_for :receipt_adjustments, allow_destroy: true

  validates :payment_method, inclusion: { in: PAYMENT_METHODS }, allow_blank: true
  validates :status, presence: true, inclusion: { in: statuses.keys }
  validates :moderation_status, presence: true, inclusion: { in: moderation_statuses.keys }
  validates :image_purged_reason, inclusion: { in: IMAGE_PURGED_REASONS }, allow_nil: true
  validates :public_id,
            presence: true,
            uniqueness: true,
            length: { maximum: 32 },
            format: { with: PUBLIC_ID_FORMAT }
  validates :display_id,
            presence: true,
            uniqueness: { scope: :user_id },
            length: { maximum: 16 },
            format: { with: DISPLAY_ID_FORMAT }

  # 合計金額数値と範囲指定
  validates :total_amount, presence: true, unless: :allow_partial_ocr_data?
  validates :total_amount,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0,
              less_than_or_equal_to: ->(_receipt) { ReceiptAmountService.receipt_total_amount_max }
            },
            allow_blank: true,
            unless: :allow_partial_ocr_data?
  validates :subtotal_amount,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0,
              less_than_or_equal_to: ->(_receipt) { ReceiptAmountService.receipt_total_amount_max }
            },
            allow_blank: true
  validates :tax_amount,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0,
              less_than_or_equal_to: ->(_receipt) { ReceiptAmountService.receipt_tax_amount_max }
            },
            allow_blank: true
  validates :tip_amount,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0,
              less_than_or_equal_to: ->(_receipt) { ReceiptAmountService.receipt_adjustment_amount_max }
            },
            allow_blank: true

  validates :store_name, presence: true, unless: :allow_partial_ocr_data?
  validates :store_name, length: { maximum: 100 }, allow_blank: true  # ストア名(MAX100文字)
  validates :memo, length: { maximum: 1000 }, allow_blank: true       # メモ(MAX1000文字)
  validates :store_address, length: { maximum: 255 }, allow_blank: true   # 住所(MAX255文字)
  validates :store_phone_number, length: { maximum: 20 }, allow_blank: true # 電話番号(MAX20文字)
  validates :country_region,
            length: { is: 3 },
            format: { with: /\A[A-Z]{3}\z/ },
            allow_blank: true
  validates :currency_code,
            length: { is: 3 },
            format: { with: /\A[A-Z]{3}\z/ },
            allow_blank: true

  validate :validate_purchased_at_not_in_future
  validate :validate_image_content_type, if: :image_attachment_changed?
  validate :validate_image_file_size, if: :image_attachment_changed?
  validate :validate_image_dimensions, if: :image_attachment_changed?
  validate :validate_image_presence_for_processing
  validate :validate_store_address_components_shape
  validate :validate_receipt_items_count_within_limit
  validate :validate_receipt_adjustments_count_within_limit
  validate :validate_receipt_payments_count_within_limit
  validate :validate_receipt_tax_details_count_within_limit
  validate :validate_quarantine_state

  before_validation :normalize_country_region
  before_validation :set_default_country_region
  before_validation :normalize_currency_code
  before_validation :normalize_store_address_components
  before_validation :normalize_store_phone_number
  before_validation :assign_public_id, on: :create
  before_validation :assign_display_id, on: :create
  before_update :mark_summary_broadcast_needed

  def save(*args, **kwargs, &block)
    save_with_unique_identifier_retry { super(*args, **kwargs, &block) }
  end

  def save!(*args, **kwargs, &block)
    save_with_unique_identifier_retry { super(*args, **kwargs, &block) }
  end

  def to_param
    public_id
  end

  def image_retention_disabled?
    keep_image == false
  end

  def image_purged?
    image_purged_at.present? || image_purged_reason.present?
  end

  def image_purged_manually?
    image_purged_reason == IMAGE_PURGED_REASON_MANUAL_DELETE
  end

  def image_purged_by_system?
    image_purged_reason == IMAGE_PURGED_REASON_SYSTEM_PURGE
  end

  def schedule_image_purge!(eligible_at: Time.current)
    attributes = {
      image_purge_eligible_at: eligible_at,
      image_purged_at: nil,
      image_purged_reason: nil
    }

    persisted? ? update!(attributes) : assign_attributes(attributes)
  end

  def mark_image_purged!(reason:, purged_at: Time.current)
    normalized_reason = reason.to_s
    unless IMAGE_PURGED_REASONS.include?(normalized_reason)
      raise ArgumentError, "Unknown image_purged_reason=#{reason}"
    end

    attributes = {
      image_purge_eligible_at: nil,
      image_purged_at: purged_at,
      image_purged_reason: normalized_reason
    }

    if persisted?
      update_columns(attributes.merge(updated_at: Time.current))
      reload
    else
      assign_attributes(attributes)
    end
  end

  def dom_target_id
    "receipt_#{public_id}"
  end

  def receipt_tax_basis_for_form
    saved_basis = amount_source_semantics_for_edit["receipt_tax_basis"]
    return "external" if saved_basis == "tax_added_to_subtotal"
    return "internal" if saved_basis == "total_includes_tax"

    external_tax_basis_from_details? ? "external" : "internal"
  end

  def amount_source_semantics_for_edit
    snapshot = amount_calculation_profile
    return {} unless snapshot.respond_to?(:with_indifferent_access)

    snapshot = snapshot.with_indifferent_access
    return {} unless snapshot[:schema_version].to_i == AMOUNT_CALCULATION_PROFILE_SCHEMA_VERSION
    return {} if snapshot[:selected_candidate_status].to_s == "rejected"
    return {} if snapshot.dig(:amount_engine, :no_safe_candidate) == true

    profile_semantics = sanitized_amount_source_semantics(snapshot[:profile])
    return edit_source_semantics_projection(profile_semantics) if profile_semantics.present?

    legacy_amount_source_semantics(snapshot)
  end

  def receipt_items_limit
    return UserLimits.effective_limit(user: user, key: "receipt_items_per_receipt") if user

    SystemSettings.limit_for("limits.receipt_items_per_receipt")
  end

  def external_tax_basis_from_details?
    complete_tax_details = receipt_tax_details.to_a.select do |tax_detail|
      tax_detail.rate.to_d.positive? &&
        tax_detail.net_amount.present? &&
        tax_detail.net_amount.to_i.positive? &&
        tax_detail.amount.present? &&
        tax_detail.amount.to_i >= 0
    end
    return false if complete_tax_details.blank?

    detail_net_amount = complete_tax_details.sum { |tax_detail| tax_detail.net_amount.to_i }
    detail_tax_amount = complete_tax_details.sum { |tax_detail| tax_detail.amount.to_i }
    item_line_total = receipt_items.to_a.sum { |item| item.line_total.to_i }

    item_line_total.positive? &&
      detail_net_amount == item_line_total &&
      subtotal_amount.to_i == detail_net_amount &&
      tax_amount.to_i == detail_tax_amount &&
      total_amount.to_i == detail_net_amount + detail_tax_amount
  end

  def sanitized_amount_source_semantics(profile)
    return {} unless profile.respond_to?(:with_indifferent_access)

    profile = profile.with_indifferent_access
    receipt_tax_basis = profile[:receipt_tax_basis].to_s
    item_amount_basis = profile[:item_amount_basis].to_s
    return {} unless AMOUNT_RECEIPT_TAX_BASES.include?(receipt_tax_basis)
    return {} unless AMOUNT_ITEM_BASES.include?(item_amount_basis)
    return {} unless valid_amount_source_basis_pair?(receipt_tax_basis, item_amount_basis)

    semantics = {
      "receipt_tax_basis" => receipt_tax_basis,
      "item_amount_basis" => item_amount_basis
    }
    tax_detail_amount_basis = profile[:tax_detail_amount_basis].to_s
    if AMOUNT_TAX_DETAIL_BASES.include?(tax_detail_amount_basis)
      semantics["tax_detail_amount_basis"] = tax_detail_amount_basis
    end
    semantics
  end

  def legacy_amount_source_semantics(snapshot)
    return {} unless snapshot[:selected_candidate_status].to_s == "accepted"

    selected_basis = snapshot.dig(:amount_engine, :selected_basis).to_s
    LEGACY_AMOUNT_SOURCE_SEMANTICS.fetch(selected_basis, {}).dup
  end

  def edit_source_semantics_projection(semantics)
    pair = [ semantics["receipt_tax_basis"], semantics["item_amount_basis"] ]
    case pair
    when [ "tax_added_to_subtotal", "line_total_as_net" ],
         [ "total_includes_tax", "line_total_as_recorded" ],
         [ "total_includes_tax", "mixed_by_tax_rate_group" ]
      semantics
    when [ "tax_added_to_subtotal", "line_total_as_recorded" ]
      if external_tax_basis_from_details?
        semantics.merge(
          "item_amount_basis" => "line_total_as_net",
          "tax_detail_amount_basis" => "net"
        )
      else
        {
          "receipt_tax_basis" => "total_includes_tax",
          "item_amount_basis" => "line_total_as_recorded"
        }
      end
    else
      {}
    end
  end

  def valid_amount_source_basis_pair?(receipt_tax_basis, item_amount_basis)
    case receipt_tax_basis
    when "tax_added_to_subtotal"
      %w[line_total_as_net line_total_as_recorded].include?(item_amount_basis)
    when "total_includes_tax"
      %w[line_total_as_recorded mixed_by_tax_rate_group].include?(item_amount_basis)
    else
      false
    end
  end

  private :sanitized_amount_source_semantics,
    :legacy_amount_source_semantics,
    :edit_source_semantics_projection,
    :valid_amount_source_basis_pair?

  scope :active_for_user, -> { where(moderation_status: MODERATION_STATUS_ACTIVE) }

  # UI表示用電話番号
  # 日本の場合:
  #   DB内部形式: +818012345678
  #   表示形式: 08012345678
  # 日本以外の場合:
  #   国別整形は未対応のため、正規化済みの内部形式をそのまま表示
  def display_store_phone_number
    return "" if store_phone_number.blank?

    normalized = normalize_phone_number_text(store_phone_number)

    return normalized unless japanese_country_region?

    if normalized.start_with?("+81")
      "0#{normalized[3..]}"
    else
      normalized
    end
  end

  def quarantined?
    moderation_quarantined?
  end

  def active_for_user?
    moderation_active?
  end

  def quarantine!(actor:, reason:, source_security_event: nil, at: Time.current)
    raise ActiveRecord::RecordInvalid, self unless moderation_active?

    update!(
      moderation_status: MODERATION_STATUS_QUARANTINED,
      quarantined_at: at,
      quarantined_by: actor,
      quarantine_reason: reason,
      quarantine_source_security_event: source_security_event,
      quarantine_released_at: nil,
      quarantine_released_by: nil,
      quarantine_released_reason: nil
    )
  end

  def release_quarantine!(actor:, reason:, at: Time.current)
    raise ActiveRecord::RecordInvalid, self unless moderation_quarantined?

    update!(
      moderation_status: MODERATION_STATUS_ACTIVE,
      quarantine_released_at: at,
      quarantine_released_by: actor,
      quarantine_released_reason: reason
    )
  end

  private

  # 将来、国/地域ごとの住所・電話番号解析を強化する場合は libphonenumber 等の導入を検討する。
  # 手動登録など country_region が空のレシートを日本扱いにする
  def normalize_country_region
    self.country_region = country_region.to_s.strip.upcase.presence if country_region.present?
  end

  def set_default_country_region
    self.country_region = "JPN" if country_region.blank?
  end

  def normalize_currency_code
    self.currency_code = currency_code.to_s.strip.upcase.presence if currency_code.present?
  end

  def normalize_store_address_components
    self.store_address_components = {} if store_address_components.nil?
    self.store_address_components = store_address_components.deep_stringify_keys if store_address_components.is_a?(Hash)
  end

  def normalize_store_phone_number
    return if store_phone_number.blank?

    normalized = normalize_phone_number_text(store_phone_number)

    self.store_phone_number =
      if japanese_country_region?
        normalize_japanese_phone_number(normalized)
      else
        normalized
      end
  end

  def japanese_country_region?
    country_region.blank? || country_region.to_s.upcase == "JPN"
  end

  def normalize_phone_number_text(value)
    value.to_s.gsub(/[^\d+]/, "")
  end

  def normalize_japanese_phone_number(normalized)
    if normalized.start_with?("+81")
      normalized
    elsif normalized.start_with?("0")
      "+81#{normalized[1..]}"
    else
      normalized
    end
  end

  def validate_purchased_at_not_in_future
    return if purchased_at.blank?
    return if purchased_at <= Time.current

    errors.add(:purchased_at, :future_date)
  end

  def validate_store_address_components_shape
    return if store_address_components.is_a?(Hash)

    errors.add(:store_address_components, :invalid)
  end

  def validate_receipt_items_count_within_limit
    limit = receipt_items_limit
    count = child_records_count_for_validation(:receipt_items)
    return if count <= limit

    errors.add(:receipt_items, :too_many, count: count, limit: limit)
  end

  def validate_receipt_adjustments_count_within_limit
    validate_child_records_count_within_limit(
      :receipt_adjustments,
      ReceiptAdjustment.per_receipt_limit,
      :too_many
    )
  end

  def validate_receipt_payments_count_within_limit
    validate_child_records_count_within_limit(
      :receipt_payments,
      ReceiptPayment.per_receipt_limit,
      :too_many
    )
  end

  def validate_receipt_tax_details_count_within_limit
    validate_child_records_count_within_limit(
      :receipt_tax_details,
      ReceiptTaxDetail.per_receipt_limit,
      :too_many
    )
  end

  def validate_quarantine_state
    return unless moderation_quarantined?

    errors.add(:quarantined_at, :blank) if quarantined_at.blank?
    errors.add(:quarantined_by, :blank) if quarantined_by.blank?
    errors.add(:quarantine_reason, :blank) if quarantine_reason.blank?
  end

  def validate_child_records_count_within_limit(association_name, limit, error)
    count = child_records_count_for_validation(association_name)
    return if count <= limit

    errors.add(association_name, error, count: count, limit: limit)
  end

  def child_records_count_for_validation(association_name)
    association_proxy = association(association_name)
    target = association_proxy.target

    if new_record? || association_proxy.loaded? || target.any?
      target.reject(&:marked_for_destruction?).size
    else
      association_proxy.scope.count
    end
  end

  def validate_image_content_type
    return unless image.attached?

    content_type = image.blob.content_type
    return if ALLOWED_IMAGE_CONTENT_TYPES.include?(content_type)

    errors.add(:image, :invalid_content_type)
  end

  def image_attachment_changed?
    attachment_changes.key?("image")
  end

  def validate_image_file_size
    return unless image.attached?
    max_file_size = self.class.image_max_file_size
    return if image.blob.byte_size <= max_file_size

    errors.add(:image, :file_too_large, max_size: ActiveSupport::NumberHelper.number_to_human_size(max_file_size))
  end

  def validate_image_dimensions
    return unless image.attached?
    return unless ALLOWED_IMAGE_CONTENT_TYPES.include?(image.blob.content_type)

    dimensions = Storage.extract_image_dimensions(blob: image.blob, attached_change: attachment_changes["image"])
    unless dimensions
      errors.add(:image, :invalid_content_type)
      return
    end

    width = dimensions.fetch(:width)
    height = dimensions.fetch(:height)

    min_dimension = self.class.image_min_dimension
    max_dimension = self.class.image_max_dimension

    if width < min_dimension || height < min_dimension
      errors.add(:image, :image_too_small, min_dimension: min_dimension)
      return
    end

    return if width <= max_dimension && height <= max_dimension

    errors.add(:image, :image_too_large, max_dimension: max_dimension)
  end

  def validate_image_presence_for_processing
    return unless processing?
    return if image.attached?

    errors.add(:image, :blank)
  end

  def allow_partial_ocr_data?
    return true if image.attached? && (uploaded? || processing? || review_needed? || failed?)

    image_purged? && (review_needed? || failed?)
  end

  public

  def self.payment_method_options
    PAYMENT_METHODS.map do |key|
      [ I18n.t("enums.receipt.payment_method.#{key}"), key ]
    end
  end

  def payment_method_label
    return "" if payment_method.blank?

    I18n.t("enums.receipt.payment_method.#{payment_method}", default: payment_method)
  end

  def status_label
    return "" if status.blank?

    I18n.t("enums.receipt.status.#{status}", default: status)
  end

  def review_reason_labels
    review_reason_labels_for(review_reasons)
  end

  def blocking_review_reason_codes
    ReviewReasons.blocking_reasons_for_user(review_reasons)
  end

  def blocking_review_reason_labels
    review_reason_labels_for(blocking_review_reason_codes)
  end

  def warning_review_reason_codes
    ReviewReasons.warning_reasons_for_user(review_reasons)
  end

  def warning_review_reason_labels
    review_reason_labels_for(warning_review_reason_codes)
  end

  def review_reason_labels_for(codes)
    ReviewReasons.review_reasons_for_user(codes).map do |code|
      I18n.t("enums.receipt_item.review_reason.#{code}", default: code)
    end
  end

  def review_items
    receipt_items.select(&:needs_review)
  end

  def review_adjustments
    receipt_adjustments.select do |adjustment|
      adjustment.persisted? &&
        !adjustment.marked_for_destruction? &&
        adjustment.needs_review? &&
        ReviewReasons.review_reasons_for_user(adjustment.review_reasons).any?
    end
  end

  def has_blocking_review_notes?
    blocking_review_reason_labels.any? || review_items.any? || review_adjustments.any?
  end

  def has_warning_notes?
    warning_review_reason_labels.any?
  end

  def has_review_notes?
    has_blocking_review_notes? || has_warning_notes?
  end

  def tax_rate_percentage_input
    return nil if tax_rate.blank?

    value = tax_rate.to_d * 100
    value.frac.zero? ? value.to_i.to_s : value.to_s("F")
  end

  def tax_rate_percentage_input=(value)
    self.tax_rate =
      if value.present?
        BigDecimal(value.to_s) / 100
      else
        nil
      end
  end

  def error_category
    return nil if processing_error_code.blank?

    Analysis.processing_error_category(processing_error_code)
  end

  def has_processing_error?
    processing_error_code.present?
  end

  def failed_with_error?
    failed? && processing_error_code.present?
  end

  def processing_flash_type
    return nil unless failed_with_error?

    case error_category
    when :image_error
      :image_error
    when :ocr_error
      :ocr_error
    when :ai_error
      :ai_error
    when :system_error
      :error
    else
      :error
    end
  end

  def processing_flash_message
    return nil unless failed_with_error?

    processing_error_user_message
  end

  def processing_error_user_message
    return nil unless has_processing_error?

    I18n.t(
      "receipts.processing_error_codes.#{processing_error_code}",
      default: I18n.t(
        "receipts.processing_errors.#{error_category}",
        default: I18n.t("receipts.processing_errors.system_error")
      )
    )
  end

  def processing_flash_messages
    return [] unless failed_with_error?

    [ processing_flash_message ]
  end

  after_create_commit :broadcast_receipt_card_prepend, if: :processing?
  after_create_commit :broadcast_created_summary_cards_update
  after_update_commit :broadcast_receipt_card_update, if: :saved_change_to_status?
  after_update_commit :broadcast_summary_cards_update_after_update, if: :summary_broadcast_needed?
  after_update_commit :broadcast_processing_flash, if: :processing_flash_notification_needed?
  after_update_commit :create_status_notification, if: :status_notification_needed?
  after_destroy_commit :broadcast_summary_cards_update_after_destroy

  private

  def mark_summary_broadcast_needed
    @summary_broadcast_needed = will_save_change_to_status? ||
      will_save_change_to_total_amount? ||
      will_save_change_to_purchased_at?
  end

  def assign_public_id
    self.public_id ||= generate_unique_public_id
  end

  def assign_display_id
    self.display_id ||= generate_unique_display_id
  end

  def save_with_unique_identifier_retry
    retry_count = 0

    begin
      yield
    rescue ActiveRecord::RecordNotUnique => e
      raise unless new_record? && unique_identifier_collision_error?(e)

      retry_count += 1
      raise if retry_count > UNIQUE_ID_RETRY_LIMIT

      regenerate_unique_identifiers
      retry
    end
  end

  def regenerate_unique_identifiers
    self.public_id = generate_unique_public_id
    self.display_id = generate_unique_display_id
  end

  def generate_unique_public_id
    UNIQUE_ID_RETRY_LIMIT.times do
      candidate = "#{PUBLIC_ID_PREFIX}#{SecureRandom.base58(PUBLIC_ID_RANDOM_LENGTH)}"
      return candidate unless self.class.unscoped.exists?(public_id: candidate)
    end

    raise ActiveRecord::RecordNotUnique, "Could not generate unique receipt public_id"
  end

  def generate_unique_display_id
    UNIQUE_ID_RETRY_LIMIT.times do
      candidate = "#{DISPLAY_ID_PREFIX}#{SecureRandom.random_number(36**DISPLAY_ID_RANDOM_LENGTH).to_s(36).upcase.rjust(DISPLAY_ID_RANDOM_LENGTH, '0')}"
      return candidate unless display_id_exists_for_user?(candidate)
    end

    raise ActiveRecord::RecordNotUnique, "Could not generate unique receipt display_id"
  end

  def display_id_exists_for_user?(candidate)
    owner_id = user_id || user&.id
    return false if owner_id.blank?

    self.class.unscoped.where(user_id: owner_id, display_id: candidate).exists?
  end

  def unique_identifier_collision_error?(error)
    message = error.message.to_s
    UNIQUE_ID_INDEX_NAMES.any? { |index_name| message.include?(index_name) }
  end

  def summary_broadcast_needed?
    @summary_broadcast_needed == true
  end

  def broadcast_receipt_card_prepend
    broadcast_prepend_later_to(
      [ user, :receipts, :index_first_page ],
      target: "receipts-list-grid",
      partial: "shared/receipts/receipt_card",
      locals: { receipt: self }
    )

    broadcast_remove_to(
      [ user, :receipts, :index_first_page ],
      target: "receipts-empty-state"
    )
  end

  def broadcast_created_summary_cards_update
    broadcast_summary_cards_update
  end

  def broadcast_summary_cards_update_after_update
    broadcast_summary_cards_update
  end

  def broadcast_summary_cards_update_after_destroy
    broadcast_summary_cards_update
  end

  def broadcast_receipt_card_update
    broadcast_replace_later_to(
      [ user, :receipts ],
      target: dom_target_id,
      partial: "shared/receipts/receipt_card",
      locals: { receipt: self }
    )
  end

  def broadcast_summary_cards_update
    summary = Receipts::SummaryQuery.call(user: user)

    broadcast_replace_later_to(
      [ user, :receipts ],
      target: "receipts_summary",
      partial: "shared/receipts/summary_cards",
      locals: summary.to_h.merge(animate_on_connect: true)
    )
  ensure
    @summary_broadcast_needed = false
  end

  def broadcast_processing_flash
    return unless user&.push_notification_enabled?

    flash_type, message =
      case status
      when "completed"
        [ :notice, I18n.t("flash.receipts.analysis_completed") ]
      when "review_needed"
        [ :caution, I18n.t("flash.receipts.analysis_review_needed") ]
      when "failed"
        [ :alert, processing_flash_message || I18n.t("flash.receipts.analysis_failed") ]
      else
        return
      end

    broadcast_append_later_to(
      [ user, :receipts ],
      target: "toast-stream",
      partial: "shared/ui/feedback/toast_notice",
      locals: {
        notice_type: flash_type,
        message: message
      }
    )
  end

  def status_notification_needed?
    return false unless saved_change_to_status?

    previous_status, current_status = saved_change_to_status

    NOTIFICATION_SOURCE_STATUSES.include?(previous_status) &&
      STATUS_NOTIFICATION_KINDS.key?(current_status)
  end

  def processing_flash_notification_needed?
    saved_change_to_status? && user&.push_notification_enabled?
  end

  def create_status_notification
    user.notifications.create_or_find_by!(
      kind: STATUS_NOTIFICATION_KINDS.fetch(status),
      notifiable: self
    ) do |notification|
      notification.title = status_notification_title
      notification.body = status_notification_body
      notification.action_path = Rails.application.routes.url_helpers.receipt_path(self)
      notification.metadata = {
        receipt_id: id,
        status: status
      }
    end
  end

  def status_notification_title
    case status
    when "completed"
      I18n.t("notifications.receipts.completed.title")
    when "review_needed"
      I18n.t("notifications.receipts.review_needed.title")
    when "failed"
      I18n.t("notifications.receipts.failed.title")
    end
  end

  def status_notification_body
    subject = store_name.presence || I18n.t("notifications.receipts.default_subject")

    case status
    when "completed"
      I18n.t("notifications.receipts.completed.body", subject: subject)
    when "review_needed"
      I18n.t("notifications.receipts.review_needed.body", subject: subject)
    when "failed"
      processing_flash_message || I18n.t("notifications.receipts.failed.body", subject: subject)
    end
  end
end
