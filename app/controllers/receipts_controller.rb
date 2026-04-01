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
    image_attached = receipt_params[:image].present?
    @receipt = current_user.receipts.new(receipt_params)
    @receipt.status = image_attached ? "processing" : "uploaded"

    if @receipt.save
      Rails.logger.info("[ReceiptAnalysis] create start receipt_id=#{@receipt.id} user_id=#{current_user.id} image_attached=#{image_attached}") if image_attached
      analysis_success = image_attached ? apply_analysis(@receipt) : true

      if analysis_success
        redirect_to @receipt, notice: t("flash.receipts.create")
      else
        redirect_to @receipt, alert: t("flash.receipts.analysis_failed")
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    image_changed = receipt_params[:image].present?

    if @receipt.update(receipt_params)
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
      elsif @receipt.receipt_items.exists?
        @receipt.update!(status: "completed")
      end

      if analysis_success
        redirect_to @receipt, notice: t("flash.receipts.update")
      else
        redirect_to @receipt, alert: t("flash.receipts.analysis_failed")
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
      :total_amount,
      :payment_method,
      :memo,
      :image,
      receipt_items_attributes: [
        :id,
        :confirmed_name,
        :category,
        :price,
        :quantity,
        :line_total,
        :needs_review
      ]
    )
  end

  # 本実装では ReceiptAnalysisService に処理を集約していく
  def apply_analysis(receipt)
    result = ReceiptAnalysisService.call(receipt)
    Rails.logger.info("[ReceiptAnalysis] processing receipt_id=#{receipt.id} status=#{receipt.status}")

    receipt.update!(
      analysis_result_params(result).merge(
        status: "review_needed",
        processing_error_message: nil,
        ocr_completed_at: Time.current
      )
    )

    rebuild_receipt_items(receipt, result[:items])
    Rails.logger.info(
      "[ReceiptAnalysis] success receipt_id=#{receipt.id} status=#{receipt.status} items_count=#{result[:items].size} error_code=#{receipt.processing_error_code.inspect}"
    )
    true
  rescue ReceiptAnalysisService::AnalysisError => e
    receipt.update!(
      status: "failed",
      processing_error_code: e.error_code,
      processing_error_message: e.message
    )
    Rails.logger.error(
      "[ReceiptAnalysis] failed receipt_id=#{receipt.id} status=#{receipt.status} error_code=#{receipt.processing_error_code} error_class=#{e.class} message=#{e.message}"
    )
    false
  rescue StandardError => e
    receipt.update!(
      status: "failed",
      processing_error_code: "unexpected_error",
      processing_error_message: e.message
    )
    Rails.logger.error(
      "[ReceiptAnalysis] failed receipt_id=#{receipt.id} status=#{receipt.status} error_code=#{receipt.processing_error_code} error_class=#{e.class} message=#{e.message}"
    )
    false
  end

  def analysis_result_params(result)
    {
      store_name: result[:store_name],
      purchased_at: result[:purchased_at],
      total_amount: result[:total_amount],
      payment_method: result[:payment_method]
    }
  end

  def rebuild_receipt_items(receipt, items)
    receipt.receipt_items.destroy_all

    items.each do |item|
      receipt.receipt_items.create!(item)
    end
  end
end
