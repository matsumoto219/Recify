require 'rails_helper'

RSpec.describe Settings::SecurityPresenter do
  describe '#totp_enabled?' do
    it 'confirmed TOTP credential is enabled' do
      user = create(:user)
      create(:totp_credential, user: user, confirmed_at: Time.current)

      presenter = described_class.new(user: user)

      expect(presenter).to be_totp_enabled
    end

    it 'missing TOTP credential is disabled' do
      presenter = described_class.new(user: create(:user))

      expect(presenter).not_to be_totp_enabled
    end
  end

  describe '#recovery_status_classes' do
    it 'returns warning classes for low recovery code status' do
      user = create(:user)
      create(:totp_credential, user: user, confirmed_at: Time.current)
      codes = TwoFactor.generate_recovery_codes_for(user: user)
      codes.first(8).each { |code| TwoFactor.verify_recovery_code(user: user, code: code) }

      presenter = described_class.new(user: user)

      expect(presenter.recovery_status_classes).to eq('token-state-warning-soft token-text-warning')
    end
  end

  describe '#passkeys' do
    it 'returns passkeys in newest first order' do
      user = create(:user)
      older = create(:passkey, user: user, created_at: 2.days.ago)
      newer = create(:passkey, user: user, created_at: 1.day.ago)

      presenter = described_class.new(user: user)

      expect(presenter.passkeys).to eq([newer, older])
      expect(presenter).to be_passkeys
    end
  end
end
