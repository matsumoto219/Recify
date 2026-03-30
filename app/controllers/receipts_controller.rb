class ReceiptsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_receipt, only: [ :show, :edit, :update, :destroy ]

  def index
    @receipts = current_user.receipts.order(created_at: :desc)
  end

  def show
  end

  def new
    @receipt = current_user.receipts.new
  end

  def create
    @receipt = current_user.receipts.new(receipt_params)

    if @receipt.save
      redirect_to @receipt, notice: t("flash.receipts.create")
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @receipt.update(receipt_params)
      apply_dummy_analysis(@receipt) if @receipt.image.attached?
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
      :purchased_at,
      :total_amount,
      :payment_method,
      :status,
      :memo,
      :image
    )
  end

  def apply_dummy_analysis(receipt)
    result = AiReceiptService.call(receipt)

    receipt.update!(
      store_name: result[:store_name],
      purchased_at: result[:purchased_at],
      total_amount: result[:total_amount],
      payment_method: result[:payment_method],
      status: result[:status]
    )

    receipt.receipt_items.destroy_all

    result[:items].each do |item|
      receipt.receipt_items.create!(item)
    end
  end
end
