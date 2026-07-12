require 'rails_helper'

RSpec.describe 'Admin users', type: :request do
  include ActiveJob::TestHelper

  around do |example|
    original_show_exceptions = Rails.application.env_config['action_dispatch.show_exceptions']
    original_show_detailed_exceptions = Rails.application.env_config['action_dispatch.show_detailed_exceptions']
    original_adapter = ActiveJob::Base.queue_adapter

    Rails.application.env_config['action_dispatch.show_exceptions'] = :all
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = false
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs

    example.run
  ensure
    clear_enqueued_jobs
    ActiveJob::Base.queue_adapter = original_adapter
    Rails.application.env_config['action_dispatch.show_exceptions'] = original_show_exceptions
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = original_show_detailed_exceptions
  end

  def comparable_headers
    response.headers.to_h.except('x-request-id', 'x-runtime')
  end

  def expect_no_admin_side_effects(previous_audit_count)
    analysis_jobs = [ ReceiptOcrJob, ReceiptAiEnrichmentJob, ReceiptFinalizeJob ]

    expect(enqueued_jobs.select { |job| analysis_jobs.include?(job[:job]) }).to be_empty
    expect(AuditLog.count).to eq(previous_audit_count)
    expect(SystemOperations).not_to have_received(:execute_receipt_analysis_cleanup)
    expect(SystemOperations).not_to have_received(:update_setting)
    expect(SystemOperations).not_to have_received(:execute_user_operation)
    expect(SystemOperations).not_to have_received(:update_user_limit)
    expect(SystemOperations).not_to have_received(:execute_receipt_analysis_retry)
  end

  def stub_fresh_admin_reauthentication
    allow_any_instance_of(Admin::UsersController).to receive(:admin_passkey_reauthenticated?).and_return(true)
    allow_any_instance_of(Admin::UsersController).to receive(:admin_reauthentication_context).and_return(
      method: 'passkey',
      reauthenticated_at: Time.current
    )
  end

  before do
    allow(SystemOperations).to receive(:execute_receipt_analysis_cleanup)
    allow(SystemOperations).to receive(:update_setting)
    allow(SystemOperations).to receive(:execute_user_operation)
    allow(SystemOperations).to receive(:update_user_limit)
    allow(SystemOperations).to receive(:execute_receipt_analysis_retry)
  end

  describe 'GET /admin/users' do
    it '非ログインユーザーには既存404と同じbody/headerを返す' do
      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      get admin_users_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.location).to be_nil
        expect(response.body).not_to include('ユーザー管理')
      end
    end

    it '一般ユーザーには既存404と同じbody/headerを返す' do
      user = create(:user)
      sign_in user

      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      sign_in user
      get admin_users_path

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.body).not_to include('ユーザー管理')
      end
    end

    it 'adminユーザーはindexを閲覧でき、navigationにユーザー管理が出る' do
      admin = create(:user, :admin)
      target = create(:user, email: 'target-user@example.com')
      create(:passkey, user: target)
      create_list(:receipt, 2, user: target)
      previous_audit_count = AuditLog.count
      sign_in admin

      get admin_users_path
      document = Nokogiri::HTML(response.body)
      email_node = document.css("[aria-label='target-user@example.com']").first
      email_cell = email_node&.ancestors&.find { |node| node.name == 'td' }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('ユーザー管理')
        expect(response.body).to include('target-user@example.com')
        expect(response.body).to include(admin_user_path(target))
        expect(response.body).not_to include('translation missing')
        expect(document.at_css("[data-admin-user-passkeys-count=\"#{target.id}\"]").text).to eq('1')
        expect(document.at_css("[data-admin-user-receipts-count=\"#{target.id}\"]").text).to eq('2')
        expect(email_node).to be_present
        expect(email_node['class']).to include('inline-flex')
        expect(email_node['class']).not_to include('grid-cols')
        expect(email_node.css('span').map { |segment| segment.text.strip }).to eq([ 'target-user', '@', 'example.com' ])
        expect(email_node.css('span').first['class']).to include('flex-[0_999_auto]')
        expect(email_node.css('span').last['class']).to include('flex-[0_1_auto]')
        expect(email_cell['class']).to include('max-w-[18rem]')
        expect(response.body).to include('解析run管理')
        expect(response.body).to include('監査ログ')
        expect(response.body).not_to include('credential_id')
        expect(response.body).not_to include('public_key')
        expect(response.body).not_to include('challenge')
        expect_no_admin_side_effects(previous_audit_count)
      end
    end

    it 'filter paramsをAdmin queryへ渡す' do
      admin = create(:user, :admin)
      sign_in admin
      allow(Admin).to receive(:users).and_call_original

      get admin_users_path,
          params: {
            email: 'target',
            admin: 'true',
            guest: 'false',
            confirmed: 'true',
            locked: 'false',
            has_passkey: 'true',
            limit: '10',
            offset: '20'
          }

      expect(Admin).to have_received(:users).with(
        email: 'target',
        admin: 'true',
        guest: 'false',
        confirmed: 'true',
        locked: 'false',
        has_passkey: 'true',
        limit: '10',
        offset: '20'
      )
    end

    it 'paginationのnext/prevがfilter paramsを維持する' do
      admin = create(:user, :admin)
      sign_in admin
      Array.new(3) do |index|
        user = create(:user, email: "passkey-user-#{index}@example.com")
        create(:passkey, user: user)
      end

      get admin_users_path,
          params: {
            has_passkey: 'true',
            limit: '1',
            offset: '1'
          }

      document = Nokogiri::HTML(response.body)
      previous_href = document.css('a').find { |link| link.text.strip == '前へ' }['href']
      next_href = document.css('a').find { |link| link.text.strip == '次へ' }['href']
      previous_query = Rack::Utils.parse_nested_query(URI.parse(previous_href).query)
      next_query = Rack::Utils.parse_nested_query(URI.parse(next_href).query)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('3件中 2-2件を表示')
        expect(previous_query).to include('has_passkey' => 'true', 'limit' => '1', 'offset' => '0')
        expect(next_query).to include('has_passkey' => 'true', 'limit' => '1', 'offset' => '2')
      end
    end
  end

  describe 'GET /admin/users/:id' do
    it 'adminユーザーはshowを閲覧でき、security/passkey/receipt/audit状態を確認できる' do
      admin = create(:user, :admin)
      user = create(
        :user,
        email: 'show-user@example.com',
        current_sign_in_at: 1.hour.ago,
        last_sign_in_at: 2.hours.ago,
        current_sign_in_ip: '203.0.113.20',
        last_sign_in_ip: '203.0.113.21',
        sign_in_count: 3,
        failed_attempts: 1
      )
      LegalDocuments::Sync.call
      accepted_at = Time.zone.local(2026, 6, 22, 10, 0, 0)
      create(
        :legal_acceptance,
        user: user,
        legal_document: LegalDocument.current!(:terms, locale: :ja),
        accepted_at: accepted_at,
        acceptance_context: "signup"
      )
      create(
        :legal_acceptance,
        user: user,
        legal_document: LegalDocument.current!(:privacy, locale: :ja),
        accepted_at: accepted_at,
        acceptance_context: "signup"
      )
      create(:passkey, user: user, credential_id: 'hidden-credential-id', public_key: 'HIDDEN PUBLIC KEY', last_used_at: 30.minutes.ago)
      receipt = create(:receipt, user: user, store_name: 'ユーザー詳細レシート')
      quarantined_receipt = create(:receipt, :quarantined, user: user, store_name: '隔離中レシート')
      create(:user_limit_override, user: user, key: 'receipt_uploads_per_day', value: { 'value' => 75 })
      create(:usage_counter, user: user, key: 'receipt_uploads_per_day', used_count: 3)
      active_session = UserSession.create!(
        user: user,
        session_uid_digest: 'hidden-session-digest',
        session_version: user.session_version,
        started_at: 2.hours.ago,
        last_seen_at: 15.minutes.ago,
        ip_address: '203.0.113.40',
        user_agent: 'Support Browser',
        sign_in_method: 'password'
      )
      UserSession.create!(
        user: user,
        session_uid_digest: SecureRandom.hex(32),
        session_version: user.session_version + 1,
        started_at: 1.hour.ago,
        last_seen_at: 10.minutes.ago,
        ip_address: '203.0.113.41',
        user_agent: 'Old Version Browser',
        sign_in_method: 'passkey'
      )
      create(:audit_log, actor_user: user, action: 'receipt_analysis.ai_retry', target_uid: 'rcpt_user_show')
      previous_audit_count = AuditLog.count
      previous_user_session_count = UserSession.count
      sign_in admin

      get admin_user_path(user)
      document = Nokogiri::HTML(response.body)
      copy_sources = document.css('[data-controller="clipboard"] [data-clipboard-target="source"]').map { |node| node.text.strip }
      copy_labels = document.css('button[data-action="click->clipboard#copy"]').map { |node| node['aria-label'] }
      email_display_node = document.at_css(%([title="show-user@example.com"] [data-email-address-display]))
      email_copy_wrapper = email_display_node&.ancestors&.find { |node| node['data-controller'] == 'clipboard' }
      email_copy_value = email_display_node&.parent
      email_copy_label = I18n.t(
        'shared.clipboard.copy_label',
        label: User.human_attribute_name(:email)
      )
      legal_acceptances_card = document.at_css('#admin-user-legal-acceptances')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('ユーザー詳細')
        expect(response.body).to include('show-user@example.com')
        expect(response.body).not_to include('translation missing')
        expect(response.body).to include('最近のレシート')
        expect(response.body).to include('ユーザー詳細レシート')
        expect(response.body).to include('隔離中レシート')
        expect(response.body).to include(admin_receipt_path(receipt))
        expect(response.body).to include(admin_receipt_path(quarantined_receipt))
        expect(response.body).to include('隔離中')
        expect(response.body).to include('203.0.113.20')
        expect(response.body).to include('203.0.113.21')
        expect(response.body).to include('receipt_analysis.ai_retry')
        expect(response.body).to include('rcpt_user_show')
        expect(document.at_css('[data-admin-user-passkeys-count]').text).to eq('1')
        expect(document.at_css('[data-admin-user-receipts-count]').text).to eq('2')
        expect(document.at_css('[data-admin-user-active-sessions-count]').text).to eq('1')
        expect(legal_acceptances_card.text).to include('法務同意')
        expect(legal_acceptances_card.text).to include('利用規約')
        expect(legal_acceptances_card.text).to include('プライバシーポリシー')
        expect(legal_acceptances_card.text).to include('現行版同意済み')
        expect(legal_acceptances_card.text).to include(LegalDocument.current!(:terms, locale: :ja).version)
        expect(legal_acceptances_card.text).to include('signup')
        expect(response.body).to include('利用量と上限')
        expect(response.body).to include('min-w-[52rem] text-left text-sm')
        expect(response.body).to include('min-w-[8rem] whitespace-nowrap px-3 py-2 font-semibold')
        expect(response.body).to include('receipt_uploads_per_day')
        expect(response.body).to include('レシートアップロード数 / 日')
        expect(response.body).to include('ユーザー別上限')
        expect(response.body).to include('API公開時の上限')
        expect(document.at_css('[data-admin-user-limit-key="receipt_uploads_per_day"]').text).to include('75')
        expect(document.at_css('[data-admin-user-limit-key="receipt_uploads_per_day"]').text).to include('3')
        expect(response.body).to include('min-w-[64rem] text-left text-sm')
        expect(response.body).to include('min-w-[20rem] max-w-md truncate px-3 py-3')
        expect(response.body).to include(I18n.l(active_session.last_seen_at, format: :short))
        expect(response.body).to include('203.0.113.40')
        expect(response.body).to include('Support Browser')
        expect(response.body).not_to include('203.0.113.41')
        expect(response.body).not_to include('Old Version Browser')
        expect(response.body).to include(admin_receipt_analysis_runs_path(user_id: user.id))
        expect(response.body).to include(admin_audit_logs_path(actor_user_id: user.id))
        expect(copy_sources).to include(user.id.to_s)
        expect(copy_sources).to include('show-user@example.com')
        expect(copy_labels).to include(a_string_including(I18n.t('admin.users.show.basic.user_id')))
        expect(copy_labels).to include(email_copy_label)
        expect(email_copy_wrapper['class'].split).to include('flex', 'w-full', 'overflow-hidden')
        expect(email_copy_value['class'].split).to include('flex-1', 'overflow-hidden')
        expect(response.body).to include('min-w-[56rem] text-left text-sm')
        expect(response.body).to include('min-w-[16rem] break-words px-3 py-3 font-mono text-xs [overflow-wrap:anywhere]')
        expect(response.body).not_to include('hidden-credential-id')
        expect(response.body).not_to include('HIDDEN PUBLIC KEY')
        expect(response.body).not_to include('hidden-session-digest')
        expect(response.body).not_to include('challenge')
        expect(response.body).not_to include('cookie')
        expect(response.body).not_to include('remember_token')
        expect(response.body).not_to include('raw_response')
        expect(response.body).not_to include('RSpec')
        expect(response.body).not_to include('request_id')
        expect(response.body).not_to include('FULL PROMPT')
        expect(response.body).not_to include('SECRET')
        expect(UserSession.count).to eq(previous_user_session_count)
        expect_no_admin_side_effects(previous_audit_count)
      end
    end

    it '存在しないidは既存404へ流す' do
      admin = create(:user, :admin)
      sign_in admin

      get admin_user_path(999_999)

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to include(I18n.t('errors.not_found.title'))
      end
    end

    it 'adminユーザーは法務同意の過去版のみ/未同意状態を確認できる' do
      admin = create(:user, :admin)
      user = create(:user, email: 'legal-target@example.com')
      LegalDocuments::Sync.call
      old_terms = create(:legal_document, document_type: "terms", version: "2026-01-01", current: false)
      create(
        :legal_acceptance,
        user: user,
        legal_document: old_terms,
        accepted_at: Time.zone.local(2026, 1, 2, 9, 0, 0),
        acceptance_context: "signup"
      )
      sign_in admin

      get admin_user_path(user)
      document = Nokogiri::HTML(response.body)
      legal_acceptances_card = document.at_css('#admin-user-legal-acceptances')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(legal_acceptances_card.text).to include('法務同意')
        expect(legal_acceptances_card.text).to include('利用規約')
        expect(legal_acceptances_card.text).to include('過去版のみ')
        expect(legal_acceptances_card.text).to include('2026-01-01')
        expect(legal_acceptances_card.text).to include('プライバシーポリシー')
        expect(legal_acceptances_card.text).to include('未同意')
        expect(legal_acceptances_card.text).to include('再同意必要')
      end
    end

    it '一般ユーザーにはshowも既存404と同じbody/headerを返す' do
      user = create(:user)
      target = create(:user)
      sign_in user

      get '/__recify_missing_route__'
      expected_body = response.body
      expected_headers = comparable_headers

      sign_in user
      get admin_user_path(target)

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(response.content_type).to eq('text/html; charset=utf-8')
        expect(response.body).to eq(expected_body)
        expect(comparable_headers).to eq(expected_headers)
        expect(response.body).not_to include('法務同意')
      end
    end

    it '管理操作カードを表示するが、再認証前は実行フォームを表示しない' do
      admin = create(:user, :admin)
      user = create(:user)
      sign_in admin

      get admin_user_path(user)

      expect(response).to have_http_status(:success)
      expect(response.body).to include('管理操作')
      expect(response.body).to include(new_admin_passkey_reauthentication_path(return_to: admin_user_path(user)))
      expect(response.body).not_to include(lock_operation_admin_user_path(user))
      expect(response.body).not_to include(force_two_factor_reset_operation_admin_user_path(user))
      expect(response.body).not_to include(force_password_reset_instruction_operation_admin_user_path(user))
      expect(response.body).not_to include(admin_email_change_recovery_operation_admin_user_path(user))
      expect(response.body).not_to include(limit_overrides_admin_user_path(user))
    end

    it 'fresh reauth済みならユーザー別上限変更フォームを表示する' do
      admin = create(:user, :admin)
      user = create(:user)
      create(:totp_credential, user: user, totp_secret: 'TOTP-SECRET-VALUE')
      recovery_code = create(:recovery_code, user: user, code_digest: 'code-digest-secret')
      sign_in admin
      stub_fresh_admin_reauthentication

      get admin_user_path(user)

      document = Nokogiri::HTML(response.body)
      textareas = document.css('textarea')
      limit_value_input = document.at_css('input[name="value"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(limit_overrides_admin_user_path(user))
        expect(response.body).to include('ユーザー別上限の変更')
        expect(response.body).to include('name="key"')
        expect(response.body).to include('name="value"')
        expect(limit_value_input['inputmode']).to eq('numeric')
        expect(response.body).to include('UPDATE USER LIMIT')
        expect(response.body).to include(force_two_factor_reset_operation_admin_user_path(user))
        expect(response.body).to include('2要素認証リセット')
        expect(response.body).to include('RESET 2FA')
        expect(response.body).to include(force_password_reset_instruction_operation_admin_user_path(user))
        expect(response.body).to include('パスワード再設定メール送信')
        expect(response.body).to include('SEND PASSWORD RESET')
        expect(response.body).to include(admin_email_change_recovery_operation_admin_user_path(user))
        expect(response.body).to include('緊急復旧操作')
        expect(response.body).to include('CHANGE RECOVERY EMAIL')
        expect(response.body).to include('material-symbols-outlined')
        expect(response.body).not_to include('material-symbols-rounded')
        expect(response.body).not_to include('TOTP-SECRET-VALUE')
        expect(response.body).not_to include(recovery_code.code_digest)
        expect(response.body).not_to include('totp_secret')
        expect(response.body).not_to include('code_digest')
        expect(response.body).to include('tune')
        expect(response.body).not_to include('sliders_horizontal')
        expect(response.body).not_to include('_HORIZONTAL')
        expect(textareas).not_to be_empty
        expect(textareas.all? { |textarea| textarea['class'].include?('py-2') }).to be(true)
        expect(textareas.all? { |textarea| textarea['class'].include?('leading-6') }).to be(true)
      end
    end

    it 'fresh reauth済みならadmin自身にもユーザー別上限変更フォームを表示する' do
      admin = create(:user, :admin)
      sign_in admin
      stub_fresh_admin_reauthentication

      get admin_user_path(admin)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(limit_overrides_admin_user_path(admin))
        expect(response.body).to include('ユーザー別上限の変更')
        expect(response.body).to include('UPDATE USER LIMIT')
        expect(response.body).not_to include('他の管理者ユーザーの上限はこの画面から変更できません。')
        expect(response.body).not_to include('自分自身の上限はこの画面から変更できません。')
      end
    end

    it 'fresh reauth済みでも他admin targetにはユーザー別上限変更フォームを表示しない' do
      admin = create(:user, :admin)
      other_admin = create(:user, :admin)
      sign_in admin
      stub_fresh_admin_reauthentication

      get admin_user_path(other_admin)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('他の管理者ユーザーの上限はこの画面から変更できません。')
        expect(response.body).not_to include(limit_overrides_admin_user_path(other_admin))
      end
    end

    it 'UIに開発者向け文言を出さない' do
      admin = create(:user, :admin)
      user = create(:user)
      sign_in admin

      get admin_user_path(user)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/v1\.0後|未実装|TODO|service\/facade|payload|development\/test|production/)
        expect(response.body).not_to include('権限変更')
        expect(response.body).not_to include('削除する')
        expect(response.body).not_to include('パスキー削除')
      end
    end
  end

  describe 'POST /admin/users/:id/operations/lock' do
    it '一般ユーザーはadmin操作へ到達できずadminにも昇格しない' do
      user = create(:user)
      target = create(:user)
      previous_audit_count = AuditLog.count
      sign_in user

      post lock_operation_admin_user_path(target),
           params: {
             reason: 'malicious admin operation attempt',
             confirmation: 'LOCK USER',
             admin: true
           }

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(user.reload).not_to be_admin
        expect(target.reload.locked_at).to be_nil
        expect_no_admin_side_effects(previous_audit_count)
      end
    end
  end
end
