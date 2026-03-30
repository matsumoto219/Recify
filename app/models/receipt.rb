class Receipt < ApplicationRecord
  belongs_to :user
  has_one_attached :image
  has_many :receipt_items, dependent: :destroy
end
