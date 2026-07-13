require "rails_helper"

RSpec.describe "shared/ui/feedback/_toast_notice", type: :view do
  it "realtime toastをTurbo cache前に削除する" do
    render partial: "shared/ui/feedback/toast_notice",
           locals: { notice_type: :notice, message: "解析が完了しました" }

    surface = Nokogiri::HTML.fragment(rendered).at_css('[data-controller~="notice-surface"]')

    aggregate_failures do
      expect(surface['role']).to eq('status')
      expect(surface['aria-live']).to eq('polite')
      expect(surface['data-notice-surface-remove-before-cache-value']).to eq('true')
    end
  end
end
