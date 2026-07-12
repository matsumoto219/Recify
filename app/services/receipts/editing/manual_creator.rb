class Receipts::Editing::ManualCreator
  Result = Data.define(:receipt, :saved, :items_missing) do
    def saved?
      saved == true
    end

    def items_missing?
      items_missing == true
    end
  end
  private_constant :Result

  def self.call(receipt:, attributes:, user:, items_missing:)
    new(receipt:, attributes:, user:, items_missing:).call
  end

  def initialize(receipt:, attributes:, user:, items_missing:)
    @receipt = receipt
    @attributes = attributes
    @user = user
    @items_missing = items_missing == true
  end

  def call
    receipt.assign_attributes(attributes)
    receipt.status = attributes["review_reasons"].empty? ? "completed" : "review_needed"
    return result(saved: false) if items_missing

    saved = false
    ActiveRecord::Base.transaction do
      if receipt.valid?
        Usage.consume_manual_receipt!(user: user)
        saved = receipt.save
      end

      raise ActiveRecord::Rollback unless saved
    end

    result(saved: saved)
  end

  private

  attr_reader :receipt, :attributes, :user, :items_missing

  def result(saved:)
    Result.new(receipt:, saved:, items_missing:)
  end
end
