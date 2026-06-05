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
  KPI_AMOUNT_STATUSES = %w[
    completed
    review_needed
  ].freeze
  NOTIFICATION_SOURCE_STATUSES = %w[
    uploaded
    processing
  ].freeze
  STATUS_NOTIFICATION_KINDS = {
    "completed" => "receipt_completed",
    "review_needed" => "receipt_review_needed",
    "failed" => "receipt_failed"
  }.freeze
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

  belongs_to :user
  has_many :notifications, as: :notifiable, dependent: :destroy
  has_many :receipt_analysis_runs, dependent: :destroy, inverse_of: :receipt
  has_many :receipt_adjustments, dependent: :destroy
  has_many :receipt_items, dependent: :destroy
  has_many :receipt_payments, dependent: :destroy
  has_many :receipt_tax_details, dependent: :destroy
  has_one_attached :image

  accepts_nested_attributes_for :receipt_items, allow_destroy: true
  accepts_nested_attributes_for :receipt_payments, allow_destroy: false
  accepts_nested_attributes_for :receipt_tax_details, allow_destroy: true
  accepts_nested_attributes_for :receipt_adjustments, allow_destroy: true

  validates :payment_method, inclusion: { in: PAYMENT_METHODS }, allow_blank: true
  validates :status, presence: true, inclusion: { in: statuses.keys }
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
            numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 999_999_999 },
            allow_blank: true,
            unless: :allow_partial_ocr_data?

  validates :store_name, presence: true, unless: :allow_partial_ocr_data?
  validates :store_name, length: { maximum: 100 }, allow_blank: true  # ストア名(MAX100文字)
  validates :memo, length: { maximum: 1000 }, allow_blank: true       # メモ(MAX1000文字)
  validates :store_address, length: { maximum: 255 }, allow_blank: true   # 住所(MAX255文字)
  validates :store_phone_number, length: { maximum: 20 }, allow_blank: true # 電話番号(MAX20文字)
  validates :currency_code,
            length: { is: 3 },
            format: { with: /\A[A-Z]{3}\z/ },
            allow_blank: true

  validate :validate_purchased_at_not_in_future
  validate :validate_image_content_type
  validate :validate_image_file_size
  validate :validate_image_dimensions
  validate :validate_image_presence_for_processing
  validate :validate_store_address_components_shape
  validate :validate_receipt_items_count_within_limit

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
    external_tax_basis_from_details? ? "external" : "internal"
  end

  def receipt_items_limit
    return UserLimits.effective_limit(user: user, key: "receipt_items_per_receipt") if user

    SystemSettings.limit_for("limits.receipt_items_per_receipt")
  end

  def external_tax_basis_from_details?
    complete_tax_details = receipt_tax_details.to_a.select do |tax_detail|
      tax_detail.net_amount.to_i.positive? && tax_detail.amount.to_i.positive?
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

  # 拡張検索（AND検索対応）
  # --------------------------------------------------
  # スペース区切りでAND検索
  # 例:
  #   セブン 1000
  #   → 店舗名に「セブン」 AND 金額1000円
  #
  #   牛乳 <=300
  #   → 明細名「牛乳」 AND 300円以下
  #
  #   date>=2026-01-01 セブン
  #   → 2026/01/01以降 AND 店舗名「セブン」
  #
  #   セブン <=1000 date>=2026-01-01
  #   → 店舗名 AND 金額条件 AND 期間条件（複合検索）
  #
  # 各トークン内はOR検索、トークン間はAND検索
  # --------------------------------------------------
  scope :search, ->(query) {
    return all if query.blank?

    tokens = query.to_s.strip.split(/\s+/).first(5) # 最大5トークンに制限（過負荷防止）
    return none if tokens.empty?

    scope = all

    tokens.each do |token|
      safe_parse_search_date = ->(date_text) do
        Date.parse(date_text)
      rescue ArgumentError
        nil
      end

      q = "%#{sanitize_sql_like(token)}%"

      matching_ids = left_joins(:receipt_items).unscope(:order).where(
        "receipts.store_name ILIKE :q OR receipts.memo ILIKE :q OR receipt_items.confirmed_name ILIKE :q OR receipt_items.suggested_name ILIKE :q OR receipt_items.raw_text ILIKE :q",
        q: q
      ).select(:id)

      token_scope = where(id: matching_ids)

      # 日付検索（YYYY-MM-DD / YYYY/MM/DD など）
      begin
        date = Date.parse(token)
        token_scope = token_scope.or(where(purchased_at: date.beginning_of_day..date.end_of_day))
      rescue ArgumentError
        # 無効な日付は無視
      end

      # 期間検索
      # 例:
      # - date:2026-01-01..2026-12-31
      # - date:2026/01/01..2026/12/31
      # - date>=2026-01-01
      # - date>=2026/01/01
      # - date<=2026-12-31
      # - date<=2026/12/31
      normalized_date_query = token.strip
      search_date_pattern = "\\d{4}[\\/-]\\d{2}[\\/-]\\d{2}"

      # 範囲指定
      if normalized_date_query =~ /\Adate:(#{search_date_pattern})\.\.(#{search_date_pattern})\z/
        from = safe_parse_search_date.call($1)
        to = safe_parse_search_date.call($2)
        token_scope = from && to ? token_scope.or(where(purchased_at: from.beginning_of_day..to.end_of_day)) : none
      end

      # 片側指定
      if normalized_date_query =~ /\Adate>=?(#{search_date_pattern})\z/
        from = safe_parse_search_date.call($1)
        token_scope = from ? token_scope.or(where("purchased_at >= ?", from.beginning_of_day)) : none
      end

      if normalized_date_query =~ /\Adate<=?(#{search_date_pattern})\z/
        to = safe_parse_search_date.call($1)
        token_scope = to ? token_scope.or(where("purchased_at <= ?", to.end_of_day)) : none
      end

      # 金額検索
      # 例:
      # - 1000        => 1000円ちょうど
      # - <=1000      => 1000円以下
      # - <1000       => 1000円未満
      # - >=1000      => 1000円以上
      # - >1000       => 1000円超
      # - amount<=1000 / total>=1000 なども許可
      normalized_amount_query = token.delete(",").downcase
      amount_condition = normalized_amount_query.match(/\A(?:amount|total)?\s*(<=|>=|<|>|=)?\s*(\d+)\z/)

      if amount_condition
        operator = amount_condition[1].presence || "="
        amount = amount_condition[2].to_i
        amount_column = arel_table[:total_amount]
        amount_predicate =
          case operator
          when "<="
            amount_column.lteq(amount)
          when ">="
            amount_column.gteq(amount)
          when "<"
            amount_column.lt(amount)
          when ">"
            amount_column.gt(amount)
          else
            amount_column.eq(amount)
          end

        token_scope = token_scope.or(where(amount_predicate))
      end

      scope = scope.merge(token_scope)
    end

    scope
  }

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

  private

  # TODO: v1.0で libphonenumber 等を導入予定
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
    count = receipt_items.reject(&:marked_for_destruction?).size
    return if count <= limit

    errors.add(:receipt_items, :too_many, count: count, limit: limit)
  end

  def validate_image_content_type
    return unless image.attached?

    content_type = image.blob.content_type
    return if ALLOWED_IMAGE_CONTENT_TYPES.include?(content_type)

    errors.add(:image, :invalid_content_type)
  end

  def validate_image_file_size
    return unless image.attached?
    return if image.blob.byte_size <= MAX_FILE_SIZE

    errors.add(:image, :file_too_large)
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

    if width < MIN_IMAGE_DIMENSION || height < MIN_IMAGE_DIMENSION
      errors.add(:image, :image_too_small)
      return
    end

    return if width <= MAX_IMAGE_DIMENSION && height <= MAX_IMAGE_DIMENSION

    errors.add(:image, :image_too_large)
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

  def self.summary_for(user, scope: nil)
    current_month_range = Time.current.beginning_of_month..Time.current.end_of_month
    previous_month = 1.month.ago
    previous_month_range = previous_month.beginning_of_month..previous_month.end_of_month
    aggregates = summary_aggregates_for(scope || user.receipts, current_month_range, previous_month_range)

    monthly_change = monthly_change_summary(aggregates[:current_month_total], aggregates[:previous_month_total])

    {
      receipts_count: aggregates[:receipts_count],
      current_month_total: aggregates[:current_month_total],
      previous_month_total: aggregates[:previous_month_total],
      overall_total: aggregates[:overall_total],
      processing_count: aggregates[:processing_count],
      review_needed_count: aggregates[:review_needed_count],
      failed_count: aggregates[:failed_count],
      monthly_change_label: monthly_change[:label],
      monthly_change_icon: monthly_change[:icon],
      monthly_change_icon_class: monthly_change[:icon_class]
    }
  end

  def self.summary_aggregates_for(receipts, current_month_range, previous_month_range)
    row = receipts.reorder(nil).pick(
      Arel.sql("COUNT(*)"),
      Arel.sql(summary_sum_sql(amount_status_condition, :total_amount)),
      Arel.sql(summary_sum_sql("#{amount_status_condition} AND #{summary_range_condition(:purchased_at, current_month_range)}", :total_amount)),
      Arel.sql(summary_sum_sql("#{amount_status_condition} AND #{summary_range_condition(:purchased_at, previous_month_range)}", :total_amount)),
      Arel.sql(summary_count_sql(summary_status_condition("processing"))),
      Arel.sql(summary_count_sql(summary_status_condition("review_needed"))),
      Arel.sql(summary_count_sql(summary_status_condition("failed")))
    )
    row ||= []

    {
      receipts_count: row[0].to_i,
      overall_total: row[1].to_i,
      current_month_total: row[2].to_i,
      previous_month_total: row[3].to_i,
      processing_count: row[4].to_i,
      review_needed_count: row[5].to_i,
      failed_count: row[6].to_i
    }
  end
  private_class_method :summary_aggregates_for

  def self.summary_sum_sql(condition, column)
    "COALESCE(SUM(CASE WHEN #{condition} THEN #{summary_column(column)} ELSE 0 END), 0)"
  end
  private_class_method :summary_sum_sql

  def self.summary_count_sql(condition)
    "COALESCE(SUM(CASE WHEN #{condition} THEN 1 ELSE 0 END), 0)"
  end
  private_class_method :summary_count_sql

  def self.amount_status_condition
    "#{summary_column(:status)} IN (#{KPI_AMOUNT_STATUSES.map { |status| connection.quote(status) }.join(', ')})"
  end
  private_class_method :amount_status_condition

  def self.summary_status_condition(status)
    "#{summary_column(:status)} = #{connection.quote(status)}"
  end
  private_class_method :summary_status_condition

  def self.summary_range_condition(column, range)
    "#{summary_column(column)} BETWEEN #{connection.quote(range.begin)} AND #{connection.quote(range.end)}"
  end
  private_class_method :summary_range_condition

  def self.summary_column(column)
    "#{quoted_table_name}.#{connection.quote_column_name(column)}"
  end
  private_class_method :summary_column

  def self.category_summary_for(user, scope: nil)
    receipts = (scope || user.receipts).where(user_id: user.id).reorder(nil)
    category_expression = Arel.sql("COALESCE(NULLIF(receipt_items.category, ''), 'uncategorized')")

    rows = receipts
      .where(status: KPI_AMOUNT_STATUSES)
      .joins(:receipt_items)
      .group(category_expression)
      .pluck(
        category_expression,
        Arel.sql("COALESCE(SUM(receipt_items.line_total), 0)"),
        Arel.sql("COUNT(receipt_items.id)")
      )

    rows.map do |category, total_amount, item_count|
      {
        category: category,
        label: category_summary_label(category),
        total_amount: total_amount.to_i,
        item_count: item_count.to_i
      }
    end.sort_by { |entry| [ -entry[:total_amount], entry[:label] ] }
  end

  def self.monthly_change_summary(current_month_total, previous_month_total)
    current_total = current_month_total.to_i
    previous_total = previous_month_total.to_i

    return {
      label: I18n.t("dashboard.summary.amount.no_previous_month"),
      icon: "trending_flat",
      icon_class: "token-text-muted"
    } if previous_total.zero?

    change_rate = ((current_total - previous_total).to_d / previous_total * 100).round

    if change_rate.positive?
      {
        label: I18n.t("dashboard.summary.amount.monthly_change", value: "+#{change_rate}"),
        icon: "trending_up",
        icon_class: "token-text-error"
      }
    elsif change_rate.negative?
      {
        label: I18n.t("dashboard.summary.amount.monthly_change", value: change_rate.to_s),
        icon: "trending_down",
        icon_class: "token-text-success"
      }
    else
      {
        label: I18n.t("dashboard.summary.amount.monthly_change", value: "±0"),
        icon: "trending_flat",
        icon_class: "token-text-muted"
      }
    end
  end

  def self.category_summary_label(category)
    return I18n.t("receipts.item_fields.uncategorized") if category == "uncategorized"

    I18n.t("enums.receipt_item.category.#{category}", default: category)
  end

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
    Array(codes).map do |code|
      I18n.t("enums.receipt_item.review_reason.#{code}", default: code)
    end
  end

  def review_items
    receipt_items.select(&:needs_review)
  end

  def has_blocking_review_notes?
    blocking_review_reason_labels.any? || review_items.any?
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
    summary = self.class.summary_for(user)

    broadcast_replace_later_to(
      [ user, :receipts ],
      target: "receipts_summary",
      partial: "shared/receipts/summary_cards",
      locals: summary.merge(animate_on_connect: true)
    )
  ensure
    @summary_broadcast_needed = false
  end

  def broadcast_processing_flash
    return unless user&.push_notification_enabled?

    flash_type, message = case status
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
