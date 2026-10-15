require 'rails_helper'

RSpec.describe Receipts::Registrations::Token do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { build_stubbed(:user) }

  it '発行したtokenを同じuserと登録種別だけで検証できる' do
    token = described_class.issue(user: user, kind: 'upload')
    result = described_class.verify(user: user, token: token)

    aggregate_failures do
      expect(result.state).to eq('valid')
      expect(result.kind).to eq('upload')
      expect(result.operation_key).to match(/\A[0-9a-f]{64}\z/)
      expect(result.expires_at - result.issued_at).to eq(24.hours)
      expect(described_class.verify(user: build_stubbed(:user), token: token).state).to eq('invalid')
    end
  end

  it '期限は署名内容から検証し受付行を必要としない' do
    travel_to(Time.zone.local(2026, 10, 13, 12)) do
      token = described_class.issue(user: user, kind: 'manual')

      travel 24.hours - 1.second
      expect(described_class.verify(user: user, token: token).state).to eq('valid')
      travel 1.second
      expect(described_class.verify(user: user, token: token).state).to eq('expired')
    end
  end

  it '改変と型違いと長大tokenを入力値を出力せず拒否する' do
    token = described_class.issue(user: user, kind: 'manual')

    [ nil, {}, token.reverse, 'private-token' * 1000 ].each do |value|
      expect(described_class.verify(user: user, token: value).state).to eq('invalid')
    end
  end

  it '同じユーザーのsession更新後も検証でき新しい操作は別IDになる' do
    token = described_class.issue(user: user, kind: 'manual')
    user.session_version += 1

    aggregate_failures do
      expect(described_class.verify(user: user, token: token).state).to eq('valid')
      expect(described_class.issue(user: user, kind: 'manual')).not_to eq(token)
    end
  end

  it '未知の発行種別を拒否する' do
    expect { described_class.issue(user: user, kind: 'edit') }
      .to raise_error(ArgumentError, 'invalid registration token request')
  end

  it '別用途で署名されたtokenは同じ本人でも受付に使用しない' do
    issued_at = Time.current.to_i
    unrelated_token = Rails.application.message_verifier('unrelated_form').generate(
      {
        'version' => 1,
        'user_id' => user.id,
        'kind' => 'manual',
        'operation_key' => 'a' * 64,
        'issued_at' => issued_at,
        'expires_at' => issued_at + 24.hours.to_i
      },
      purpose: 'unrelated_form'
    )

    expect(described_class.verify(user: user, token: unrelated_token).state).to eq('invalid')
  end
end
