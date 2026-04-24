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

  scope :needs_review_only, -> { where(needs_review: true) }

  validates :category, inclusion: { in: CATEGORIES }, allow_blank: true

  # 数値の最低値を0以上に
  validates :price,
            :quantity,
            :line_total,
            :position_index,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_blank: true

  validates :needs_review,
            inclusion: { in: [ true, false ] },
            allow_nil: true

  # 税率（0.0〜1.0で保存）
  validates :tax_rate,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
            allow_nil: true

  # 文字列項目の最大文字数
  validates :raw_text, length: { maximum: 1000 }, allow_blank: true       # OCR原文テキスト(MAX1000文字)
  validates :suggested_name, length: { maximum: 500 }, allow_blank: true  # AI補完候補名(MAX500文字)
  validates :confirmed_name, length: { maximum: 500 }, allow_blank: true  # ユーザー確定名(MAX500文字)
  validates :quantity_unit, length: { maximum: 50 }, allow_blank: true    # 数量単位(MAX50文字)
  validates :product_code, length: { maximum: 100 }, allow_blank: true    # 商品コード(MAX100文字)

  # AI関連(信頼度 0.0~1.0)
  validates :confidence,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
            allow_blank: true

  def review_required?
    needs_review?
  end

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
