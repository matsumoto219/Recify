module Receipts::Registrations
  class Cleanup
    Result = Data.define(:scanned, :deleted, :pending, :busy, :failed, :next_after_id, :through_id)
    private_constant :Result

    def self.call(limit: 100, after_id: 0, through_id: nil)
      raise ArgumentError, "invalid cleanup limit" unless limit.is_a?(Integer) && limit.between?(1, 1000)
      unless after_id.is_a?(Integer) && after_id >= 0 &&
          (through_id.nil? || (through_id.is_a?(Integer) && through_id >= after_id))
        raise ArgumentError, "invalid cleanup cursor"
      end

      expired = ReceiptRegistrationOperation.where("expires_at <= ?", Time.current)
      through_id ||= expired.maximum(:id).to_i
      candidates = expired.where(id: (after_id + 1)..through_id)
      records = candidates.order(:id).limit(limit).to_a
      counts = { scanned: 0, deleted: 0, pending: 0, busy: 0, failed: 0 }
      records.each do |record|
        counts[:scanned] += 1
        outcome = Storage.with_upload_operation_lock(key: "#{record.user_id}:#{record.operation_key}") do
          discard(record)
        end
        counts[outcome || :busy] += 1 unless outcome == :missing
      rescue StandardError => error
        counts[:failed] += 1
        Rails.logger.warn("[ReceiptRegistration] cleanup_failed error_class=#{error.class}")
      end
      next_after_id = records.last.id if records.any? && candidates.where("id > ?", records.last.id).exists?
      Result.new(**counts, next_after_id:, through_id:)
    end

    def self.discard(record)
      ReceiptRegistrationOperation.transaction do
        next :missing unless User.lock.find_by(id: record.user_id)

        locked = ReceiptRegistrationOperation.lock.find_by(id: record.id, user_id: record.user_id)
        next :missing unless locked && locked.expires_at <= Time.current
        if Storage.pending_prepared_registration?(user_id: locked.user_id, operation_key: locked.operation_key)
          next :pending
        end

        locked.destroy!
        :deleted
      end
    end
    private_class_method :discard
  end
end
