# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Password reveal Stimulus controller" do
  let(:source) { Rails.root.join("app/javascript/controllers/password_reveal_controller.js").read }

  it "toggles password inputs without storing the password value outside the input" do
    aggregate_failures do
      expect(source).to include("this.inputTarget.type = revealed ? 'text' : 'password'")
      expect(source).to include("aria-pressed")
      expect(source).to include("aria-label")
      expect(source).to include("visibility_off")
      expect(source).to include("visibility")
      expect(source).not_to include("dataset.password")
      expect(source).not_to include("console.")
    end
  end

  it "resets revealed passwords before Turbo caches the page" do
    aggregate_failures do
      expect(source).to include("turbo:before-cache")
      expect(source).to include("this.reset.bind(this)")
      expect(source).to include("this.setRevealed(false)")
    end
  end
end
