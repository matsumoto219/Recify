class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  has_many :receipts, dependent: :destroy

  validates :name, length: { maximum: 30 }, allow_blank: true

  def self.guest!
    create!(
      email: "guest_#{SecureRandom.hex(8)}@example.com",
      password: SecureRandom.urlsafe_base64(12),
      name: "ゲストユーザー",
      guest: true
    )
  end
end
