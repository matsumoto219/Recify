require 'rails_helper'

RSpec.describe Receipt, type: :model do
  describe '.summary_for' do
    it 'failed_countを返す' do
      user = create(:user)
      create(:receipt, :completed, user: user)
      create(:receipt, :processing, :with_image, user: user)
      create(:receipt, :review_needed, user: user)
      create(:receipt, :failed, user: user)
      create(:receipt, :failed, user: user)

      summary = described_class.summary_for(user)

      aggregate_failures do
        expect(summary[:processing_count]).to eq(1)
        expect(summary[:review_needed_count]).to eq(1)
        expect(summary[:failed_count]).to eq(2)
      end
    end
  end
end
