module Storage
  class << self
    def purge_attachment(attachment)
      AttachmentPurger.call(attachment)
    end

    def usage_calculator(user)
      UsageCalculator.new(user)
    end

    alias usage_for usage_calculator
  end
end
