# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Turnstile Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/turnstile_controller.js").read }

  it "loads the Cloudflare API in explicit render mode only once" do
    aggregate_failures do
      expect(source).to include("https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit")
      expect(source).to include("TURNSTILE_SCRIPT_ID")
      expect(source).to include("document.getElementById(TURNSTILE_SCRIPT_ID)")
    end
  end

  it "removes the rendered widget before Turbo caches the page" do
    aggregate_failures do
      expect(source).to include("turbo:before-cache")
      expect(source).to include("turnstile.remove(this.widgetId)")
      expect(source).to include("this.widgetId = null")
    end
  end

  it "keeps token and verification details out of browser logs" do
    expect(source).not_to include("console.")
  end
end
