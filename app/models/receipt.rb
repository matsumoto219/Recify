class Receipt < ApplicationRecord
  belongs_to :user
  has_many :receipt_items, dependent: :destroy
  has_one_attached :image

  accepts_nested_attributes_for :receipt_items, allow_destroy: false
end
