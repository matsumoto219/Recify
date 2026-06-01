require "openssl"

module Users
  class AccountDeletionService
    EMAIL_DIGEST_SALT = "recify/account-deletion-email-digest"

    Result = Struct.new(:summary, :audit_log, keyword_init: true) do
      def success?
        true
      end
    end

    class << self
      def call(user:, actor: nil, reason: nil, request: nil, audit: false)
        new(
          user: user,
          actor: actor,
          reason: reason,
          request: request,
          audit: audit
        ).call
      end

      def email_digest(email)
        OpenSSL::HMAC.hexdigest("SHA256", email_digest_key, email.to_s.downcase)
      end

      private

      def email_digest_key
        Rails.application.key_generator.generate_key(EMAIL_DIGEST_SALT, 32)
      end
    end

    def initialize(user:, actor:, reason:, request:, audit:)
      @user = user
      @actor = actor
      @reason = reason
      @request = request
      @audit = audit
    end

    def call
      raise ArgumentError, "user is required" unless user

      result = nil

      User.transaction do
        summary = safe_summary(user)
        user.destroy!
        result = Result.new(summary: summary, audit_log: nil)
      end

      result
    end

    private

    attr_reader :user, :actor, :reason, :request, :audit

    def safe_summary(target_user)
      {
        user_id: target_user.id,
        email_digest: email_digest(target_user.email),
        admin: target_user.admin?,
        guest: target_user.guest?,
        receipts_count: target_user.receipts.count,
        passkeys_count: target_user.passkeys.count,
        user_sessions_count: target_user.user_sessions.count,
        notifications_count: target_user.notifications.count,
        avatar_attached: target_user.avatar.attached?
      }
    end

    def email_digest(email)
      self.class.email_digest(email)
    end
  end
end
