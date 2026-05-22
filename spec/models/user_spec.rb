require 'rails_helper'

RSpec.describe User, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  describe 'defaults' do
    it 'push_notification_enabled は初期値trueにする' do
      user = create(:user)

      expect(user.push_notification_enabled).to be(true)
    end

    it 'delete_confirmation_enabled は初期値trueにする' do
      user = create(:user)

      expect(user.delete_confirmation_enabled).to be(true)
    end
  end

  describe 'devise modules' do
    it 'Trackable / Confirmable / Lockable を有効にする' do
      expect(described_class.devise_modules).to include(:trackable, :confirmable, :lockable)
    end
  end

  describe 'factory confirmation state' do
    it '通常user factoryはconfirmed済みにする' do
      user = create(:user)

      expect(user).to be_confirmed
    end

    it 'unconfirmed traitは未確認userを作る' do
      user = create(:user, :unconfirmed)

      expect(user).not_to be_confirmed
    end
  end

  describe '.guest!' do
    it 'confirmed済みのゲストユーザーを作成する' do
      user = described_class.guest!

      aggregate_failures do
        expect(user).to be_persisted
        expect(user).to be_guest
        expect(user).to be_confirmed
        expect(user.confirmation_token).to be_nil
      end
    end
  end

  describe '.guest_cleanup_candidates' do
    around do |example|
      travel_to(Time.zone.parse('2026-05-22 10:00:00')) { example.run }
    end

    it 'confirmed済みで7日以上前にログインしたguestだけを返す' do
      old_guest = create(:user, guest: true, last_sign_in_at: 7.days.ago)
      recent_guest = create(:user, guest: true, last_sign_in_at: 6.days.ago)
      regular_user = create(:user, guest: false, last_sign_in_at: 8.days.ago)
      unconfirmed_guest = create(:user, :unconfirmed, guest: true, last_sign_in_at: 8.days.ago)

      candidates = described_class.guest_cleanup_candidates

      aggregate_failures do
        expect(candidates).to include(old_guest)
        expect(candidates).not_to include(recent_guest)
        expect(candidates).not_to include(regular_user)
        expect(candidates).not_to include(unconfirmed_guest)
      end
    end

    it 'last_sign_in_atがないguestはupdated_atで判定する' do
      old_guest = create(:user, guest: true, last_sign_in_at: nil)
      recent_guest = create(:user, guest: true, last_sign_in_at: nil)
      old_guest.update_columns(updated_at: 8.days.ago)
      recent_guest.update_columns(updated_at: 6.days.ago)

      candidates = described_class.guest_cleanup_candidates

      aggregate_failures do
        expect(candidates).to include(old_guest)
        expect(candidates).not_to include(recent_guest)
      end
    end
  end

  describe 'avatar validation' do
    it 'invalid content type uses locale-backed error message' do
      user = build(:user)
      user.avatar.attach(
        io: StringIO.new('not an image'),
        filename: 'avatar.txt',
        content_type: 'text/plain'
      )

      expect(user).not_to be_valid

      expected_message = "#{I18n.t('activerecord.attributes.user.avatar')}#{I18n.t('activerecord.errors.models.user.attributes.avatar.invalid_content_type')}"
      expect(user.errors.full_messages_for(:avatar)).to include(expected_message)
    end

    it 'oversized avatar uses locale-backed error message' do
      user = build(:user)
      user.avatar.attach(
        io: StringIO.new('0' * (5.megabytes + 1)),
        filename: 'avatar.jpg',
        content_type: 'image/jpeg'
      )

      expect(user).not_to be_valid

      expected_message = "#{I18n.t('activerecord.attributes.user.avatar')}#{I18n.t('activerecord.errors.models.user.attributes.avatar.file_too_large')}"
      expect(user.errors.full_messages_for(:avatar)).to include(expected_message)
    end
  end

  describe 'storage_limit_bytes validation' do
    it '0以下は不正にする' do
      user = build(:user, storage_limit_bytes: 0)

      expect(user).not_to be_valid
    end
  end

  describe 'storage wrapper methods' do
    let(:user) { create(:user, storage_limit_bytes: 100.kilobytes) }

    def attach_avatar(byte_size)
      blob = ActiveStorage::Blob.create!(
        key: SecureRandom.uuid,
        filename: 'avatar.jpg',
        content_type: 'image/jpeg',
        metadata: {},
        service_name: ActiveStorage::Blob.service.name,
        byte_size: byte_size,
        checksum: SecureRandom.base64(16)
      )
      ActiveStorage::Attachment.create!(
        name: 'avatar',
        record: user,
        blob: blob
      )
      blob
    end

    it 'storage_usageを返す' do
      expect(user.storage_usage).to be_a(Storage::UsageCalculator)
    end

    it 'storage_used_bytesを返す' do
      attach_avatar(10.kilobytes)

      expect(user.storage_used_bytes).to eq(10.kilobytes)
    end

    it 'storage_can_add?で追加可能容量を判定する' do
      attach_avatar(90.kilobytes)

      aggregate_failures do
        expect(user.storage_can_add?(10.kilobytes)).to be(true)
        expect(user.storage_can_add?(11.kilobytes)).to be(false)
      end
    end
  end
end
