require 'rails_helper'

RSpec.describe 'Account recovery enumeration resistance', type: :request do
  def observable_response
    {
      status: response.status,
      location: response.location,
      notice: flash[:notice],
      alert: flash[:alert]
    }
  end

  it 'password resetは登録済み/未登録emailで同じ応答を返す' do
    user = create(:user)

    post user_password_path, params: { user: { email: user.email } }
    known_response = observable_response
    expect(ActionMailer::Base.deliveries.size).to eq(1)
    follow_redirect!

    ActionMailer::Base.deliveries.clear
    post user_password_path, params: { user: { email: 'missing-password@example.test' } }

    aggregate_failures do
      expect(observable_response).to eq(known_response)
      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end

  it 'confirmation resendは登録済み/未登録emailで同じ応答を返す' do
    user = create(:user, :unconfirmed)
    ActionMailer::Base.deliveries.clear

    post user_confirmation_path, params: { user: { email: user.email } }
    known_response = observable_response
    expect(ActionMailer::Base.deliveries.size).to eq(1)
    follow_redirect!

    ActionMailer::Base.deliveries.clear
    post user_confirmation_path, params: { user: { email: 'missing-confirmation@example.test' } }

    aggregate_failures do
      expect(observable_response).to eq(known_response)
      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end

  it 'unlock resendは登録済み/未登録emailで同じ応答を返す' do
    user = create(:user)
    user.lock_access!(send_instructions: false)
    ActionMailer::Base.deliveries.clear

    post user_unlock_path, params: { user: { email: user.email } }
    known_response = observable_response
    expect(ActionMailer::Base.deliveries.size).to eq(1)
    follow_redirect!

    ActionMailer::Base.deliveries.clear
    post user_unlock_path, params: { user: { email: 'missing-unlock@example.test' } }

    aggregate_failures do
      expect(observable_response).to eq(known_response)
      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end
end
