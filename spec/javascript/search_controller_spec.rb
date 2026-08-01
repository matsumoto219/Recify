# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Search Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/search_controller.js").read }

  it "removes search errors before Turbo caches the page and uses error ARIA semantics" do
    aggregate_failures do
      expect(source).to include("this.removeSearchErrorNotice()")
      expect(source).to include("getElementById('toast-stream')")
      expect(source).not_to include("search-error-toast-container")
      expect(source).to include("data-notice-surface-remove-before-cache-value")
      expect(source).to include("notice.setAttribute('aria-live', 'assertive')")
      expect(source).to include("notice.setAttribute('aria-atomic', 'true')")
    end
  end

  it "restores server-selected index control values before Turbo caches the page" do
    aggregate_failures do
      expect(source).to include("'cacheValue'")
      expect(source).to include("this.restoreCacheValues()")
      expect(source).to include("option.defaultSelected")
      expect(source).to include("control.value = serverSelectedOption.value")
    end
  end
end
