class Receipts::Editing::ManualUpdater
  Result = Data.define(:receipt, :saved, :items_missing) do
    def saved?
      saved == true
    end

    def items_missing?
      items_missing == true
    end
  end
  private_constant :Result

  def self.call(receipt:, attributes:, items_missing:)
    new(receipt:, attributes:, items_missing:).call
  end

  def initialize(receipt:, attributes:, items_missing:)
    @receipt = receipt
    @attributes = attributes
    @items_missing = items_missing == true
  end

  def call
    if items_missing
      receipt.assign_attributes(attributes)
      return result(saved: false)
    end

    result(saved: receipt.update(attributes))
  end

  private

  attr_reader :receipt, :attributes, :items_missing

  def result(saved:)
    Result.new(receipt:, saved:, items_missing:)
  end
end
