class ReceiptsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_receipt, only: [ :show, :edit, :update, :destroy ]

  def index
    @receipts = current_user.receipts.order(created_at: :desc)
  end

  def show
  end

  def select_input_method
  end

  def new
    @receipt = current_user.receipts.new
    @mode = params[:mode]

    if @mode == "manual"
      @receipt.receipt_items.build
    end
  end

  def create
    image_attached = normalized_receipt_params[:image].present?
    @receipt = current_user.receipts.new(normalized_receipt_params)
    @receipt.status = image_attached ? "processing" : "uploaded"

    if @receipt.save
      Rails.logger.info("[ReceiptAnalysis] create start receipt_id=#{@receipt.id} user_id=#{current_user.id} image_attached=#{image_attached}") if image_attached
      analysis_success = image_attached ? apply_analysis(@receipt) : true

      if analysis_success
        redirect_to receipts_path, notice: t("flash.receipts.create")
      else
        flash[@receipt.processing_flash_type] = @receipt.processing_flash_messages
        redirect_to receipts_path
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    update_params = normalized_receipt_params.to_h
    apply_amount_calculation!(update_params)

    if @receipt.update(update_params)
      redirect_to @receipt, notice: t("flash.receipts.update")
    else
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
        :_destroy
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

  def apply_analysis(receipt)
    ReceiptAnalysisService.call(receipt)
    receipt.reload

    Rails.logger.info(
      "[ReceiptAnalysis] controller_apply_analysis receipt_id=#{receipt.id} status=#{receipt.status} error_code=#{receipt.processing_error_code.inspect}"
    )

    !receipt.failed?
  rescue StandardError => e
    fail_receipt!(receipt, "unexpected_error", e.message)
    Rails.logger.error(
      "[ReceiptAnalysis] controller_apply_analysis_failed receipt_id=#{receipt.id} status=#{receipt.status} error_code=#{receipt.processing_error_code} error_class=#{e.class} message=#{e.message}"
    )
    false
  end

  def fail_receipt!(receipt, error_code, message)
    mapped = ::Analysis::ReceiptProcessingErrorMapper.map(error_code)

    receipt.update!(
      status: "failed",
      processing_error_code: mapped[:error_code],
      processing_error_message: message
    )
  end
end
