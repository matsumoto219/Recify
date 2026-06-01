module Users
  class << self
    def delete_account(user:, actor: nil, reason: nil, request: nil, audit: false)
      AccountDeletionService.call(
        user: user,
        actor: actor,
        reason: reason,
        request: request,
        audit: audit
      )
    end

    def account_deletion_email_digest(email)
      AccountDeletionService.email_digest(email)
    end
  end
end
