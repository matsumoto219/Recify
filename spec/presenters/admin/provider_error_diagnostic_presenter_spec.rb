require 'rails_helper'

RSpec.describe Admin::ProviderErrorDiagnosticPresenter do
  it '保存された原因の構造と順序を検証後の値で返す' do
    detail = ExternalServices.error_detail(
      body: {
        error: {
          code: 'InvalidRequest',
          innererror: { code: 'InvalidContentLength', message: 'The input image is too large.', target: 'document' }
        }
      }
    )
    presenter = described_class.new(detail)

    aggregate_failures do
      expect(presenter.recorded?).to be(true)
      expect(presenter.nodes.map { |node| node[:path] }).to eq([ 'error', 'error.innererror' ])
      expect(presenter.nodes.last[:fields]).to include(
        [ 'code', 'InvalidContentLength' ],
        [ 'message', 'The input image is too large.' ],
        [ 'target', 'document' ]
      )
      expect(presenter.omissions).to eq([])
    end
  end

  it '未記録と取得できなかった理由を区別する' do
    missing = described_class.new(provider_error_code: 'InvalidRequest')
    invalid = described_class.new(diagnostic: { schema_version: 'unknown' })

    aggregate_failures do
      expect(missing.recorded?).to be(false)
      expect(missing.notice).to eq('内側の原因は記録されていません。')
      expect(invalid.recorded?).to be(true)
      expect(invalid.nodes).to eq([])
      expect(invalid.omissions).to include(
        path: 'diagnostic', reason: '保存形式が未対応のため表示できません。'
      )
    end
  end

  it 'local issueのallowlist文言を使いraw refusal等を表示しない' do
    presenter = described_class.new(ExternalServices.error_detail(local_issue: 'refusal'))

    aggregate_failures do
      expect(presenter.local_issue).to eq('プロバイダーが回答を拒否しました。拒否本文は保存しません。')
      expect(presenter.nodes).to eq([])
    end
  end

  it '保存後に混入したraw fieldや秘密を表示用shapeへ通さない' do
    presenter = described_class.new(
      diagnostic: {
        schema_version: 'external_service_error_diagnostic_v1',
        nodes: [
          { path: 'error', code: 'InvalidRequest', message_safe: 'Failure person@example.test', raw: 'private data' }
        ],
        omissions: []
      }
    )

    aggregate_failures do
      expect(presenter.nodes.first[:fields]).to include([ 'message', 'Failure [FILTERED]' ])
      expect(JSON.generate(presenter.nodes)).not_to match(/private data|person@/)
      expect(presenter.omissions.map { |entry| entry[:reason] }).to include('機密情報・入力内容を除去しました。')
    end
  end
end
