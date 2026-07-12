require "stringio"

module Receipts::Processing::Runs
  class OcrResponseArtifact
    CAPTURE_ENABLED_KEY = "analysis_artifact.ocr_raw_response_capture_enabled".freeze
    MAX_BYTES_KEY = SystemSettings::OCR_RAW_RESPONSE_MAX_BYTES_KEY
    RETENTION_DAYS_KEY = SystemSettings::OCR_RAW_RESPONSE_RETENTION_KEY
    DEFAULT_MAX_BYTES = 5.megabytes
    DEFAULT_RETENTION_DAYS = 7
    CONTENT_TYPE = "application/json".freeze

    Result = Struct.new(:saved, :skipped, :reason, :byte_size, :attachment, keyword_init: true) do
      def saved?
        saved == true
      end

      def skipped?
        skipped == true
      end
    end

    class << self
      def capture(run, raw_response_body, provider:, model_id: nil, at: Time.current)
        new(run).capture(raw_response_body, provider: provider, model_id: model_id, at: at)
      end

      def purge_expired(cutoff:, limit:, dry_run:)
        new(nil).purge_expired(cutoff: cutoff, limit: limit, dry_run: dry_run)
      end

      def capture_enabled?
        SystemSettings.enabled?(CAPTURE_ENABLED_KEY)
      rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
        false
      end

      def max_bytes
        SystemSettings.limit_for(MAX_BYTES_KEY)
      rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
        DEFAULT_MAX_BYTES
      end

      def retention_days
        SystemSettings.limit_for(RETENTION_DAYS_KEY)
      rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
        DEFAULT_RETENTION_DAYS
      end
    end

    def initialize(run)
      @run = run
    end

    def capture(raw_response_body, provider:, model_id: nil, at: Time.current)
      return skipped_result("disabled") unless self.class.capture_enabled?
      return skipped_result("run_missing") unless run
      return skipped_result("already_attached", attachment: run.ocr_response_artifact) if run.ocr_response_artifact.attached?

      body = normalize_body(raw_response_body)
      return skipped_result("blank") if body.blank?

      byte_size = body.bytesize
      return skipped_result("too_large", byte_size:) if byte_size > self.class.max_bytes
      return skipped_result("global_storage_quota_exceeded", byte_size:) unless Storage.global_quota_can_add?(byte_size)

      run.ocr_response_artifact.attach(
        io: StringIO.new(body),
        filename: filename_for(run),
        content_type: CONTENT_TYPE,
        identify: false,
        metadata: {
          "provider" => provider.to_s,
          "model_id" => model_id.to_s.presence,
          "captured_at" => at.iso8601,
          "schema_version" => 1
        }.compact
      )

      Result.new(
        saved: true,
        skipped: false,
        reason: "saved",
        byte_size: byte_size,
        attachment: run.ocr_response_artifact
      )
    rescue StandardError => e
      Rails.logger.warn("[ReceiptAnalysisRuns::OcrResponseArtifact] capture_failed class=#{e.class}")
      skipped_result("capture_failed")
    end

    def purge_expired(cutoff:, limit:, dry_run:)
      attachments = expired_attachments(cutoff: cutoff, limit: limit)
      records = attachments.map { |attachment| attachment_record(attachment) }
      result = {
        dry_run: dry_run,
        cutoff: cutoff,
        limit: limit,
        expired_artifact_count: attachments.size,
        purged_artifact_count: 0,
        records: records,
        errors: []
      }

      return result if dry_run

      attachments.each do |attachment|
        attachment.purge
        result[:purged_artifact_count] += 1
      rescue StandardError => e
        result[:errors] << {
          attachment_id: attachment.id,
          record_id: attachment.record_id,
          error_class: e.class.name
        }
      end

      result
    end

    private

    attr_reader :run

    def normalize_body(raw_response_body)
      body = case raw_response_body
      when String
        raw_response_body
      else
        JSON.generate(raw_response_body)
      end

      JSON.parse(body)
      body
    rescue JSON::GeneratorError, JSON::ParserError, TypeError
      nil
    end

    def skipped_result(reason, byte_size: nil, attachment: nil)
      Result.new(
        saved: false,
        skipped: true,
        reason: reason,
        byte_size: byte_size,
        attachment: attachment
      )
    end

    def filename_for(run)
      attempt = run.attempt_number.to_i.positive? ? run.attempt_number : 1
      "ocr_response_#{run.run_key}_attempt#{attempt.to_s.rjust(2, '0')}.json"
    end

    def expired_attachments(cutoff:, limit:)
      ActiveStorage::Attachment
        .where(record_type: "ReceiptAnalysisRun", name: "ocr_response_artifact")
        .where(created_at: ..cutoff)
        .order(:created_at, :id)
        .limit(limit)
        .includes(:blob)
        .to_a
    end

    def attachment_record(attachment)
      {
        attachment_id: attachment.id,
        record_id: attachment.record_id,
        byte_size: attachment.blob&.byte_size,
        created_at: attachment.created_at
      }
    end
  end
end
