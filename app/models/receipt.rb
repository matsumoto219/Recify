class Receipt < ApplicationRecord
  belongs_to :user
  has_many :receipt_items, dependent: :destroy
end
