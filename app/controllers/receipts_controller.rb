class ReceiptsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_receipt, only: [ :show, :edit, :update, :destroy ]
  before_action :block_processing_receipt, only: [ :show, :edit, :update ]

  MAX_SEARCH_QUERY_LENGTH = 100
  SUSPICIOUS_SEARCH_PATTERN = /(--|;|\/\*|\*\/|\b(drop|delete|insert|update|alter|truncate|union|select)\b)/i

  def index
    @query = normalize_search_query(params[:q])
    log_suspicious_search_query(@query) if suspicious_search_query?(@query)
    @receipts = current_user.receipts.order(created_at: :desc)
    @receipts = @receipts.search(@query) if @query.present?
    summary = Receipt.summary_for(current_user, scope: @receipts)

    @receipts_count = summary[:receipts_count]
    @current_month_total = summary[:current_month_total]
    @overall_total = summary[:overall_total]
    @processing_count = summary[:processing_count]
    @review_needed_count = summary[:review_needed_count]
    @monthly_change_label = summary[:monthly_change_label]
    @monthly_change_icon = summary[:monthly_change_icon]
    @monthly_change_icon_class = summary[:monthly_change_icon_class]
  end

  def show
  end

  def select_input_method
  end

  def new
    @receipt = current_user.receipts.new
    @receipt.receipt_items.build
  end

  def new_upload
    @receipt = current_user.receipts.new
  end

  def upload
    @receipt = current_user.receipts.new(upload_receipt_params)
    @receipt.status = "processing"

    if @receipt.save
      Rails.logger.info("[ReceiptAnalysis] enqueue receipt_id=#{@receipt.id} user_id=#{current_user.id} image_attached=#{@receipt.image.attached?}")
      ReceiptAnalysisJob.perform_later(@receipt.id)

      redirect_to receipts_path, notice: t("flash.receipts.enqueued")
    else
      Rails.logger.warn(
        "[ReceiptUpload] failed user_id=#{current_user.id} errors=#{@receipt.errors.full_messages.join(', ')}"
      )
      flash.now[:alert] = @receipt.errors.full_messages
      render :new_upload, status: :unprocessable_entity
    end
  end

  def create
    @receipt = current_user.receipts.new(normalized_receipt_params)
    @receipt.status = "completed"

    if @receipt.save
      redirect_to receipts_path, notice: t("flash.receipts.create")
    else
      flash.now[:alert] = @receipt.errors.full_messages
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    update_params = normalized_receipt_params.to_h
    clear_review_flags_for_edited_items!(update_params)
    apply_amount_calculation!(update_params)

    if @receipt.update(update_params)
      redirect_to @receipt, notice: t("flash.receipts.update")
    else
      flash.now[:alert] = @receipt.errors.full_messages
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @receipt.destroy
    redirect_to receipts_path, notice: t("flash.receipts.destroy")
  end

  private

  def set_receipt
    @receipt = current_user.receipts.find(params[:id])
  end

  def block_processing_receipt
    return unless @receipt.processing?

    redirect_to receipts_path, alert: t("flash.receipts.processing")
  end

  def upload_receipt_params
    params.require(:receipt).permit(:image)
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

    tax_rate = BigDecimal(raw_tax_rate.to_s)
    tax_rate > 1 ? tax_rate / 100 : tax_rate
  rescue ArgumentError
    nil
  end

  def apply_amount_calculation!(permitted)
    result = ReceiptAmountService.call(
      receipt: permitted,
      receipt_items: amount_receipt_items(permitted),
      receipt_tax_details: [],
      context: :edit_save
    )

    resolved = result[:resolved]
    permitted["subtotal_amount"] = resolved[:subtotal]
    permitted["tax_amount"] = resolved[:tax]
    permitted["total_amount"] = resolved[:total]
    permitted["tax_rate"] = resolved[:tax_rate]
    permitted["receipt_tax_details_attributes"] = receipt_tax_detail_attributes(result[:tax_details])
  end

  def receipt_tax_detail_attributes(tax_details)
    destroy_existing_receipt_tax_details + build_receipt_tax_detail_attributes(tax_details)
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
