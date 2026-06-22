# frozen_string_literal: true

module Security
  class IpAccessRules
    CACHE_TTL = 1.minute

    class << self
      def blocked?(ip_address)
        normalized = IpAddress.normalize(ip_address)
        return false if normalized.blank?

        cached = Rails.cache.read(cache_key(normalized))
        return cached == true unless cached.nil?

        blocked = SecurityIpBlock.currently_effective_for_ip(normalized).exists?
        Rails.cache.write(cache_key(normalized), blocked, expires_in: CACHE_TTL)
        blocked
      rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
        false
      end

      def clear_cache!(ip_address)
        normalized = IpAddress.normalize(ip_address)
        return false if normalized.blank?

        Rails.cache.delete(cache_key(normalized))
      end

      private

      def cache_key(ip_address)
        "security:ip_access_rules:blocked:#{ip_address}"
      end
    end
  end
end
