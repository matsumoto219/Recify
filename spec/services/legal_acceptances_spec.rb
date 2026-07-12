require 'rails_helper'

RSpec.describe LegalAcceptances do
  describe '.record_current_documents!' do
    it 'delegates the persistence workflow to the private recorder' do
      user = build_stubbed(:user)
      allow(LegalAcceptances::Recorder).to receive(:record_current_documents!).and_return(:recorded)

      result = described_class.record_current_documents!(
        user: user,
        acceptance_context: 'signup',
        locale: :ja
      )

      aggregate_failures do
        expect(result).to eq(:recorded)
        expect(LegalAcceptances::Recorder).to have_received(:record_current_documents!).with(
          user: user,
          acceptance_context: 'signup',
          locale: :ja
        )
      end
    end
  end
end
