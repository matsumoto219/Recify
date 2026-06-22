# frozen_string_literal: true

module Security
  Error = Class.new(StandardError)
  ValidationError = Class.new(Error)

  class << self
    def ip_access_snapshot(...)
      IpAccessSnapshot.call(...)
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
  end
end
