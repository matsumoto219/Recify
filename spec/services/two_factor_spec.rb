require 'rails_helper'

RSpec.describe TwoFactor do
  describe 'TOTP' do
    it 'secretを生成する' do
      secret = described_class.generate_totp_secret

      aggregate_failures do
        expect(secret).to be_present
        expect(secret).to match(/\A[A-Z2-7]+\z/)
      end
    end

    it 'provisioning URIを生成する' do
      user = create(:user, email: 'totp-user@example.com')
      secret = described_class.generate_totp_secret

      uri = described_class.totp_provisioning_uri(user: user, secret: secret)

      aggregate_failures do
        expect(uri).to start_with('otpauth://totp/')
        expect(uri).to include('issuer=Recify')
        expect(uri).to include('totp-user%40example.com')
        expect(uri).to include(secret)
      end
    end

    it 'QR SVGを文字列として生成する' do
      svg = described_class.totp_qr_svg(
        provisioning_uri: 'otpauth://totp/Recify:user@example.com?secret=ABC&issuer=Recify'
      )

      aggregate_failures do
        expect(svg).to include('<svg')
        expect(svg).to include('</svg>')
      end
    end

    it 'setup verify成功でconfirmed_atとlast_accepted_time_stepを保存する' do
      user = create(:user)
      secret = described_class.generate_totp_secret
      create(:totp_credential, user: user, totp_secret: secret, confirmed_at: nil, last_accepted_time_step: nil)
      code = ROTP::TOTP.new(secret, issuer: 'Recify').now

      credential = described_class.verify_totp_setup(user: user, code: code)

      aggregate_failures do
        expect(credential).to be_confirmed
        expect(credential.last_used_at).to be_present
        expect(credential.last_accepted_time_step).to be_present
      end
    end

    it '同一time stepのTOTP再利用を拒否する' do
      user = create(:user)
      secret = described_class.generate_totp_secret
      create(:totp_credential, user: user, totp_secret: secret, confirmed_at: Time.current, last_accepted_time_step: nil)
      code = ROTP::TOTP.new(secret, issuer: 'Recify').now

      described_class.verify_totp(user: user, code: code)

      expect {
        described_class.verify_totp(user: user, code: code)
      }.to raise_error(TwoFactor::VerificationError, 'totp_code_invalid')
    end

    it '未確認credentialの通常verifyを拒否する' do
      user = create(:user)
      create(:totp_credential, user: user, confirmed_at: nil)

      expect {
        described_class.verify_totp(user: user, code: '123456')
      }.to raise_error(TwoFactor::VerificationError, 'totp_credential_unconfirmed')
    end
  end

  describe 'recovery codes' do
    it '10件発行し、平文をDB保存しない' do
      user = create(:user)

      codes = described_class.generate_recovery_codes_for(user: user)

      aggregate_failures do
        expect(codes.size).to eq(10)
        expect(user.recovery_codes.count).to eq(10)
        codes.each do |code|
          expect(RecoveryCode.where(code_digest: code).exists?).to be(false)
        end
        expect(user.recovery_codes.pluck(:code_digest).join("\n")).not_to include(*codes)
      end
    end

    it 'verify成功でused_atを保存し、再利用を拒否する' do
      user = create(:user)
      code = described_class.generate_recovery_codes_for(user: user).first

      recovery_code = described_class.verify_recovery_code(user: user, code: code)

      aggregate_failures do
        expect(recovery_code).to be_used
        expect {
          described_class.verify_recovery_code(user: user, code: code)
        }.to raise_error(TwoFactor::VerificationError, 'recovery_code_invalid')
      end
    end

    it '再生成時に既存codeを削除して新規発行する' do
      user = create(:user)
      old_codes = described_class.generate_recovery_codes_for(user: user)
      old_digests = user.recovery_codes.pluck(:code_digest)

      new_codes = described_class.regenerate_recovery_codes_for(user: user)

      aggregate_failures do
        expect(new_codes.size).to eq(10)
        expect(user.recovery_codes.count).to eq(10)
        expect(user.recovery_codes.pluck(:code_digest)).not_to include(*old_digests)
        expect {
          described_class.verify_recovery_code(user: user, code: old_codes.first)
        }.to raise_error(TwoFactor::VerificationError, 'recovery_code_invalid')
      end
    end

    it 'コード表記のハイフンや空白に依存せずdigestを一致させる' do
      compact_code = 'ABCD1234EFGH5678IJKL'
      dashed_code = 'ABCD-1234-EFGH-5678-IJKL'

      expect(described_class.recovery_code_digest(compact_code)).to eq(
        described_class.recovery_code_digest(dashed_code)
      )
    end
  end
end
