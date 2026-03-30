
class ReceiptItem < ApplicationRecord
  CATEGORIES = %w[
    food
    drink
    daily_goods
    household
    medical
    beauty
    transportation
    hobby
    other
  ].freeze

  belongs_to :receipt

  def self.category_options
    CATEGORIES.map do |key|
      [ I18n.t("enums.receipt_item.category.#{key}"), key ]
    end
  end

  def category_label
    I18n.t("enums.receipt_item.category.#{category}")
  end
end
