class ReceiptTaxDetail < ApplicationRecord
  belongs_to :receipt

  # --- Validations ---
  validates :rate, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :amount, numericality: { greater_than_or_equal_to: 0 }
  validates :net_amount, numericality: { greater_than_or_equal_to: 0 }

  # --- Optional: presence constraints (if you want stricter control) ---
  # validates :rate, presence: true
  # validates :amount, presence: true
  # validates :net_amount, presence: true
end
