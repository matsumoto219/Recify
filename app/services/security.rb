# frozen_string_literal: true

module Security
  Error = Class.new(StandardError)
  ValidationError = Class.new(Error)

  class << self
    def ip_access_snapshot(...)
      IpAccessSnapshot.call(...)
    end

    def request_ip_snapshot(...)
      RequestIpSnapshot.call(...)
    end

    def manual_ip_block(...)
      ManualIpBlocker.call(...)
    end

    def manual_ip_unblock(...)
      ManualIpUnblocker.call(...)
    end

    def rack_attack_ban_reset(...)
      RackAttackBanResetter.call(...)
    end

    def record_ip_action(...)
      IpActionRecorder.call(...)
    end

    def record_ip_rate_limit_action(...)
      IpActionRecorder.record_rate_limit(...)
    end

    def record_ip_access_operation(...)
      IpActionRecorder.record_operation(...)
    end
  end
end
