# frozen_string_literal: true

module Security
  class IpAccessRules
    class << self
      def blocked?(ip_address)
        normalized = IpAddress.normalize(ip_address)
        return false if normalized.blank?

        SecurityIpBlock.currently_effective_for_ip(normalized).exists?
      rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
        false
      end
    end
  end
end
