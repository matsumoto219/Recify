require 'rails_helper'

RSpec.describe User, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  before do
    ActionMailer::Base.deliveries.clear
  end

  after do
    ActionMailer::Base.deliveries.clear
  end

  describe 'defaults' do
    it 'push_notification_enabled は初期値trueにする' do
      user = create(:user)

      expect(user.push_notification_enabled).to be(true)
    end

    it 'delete_confirmation_enabled は初期値trueにする' do
      user = create(:user)

      expect(user.delete_confirmation_enabled).to be(true)
    end

    it 'rounding mode は税額floor・割引額roundを初期値にする' do
      user = create(:user)

      aggregate_failures do
        expect(user.tax_rounding_mode).to eq('floor')
        expect(user.discount_rounding_mode).to eq('round')
      end
    end

    it 'admin は初期値falseにする' do
      user = create(:user)

      expect(user).not_to be_admin
    end

    it 'レシート画像保持設定は初期状態でsystem defaultを継承する' do
      user = create(:user)

      aggregate_failures do
        expect(user.keep_receipt_images).to be_nil
        expect(user.effective_keep_receipt_images).to be(true)
      end
    end
  end

  describe 'admin flag' do
    it 'admin userを作成できる' do
      user = create(:user, :admin)

      expect(user).to be_admin
    end
  end

  describe 'associations' do
    it 'passkeysはuser削除時に削除する' do
      user = create(:user)
      passkey = create(:passkey, user: user)

      user.destroy!

      expect(Passkey.where(id: passkey.id)).not_to exist
    end

    it 'requested_by_userとして紐づく解析runはuser削除時にnilへ戻す' do
      receipt_owner = create(:user)
      requested_by_user = create(:user)
      receipt = create(:receipt, user: receipt_owner)
      run = create(:receipt_analysis_run, :admin_retry, receipt:, requested_by_user:)

      requested_by_user.destroy!

      expect(run.reload.requested_by_user).to be_nil
    end
  end

  describe '#ensure_webauthn_id!' do
    it 'ランダムなstable user handleを保存する' do
      user = create(:user, webauthn_id: nil)

      webauthn_id = user.ensure_webauthn_id!

      aggregate_failures do
        expect(webauthn_id).to be_present
        expect(user.reload.webauthn_id).to eq(webauthn_id)
      end
    end

    it '既存webauthn_idがあれば変更しない' do
      user = create(:user, webauthn_id: 'existing-user-handle')

      expect(user.ensure_webauthn_id!).to eq('existing-user-handle')
      expect(user.reload.webauthn_id).to eq('existing-user-handle')
    end

    it 'webauthn_idにunique indexを持つ' do
      index = ActiveRecord::Base.connection.indexes(:users).find do |candidate|
        candidate.name == 'index_users_on_webauthn_id'
      end

      expect(index).to be_present
      expect(index.unique).to be(true)
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
        expect(user.name).to be_blank
        expect(user.legal_acceptances).to be_empty
      end
    end
  end

  describe 'legal agreement validation' do
    it '同意必須contextでは同意済みなら有効にする' do
      user = build(:user, legal_agreement_required: true, legal_agreement: '1')

      expect(user).to be_valid
      expect { user.save! }.not_to change(LegalAcceptance, :count)
    end

    it '同意必須contextで未同意なら不正にする' do
      user = build(:user, legal_agreement_required: true, legal_agreement: '0')

      expect(user).not_to be_valid
      expect(user.errors.full_messages_for(:legal_agreement)).to include(
        "#{I18n.t('activerecord.attributes.user.legal_agreement')}#{I18n.t('activerecord.errors.models.user.attributes.legal_agreement.accepted')}"
      )
    end

    it '通常の更新では同意validationを要求しない' do
      user = create(:user)

      expect(user.update(name: 'Updated Name')).to be(true)
    end
  end

  describe 'unconfirmed_email uniqueness' do
    it 'case insensitiveに確認待ちメールアドレスの重複を不正にする' do
      create(:user, unconfirmed_email: 'Pending-Duplicate@example.com')
      user = build(:user, unconfirmed_email: 'pending-duplicate@example.com')

      expect(user).not_to be_valid

      aggregate_failures do
        expect(user.errors.full_messages_for(:unconfirmed_email)).to include(
          "#{I18n.t('activerecord.attributes.user.unconfirmed_email')}#{I18n.t('activerecord.errors.models.user.attributes.unconfirmed_email.taken')}"
        )
        expect(user.errors.full_messages_for(:email)).to include(
          "#{I18n.t('activerecord.attributes.user.email')}#{I18n.t('activerecord.errors.models.user.attributes.email.taken')}"
        )
      end
    end

    it 'unconfirmed_emailがnilまたはblankなら複数許可する' do
      create(:user, unconfirmed_email: nil)
      create(:user, unconfirmed_email: '')

      aggregate_failures do
        expect(build(:user, unconfirmed_email: nil)).to be_valid
        expect(build(:user, unconfirmed_email: '')).to be_valid
      end
    end

    it 'partial expression unique indexを持つ' do
      index = ActiveRecord::Base.connection.indexes(:users).find do |candidate|
        candidate.name == 'index_users_on_lower_unconfirmed_email_unique'
      end

      aggregate_failures do
        expect(index).to be_present
        expect(index.unique).to be(true)
        expect(index.where).to include("unconfirmed_email IS NOT NULL")
        expect(index.where).to include("unconfirmed_email")
        expect(index.where).to include("<> ''")
      end
    end

    it 'DB制約でも大文字小文字違いの重複を防ぐ' do
      first_user = create(:user)
      second_user = create(:user)
      first_user.update_columns(unconfirmed_email: 'db-pending@example.com')

      expect do
        second_user.update_columns(unconfirmed_email: 'DB-PENDING@example.com')
      end.to raise_error(ActiveRecord::RecordNotUnique)
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

  describe 'display labels' do
    it '名前なしguestは内部メールを表示名・表示メールに使わない' do
      guest = described_class.guest!

      aggregate_failures do
        expect(guest.name).to be_blank
        expect(guest.display_name).to eq(I18n.t('users.display.guest_name'))
        expect(guest.display_email).to eq(I18n.t('users.display.email_unregistered'))
        expect(guest.display_name).not_to include(guest.email)
        expect(guest.display_email).not_to include(guest.email)
      end
    end

    it '通常ユーザーは名前がなければメールアドレスを表示名に使う' do
      user = create(:user, name: '')

      aggregate_failures do
        expect(user.display_name).to eq(user.email)
        expect(user.display_email).to eq(user.email)
      end
    end
  end

  describe '#guest_registration_pending?' do
    it 'guestの本登録申請中だけtrueにする' do
      guest = described_class.guest!
      guest.start_guest_registration(
        email: 'pending-guest@example.com',
        password: 'password123',
        password_confirmation: 'password123',
        legal_agreement: '1'
      )

      aggregate_failures do
        expect(guest.reload).to be_guest_registration_pending
        expect(create(:user)).not_to be_guest_registration_pending
      end
    end
  end

  describe '#confirm' do
    it 'guest本登録のconfirmation完了時だけguest:falseにする' do
      guest = described_class.guest!
      guest.start_guest_registration(
        email: 'complete-guest@example.com',
        password: 'password123',
        password_confirmation: 'password123',
        legal_agreement: '1'
      )

      expect do
        guest.confirm
      end.to change { guest.reload.guest? }.from(true).to(false)

      aggregate_failures do
        expect(guest.email).to eq('complete-guest@example.com')
        expect(guest.unconfirmed_email).to be_nil
      end
    end

    it '通常ユーザーのreconfirmationではguest状態を変更しない' do
      user = create(:user)
      user.update!(email: 'normal-reconfirm@example.com')

      expect do
        user.confirm
      end.not_to change { user.reload.guest? }

      aggregate_failures do
        expect(user.email).to eq('normal-reconfirm@example.com')
        expect(user.unconfirmed_email).to be_nil
      end
    end
  end

  describe 'guest devise notifications' do
    it 'guest本登録のconfirmation mailだけは新メール宛に送る' do
      guest = described_class.guest!
      fake_email = guest.email

      guest.start_guest_registration(
        email: 'guest-notification-confirm@example.com',
        password: 'password123',
        password_confirmation: 'password123',
        legal_agreement: '1'
      )

      delivered_recipients = ActionMailer::Base.deliveries.flat_map(&:to)

      aggregate_failures do
        expect(ActionMailer::Base.deliveries.size).to eq(1)
        expect(delivered_recipients).to include('guest-notification-confirm@example.com')
        expect(delivered_recipients).not_to include(fake_email)
      end
    end

    it 'guestのfake email宛Devise通知は送らない' do
      guest = described_class.guest!

      guest.send_reset_password_instructions
      guest.lock_access!(send_instructions: true)

      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end

  describe 'avatar validation' do
    it 'valid image content is accepted' do
      user = build(:user)
      user.avatar.attach(
        io: StringIO.new(File.binread(Rails.root.join('spec/fixtures/files/receipt_sample.jpg'))),
        filename: 'avatar.jpg',
        content_type: 'image/jpeg'
      )

      expect(user).to be_valid
    end

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

    it 'image content type with non-image body uses locale-backed error message' do
      user = build(:user)
      user.avatar.attach(
        io: StringIO.new('not an image'),
        filename: 'avatar.jpg',
        content_type: 'image/jpeg'
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

      expected_message = "#{I18n.t('activerecord.attributes.user.avatar')}#{I18n.t('activerecord.errors.models.user.attributes.avatar.file_too_large', max_size: ActiveSupport::NumberHelper.number_to_human_size(User.avatar_max_file_size))}"
      expect(user.errors.full_messages_for(:avatar)).to include(expected_message)
    end
  end

  describe 'storage_limit_bytes validation' do
    it '0以下は不正にする' do
      user = build(:user, storage_limit_bytes: 0)

      expect(user).not_to be_valid
    end
  end

  describe 'rounding mode validation' do
    it 'floor / round / ceil を有効にする' do
      User::ROUNDING_MODES.each do |rounding_mode|
        user = build(:user, tax_rounding_mode: rounding_mode, discount_rounding_mode: rounding_mode)

        expect(user).to be_valid
      end
    end

    it '不正な税額rounding modeは無効にする' do
      user = build(:user, tax_rounding_mode: 'bankers')

      expect(user).not_to be_valid
    end

    it '不正な割引rounding modeは無効にする' do
      user = build(:user, discount_rounding_mode: 'bankers')

      expect(user).not_to be_valid
    end
  end

  describe '#effective_keep_receipt_images' do
    it 'user overrideがtrueならtrueを返す' do
      user = create(:user, keep_receipt_images: true)

      expect(user.effective_keep_receipt_images).to be(true)
    end

    it 'user overrideがfalseならfalseを返す' do
      user = create(:user, keep_receipt_images: false)

      expect(user.effective_keep_receipt_images).to be(false)
    end

    it 'user overrideがnilならSystemSettings defaultを返す' do
      create(
        :system_setting,
        key: 'storage.keep_receipt_images_default',
        value: SystemSettings.stored_value(false)
      )
      user = create(:user, keep_receipt_images: nil)

      expect(user.effective_keep_receipt_images).to be(false)
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
