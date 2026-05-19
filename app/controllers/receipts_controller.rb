class ReceiptsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_receipt, only: [ :show, :edit, :update, :destroy ]
  before_action :block_processing_receipt, only: [ :show, :edit, :update ]

  MAX_SEARCH_QUERY_LENGTH = 100
  SUSPICIOUS_SEARCH_PATTERN = /(--|;|\/\*|\*\/|\b(drop|delete|insert|update|alter|truncate|union|select)\b)/i

  def index
    @query = normalize_search_query(params[:q])
    log_suspicious_search_query(@query) if suspicious_search_query?(@query)
    receipts_scope = current_user.receipts.order(created_at: :desc)
    receipts_scope = receipts_scope.search(@query) if @query.present?

    @pagy, @receipts = pagy(:offset, receipts_scope, limit: 20)
    return if redirect_to_canonical_receipts_page_if_needed

    summary = Receipt.summary_for(current_user, scope: receipts_scope)

    @receipts_count = summary[:receipts_count]
    @current_month_total = summary[:current_month_total]
    @overall_total = summary[:overall_total]
    @processing_count = summary[:processing_count]
    @review_needed_count = summary[:review_needed_count]
    @failed_count = summary[:failed_count]
    @monthly_change_label = summary[:monthly_change_label]
    @monthly_change_icon = summary[:monthly_change_icon]
    @monthly_change_icon_class = summary[:monthly_change_icon_class]
  end

  def show
  end

  def select_input_method
    set_external_service_states
  end

  def new
    @receipt = current_user.receipts.new
    @receipt.receipt_items.build
  end

  def new_upload
    set_external_service_states
    @receipt = current_user.receipts.new
  end

  def upload
    set_external_service_states

    if ExternalServiceStatus.down?(:ocr)
      @receipt = current_user.receipts.new
      flash.now[:alert] = t("flash.receipts.ocr_unavailable")
      render :new_upload, status: :unprocessable_content
      return
    end

    if storage_quota_exceeded_for?(uploaded_receipt_image)
      @receipt = current_user.receipts.new
      @receipt.errors.add(:image, :storage_quota_exceeded)
      flash.now[:alert] = t("flash.storage.quota_exceeded")
      render :new_upload, status: :unprocessable_content
      return
    end

    @receipt = current_user.receipts.new(upload_receipt_params)
    @receipt.status = "processing"

    if @receipt.save
      Rails.logger.info("[ReceiptAnalysis] enqueue receipt_id=#{@receipt.id} user_id=#{current_user.id} image_attached=#{@receipt.image.attached?}")
      ReceiptAnalysisJob.perform_later(@receipt.id)

      redirect_to receipts_path, **temporary_notice_options(t("flash.receipts.enqueued"))
    else
      Rails.logger.warn(
        "[ReceiptUpload] failed user_id=#{current_user.id} errors=#{@receipt.errors.full_messages.join(', ')}"
      )
      flash.now[:alert] = @receipt.errors.full_messages
      render :new_upload, status: :unprocessable_content
    end
  end

  def create
    create_params = normalized_receipt_params.to_h
    @receipt = current_user.receipts.new

    apply_amount_calculation!(create_params, context: :manual)

    @receipt.assign_attributes(create_params)
    @receipt.status = "completed"

    if @receipt.save
      redirect_to receipts_path, **temporary_notice_options(t("flash.receipts.create"))
    else
      flash.now[:alert] = @receipt.errors.full_messages
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if storage_quota_exceeded_for?(uploaded_receipt_image, excluding_blob: existing_receipt_image_blob)
      @receipt.errors.add(:image, :storage_quota_exceeded)
      flash.now[:alert] = t("flash.storage.quota_exceeded")
      render :edit, status: :unprocessable_content
      return
    end

    update_params = normalized_receipt_params.to_h
    clear_review_flags_for_edited_items!(update_params)
    apply_amount_calculation!(update_params, context: :edit_save)
    clear_processing_error_after_manual_update!(update_params)

    if @receipt.update(update_params)
      redirect_to @receipt, **temporary_notice_options(t("flash.receipts.update"))
    else
      flash.now[:alert] = @receipt.errors.full_messages
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    @receipt.destroy
    redirect_to receipts_path, **temporary_notice_options(t("flash.receipts.destroy"))
  end

  private

  def set_receipt
    @receipt = current_user.receipts.find(params[:id])
  end

  def block_processing_receipt
    return unless @receipt.processing?

    redirect_to receipts_path, alert: t("flash.receipts.processing")
  end

  def set_external_service_states
    @ocr_state = ExternalServiceStatus.snapshot(:ocr)
    @ai_state = ExternalServiceStatus.snapshot(:ai)
  end

  def temporary_notice_options(message)
    return {} unless current_user&.push_notification_enabled?

    { notice: message }
  end

  def redirect_to_canonical_receipts_page_if_needed
    return false unless @pagy.count.positive?

    page_key = @pagy.options.fetch(:page_key, "page").to_s
    requested_page = params[page_key]
    return false if requested_page.blank?

    canonical_page = canonical_receipts_page(requested_page)
    return false if canonical_page.blank?

    redirect_to receipts_path(request.query_parameters.merge(page_key => canonical_page))
    true
  end

  def canonical_receipts_page(requested_page)
    requested_page_number = Integer(requested_page, exception: false)
    return 1 if requested_page_number.blank? || requested_page_number < 1
    return @pagy.last if @pagy.page > @pagy.last

    nil
  end

  def upload_receipt_params
    params.require(:receipt).permit(:image)
  end

  def uploaded_receipt_image
    params.dig(:receipt, :image)
  end

  def existing_receipt_image_blob
    @receipt.image.blob if @receipt&.image&.attached?
  end

  def storage_quota_exceeded_for?(uploaded_file, excluding_blob: nil)
    uploaded_file.present? &&
      !current_user.storage_can_add?(uploaded_file.size, excluding_blob: excluding_blob)
  end

  def receipt_params
    params.require(:receipt).permit(
      :store_name,
      :purchased_on,
      :purchased_time,
      :total_amount,
      :subtotal_amount,
      :tax_amount,
      :tax_rate,
      :payment_method,
      :memo,
      :image,
      :keep_image,
      :store_address,
      :store_phone_number,
      # NOTE: 以下は将来フォームから直接編集する場合の候補
      # :purchased_at,
      # :tip_amount,
      # :country_region,
      # :receipt_type,
      receipt_items_attributes: [
        :id,
        :confirmed_name,
        :category,
        :price,
        :quantity,
        :quantity_unit,
        :product_code,
        :tax_rate,
        :discount_rate,
        :line_total,
        :needs_review,
        :position_index,
        :_destroy,
        { review_reasons: [] }
      ]
      # NOTE: 以下は将来 nested attributes で直接編集する場合の候補
      # , receipt_payments_attributes: [
      #   :id,
      #   :method,
      #   :amount,
      #   :_destroy
      # ],
      # receipt_tax_details_attributes: [
      #   :id,
      #   :description,
      #   :amount,
      #   :rate,
      #   :net_amount,
      #   :_destroy
      # ]
    )
  end

  def normalized_receipt_params
    permitted = receipt_params.to_h.deep_dup

    purchased_on = permitted.delete("purchased_on")
    purchased_time = permitted.delete("purchased_time")

    permitted["purchased_at"] = build_purchased_at(purchased_on, purchased_time)
    normalize_receipt_item_tax_rates!(permitted)

    ActionController::Parameters.new(permitted).permit!
  end

  def build_purchased_at(purchased_on, purchased_time)
    return nil if purchased_on.blank?

    datetime_text = [ purchased_on, purchased_time.presence ].compact.join(" ")
    Time.zone.parse(datetime_text)
  rescue ArgumentError, TypeError
    nil
  end

  def normalize_receipt_item_tax_rates!(permitted)
    items_attributes = permitted["receipt_items_attributes"]
    return if items_attributes.blank?

    items_attributes.each_value do |item_attributes|
      raw_tax_rate = item_attributes["tax_rate"]
      item_attributes["tax_rate"] = normalize_tax_rate(raw_tax_rate)
    end
  end

  def normalize_tax_rate(raw_tax_rate)
    return nil if raw_tax_rate.blank?

    BigDecimal(raw_tax_rate.to_s) / 100
  rescue ArgumentError
    nil
  end

  def apply_amount_calculation!(permitted, context:)
    result = ReceiptAmountService.call(
      receipt: amount_receipt(permitted, context),
      receipt_items: amount_receipt_items(permitted),
      receipt_tax_details: amount_receipt_tax_details(context),
      context: context,
      tax_rounding_mode: :floor,
      discount_rounding_mode: :round
    )

    resolved = result[:resolved]
    permitted["subtotal_amount"] = resolved[:subtotal]
    permitted["tax_amount"] = resolved[:tax]
    permitted["total_amount"] = resolved[:total]
    permitted["tax_rate"] = resolved[:tax_rate]
    # 明細の quantity / line_total を計算結果で上書き（複数行対応）
    apply_item_totals!(permitted, result.dig(:computed, :items))
    permitted["receipt_tax_details_attributes"] = receipt_tax_detail_attributes(result[:tax_details])
  end

  def apply_item_totals!(permitted, calculated_items)
    items_attributes = permitted["receipt_items_attributes"]
    return if items_attributes.blank?

    calculated_items = Array(calculated_items)
    return if calculated_items.empty?

    # 有効な明細（_destroy でないもの）のみ対象に順序対応
    valid_item_attrs = items_attributes.values.reject do |item_attr|
      item_attr.blank? || ActiveModel::Type::Boolean.new.cast(item_attr["_destroy"])
    end

    valid_item_attrs.each_with_index do |item_attr, index|
      calc = calculated_items[index]
      next if calc.blank?

      quantity = calc[:quantity] || calc["quantity"]
      price = calc[:price] || calc["price"]
      line_total = calc[:line_total] || calc["line_total"]
      original_line_total = calculated_item_value(calc, :original_line_total)
      discount_amount = calculated_item_value(calc, :discount_amount)
      discount_rate = calculated_item_value(calc, :discount_rate)

      item_attr["quantity"] = quantity unless quantity.nil?
      item_attr["price"] = price unless price.nil?
      item_attr["line_total"] = line_total unless line_total.nil?
      item_attr["original_line_total"] = original_line_total unless original_line_total.nil?
      item_attr["discount_amount"] = discount_amount unless discount_amount.nil?
      item_attr["discount_rate"] = discount_rate if calculated_item_key?(calc, :discount_rate)
    end
  end

  def calculated_item_value(calculated_item, key)
    return calculated_item[key] if calculated_item.key?(key)

    calculated_item[key.to_s]
  end

  def calculated_item_key?(calculated_item, key)
    calculated_item.key?(key) || calculated_item.key?(key.to_s)
  end

  def receipt_tax_detail_attributes(tax_details)
    destroy_existing_receipt_tax_details + build_receipt_tax_detail_attributes(tax_details)
  end

  def clear_processing_error_after_manual_update!(permitted)
    return unless @receipt.has_processing_error?

    permitted["processing_error_code"] = nil
    permitted["processing_error_message"] = nil
    permitted["status"] = "completed" if @receipt.failed?
  end

  def destroy_existing_receipt_tax_details
    @receipt.receipt_tax_details.map do |tax_detail|
      {
        "id" => tax_detail.id,
        "_destroy" => "1"
      }
    end
  end

  def build_receipt_tax_detail_attributes(tax_details)
    Array(tax_details).map do |tax_detail|
      {
        "description" => tax_detail[:description],
        "amount" => tax_detail[:amount],
        "rate" => tax_detail[:rate],
        "net_amount" => tax_detail[:net_amount]
      }
    end
  end

  def amount_receipt_items(permitted)
    items_attributes = permitted["receipt_items_attributes"]
    return [] if items_attributes.blank?

    items_attributes.values.reject do |item_attributes|
      ActiveModel::Type::Boolean.new.cast(item_attributes["_destroy"])
    end
  end

  def amount_receipt(permitted, context)
    return permitted unless context == :edit_save
    return permitted unless @receipt&.persisted?

    existing_amounts = {
      "subtotal_amount" => @receipt.subtotal_amount,
      "tax_amount" => @receipt.tax_amount,
      "total_amount" => @receipt.total_amount,
      "tax_rate" => @receipt.tax_rate
    }

    existing_amounts.merge(permitted) do |_key, existing_value, permitted_value|
      permitted_value.presence || existing_value
    end
  end

  def amount_receipt_tax_details(context)
    return [] unless context == :edit_save
    return [] unless @receipt&.persisted?

    @receipt.receipt_tax_details.map do |tax_detail|
      {
        rate: tax_detail.rate,
        net_amount: tax_detail.net_amount,
        amount: tax_detail.amount,
        description: tax_detail.description
      }
    end
  end

  def clear_review_flags_for_edited_items!(permitted)
    items_attributes = permitted["receipt_items_attributes"]
    return if items_attributes.blank?

    existing_items = @receipt.receipt_items.index_by { |item| item.id.to_s }

    items_attributes.each_value do |item_attributes|
      next if ActiveModel::Type::Boolean.new.cast(item_attributes["_destroy"])

      item = existing_items[item_attributes["id"].to_s]
      next if item.blank?
      next unless review_clear_target_changed?(item, item_attributes)

      item_attributes["needs_review"] = false
      item_attributes["review_reasons"] = []
    end
  end

  def review_clear_target_changed?(item, item_attributes)
    review_clear_target_fields.any? do |field|
      item_value = normalize_review_compare_value(item.public_send(field), field)
      param_value = normalize_review_compare_value(item_attributes[field.to_s], field)

      item_value != param_value
    end
  end

  def review_clear_target_fields
    %i[
      confirmed_name
      category
      price
      quantity
      quantity_unit
      product_code
      tax_rate
      line_total
    ]
  end

  def normalize_review_compare_value(value, field)
    return nil if value.blank?

    case field
    when :price, :quantity, :tax_rate, :line_total
      BigDecimal(value.to_s)
    else
      value.to_s
    end
  rescue ArgumentError
    nil
  end

  def normalize_search_query(value)
    value.to_s.strip.first(MAX_SEARCH_QUERY_LENGTH)
  end

  def suspicious_search_query?(query)
    query.present? && query.match?(SUSPICIOUS_SEARCH_PATTERN)
  end

  def log_suspicious_search_query(query)
    Rails.logger.warn(
      "[ReceiptSearch] suspicious_query user_id=#{current_user.id} query=#{query.inspect}"
    )
  end
end
