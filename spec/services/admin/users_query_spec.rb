require 'rails_helper'

RSpec.describe Admin::UsersQuery do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    travel_to(Time.zone.parse('2026-05-26 12:00:00')) { example.run }
  end

  describe '.call' do
    it 'latest順で管理画面用recordを返す' do
      older = create(:user, email: 'older@example.com', created_at: 2.days.ago)
      newer = create(:user, email: 'newer@example.com', created_at: 1.day.ago)
      create(:passkey, user: newer, last_used_at: 1.hour.ago)
      create_list(:receipt, 2, user: newer)

      result = described_class.call
      record = result.records.first

      aggregate_failures do
        expect(result.records.map { |item| item[:id] }).to eq([ newer.id, older.id ])
        expect(record).to include(
          id: newer.id,
          email: 'newer@example.com',
          admin: false,
          guest: false,
          confirmed: true,
          locked: false,
          passkeys_count: 1,
          receipts_count: 2,
          latest_passkey_last_used_at: 1.hour.ago
        )
        expect(result.limit).to eq(50)
        expect(result.offset).to eq(0)
        expect(result.total_count).to eq(2)
      end
    end

    it 'email / admin / guest / confirmed / locked / has_passkeyで絞り込める' do
      target = create(:user, :admin, email: 'target-admin@example.com')
      create(:passkey, user: target)
      create(:user, email: 'normal@example.com')
      create(:user, :unconfirmed, email: 'pending@example.com')
      create(:user, email: 'guest@example.com', guest: true)
      locked = create(:user, email: 'locked@example.com', locked_at: 1.hour.ago)

      aggregate_failures do
        expect(described_class.call(email: 'TARGET').records.map { |record| record[:id] }).to eq([ target.id ])
        expect(described_class.call(admin: 'true').records.map { |record| record[:id] }).to eq([ target.id ])
        expect(described_class.call(guest: 'true').records.map { |record| record[:id] }).to eq([ User.find_by!(email: 'guest@example.com').id ])
        expect(described_class.call(confirmed: 'false').records.map { |record| record[:id] }).to eq([ User.find_by!(email: 'pending@example.com').id ])
        expect(described_class.call(locked: 'true').records.map { |record| record[:id] }).to eq([ locked.id ])
        expect(described_class.call(has_passkey: 'true').records.map { |record| record[:id] }).to eq([ target.id ])
      end
    end

    it 'limit上限とoffsetを適用する' do
      users = Array.new(3) { |index| create(:user, created_at: index.minutes.ago) }

      result = described_class.call(limit: 500, offset: 1)

      aggregate_failures do
        expect(result.limit).to eq(100)
        expect(result.offset).to eq(1)
        expect(result.total_count).to eq(3)
        expect(result.records.map { |record| record[:id] }).to eq(users.sort_by(&:created_at).reverse.drop(1).map(&:id))
      end
    end

    it 'passkey credentialや認証系カラムをrecordへ含めない' do
      user = create(:user)
      create(:passkey, user: user, credential_id: 'credential-secret-value', public_key: 'PUBLIC KEY SECRET')
      user.update_column(:reset_password_token, 'RESET TOKEN SECRET')

      json = described_class.call(id: user.id).records.first.to_json

      aggregate_failures do
        expect(json).to include(user.email)
        expect(json).not_to include('credential-secret-value')
        expect(json).not_to include('PUBLIC KEY SECRET')
        expect(json).not_to include('encrypted_password')
        expect(json).not_to include('RESET TOKEN SECRET')
        expect(json).not_to include('reset_password_token')
        expect(json).not_to include('challenge')
        expect(json).not_to include('raw_response')
        expect(json).not_to include('prompt')
      end
    end
  end

  describe '.find' do
    it 'idに一致するrecordを返す' do
      user = create(:user)

      expect(described_class.find(id: user.id)).to include(id: user.id, email: user.email)
    end

    it '存在しないidはnilを返す' do
      expect(described_class.find(id: 999_999)).to be_nil
    end
  end
end
