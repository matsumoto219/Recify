# frozen_string_literal: true

require "rails_helper"

RSpec.describe "App icons", type: :request do
  def document
    Nokogiri::HTML(response.body)
  end

  it "application layout references the Recify favicon and apple touch icon files" do
    get root_path

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(document.at_css('link[rel="icon"][href="/icon.svg"][type="image/svg+xml"]')).to be_present
      expect(document.at_css('link[rel="icon"][href="/icon.png"][type="image/png"]')).to be_present
      expect(document.at_css('link[rel="apple-touch-icon"][href="/apple-touch-icon.png"]')).to be_present
      expect(document.at_css('link[rel="manifest"]')).to be_nil
    end
  end

  it "error layout references the same icon files" do
    get "/404"

    aggregate_failures do
      expect(response).to have_http_status(:not_found)
      expect(document.at_css('link[rel="icon"][href="/icon.svg"][type="image/svg+xml"]')).to be_present
      expect(document.at_css('link[rel="icon"][href="/icon.png"][type="image/png"]')).to be_present
      expect(document.at_css('link[rel="apple-touch-icon"][href="/apple-touch-icon.png"]')).to be_present
    end
  end

  it "public icon files exist without keeping the Rails placeholder SVG" do
    icon_svg = Rails.root.join("public/icon.svg").read

    aggregate_failures do
      expect(Rails.root.join("public/icon.png")).to exist
      expect(Rails.root.join("public/apple-touch-icon.png")).to exist
      expect(Rails.root.join("public/icon-192.png")).to exist
      expect(Rails.root.join("public/icon-512.png")).to exist
      expect(icon_svg).to include("#4B4DD8")
      expect(icon_svg).not_to include('fill="red"')
      expect(icon_svg).not_to match(/<script|<style|<image|foreignObject|\b(?:href|xlink:href)=["']https?:/i)
    end
  end

  it "keeps the PWA manifest prepared without placeholder colors" do
    manifest_json = ApplicationController.renderer.render(template: "pwa/manifest", formats: :json)
    manifest = JSON.parse(manifest_json)

    aggregate_failures do
      expect(manifest).to include(
        "name" => "Recify",
        "short_name" => "Recify",
        "theme_color" => "#4B4DD8",
        "background_color" => "#FAFAFA"
      )
      expect(manifest["description"]).to eq(I18n.t("pwa.manifest.description"))
      expect(manifest["icons"]).to include(
        { "src" => "/icon-192.png", "type" => "image/png", "sizes" => "192x192" },
        { "src" => "/icon-512.png", "type" => "image/png", "sizes" => "512x512" }
      )
      expect(manifest.to_json).not_to include("red")
    end
  end
end
