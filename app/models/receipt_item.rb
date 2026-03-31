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
  validates :category, inclusion: { in: CATEGORIES }, allow_blank: true

  # 数値の最低値を0以上に
  validates :price,
            :quantity,
            :line_total,
            :position_index,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_blank: true

  # 文字列項目の最大文字数
  validates :raw_text, length: { maximum: 255 }, allow_blank: true        # OCR原文テキスト(MAX255文字)
  validates :suggested_name, length: { maximum: 255 }, allow_blank: true  # AI補完候補名(MAX255文字)
  validates :confirmed_name, length: { maximum: 255 }, allow_blank: true  # ユーザー確定名(MAX255文字)

  # AI関連(信頼度 0.0~1.0)
  validates :confidence,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
            allow_blank: true

  def self.category_options
    CATEGORIES.map do |key|
      [ I18n.t("enums.receipt_item.category.#{key}"), key ]
    end
  end

  def category_label
    return "" if category.blank?

    I18n.t("enums.receipt_item.category.#{category}", default: category)
  end
end
