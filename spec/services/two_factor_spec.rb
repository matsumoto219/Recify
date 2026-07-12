require 'rails_helper'

RSpec.describe TwoFactor do
  uses_transaction '同じrecovery codeの並行検証を1回だけ成功させる'

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
      document = Nokogiri::XML(svg)
      svg_node = document.at_xpath('//*[local-name()="svg"]')
      path_node = document.at_xpath('//*[local-name()="path"]')

      aggregate_failures do
        expect(svg).to include('<svg')
        expect(svg).to include('</svg>')
        expect(svg_node['viewBox']).to match(/\A0 0 \d+ \d+\z/)
        expect(svg_node['width']).to eq('100%')
        expect(svg_node['height']).to eq('100%')
        expect(path_node['d']).to be_present
        expect(path_node['transform']).to include('scale(')
      end
    end

    it 'setup materialをDB保存なしで生成する' do
      user = create(:user, email: 'setup-user@example.com')

      setup = described_class.prepare_totp_setup(user: user)

      aggregate_failures do
        expect(setup.secret).to match(/\A[A-Z2-7]+\z/)
        expect(setup.provisioning_uri).to include('setup-user%40example.com')
        expect(setup.qr_svg).to include('<svg')
        expect(user.reload.totp_credential).to be_blank
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

    it 'transient secretのsetup確認成功でcredentialとrecovery codesを作成する' do
      user = create(:user)
      secret = described_class.generate_totp_secret
      code = ROTP::TOTP.new(secret, issuer: 'Recify').now

      confirmation = described_class.confirm_totp_setup(user: user, secret: secret, code: code)

      aggregate_failures do
        expect(confirmation.credential).to be_confirmed
        expect(confirmation.credential.totp_secret).to eq(secret)
        expect(confirmation.recovery_codes.size).to eq(10)
        expect(user.reload.recovery_codes.count).to eq(10)
      end
    end

    it 'setup確認失敗ではcredentialを作成しない' do
      user = create(:user)

      expect {
        described_class.confirm_totp_setup(user: user, secret: described_class.generate_totp_secret, code: '000000')
      }.to raise_error(TwoFactor::VerificationError, 'totp_code_invalid')

      aggregate_failures do
        expect(user.reload.totp_credential).to be_blank
        expect(user.recovery_codes.count).to eq(0)
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

    it 'TOTPを無効化するとcredentialとrecovery codesを削除する' do
      user = create(:user)
      create(:totp_credential, user: user)
      described_class.generate_recovery_codes_for(user: user)

      described_class.disable_totp_for(user: user)

      aggregate_failures do
        expect(user.reload.totp_credential).to be_blank
        expect(user.recovery_codes.count).to eq(0)
      end
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

    it '同じrecovery codeの並行検証を1回だけ成功させる' do
      email = "recovery-race-#{SecureRandom.hex(8)}@example.test"
      user = create(:user, email: email)
      code = described_class.generate_recovery_codes_for(user: user).first
      mutex = Mutex.new
      condition = ConditionVariable.new
      update_arrivals = 0
      update_barrier = proc do
        mutex.synchronize do
          update_arrivals += 1
          if update_arrivals < 2
            condition.wait(mutex, 0.5)
          else
            condition.broadcast
          end
        end
      end
      RecoveryCode.set_callback(:update, :before, update_barrier)

      ready = Queue.new
      start = Queue.new
      results = Queue.new
      threads = 2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            start.pop
            thread_user = User.find(user.id)
            results << described_class.verify_recovery_code(user: thread_user, code: code)
          rescue StandardError => error
            results << error
          end
        end
      end

      2.times { ready.pop }
      2.times { start << true }
      threads.each(&:join)
      outcomes = 2.times.map { results.pop }

      aggregate_failures do
        expect(outcomes.grep(RecoveryCode).size).to eq(1)
        expect(outcomes.grep(TwoFactor::VerificationError).size).to eq(1)
        expect(user.recovery_codes.where.not(used_at: nil).count).to eq(1)
      end
    ensure
      RecoveryCode.skip_callback(:update, :before, update_barrier) if update_barrier
      User.find_by(email: email)&.destroy!
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

    it 'TOTP未設定ならrecovery code statusはdisabledにする' do
      user = create(:user)

      status = described_class.recovery_codes_status(user: user)

      aggregate_failures do
        expect(status.enabled).to be(false)
        expect(status.unused_count).to eq(0)
        expect(status.status).to eq(:missing)
      end
    end

    it '未使用codeが3件以上ならokにする' do
      user = create(:user)
      create(:totp_credential, user: user, confirmed_at: Time.current)
      described_class.generate_recovery_codes_for(user: user)

      status = described_class.recovery_codes_status(user: user)

      aggregate_failures do
        expect(status.enabled).to be(true)
        expect(status.unused_count).to eq(10)
        expect(status.status).to eq(:ok)
      end
    end

    it '未使用codeが1〜2件ならlowにする' do
      user = create(:user)
      create(:totp_credential, user: user, confirmed_at: Time.current)
      codes = described_class.generate_recovery_codes_for(user: user)
      codes.first(8).each { |code| described_class.verify_recovery_code(user: user, code: code) }

      status = described_class.recovery_codes_status(user: user)

      aggregate_failures do
        expect(status.unused_count).to eq(2)
        expect(status.status).to eq(:low)
      end
    end

    it '全code使用済みならemptyにする' do
      user = create(:user)
      create(:totp_credential, user: user, confirmed_at: Time.current)
      codes = described_class.generate_recovery_codes_for(user: user)
      codes.each { |code| described_class.verify_recovery_code(user: user, code: code) }

      status = described_class.recovery_codes_status(user: user)

      aggregate_failures do
        expect(status.unused_count).to eq(0)
        expect(status.status).to eq(:empty)
      end
    end

    it 'TOTP有効でcode未発行ならmissingにする' do
      user = create(:user)
      create(:totp_credential, user: user, confirmed_at: Time.current)

      status = described_class.recovery_codes_status(user: user)

      aggregate_failures do
        expect(status.enabled).to be(true)
        expect(status.unused_count).to eq(0)
        expect(status.status).to eq(:missing)
      end
    end
  end
end
