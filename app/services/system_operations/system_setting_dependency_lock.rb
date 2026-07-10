require "zlib"

module SystemOperations
  class SystemSettingDependencyLock
    # This namespace must stay stable so every application process competes for the same locks.
    ADVISORY_LOCK_NAMESPACE = 1_684_118_611
    PROCESS_LOCKS = SystemSettings::SETTING_DEPENDENCY_LOCK_GROUPS.keys.index_with { Mutex.new }.freeze
    ADVISORY_LOCK_IDS = SystemSettings::SETTING_DEPENDENCY_LOCK_GROUPS.keys.index_with do |group|
      unsigned = Zlib.crc32("recify.system_setting_dependency.#{group}")
      unsigned >= (2**31) ? unsigned - (2**32) : unsigned
    end.freeze

    class << self
      def call(groups:, &operation)
        normalized_groups = Array(groups).map(&:to_s).uniq.sort

        synchronize_process_locks(normalized_groups) do
          SystemSetting.transaction do
            acquire_database_locks(normalized_groups)
            operation.call
          end
        end
      end

      private

      def synchronize_process_locks(groups, index = 0, &operation)
        return operation.call if index >= groups.length

        PROCESS_LOCKS.fetch(groups.fetch(index)).synchronize do
          synchronize_process_locks(groups, index + 1, &operation)
        end
      end

      def acquire_database_locks(groups)
        groups.each do |group|
          SystemSetting.connection.execute(
            "SELECT pg_advisory_xact_lock(#{ADVISORY_LOCK_NAMESPACE}, #{ADVISORY_LOCK_IDS.fetch(group)})"
          )
        end
      end
    end
  end
end
