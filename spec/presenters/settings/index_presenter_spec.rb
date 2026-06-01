require 'rails_helper'

RSpec.describe Settings::IndexPresenter do
  let(:view_context) { double('view_context', masked_email_with_domain: 'masked@example.com') }

  describe '#user labels' do
    it 'returns registered user labels through the view email formatter' do
      user = build_stubbed(:user, name: nil, email: 'long-account-name@example.com', guest: false)

      presenter = described_class.new(user: user, view_context: view_context)

      aggregate_failures do
        expect(presenter.user_status_label).to eq(I18n.t('settings.index.user.registered'))
        expect(presenter.user_name_label).to eq(I18n.t('settings.index.user.name_missing'))
        expect(presenter.user_email_label).to eq('masked@example.com')
        expect(view_context).to have_received(:masked_email_with_domain).with(
          'long-account-name@example.com',
          local_max_length: 10,
          local_max_length_mobile: 6,
          domain_max_length_mobile: 14
        )
      end
    end

    it 'returns guest labels without exposing the internal email' do
      user = build_stubbed(:user, name: nil, email: 'guest-internal@example.com', guest: true)

      presenter = described_class.new(user: user, view_context: view_context)

      aggregate_failures do
        expect(presenter).to be_guest
        expect(presenter.user_status_label).to eq(I18n.t('settings.index.user.guest'))
        expect(presenter.user_name_label).to eq(I18n.t('users.display.guest_name'))
        expect(presenter.user_email_label).to eq(I18n.t('users.display.email_unregistered'))
        expect(view_context).not_to have_received(:masked_email_with_domain)
      end
    end
  end

  describe '#totp_state and #passkey_state' do
    it 'returns active states when the user has confirmed TOTP and a passkey' do
      user = create(:user)
      create(:totp_credential, user: user, confirmed_at: Time.current)
      create(:passkey, user: user)

      presenter = described_class.new(user: user, view_context: view_context)

      aggregate_failures do
        expect(presenter.totp_state).to eq(:active)
        expect(presenter.passkey_state).to eq(:active)
      end
    end

    it 'returns inactive states when authentication methods are missing' do
      presenter = described_class.new(user: create(:user), view_context: view_context)

      aggregate_failures do
        expect(presenter.totp_state).to eq(:inactive)
        expect(presenter.passkey_state).to eq(:inactive)
      end
    end
  end

  describe '#theme_options and #rounding_mode_options' do
    it 'returns display option payloads used by the settings controls' do
      presenter = described_class.new(user: build_stubbed(:user), view_context: view_context)

      aggregate_failures do
        expect(presenter.theme_options.map { |option| option[:value] }).to eq(%w[system light dark])
        expect(presenter.rounding_mode_options.map { |option| option[:value] }).to eq(%w[floor round ceil])
      end
    end
  end
end
