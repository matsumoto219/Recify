require 'rails_helper'

RSpec.describe Storage do
  describe '.purge_attachment' do
    it 'AttachmentPurgerへ委譲する' do
      attachment = instance_double(ActiveStorage::Attached::One)

      allow(Storage::AttachmentPurger).to receive(:call).with(attachment).and_return(true)

      expect(described_class.purge_attachment(attachment)).to eq(true)
    end
  end

  describe '.usage_calculator' do
    it 'UsageCalculatorを返す' do
      user = build(:user)

      expect(described_class.usage_calculator(user)).to be_a(Storage::UsageCalculator)
    end
  end
end
