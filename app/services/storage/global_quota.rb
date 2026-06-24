module Storage
  class GlobalQuota
    WARNING_PERCENTAGE = 75
    CRITICAL_PERCENTAGE = 90
    HARD_STOP_BYTES = 20.gigabytes

    Snapshot = Struct.new(
      :used_bytes,
      :hard_stop_bytes,
      :warning_percentage,
      :critical_percentage,
      keyword_init: true
    ) do
      def warning_bytes
        threshold_bytes(warning_percentage)
      end

      def critical_bytes
        threshold_bytes(critical_percentage)
      end

      def remaining_bytes
        hard_stop_bytes - used_bytes
      end

      def usage_percentage
        return 0.0 if hard_stop_bytes <= 0

        (used_bytes.to_f / hard_stop_bytes) * 100
      end

      def state
        if used_bytes >= hard_stop_bytes
          :hard_stop
        elsif usage_percentage >= critical_percentage
          :critical
        elsif usage_percentage >= warning_percentage
          :warning
        else
          :normal
        end
      end

      def can_add?(byte_size, excluding_blob: nil)
        candidate_used_bytes(byte_size, excluding_blob: excluding_blob) <= hard_stop_bytes
      end

      def candidate_used_bytes(byte_size, excluding_blob: nil)
        excluded_bytes = excluding_blob&.byte_size.to_i

        [ used_bytes - excluded_bytes, 0 ].max + byte_size.to_i
      end

      def to_h
        {
          used_bytes: used_bytes,
          hard_stop_bytes: hard_stop_bytes,
          warning_percentage: warning_percentage,
          critical_percentage: critical_percentage,
          warning_bytes: warning_bytes,
          critical_bytes: critical_bytes,
          remaining_bytes: remaining_bytes,
          usage_percentage: usage_percentage,
          state: state
        }
      end

      private

      def threshold_bytes(percentage)
        ((hard_stop_bytes * percentage.to_i) / 100.0).ceil
      end
    end

    class << self
      def call
        new.call
      end

      def can_add?(byte_size, excluding_blob: nil)
        call.can_add?(byte_size, excluding_blob: excluding_blob)
      end

      def hard_stop_bytes
        SystemSettings.limit_for("storage.global_hard_stop_bytes")
      rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
        HARD_STOP_BYTES
      end

      def warning_percentage
        SystemSettings.limit_for("storage.global_usage_warning_percentage")
      rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
        WARNING_PERCENTAGE
      end

      def critical_percentage
        SystemSettings.limit_for("storage.global_usage_critical_percentage")
      rescue SystemSettings::UnknownKeyError, SystemSettings::ValidationError, ArgumentError, TypeError
        CRITICAL_PERCENTAGE
      end
    end

    def call
      Snapshot.new(
        used_bytes: ActiveStorage::Blob.sum(:byte_size),
        hard_stop_bytes: self.class.hard_stop_bytes,
        warning_percentage: self.class.warning_percentage,
        critical_percentage: self.class.critical_percentage
      )
    end
  end
end
