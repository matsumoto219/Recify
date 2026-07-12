require 'rails_helper'

RSpec.describe LegalConsents do
  describe '.requirement' do
    it 'builds the private requirement through the facade' do
      user = build_stubbed(:user)
      requirement = instance_double(LegalConsents::Requirement)
      allow(LegalConsents::Requirement).to receive(:new).and_return(requirement)

      expect(described_class.requirement(user: user, locale: :ja)).to eq(requirement)
      expect(LegalConsents::Requirement).to have_received(:new).with(user: user, locale: :ja)
    end
  end
end
