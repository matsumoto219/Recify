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

  OCR_ERROR_CODES = %w[
    ocr_unreadable
    ocr_timeout
    ocr_api_error
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
  has_many :receipt_items, dependent: :destroy
  has_many :receipt_payments, dependent: :destroy
  has_many :receipt_tax_details, dependent: :destroy
  has_one_attached :image

  accepts_nested_attributes_for :receipt_items, allow_destroy: true
  accepts_nested_attributes_for :receipt_payments, allow_destroy: false
  accepts_nested_attributes_for :receipt_tax_details, allow_destroy: false

  validates :payment_method, inclusion: { in: PAYMENT_METHODS }, allow_blank: true
  validates :status, presence: true, inclusion: { in: statuses.keys }

  # 合計金額数値と最小値指定
  validates :total_amount,
            presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            unless: :allow_partial_ocr_data?

  validates :store_name, presence: true, unless: :allow_partial_ocr_data?
  validates :store_name, length: { maximum: 100 }, allow_blank: true  # ストア名(MAX100文字)
  validates :memo, length: { maximum: 1000 }, allow_blank: true       # メモ(MAX1000文字)

  validate :validate_image_content_type
  validate :validate_image_file_size
  validate :validate_image_dimensions

  private

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

    metadata = image.blob.metadata || {}
    width = metadata["width"]
    height = metadata["height"]
    return if width.blank? || height.blank?

    if width < MIN_IMAGE_DIMENSION || height < MIN_IMAGE_DIMENSION
      errors.add(:image, :image_too_small)
      return
    end

    return if width <= MAX_IMAGE_DIMENSION && height <= MAX_IMAGE_DIMENSION

    errors.add(:image, :image_too_large)
  end

  def allow_partial_ocr_data?
    image.attached? && (
      uploaded? ||
      processing? ||
      review_needed? ||
      failed?
    )
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

    Analysis::ReceiptProcessingErrorMapper.map(processing_error_code)[:error_category]&.to_sym
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

    case error_category
    when :image_error
      "画像の読み込みに失敗しました。画像を変更して再試行するか、手動入力で続行してください。"
    when :ocr_error
      "OCR処理に失敗しました。画像を変更して再試行できます。手動入力で続行することも可能です。"
    when :ai_error
      "AI補完処理に失敗しました。画像を変更して再試行するか、OCR結果をもとに手動修正してください。"
    when :system_error
      "処理に失敗しました。時間をおいて再試行するか、手動で修正してください。"
    else
      "処理に失敗しました。時間をおいて再試行するか、手動で修正してください。"
    end
  end

  def processing_flash_messages
    return [] unless failed_with_error?

    [ processing_flash_message ]
  end
end
