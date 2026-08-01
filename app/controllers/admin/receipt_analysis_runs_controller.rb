class Admin::ReceiptAnalysisRunsController < Admin::BaseController
  RETRY_TYPES = Receipts::Processing.admin_retry_types.freeze
  RETRY_CONFIRMATION_TEXT = SystemOperations.receipt_analysis_retry_confirmation_text
  OCR_RESPONSE_ARTIFACT_DOWNLOAD_VARIANTS = %w[raw pretty].freeze
  OCR_RESPONSE_ARTIFACT_PRETTY_JSON_OPTIONS = {
    indent: "\t",
    space: " ",
    object_nl: "\n",
    array_nl: "\n"
  }.freeze
  MAX_STATUS_SYNC_RUNS = 100

  helper_method :admin_retry_enabled?,
                :admin_retry_reauthentication_required?,
                :admin_ocr_response_artifact_download_enabled?,
                :retry_confirmation_text

  def index
    @filters = filter_params
    @result = Admin.receipt_analysis_runs(**receipt_analysis_run_query_filters)
    @filter_options = Admin.receipt_analysis_run_filter_options
  end

  def show
    @result = Admin.receipt_analysis_runs(run_key: params[:run_key], limit: 1, include_retry_options: true)
    @record = @result.records.first
    return if @record.present?

    raise_not_found
  end

  def status
    run_keys = status_run_keys
    records = if run_keys.empty?
      {}
    else
      Admin.receipt_analysis_runs(run_key: run_keys, limit: run_keys.size).records.index_by { |record|
        record[:run_key]
      }
    end

    response.headers["Cache-Control"] = "no-store"
    render json: {
      runs: run_keys.map { |run_key| status_payload(run_key, records[run_key]) }
    }
  end

  def retry
    @result = Admin.receipt_analysis_runs(run_key: params[:run_key], limit: 1, include_retry_options: true)
    @record = @result.records.first
    raise_not_found if @record.blank?

    unless admin_retry_enabled?
      redirect_to new_admin_passkey_reauthentication_path(return_to: admin_receipt_analysis_run_path(@record[:run_key])),
                  alert: t("admin.receipt_analysis_runs.messages.reauthentication_required"),
                  status: :see_other
      return
    end

    retry_type = params[:retry_kind].presence || params[:retry_type].to_s
    reason = params[:reason].to_s.strip

    unless RETRY_TYPES.include?(retry_type)
      redirect_to admin_receipt_analysis_run_path(params[:run_key]), alert: t("admin.receipt_analysis_runs.messages.retry_type_required")
      return
    end

    if reason.blank?
      redirect_to admin_receipt_analysis_run_path(params[:run_key]), alert: t("admin.receipt_analysis_runs.messages.reason_required")
      return
    end

    unless params[:confirmation].to_s.strip == RETRY_CONFIRMATION_TEXT
      redirect_to admin_receipt_analysis_run_path(params[:run_key]), alert: t("admin.receipt_analysis_runs.messages.confirmation_required")
      return
    end

    retry_attributes = {
      receipt: @record[:receipt],
      parent_run: @record[:run],
      actor: current_user,
      retry_type: retry_type,
      reason: reason,
      request: request,
      reauthentication: admin_reauthentication_context,
      confirmation: params[:confirmation]
    }

    result = SystemOperations.execute_receipt_analysis_retry(**retry_attributes)

    if result.success?
      redirect_to admin_receipt_analysis_run_path(result.run.run_key), notice: t("admin.receipt_analysis_runs.messages.accepted")
    else
      redirect_to admin_receipt_analysis_run_path(params[:run_key]), alert: t("admin.receipt_analysis_runs.messages.failed", error_code: result.error_code)
    end
  end

  def ocr_response_artifact
    @result = Admin.receipt_analysis_runs(run_key: params[:run_key], limit: 1)
    @record = @result.records.first
    raise_not_found if @record.blank?

    unless admin_ocr_response_artifact_download_enabled?
      redirect_to new_admin_passkey_reauthentication_path(return_to: admin_receipt_analysis_run_path(@record[:run_key])),
                  alert: t("admin.receipt_analysis_runs.messages.sensitive_download_reauthentication_required"),
                  status: :see_other
      return
    end

    artifact = @record[:run].ocr_response_artifact
    unless artifact.attached?
      record_ocr_response_artifact_download_audit!(
        outcome: "failed",
        error_code: "artifact_missing",
        metadata: { receipt_public_id: @record[:public_id] }
      )
      redirect_to admin_receipt_analysis_run_path(@record[:run_key]),
                  alert: t("admin.receipt_analysis_runs.messages.ocr_response_artifact_missing"),
                  status: :see_other
      return
    end

    blob = artifact.blob
    download_variant = ocr_response_artifact_download_variant
    raw_body = artifact.download
    body = ocr_response_artifact_download_body(raw_body, variant: download_variant)
    filename = ocr_response_artifact_download_filename(blob.filename.to_s, variant: download_variant)

    record_ocr_response_artifact_download_audit!(
      outcome: "succeeded",
      metadata: {
        receipt_public_id: @record[:public_id],
        byte_size: blob.byte_size,
        response_byte_size: body.bytesize,
        content_type: blob.content_type,
        filename: filename,
        download_format: download_variant
      }
    )

    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    send_data body,
              filename: filename,
              type: blob.content_type.presence || "application/json",
              disposition: "attachment"
  rescue ActiveStorage::FileNotFoundError
    record_ocr_response_artifact_download_audit!(
      outcome: "failed",
      error_code: "artifact_file_missing",
      metadata: { receipt_public_id: @record&.dig(:public_id) }
    )
    redirect_to admin_receipt_analysis_run_path(@record[:run_key]),
                alert: t("admin.receipt_analysis_runs.messages.ocr_response_artifact_missing"),
                status: :see_other
  rescue JSON::ParserError, TypeError
    record_ocr_response_artifact_download_audit!(
      outcome: "failed",
      error_code: "invalid_json",
      metadata: {
        receipt_public_id: @record&.dig(:public_id),
        download_format: ocr_response_artifact_download_variant
      }
    )
    redirect_to admin_receipt_analysis_run_path(@record[:run_key]),
                alert: t("admin.receipt_analysis_runs.messages.ocr_response_artifact_invalid_json"),
                status: :see_other
  end

  private

  def status_run_keys
    Array(params[:run_keys])
      .map(&:to_s)
      .select { |run_key| run_key.present? && run_key.length <= 100 }
      .uniq
      .first(MAX_STATUS_SYNC_RUNS)
  end

  def status_payload(run_key, record)
    return { run_key: run_key, missing: true, terminal: true } unless record

    {
      run_key: run_key,
      stage: record[:stage],
      status: record[:status],
      receipt_status: record[:receipt_status],
      error_code: record[:error_code].presence || "-",
      state_revision: record[:state_revision],
      terminal: record[:terminal]
    }
  end

  def admin_retry_enabled?
    current_user.passkeys.exists? && admin_passkey_reauthenticated?
  end

  def admin_ocr_response_artifact_download_enabled?
    current_user.passkeys.exists? && admin_passkey_reauthenticated?
  end

  def admin_retry_reauthentication_required?
    !admin_retry_enabled?
  end

  def retry_confirmation_text
    RETRY_CONFIRMATION_TEXT
  end

  def record_ocr_response_artifact_download_audit!(outcome:, error_code: nil, metadata: {})
    AuditLogs.record_admin_action!(
      actor: current_user,
      action: "receipt_analysis_runs.ocr_response_artifact.download",
      target: @record[:run],
      target_uid: @record[:run_key],
      outcome: outcome,
      error_code: error_code,
      metadata: metadata.compact,
      request: request
    )
  end

  def ocr_response_artifact_download_variant
    variant = params[:variant].to_s
    return variant if OCR_RESPONSE_ARTIFACT_DOWNLOAD_VARIANTS.include?(variant)

    "raw"
  end

  def ocr_response_artifact_download_body(raw_body, variant:)
    return raw_body unless variant == "pretty"

    body = JSON.pretty_generate(
      JSON.parse(raw_body),
      OCR_RESPONSE_ARTIFACT_PRETTY_JSON_OPTIONS
    )
    body.end_with?("\n") ? body : "#{body}\n"
  end

  def ocr_response_artifact_download_filename(filename, variant:)
    return filename unless variant == "pretty"
    return filename.sub(/\.json\z/i, "_pretty.json") if filename.match?(/\.json\z/i)

    "#{filename}_pretty.json"
  end

  def filter_params
    params.permit(
      :receipt_public_id,
      :user_id,
      :status,
      :stage,
      :error_code,
      :source,
      :receipt_status,
      :needs_attention,
      :run_key,
      :limit,
      :offset
    ).to_h.each_with_object({}) do |(key, value), filters|
      next if value.blank?

      filters[key.to_sym] = value
    end
  end

  def receipt_analysis_run_query_filters
    value = params[:receipt_public_id]
    return @filters unless params.key?(:receipt_public_id) && !value.is_a?(String)

    @filters.merge(receipt_public_id: value)
  end

  def raise_not_found
    raise ActionController::RoutingError,
          "No route matches [#{request.request_method}] #{request.path}"
  end
end
