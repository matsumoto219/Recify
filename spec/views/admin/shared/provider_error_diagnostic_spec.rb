require 'rails_helper'

RSpec.describe 'admin/shared/_provider_error_diagnostic', type: :view do
  it '原因・省略の説明をescapeして表示し操作やraw dumpを追加しない' do
    detail = ExternalServices.error_detail(
      body: {
        error: {
          code: 'InvalidRequest',
          innererror: { code: 'InvalidParameter', param: 'model', message: '<script>alert(1)</script> person@example.test' }
        }
      }
    )
    render partial: 'admin/shared/provider_error_diagnostic',
           locals: { diagnostic: Admin::ProviderErrorDiagnosticPresenter.new(detail) }
    document = Nokogiri::HTML.fragment(rendered)

    aggregate_failures do
      expect(document.text).to include('Provider causes', 'error.innererror', 'InvalidParameter', 'model')
      expect(document.text).to include('機密情報・入力内容を除去しました。')
      expect(document.text).not_to include('person@example.test', 'translation missing')
      expect(document.css('script, form, button, pre')).to be_empty
      expect(document.css('[data-provider-error-node]').size).to eq(2)
    end
  end

  it '旧記録の原因未取得を空の正常詳細として表示しない' do
    render partial: 'admin/shared/provider_error_diagnostic',
           locals: { diagnostic: Admin::ProviderErrorDiagnosticPresenter.new(provider_error_code: 'InvalidRequest') }

    expect(rendered).to include('内側の原因は記録されていません。')
  end

  it '長いmessageを省略せず折返し対象の要素に表示する' do
    message = 'Invalid document. ' * 80
    detail = ExternalServices.error_detail(body: { error: { message: message } })
    render partial: 'admin/shared/provider_error_diagnostic',
           locals: { diagnostic: Admin::ProviderErrorDiagnosticPresenter.new(detail) }

    aggregate_failures do
      expect(Nokogiri::HTML.fragment(rendered).text).to include(message.strip)
      expect(rendered).to include('[overflow-wrap:anywhere]')
      expect(rendered).not_to include('truncate', 'line-clamp')
    end
  end
end
