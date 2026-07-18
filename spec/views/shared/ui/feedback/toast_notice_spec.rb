require "rails_helper"

RSpec.describe "shared/ui/feedback/_toast_notice", type: :view do
  it "realtime toastをTurbo cache前に削除する" do
    render partial: "shared/ui/feedback/toast_notice",
           locals: { notice_type: :notice, message: "解析が完了しました" }

    surface = Nokogiri::HTML.fragment(rendered).at_css('[data-controller~="notice-surface"]')

    aggregate_failures do
      expect(surface['role']).to eq('status')
      expect(surface['aria-live']).to eq('polite')
      expect(surface['data-notice-surface-auto-dismiss-value']).to eq('true')
      expect(surface['data-notice-surface-auto-dismiss-delay-value']).to eq('4000')
      expect(surface['data-notice-surface-remove-before-cache-value']).to eq('true')
    end
  end

  it "error toastは既存の7秒timerを使う" do
    render partial: "shared/ui/feedback/toast_notice",
           locals: { notice_type: :alert, message: "解析に失敗しました" }

    surface = Nokogiri::HTML.fragment(rendered).at_css('[data-controller~="notice-surface"]')

    aggregate_failures do
      expect(surface['role']).to eq('alert')
      expect(surface['aria-live']).to eq('assertive')
      expect(surface['data-notice-surface-auto-dismiss-value']).to eq('true')
      expect(surface['data-notice-surface-auto-dismiss-delay-value']).to eq('7000')
    end
  end
end
