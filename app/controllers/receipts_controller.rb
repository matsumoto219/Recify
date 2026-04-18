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
    image_changed = normalized_receipt_params[:image].present?

    if @receipt.update(normalized_receipt_params)
      analysis_success = true

      if image_changed
        @receipt.update!(
          status: "processing",
          processing_error_code: nil,
          processing_error_message: nil,
          ocr_completed_at: nil
        )
        Rails.logger.info("[ReceiptAnalysis] update start receipt_id=#{@receipt.id} user_id=#{current_user.id} image_changed=#{image_changed}")
        analysis_success = apply_analysis(@receipt)
      end

      if analysis_success
        redirect_to @receipt, notice: t("flash.receipts.update")
      else
        flash[@receipt.processing_flash_type] = @receipt.processing_flash_messages
        redirect_to @receipt
      end
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
      :purchased_at,
      :purchased_on,
      :purchased_time,
      :total_amount,
      :payment_method,
      :memo,
      :image,
      :keep_image,
      :store_address,
      :store_phone_number,
      # NOTE: 以下は将来フォームから直接編集する場合の候補
      # :subtotal_amount,
      # :tax_amount,
      # :tax_rate,
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

    built_purchased_at = build_purchased_at(purchased_on, purchased_time)
    permitted["purchased_at"] = built_purchased_at if built_purchased_at.present?

    ActionController::Parameters.new(permitted).permit!
  end

  def build_purchased_at(purchased_on, purchased_time)
    return nil if purchased_on.blank?

    if purchased_time.present?
      Time.zone.parse("#{purchased_on} #{purchased_time}")
    else
      Time.zone.parse(purchased_on.to_s)
    end
  rescue ArgumentError, TypeError
    nil
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
    mapped = ReceiptProcessingErrorMapper.map(error_code)

    receipt.update!(
      status: "failed",
      processing_error_code: mapped[:error_code],
      processing_error_message: message
    )
  end
end
