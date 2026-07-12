module LegalConsents
  class << self
    def requirement(user:, locale: I18n.locale)
      Requirement.new(user: user, locale: locale)
    end
  end
end
