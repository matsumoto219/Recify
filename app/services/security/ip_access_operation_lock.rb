require "zlib"

module Security
  class IpAccessOperationLock
    # These values must stay stable so every application process competes for the same locks.
    ADVISORY_LOCK_NAMESPACE = 1_909_403_571
    PROCESS_LOCK_STRIPES = Array.new(64) { Mutex.new }.freeze

    class << self
      def call(ip_address:, &operation)
        lock_id = advisory_lock_id(ip_address)

        process_lock(lock_id).synchronize do
          SecurityIpBlock.transaction(requires_new: true) do
            acquire_database_lock(lock_id)
            operation.call
          end
        end
      end

      private

      def process_lock(lock_id)
        PROCESS_LOCK_STRIPES.fetch(lock_id % PROCESS_LOCK_STRIPES.length)
      end

      def advisory_lock_id(ip_address)
        unsigned = Zlib.crc32("recify.security_ip_access.#{ip_address}")
        unsigned >= (2**31) ? unsigned - (2**32) : unsigned
      end

      def acquire_database_lock(lock_id)
        SecurityIpBlock.connection.execute(
          "SELECT pg_advisory_xact_lock(#{ADVISORY_LOCK_NAMESPACE}, #{lock_id})"
        )
      end
    end
  end
end
