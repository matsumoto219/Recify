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
  end
end
