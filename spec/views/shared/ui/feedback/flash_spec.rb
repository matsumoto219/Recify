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

  it 'toneごとにstatusとalertを使い分け、共通stackへ渡すsurfaceだけを描画する' do
    document = render_flash(
      flash_messages: {
        info: '本人確認が必要です',
        notice: '保存しました',
        warning: '有効期限が切れました',
        alert: '検証に失敗しました'
      }
    )

    surfaces = document.css('[data-controller~="notice-surface"]')
    by_message = surfaces.index_by { |surface| surface.text }
    info_surface = by_message.find { |text, _surface| text.include?('本人確認が必要です') }.last
    error_surface = by_message.find { |text, _surface| text.include?('検証に失敗しました') }.last

    aggregate_failures do
      expect(document.at_css('[data-notice-surface-container]')).to be_nil
      expect(info_surface['role']).to eq('status')
      expect(info_surface['aria-live']).to eq('polite')
      expect(info_surface['aria-atomic']).to eq('true')
      expect(by_message.find { |text, _surface| text.include?('保存しました') }.last['role']).to eq('status')
      expect(by_message.find { |text, _surface| text.include?('有効期限が切れました') }.last['role']).to eq('status')
      expect(error_surface['role']).to eq('alert')
      expect(error_surface['aria-live']).to eq('assertive')
      expect(error_surface['aria-atomic']).to eq('true')
    end
  end
end
