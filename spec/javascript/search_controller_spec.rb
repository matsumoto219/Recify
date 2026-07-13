# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Search Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/search_controller.js").read }

  it "removes search errors before Turbo caches the page and uses error ARIA semantics" do
    aggregate_failures do
      expect(source).to include("this.removeSearchErrorNotice()")
      expect(source).to include("data-notice-surface-container")
      expect(source).to include("data-notice-surface-remove-before-cache-value")
      expect(source).to include("notice.setAttribute('aria-live', 'assertive')")
      expect(source).to include("notice.setAttribute('aria-atomic', 'true')")
    end
  end
end
