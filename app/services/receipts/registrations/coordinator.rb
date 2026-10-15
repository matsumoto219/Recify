module Receipts::Registrations
  class Coordinator
    class << self
      def call(user:, token:, kind:, input:, &operation)
        new(user:, token:, kind:, input:).call(&operation)
      end

      def accept!(operation:, receipts:)
        raise InvalidOperation unless operation.is_a?(Handle) && ReceiptRegistrationOperation.connection.transaction_open?

        User.lock.find(operation.user_id)
        record = ReceiptRegistrationOperation.lock.find(operation.id)
        unless record.user_id == operation.user_id && record.operation_key == operation.operation_key &&
            record.attempt_key == operation.attempt_key && record.state == "processing" && record.expires_at > Time.current
          raise InvalidOperation
        end

        ids = receipt_ids_for(receipts, record)
        record.update!(state: "accepted", receipt_ids: ids, accepted_at: Time.current)
        true
      rescue ActiveRecord::RecordNotFound
        raise InvalidOperation
      end

      private

      def receipt_ids_for(receipts, record)
        maximum = record.kind == "batch_upload" ? ReceiptRegistrationOperation::MAX_RECEIPTS : 1
        unless receipts.is_a?(Array) && receipts.size.between?(1, maximum) &&
            receipts.all? { |receipt| receipt.is_a?(Receipt) && receipt.persisted? && receipt.user_id == record.user_id }
          raise InvalidOperation
        end

        ids = receipts.map(&:id)
        unless ids.uniq == ids && Receipt.where(user_id: record.user_id, id: ids).count == ids.size
          raise InvalidOperation
        end

        ids
      end
    end

    def initialize(user:, token:, kind:, input:)
      @user = user
      @token = token
      @kind = kind
      @input = input
    end

    def call
      @verified = Token.verify(user:, token:)
      return Result.new(state: verified.state) unless verified.state == "valid"
      return Result.new(state: "conflict") unless allowed_kind?

      @fingerprint = input_fingerprint
      return Result.new(state: "invalid") unless fingerprint

      Storage.with_upload_operation_lock(key: "#{user.id}:#{verified.operation_key}") do
        handle = claim
        next handle if handle.is_a?(Result)

        execute(handle) { yield handle }
      end || Result.new(state: "processing", kind:)
    end

    private

    attr_reader :user, :token, :kind, :input, :verified, :fingerprint

    def allowed_kind?
      (verified.kind == "manual" && kind == "manual") ||
        (verified.kind == "upload" && %w[upload batch_upload].include?(kind))
    end

    def input_fingerprint
      Fingerprint.call(user:, kind:, input:)
    rescue ArgumentError
      nil
    end

    def claim
      ReceiptRegistrationOperation.transaction(requires_new: true) do
        User.lock.find(user.id)
        next Result.new(state: "expired") if verified.expires_at <= Time.current

        record = ReceiptRegistrationOperation.lock.find_by(user_id: user.id, operation_key: verified.operation_key)
        if record
          next Result.new(state: "conflict") unless record.kind == kind && record.input_fingerprint == fingerprint
          if record.state == "accepted"
            next Result.new(state: "accepted", kind:, receipt_ids: record.receipt_ids, replayed: true)
          end
        else
          record = ReceiptRegistrationOperation.new(
            user_id: user.id,
            operation_key: verified.operation_key,
            kind: kind,
            input_fingerprint: fingerprint,
            issued_at: verified.issued_at,
            expires_at: verified.expires_at
          )
        end
        record.assign_attributes(state: "processing", attempt_key: SecureRandom.hex(16))
        record.save!
        Handle.new(
          id: record.id,
          user_id: record.user_id,
          operation_key: record.operation_key.dup.freeze,
          attempt_key: record.attempt_key.dup.freeze
        )
      end
    rescue ActiveRecord::RecordNotFound
      Result.new(state: "invalid")
    end

    def execute(handle)
      begin
        value = yield
      rescue StandardError
        begin
          finish_attempt(handle)
        rescue StandardError
          # Keep the original failure; an unfinished attempt remains recoverable under its operation lock.
        end
        raise
      end
      record = finish_attempt(handle)
      Result.new(state: record.state, kind: record.kind, receipt_ids: record.receipt_ids, value:)
    end

    def finish_attempt(handle)
      ReceiptRegistrationOperation.transaction(requires_new: true) do
        User.lock.find(handle.user_id)
        record = ReceiptRegistrationOperation.lock.find(handle.id)
        unless record.user_id == handle.user_id && record.attempt_key == handle.attempt_key
          raise InvalidOperation
        end
        record.update!(state: "failed") if record.state == "processing"
        record
      end
    end
  end
end
