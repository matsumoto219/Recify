require "openssl"

module TwoFactor
  class RecoveryCodes
    CODE_COUNT = 10
    CODE_LENGTH = 20

    class << self
      def generate_for(user:)
        codes = Array.new(CODE_COUNT) { generate_code }
        RecoveryCode.transaction do
          codes.each do |code|
            user.recovery_codes.create!(code_digest: digest(code))
          end
        end
        codes
      end

      def regenerate_for(user:)
        RecoveryCode.transaction do
          user.recovery_codes.delete_all
          generate_for(user: user)
        end
      end

      def verify(user:, code:)
        recovery_code = user.recovery_codes.find_by!(
          code_digest: digest(code),
          used_at: nil
        )
        recovery_code.update!(used_at: Time.current)
        recovery_code
      rescue ActiveRecord::RecordNotFound
        raise VerificationError, "recovery_code_invalid"
      end

      def digest(code)
        OpenSSL::HMAC.hexdigest("SHA256", digest_key, normalize_code(code))
      end

      private

      def generate_code
        SecureRandom
          .alphanumeric(CODE_LENGTH)
          .upcase
          .scan(/.{1,4}/)
          .join("-")
      end

      def normalize_code(code)
        code.to_s.upcase.gsub(/[^A-Z0-9]/, "")
      end

      def digest_key
        Rails.application.key_generator.generate_key("recify/two-factor/recovery-codes", 32)
      end
    end
  end
end
