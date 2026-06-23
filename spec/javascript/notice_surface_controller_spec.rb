# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Notice surface Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/notice_surface_controller.js").read }

  it "can remove flash notices before Turbo caches the page" do
    aggregate_failures do
      expect(source).to include("removeBeforeCache: Boolean")
      expect(source).to include("turbo:before-cache")
      expect(source).to include("this.element.remove()")
    end
  end
end
