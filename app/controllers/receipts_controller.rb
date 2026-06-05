class ReceiptsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_receipt, only: [ :show, :edit, :update, :destroy ]
  before_action :block_processing_receipt, only: [ :show, :edit, :update ]
  rate_limit to: 10,
             within: 1.hour,
             by: :rate_limit_current_user_key,
             with: :rate_limit_exceeded,
             store: ApplicationController::RateLimitStore,
             name: "receipt-upload/user",
             only: :upload,
             if: :rate_limit_signed_in?

  MAX_SEARCH_QUERY_LENGTH = 100
  SUSPICIOUS_SEARCH_PATTERN = /(--|;|\/\*|\*\/|\b(drop|delete|insert|update|alter|truncate|union|select)\b)/i

  def index
    @query = normalize_search_query(params[:q])
    log_suspicious_search_query(@query) if suspicious_search_query?(@query)

    search_validation = ReceiptSearch.validate_query(@query)
    unless search_validation.valid?
      render_invalid_search_query
      return
    end

    prepare_receipt_index_query(current_user.receipts)
    receipts_scope = @receipt_index_query.scope

    @pagy, @receipts = pagy(:offset, receipts_scope, limit: @per_page)
    return if redirect_to_canonical_receipts_page_if_needed

    assign_receipts_index_summary(receipts_scope)
    assign_receipt_index_count_summary
  end

  def show
  end

  def select_input_method
    set_external_service_states
  end

  def new
    @receipt = current_user.receipts.new
    @receipt.receipt_items.build
    prepare_receipt_form_presenter
  end

  def new_upload
    set_external_service_states
    @receipt = current_user.receipts.new
    prepare_upload_page_presenter
  end

  def upload
    set_external_service_states
    prepare_upload_page_presenter

    if ExternalServices.down?(:ocr)
      @receipt = current_user.receipts.new
      flash.now[:alert] = t("flash.receipts.ocr_unavailable")
      render :new_upload, status: :unprocessable_content, formats: :html
      return
    end

    if batch_upload_requested?
      handle_batch_upload
      return
    end

    if storage_quota_exceeded_for?(uploaded_receipt_image)
      @receipt = current_user.receipts.new
      @receipt.errors.add(:image, :storage_quota_exceeded)
      flash.now[:alert] = t("flash.storage.quota_exceeded")
      render :new_upload, status: :unprocessable_content, formats: :html
      return
    end

    @receipt = current_user.receipts.new(
      upload_receipt_params.merge(keep_image: current_user.effective_keep_receipt_images)
    )
    @receipt.status = "processing"

    saved = false

    begin
      ActiveRecord::Base.transaction do
        consume_single_upload_limit!
        saved = @receipt.save
        raise ActiveRecord::Rollback unless saved
      end
    rescue Usage::LimitExceeded
      render_upload_usage_limit_exceeded
      return
    end

    if saved
      enqueue_analysis_job(@receipt, source: "upload", requested_by_user: current_user)

      redirect_to receipts_path, **temporary_notice_options(t("flash.receipts.enqueued"))
    else
      Rails.logger.warn(
        "[ReceiptUpload] failed user_id=#{current_user.id} errors=#{@receipt.errors.full_messages.join(', ')}"
      )
      flash.now[:alert] = @receipt.errors.full_messages
      render :new_upload, status: :unprocessable_content, formats: :html
    end
  end

  def create
    rebuild_blank_item_row_after_failure = blank_new_receipt_item_rows_submitted?
    rebuild_blank_adjustment_row_after_failure = blank_new_receipt_adjustment_rows_submitted?
    create_params = normalized_receipt_params.to_h
    @receipt = current_user.receipts.new

    amount_result = apply_amount_calculation!(create_params, context: :manual)
    create_params["review_reasons"] = manual_update_blocking_review_reasons(amount_result)
    apply_current_image_retention_snapshot!(
      create_params,
      purge_eligible: create_params["image"].present?
    )

    @receipt.assign_attributes(create_params)
    @receipt.status = create_params["review_reasons"].empty? ? "completed" : "review_needed"

    if manual_receipt_items_missing?(create_params, context: :manual)
      prepare_manual_receipt_items_missing_error!(create_params)
      build_receipt_item_row_for_render if rebuild_blank_item_row_after_failure && @receipt.receipt_items.empty?
      build_receipt_adjustment_row_for_render if rebuild_blank_adjustment_row_after_failure
      prepare_receipt_form_presenter
      flash.now[:alert] = @receipt.errors.full_messages
      render :new, status: :unprocessable_content, formats: :html
      return
    end

    saved = false

    begin
      ActiveRecord::Base.transaction do
        if @receipt.valid?
          consume_manual_receipt_limit!
          saved = @receipt.save
        end

        raise ActiveRecord::Rollback unless saved
      end
    rescue Usage::LimitExceeded
      render_manual_receipt_usage_limit_exceeded(
        rebuild_blank_item_row_after_failure: rebuild_blank_item_row_after_failure,
        rebuild_blank_adjustment_row_after_failure: rebuild_blank_adjustment_row_after_failure
      )
      return
    end

    if saved
      redirect_to receipts_path, **temporary_notice_options(t("flash.receipts.create"))
    else
      replace_manual_amount_errors!(create_params)
      build_receipt_item_row_for_render if rebuild_blank_item_row_after_failure && @receipt.receipt_items.empty?
      build_receipt_adjustment_row_for_render if rebuild_blank_adjustment_row_after_failure
      prepare_receipt_form_presenter
      flash.now[:alert] = @receipt.errors.full_messages
      render :new, status: :unprocessable_content, formats: :html
    end
  end

  def edit
    prepare_receipt_form_presenter
  end

  def update
    rebuild_blank_adjustment_row_after_failure = blank_new_receipt_adjustment_rows_submitted?

    if storage_quota_exceeded_for?(uploaded_receipt_image, excluding_blob: existing_receipt_image_blob)
      @receipt.errors.add(:image, :storage_quota_exceeded)
      prepare_receipt_form_presenter
      flash.now[:alert] = t("flash.storage.quota_exceeded")
      render :edit, status: :unprocessable_content, formats: :html
      return
    end

    update_params = normalized_receipt_params.to_h
    if uploaded_receipt_image.present?
      apply_current_image_retention_snapshot!(update_params, purge_eligible: true)
    end
    clear_review_flags_for_edited_items!(update_params)
    amount_result = apply_amount_calculation!(update_params, context: :edit_save)
    rebuild_review_state_after_manual_update!(update_params, amount_result)
    clear_processing_error_after_manual_update!(update_params)

    if manual_receipt_items_missing?(update_params, context: :edit_save)
      @receipt.assign_attributes(update_params)
      prepare_manual_receipt_items_missing_error!(update_params)
      build_receipt_adjustment_row_for_render if rebuild_blank_adjustment_row_after_failure
      prepare_receipt_form_presenter
      flash.now[:alert] = @receipt.errors.full_messages
      render :edit, status: :unprocessable_content, formats: :html
      return
    end

    if @receipt.update(update_params)
      purge_receipt_image_if_requested!
      redirect_to @receipt, **temporary_notice_options(t("flash.receipts.update"))
    else
      build_receipt_adjustment_row_for_render if rebuild_blank_adjustment_row_after_failure
      prepare_receipt_form_presenter
      flash.now[:alert] = @receipt.errors.full_messages
      render :edit, status: :unprocessable_content, formats: :html
    end
  end

  def destroy
    @receipt.destroy
    redirect_to receipts_path, **temporary_notice_options(t("flash.receipts.destroy"))
  end

  private

  def set_receipt
    @receipt = current_user.receipts.find_by!(public_id: params[:public_id])
  end

  def prepare_receipt_form_presenter
    @receipt_form_presenter = ReceiptFormPresenter.new(receipt: @receipt)
  end

  def prepare_upload_page_presenter
    @upload_page_presenter = Receipts::UploadPagePresenter.new(
      user: current_user,
      ocr_state: @ocr_state,
      ai_state: @ai_state
    )
  end

  def prepare_receipt_index_query(scope)
    @receipt_index_query = ReceiptSearch.index_query(
      scope: scope,
      query: @query,
      sort: params[:sort],
      per_page: params[:per_page]
    )
    @sort = @receipt_index_query.sort
    @per_page = @receipt_index_query.per_page
    @receipt_index_params = @receipt_index_query.sanitized_params
    @receipt_search_hidden_fields = @receipt_index_params.except(:q)
  end

  def assign_receipt_index_count_summary
    total_count = @pagy.count
    offset = (@pagy.page - 1) * @per_page

    @receipt_index_count_summary = {
      total: total_count,
      start: total_count.zero? ? 0 : offset + 1,
      finish: [ offset + @receipts.size, total_count ].min
    }
  end

  def block_processing_receipt
    return unless @receipt.processing?

    redirect_to receipts_path, alert: t("flash.receipts.processing")
  end

  def set_external_service_states
    @ocr_state = ExternalServices.snapshot(:ocr)
    @ai_state = ExternalServices.snapshot(:ai)
  end

  def enqueue_analysis_job(receipt, source:, requested_by_user:)
    result = ReceiptAnalysisRuns.start(
      receipt: receipt,
      source: source,
      requested_by_user: requested_by_user
    )

    unless result.created?
      Rails.logger.info(
        "[ReceiptAnalysis] skip_enqueue_existing_run receipt_id=#{receipt.id} run_id=#{result.run.id} user_id=#{requested_by_user.id}"
      )
      return
    end

    Rails.logger.info(
      "[ReceiptAnalysis] enqueue receipt_id=#{receipt.id} run_id=#{result.run.id} user_id=#{requested_by_user.id} image_attached=#{receipt.image.attached?}"
    )
    unless consume_ocr_job_limit_for!(result.run, requested_by_user)
      Rails.logger.info(
        "[ReceiptAnalysis] blocked_enqueue_usage_limit receipt_id=#{receipt.id} run_id=#{result.run.id} user_id=#{requested_by_user.id}"
      )
      return
    end

    ReceiptOcrJob.perform_later(run_id: result.run.id)
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

    redirect_to receipts_path(@receipt_index_query.pagination_params.merge(page_key => canonical_page))
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

  def batch_upload_requested?
    uploaded_receipt_images.any?
  end

  def uploaded_receipt_images
    Array(params.dig(:receipt, :images)).compact_blank
  end

  def uploaded_receipt_image
    params.dig(:receipt, :image)
  end

  def handle_batch_upload
    result = ReceiptBatchUploadService.call(
      user: current_user,
      files: uploaded_receipt_images
    )
    @receipt = current_user.receipts.new

    if result.success?
      notice_message =
        if result.count == 1
          t("flash.receipts.enqueued")
        else
          t("flash.receipts.batch_enqueued", count: result.count)
        end

      redirect_to receipts_path, **temporary_notice_options(notice_message)
    else
      Rails.logger.warn(
        "[ReceiptBatchUpload] failed user_id=#{current_user.id} errors=#{result.errors.join(', ')}"
      )
      flash.now[:alert] = result.errors
      render :new_upload, status: :unprocessable_content, formats: :html
    end
  end

  def existing_receipt_image_blob
    @receipt.image.blob if @receipt&.image&.attached?
  end

  def storage_quota_exceeded_for?(uploaded_file, excluding_blob: nil)
    uploaded_file.present? &&
      !current_user.storage_can_add?(uploaded_file.size, excluding_blob: excluding_blob)
  end

  def consume_single_upload_limit!
    Usage.consume_receipt_upload!(user: current_user)
  end

  def consume_manual_receipt_limit!
    Usage.consume_manual_receipt!(user: current_user)
  end

  def render_upload_usage_limit_exceeded
    @receipt = current_user.receipts.new
    flash.now[:alert] = t("flash.usage_limits.uploads_exceeded")
    render :new_upload, status: :unprocessable_content, formats: :html
  end

  def render_manual_receipt_usage_limit_exceeded(rebuild_blank_item_row_after_failure:, rebuild_blank_adjustment_row_after_failure:)
    build_receipt_item_row_for_render if rebuild_blank_item_row_after_failure && @receipt.receipt_items.empty?
    build_receipt_adjustment_row_for_render if rebuild_blank_adjustment_row_after_failure
    prepare_receipt_form_presenter
    flash.now[:alert] = t("flash.usage_limits.manual_receipts_exceeded")
    render :new, status: :unprocessable_content, formats: :html
  end

  def consume_ocr_job_limit_for!(run, user)
    Usage.consume_ocr_job!(user: user)
    true
  rescue Usage::LimitExceeded
    Usage.mark_analysis_run_blocked!(run: run, stage: "ocr")
    false
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
      :remove_image,
      :store_address,
      :store_phone_number,
      # NOTE: purchased_at は purchased_on / purchased_time に分けて編集する。
      # 以下は保存済みだが、一般ユーザー編集フォームには未開放の項目。
      # :tip_amount,
      # :country_region,
      # :receipt_type,
      # :currency_code,
      # :store_address_components,
      receipt_items_attributes: [
        :id,
        :confirmed_name,
        :category,
        :price,
        :quantity,
        :quantity_unit,
        # ProductCode は保存/permit済みだが、UI入力欄はまだ出していない。
        :product_code,
        :tax_rate,
        :discount_rate,
        :line_total,
        :needs_review,
        :position_index,
        :_destroy,
        { review_reasons: [] }
      ],
      receipt_adjustments_attributes: [
        :id,
        :kind,
        :label,
        :amount,
        :sign,
        :tax_rate,
        :position_index,
        :_destroy
      ]
      # NOTE: receipt_payments は保存されるがUI未活用。
      # receipt_tax_details は表示/金額計算に使い、ユーザー入力ではなく再計算結果として保存する。
      # 以下は将来 nested attributes で直接編集する場合の候補。
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
    permitted.delete("remove_image")

    purchased_on = permitted.delete("purchased_on")
    purchased_time = permitted.delete("purchased_time")

    permitted["purchased_at"] = build_purchased_at(purchased_on, purchased_time)
    normalize_receipt_item_tax_rates!(permitted)
    normalize_receipt_adjustment_attributes!(permitted)
    prune_blank_new_receipt_items!(permitted)
    prune_blank_new_receipt_adjustments!(permitted)

    ActionController::Parameters.new(permitted).permit!
  end

  def remove_image_requested?
    ActiveModel::Type::Boolean.new.cast(params.dig(:receipt, :remove_image))
  end

  def purge_receipt_image_if_requested!
    return unless remove_image_requested?
    return if uploaded_receipt_image.present?
    return unless @receipt.image.attached?

    Storage.purge_attachment(@receipt.image)
    @receipt.mark_image_purged!(reason: Receipt::IMAGE_PURGED_REASON_MANUAL_DELETE)
  end

  def apply_current_image_retention_snapshot!(attributes, purge_eligible:)
    keep_image = current_user.effective_keep_receipt_images

    attributes["keep_image"] = keep_image
    attributes["image_purge_eligible_at"] = !keep_image && purge_eligible ? Time.current : nil
    attributes["image_purged_at"] = nil
    attributes["image_purged_reason"] = nil
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

  def normalize_receipt_adjustment_attributes!(permitted)
    adjustments_attributes = permitted["receipt_adjustments_attributes"]
    return if adjustments_attributes.blank?

    adjustments_attributes.each_value do |adjustment_attributes|
      adjustment_attributes["tax_rate"] = normalize_tax_rate(adjustment_attributes["tax_rate"])
      adjustment_attributes["sign"] = manual_adjustment_sign(
        kind: adjustment_attributes["kind"],
        requested_sign: adjustment_attributes["sign"]
      )
      adjustment_attributes["source"] = "manual"
      adjustment_attributes["needs_review"] = false
      adjustment_attributes["review_reasons"] = []
    end
  end

  def manual_adjustment_sign(kind:, requested_sign:)
    kind = kind.to_s
    requested_sign = requested_sign.to_s

    if kind == "other"
      return requested_sign if ReceiptAdjustment::SIGNS.include?(requested_sign)

      return "surcharge"
    end

    ReceiptAdjustment.default_sign_for(kind)
  end

  def prune_blank_new_receipt_items!(permitted)
    items_attributes = permitted["receipt_items_attributes"]
    return if items_attributes.blank?

    items_attributes.delete_if do |_index, item_attributes|
      blank_new_receipt_item_attributes?(item_attributes)
    end

    permitted.delete("receipt_items_attributes") if items_attributes.empty?
  end

  def prune_blank_new_receipt_adjustments!(permitted)
    adjustments_attributes = permitted["receipt_adjustments_attributes"]
    return if adjustments_attributes.blank?

    adjustments_attributes.delete_if do |_index, adjustment_attributes|
      blank_new_receipt_adjustment_attributes?(adjustment_attributes)
    end

    permitted.delete("receipt_adjustments_attributes") if adjustments_attributes.empty?
  end

  def blank_new_receipt_item_attributes?(item_attributes)
    return false if item_attributes["id"].present?
    return false if ActiveModel::Type::Boolean.new.cast(item_attributes["_destroy"])

    !receipt_item_meaningful_input?(item_attributes)
  end

  def receipt_item_meaningful_input?(item_attributes)
    return true if %w[confirmed_name category product_code].any? { |field| item_attributes[field].present? }
    return true if Array(item_attributes["review_reasons"]).reject(&:blank?).present?
    return true if numeric_input_present?(item_attributes["price"])
    return true if positive_numeric_input?(item_attributes["line_total"])
    return true if positive_numeric_input?(item_attributes["tax_rate"])
    return true if positive_numeric_input?(item_attributes["discount_rate"])

    false
  end

  def blank_new_receipt_adjustment_attributes?(adjustment_attributes)
    return false if adjustment_attributes["id"].present?
    return false if ActiveModel::Type::Boolean.new.cast(adjustment_attributes["_destroy"])

    !receipt_adjustment_meaningful_input?(adjustment_attributes)
  end

  def receipt_adjustment_meaningful_input?(adjustment_attributes)
    return true if adjustment_attributes["label"].present?
    return true if numeric_input_present?(adjustment_attributes["amount"])
    return true if positive_numeric_input?(adjustment_attributes["tax_rate"])

    false
  end

  def numeric_input_present?(value)
    !value.nil? && value.to_s.strip != ""
  end

  def positive_numeric_input?(value)
    return false unless numeric_input_present?(value)

    BigDecimal(value.to_s).positive?
  rescue ArgumentError
    false
  end

  def blank_new_receipt_item_rows_submitted?
    item_attribute_values = submitted_receipt_item_attribute_values
    return false if item_attribute_values.blank?

    item_attribute_values.all? do |item_attributes|
      next false unless item_attributes.respond_to?(:stringify_keys)

      blank_new_receipt_item_attributes?(item_attributes.stringify_keys)
    end
  end

  def blank_new_receipt_adjustment_rows_submitted?
    adjustment_attribute_values = submitted_receipt_adjustment_attribute_values
    return false if adjustment_attribute_values.blank?

    adjustment_attribute_values.any? do |adjustment_attributes|
      next false unless adjustment_attributes.respond_to?(:stringify_keys)

      blank_new_receipt_adjustment_attributes?(adjustment_attributes.stringify_keys)
    end
  end

  def submitted_receipt_item_attribute_values
    items_attributes = params.dig(:receipt, :receipt_items_attributes)
    return [] if items_attributes.blank?

    values =
      if items_attributes.respond_to?(:values)
        items_attributes.values
      else
        Array(items_attributes)
      end

    values.map do |item_attributes|
      if item_attributes.respond_to?(:to_unsafe_h)
        item_attributes.to_unsafe_h
      elsif item_attributes.respond_to?(:to_h)
        item_attributes.to_h
      else
        item_attributes
      end
    end
  end

  def submitted_receipt_adjustment_attribute_values
    adjustments_attributes = params.dig(:receipt, :receipt_adjustments_attributes)
    return [] if adjustments_attributes.blank?

    values =
      if adjustments_attributes.respond_to?(:values)
        adjustments_attributes.values
      else
        Array(adjustments_attributes)
      end

    values.map do |adjustment_attributes|
      if adjustment_attributes.respond_to?(:to_unsafe_h)
        adjustment_attributes.to_unsafe_h
      elsif adjustment_attributes.respond_to?(:to_h)
        adjustment_attributes.to_h
      else
        adjustment_attributes
      end
    end
  end

  def replace_manual_amount_errors!(permitted)
    return unless permitted["total_amount"].blank?
    return if @receipt.errors[:total_amount].blank?

    @receipt.errors.delete(:total_amount)
    @receipt.errors.add(:base, manual_amount_error_message(permitted))
  end

  def manual_amount_error_message(permitted)
    if amount_receipt_items(permitted).empty?
      t("receipts.form.errors.items_required")
    else
      t("receipts.form.errors.item_amount_required")
    end
  end

  def build_receipt_item_row_for_render
    @receipt.receipt_items.build
  end

  def build_receipt_adjustment_row_for_render
    @receipt.receipt_adjustments.build(kind: "delivery_fee", sign: "surcharge", source: "manual")
  end

  def manual_receipt_items_missing?(permitted, context:)
    if context == :edit_save && permitted["receipt_items_attributes"].blank?
      return false
    end

    amount_receipt_items(permitted).empty?
  end

  def prepare_manual_receipt_items_missing_error!(permitted)
    @receipt.valid?
    replace_manual_amount_errors!(permitted)
    add_manual_receipt_items_error!
  end

  def add_manual_receipt_items_error!
    message = t("receipts.form.errors.items_required")
    return if @receipt.errors.full_messages.include?(message)

    @receipt.errors.add(:base, message)
  end

  def apply_amount_calculation!(permitted, context:)
    clear_amounts = clear_amounts_for_deleted_receipt_items?(permitted, context)
    receipt_tax_details = clear_amounts ? [] : amount_receipt_tax_details(context)
    result = calculate_receipt_amounts(permitted, context, clear_amounts, receipt_tax_details)
    if recalculate_tax_details_after_manual_item_update?(permitted, result, clear_amounts)
      result = calculate_receipt_amounts(permitted, context, clear_amounts, [])
    end

    resolved = result[:resolved]
    permitted["subtotal_amount"] = resolved[:subtotal]
    permitted["tax_amount"] = resolved[:tax]
    permitted["total_amount"] = resolved[:total]
    permitted["tax_rate"] = resolved[:tax_rate]
    permitted["amount_calculation_profile"] = ReceiptAmountService.calculation_profile_snapshot(result)
    # 明細の quantity / line_total を計算結果で上書き（複数行対応）
    apply_item_totals!(permitted, result.dig(:computed, :items))
    permitted["receipt_tax_details_attributes"] = receipt_tax_detail_attributes(result[:tax_details])
    result
  end

  def calculate_receipt_amounts(permitted, context, clear_amounts, receipt_tax_details)
    ReceiptAmountService.call(
      receipt: amount_receipt(permitted, context, clear_amounts: clear_amounts),
      receipt_items: amount_receipt_items(permitted),
      receipt_tax_details: receipt_tax_details,
      receipt_adjustments: amount_receipt_adjustments(permitted, context),
      context: context,
      tax_rounding_mode: current_user.tax_rounding_mode,
      discount_rounding_mode: current_user.discount_rounding_mode
    )
  end

  def recalculate_tax_details_after_manual_item_update?(permitted, result, clear_amounts)
    return false if clear_amounts
    return false if permitted["receipt_items_attributes"].blank?

    Array(result[:blocking_inconsistencies]).map(&:to_sym).include?(:tax_detail_mismatch)
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

      quantity = calculated_item_value(calc, :quantity)
      price = calculated_item_value(calc, :price)
      line_total = calculated_item_value(calc, :line_total)
      original_line_total = calculated_item_value(calc, :original_line_total)
      discount_amount = calculated_item_value(calc, :discount_amount)
      discount_rate = calculated_item_value(calc, :discount_rate)

      item_attr["quantity"] = quantity if calculated_item_key?(calc, :quantity) && !quantity.nil?
      item_attr["price"] = price if calculated_item_key?(calc, :price) && !price.nil?
      item_attr["line_total"] = line_total if calculated_item_key?(calc, :line_total) && !line_total.nil?
      item_attr["original_line_total"] = original_line_total unless original_line_total.nil?
      item_attr["discount_amount"] = discount_amount if calculated_item_key?(calc, :discount_amount)
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
    permitted["status"] = "completed" if @receipt.failed? && !permitted.key?("status")
  end

  def rebuild_review_state_after_manual_update!(permitted, amount_result)
    return unless manual_review_state_rebuild_target?(permitted)

    blocking_reasons = manual_update_blocking_review_reasons(amount_result)
    permitted["review_reasons"] = blocking_reasons
    permitted["status"] =
      if blocking_reasons.empty? && !manual_update_item_review_remaining?(permitted)
        "completed"
      else
        "review_needed"
      end
  end

  def manual_review_state_rebuild_target?(permitted)
    return false if permitted["receipt_items_attributes"].blank?

    @receipt.completed? || @receipt.review_needed? || @receipt.failed? || @receipt.has_processing_error?
  end

  def manual_update_blocking_review_reasons(amount_result)
    reasons =
      if amount_result.respond_to?(:key?) && amount_result.key?(:blocking_inconsistencies)
        amount_result[:blocking_inconsistencies]
      else
        amount_result[:inconsistencies]
      end

    ReviewReasons.blocking_reasons_for_user(reasons)
  end

  def manual_update_item_review_remaining?(permitted)
    manual_update_item_review_states(permitted).any? do |state|
      state[:needs_review] || ReviewReasons.blocking_reasons_for_user(state[:review_reasons]).any?
    end
  end

  def manual_update_item_review_states(permitted)
    states = @receipt.receipt_items.each_with_object({}) do |item, result|
      result[item.id.to_s] = {
        needs_review: item.needs_review?,
        review_reasons: Array(item.review_reasons).map(&:to_s)
      }
    end

    items_attributes = permitted["receipt_items_attributes"]
    return states.values if items_attributes.blank?

    items_attributes.each_with_index do |(_param_key, item_attributes), index|
      item_id = item_attributes["id"].to_s

      if ActiveModel::Type::Boolean.new.cast(item_attributes["_destroy"])
        states.delete(item_id) if item_id.present?
        next
      end

      state_key = item_id.presence || "new_#{index}"
      existing_state = states[state_key] || { needs_review: false, review_reasons: [] }
      states[state_key] = {
        needs_review: manual_update_item_needs_review?(item_attributes, existing_state),
        review_reasons: manual_update_item_review_reasons(item_attributes, existing_state)
      }
    end

    states.values
  end

  def manual_update_item_needs_review?(item_attributes, existing_state)
    return existing_state[:needs_review] unless item_attributes.key?("needs_review")

    ActiveModel::Type::Boolean.new.cast(item_attributes["needs_review"])
  end

  def manual_update_item_review_reasons(item_attributes, existing_state)
    return existing_state[:review_reasons] unless item_attributes.key?("review_reasons")

    Array(item_attributes["review_reasons"]).reject(&:blank?).map(&:to_s)
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

  def amount_receipt_adjustments(permitted, context)
    adjustments_attributes = permitted["receipt_adjustments_attributes"]
    if adjustments_attributes.present?
      return adjustments_attributes.values.reject do |adjustment_attributes|
        ActiveModel::Type::Boolean.new.cast(adjustment_attributes["_destroy"])
      end
    end

    return [] unless context == :edit_save
    return [] unless @receipt&.persisted?

    @receipt.receipt_adjustments.map do |adjustment|
      {
        kind: adjustment.kind,
        label: adjustment.label,
        amount: adjustment.amount,
        sign: adjustment.sign,
        tax_rate: adjustment.tax_rate,
        needs_review: adjustment.needs_review?,
        review_reasons: adjustment.review_reasons,
        source: adjustment.source
      }
    end
  end

  def amount_receipt(permitted, context, clear_amounts: false)
    return permitted.except("subtotal_amount", "tax_amount", "total_amount", "tax_rate") if clear_amounts
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

  def clear_amounts_for_deleted_receipt_items?(permitted, context)
    return false unless context == :edit_save
    return false unless @receipt&.persisted?

    items_attributes = permitted["receipt_items_attributes"]
    return false if items_attributes.blank?
    return false if amount_receipt_items(permitted).present?

    items_attributes.values.any? do |item_attributes|
      item_attributes["id"].present? && ActiveModel::Type::Boolean.new.cast(item_attributes["_destroy"])
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

  def render_invalid_search_query
    message = t("search.realtime.invalid_query_message")

    if realtime_search_request? || request.format.json?
      render json: { error: "invalid_search_query", message: message }, status: :unprocessable_content
      return
    end

    prepare_receipt_index_query(current_user.receipts.none)
    receipts_scope = @receipt_index_query.scope
    @pagy, @receipts = pagy(:offset, receipts_scope, limit: @per_page)
    assign_receipts_index_summary(receipts_scope)
    assign_receipt_index_count_summary
    flash.now[:alert] = message
    render :index, status: :unprocessable_content, formats: :html
  end

  def realtime_search_request?
    request.headers["X-Recify-Search"] == "realtime"
  end

  def assign_receipts_index_summary(receipts_scope)
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

  def suspicious_search_query?(query)
    query.present? && query.match?(SUSPICIOUS_SEARCH_PATTERN)
  end

  def log_suspicious_search_query(query)
    Rails.logger.warn(
      "[ReceiptSearch] suspicious_query user_id=#{current_user.id} query=#{query.inspect}"
    )
  end
end
