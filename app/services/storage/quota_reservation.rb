module Storage
  class QuotaReservation
    # These values must stay stable so every application process competes for the same lock.
    ADVISORY_LOCK_NAMESPACE = 1_919_401_793
    ADVISORY_LOCK_ID = 1
    PROCESS_LOCK = Mutex.new

    class << self
      def call(byte_size:, user: nil, excluding_blob: nil, &operation)
        PROCESS_LOCK.synchronize do
          ActiveStorage::Blob.transaction do
            acquire_database_lock
            verify_global_quota!(byte_size, excluding_blob: excluding_blob)
            verify_user_quota!(user, byte_size, excluding_blob: excluding_blob) if user
            operation.call
          end
        end
      end

      private

      def acquire_database_lock
        ActiveStorage::Blob.connection.execute(
          "SELECT pg_advisory_xact_lock(#{ADVISORY_LOCK_NAMESPACE}, #{ADVISORY_LOCK_ID})"
        )
      end

      def verify_global_quota!(byte_size, excluding_blob:)
        return if GlobalQuota.can_add?(byte_size, excluding_blob: excluding_blob)

        raise QuotaExceeded.new(scope: :global)
      end

      def verify_user_quota!(user, byte_size, excluding_blob:)
        locked_user = User.lock.find(user.id)
        return if UsageCalculator.new(locked_user).can_add?(byte_size, excluding_blob: excluding_blob)

        raise QuotaExceeded.new(scope: :user)
      end
    end
  end
end
