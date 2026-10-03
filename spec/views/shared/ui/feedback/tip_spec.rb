require "rails_helper"

RSpec.describe "shared/ui/feedback/_tip", type: :view do
  def render_tip(**locals)
    render partial: "shared/ui/feedback/tip",
           locals: { message: "補足説明です。", label: "金額の説明" }.merge(locals)

    Nokogiri::HTML.fragment(rendered)
  end

  it "renders an icon-only accessible trigger and an initially hidden explanation" do
    document = render_tip(id: "amount-tip")
    trigger = document.at_css('[data-tip-target="trigger"]')
    panel = document.at_css('[data-tip-target="panel"]')

    aggregate_failures do
      expect(trigger['type']).to eq('button')
      expect(trigger['aria-label']).to eq('金額の説明')
      expect(trigger['aria-controls']).to eq('amount-tip')
      expect(trigger['aria-expanded']).to eq('false')
      expect(trigger['aria-haspopup']).to eq('dialog')
      expect(trigger.at_css('.material-symbols-outlined')['aria-hidden']).to eq('true')
      expect(panel['role']).to eq('dialog')
      expect(panel['hidden']).not_to be_nil
      expect(panel.text).to include('補足説明です。')
      expect(panel.at_css('[data-tip-close]')['aria-label']).to eq(I18n.t("shared.tip.close_label"))
    end
  end

  it "preserves shared partial options without requiring a timer" do
    document = render_tip(
      auto_dismiss: true,
      auto_dismiss_delay: 12000,
      close_on_outside: false,
      close_button_position: :start,
      class: "ml-auto"
    )
    root = document.at_css('[data-controller="tip"]')
    panel = document.at_css('[data-tip-target="panel"]')

    aggregate_failures do
      expect(root['data-tip-auto-dismiss-value']).to eq('true')
      expect(root['data-tip-auto-dismiss-delay-value']).to eq('12000')
      expect(root['data-tip-close-on-outside-value']).to eq('false')
      expect(root['class']).to include('ml-auto')
      expect(panel.at_css('[data-tip-close]')['class']).to include('order-first')
    end
  end

  it "can omit the close button and defaults an unknown position to the end" do
    expect(render_tip(dismissible: false).at_css('[data-tip-close]')).to be_nil
    document = render_tip(close_button_position: :unknown)

    aggregate_failures do
      expect(document.at_css('[data-controller="tip"]')['data-tip-auto-dismiss-value']).to eq('false')
      expect(document.at_css('[data-tip-close]')['class']).not_to include('order-first')
    end
  end

  it "escapes text and keeps long content wrappable within a scrolling panel" do
    document = render_tip(message: "<script>alert(1)</script>", label: '説明" onclick="alert(1)')
    panel = document.at_css('[data-tip-target="panel"]')

    aggregate_failures do
      expect(document.css('script, [onclick]')).to be_empty
      expect(panel.text).to include('<script>alert(1)</script>')
      expect(panel['class']).to include('overflow-y-auto', '[overflow-wrap:anywhere]')
    end
  end
end
