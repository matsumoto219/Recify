require 'rails_helper'

RSpec.describe 'shared/ui/feedback/_flash', type: :view do
  def render_flash(**locals)
    render partial: 'shared/ui/feedback/flash', locals: locals

    Nokogiri::HTML.fragment(rendered)
  end

  it '指定されたmessageだけ自動消去せず、指定なしmessageは自動消去する' do
    document = render_flash(
      flash_messages: {
        notice: [
          '自動で消えるお知らせ',
          { message: '手動で閉じるお知らせ', auto_dismiss: false }
        ]
      }
    )

    surfaces = document.css('[data-controller~="notice-surface"]')
    auto_surface = surfaces.find { |surface| surface.text.include?('自動で消えるお知らせ') }
    manual_surface = surfaces.find { |surface| surface.text.include?('手動で閉じるお知らせ') }

    aggregate_failures do
      expect(surfaces.size).to eq(2)
      expect(auto_surface['data-notice-surface-auto-dismiss-value']).to eq('true')
      expect(manual_surface['data-notice-surface-auto-dismiss-value']).to eq('false')
      expect(auto_surface['data-notice-surface-remove-before-cache-value']).to eq('true')
      expect(manual_surface['data-notice-surface-remove-before-cache-value']).to eq('true')
    end
  end

  it 'partial呼び出し時のauto_dismiss falseをデフォルトにできる' do
    document = render_flash(
      flash_messages: { notice: '手動で閉じるお知らせ' },
      auto_dismiss: false
    )

    notice_surface = document.at_css('[data-controller~="notice-surface"]')

    aggregate_failures do
      expect(notice_surface.text).to include('手動で閉じるお知らせ')
      expect(notice_surface['data-notice-surface-auto-dismiss-value']).to eq('false')
    end
  end
end
