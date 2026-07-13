require "zlib"

module Security
  class IpAccessOperationLock
    # These values must stay stable so every application process competes for the same locks.
    ADVISORY_LOCK_NAMESPACE = 1_909_403_571
    ADVISORY_LOCK_SQL = "SELECT pg_advisory_xact_lock($1, $2) IS NULL AS lock_result_ignored".freeze
    ADVISORY_LOCK_INTEGER = ActiveRecord::Type::Integer.new(limit: 4).freeze
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
        binds = [
          ActiveRecord::Relation::QueryAttribute.new(
            "namespace",
            ADVISORY_LOCK_NAMESPACE,
            ADVISORY_LOCK_INTEGER
          ),
          ActiveRecord::Relation::QueryAttribute.new("lock_id", lock_id, ADVISORY_LOCK_INTEGER)
        ]

        SecurityIpBlock.connection.exec_query(
          ADVISORY_LOCK_SQL,
          "Security::IpAccessOperationLock",
          binds,
          prepare: true
        )
      end
    end
  end
end
