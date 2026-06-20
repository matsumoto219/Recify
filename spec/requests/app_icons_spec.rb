# frozen_string_literal: true

require "rails_helper"

RSpec.describe "App icons", type: :request do
  def png_info(path)
    data = File.binread(path, 26)

    expect(data.byteslice(0, 8)).to eq("\x89PNG\r\n\x1A\n".b)
    width, height, bit_depth, color_type = data.byteslice(16, 10).unpack("NNCC")

    { width: width, height: height, bit_depth: bit_depth, color_type: color_type }
  end

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

  it "keeps brand OGP and full logo assets in expected public-ready dimensions" do
    ogp_path = Rails.root.join("app/assets/images/brand/recify-ogp.png")
    full_logo_png_path = Rails.root.join("app/assets/images/brand/recify-logo-full.png")
    wordmark_png_path = Rails.root.join("app/assets/images/brand/recify-logo-wordmark.png")
    full_logo_svg_path = Rails.root.join("app/assets/images/brand/recify-logo-full.svg")
    wordmark_svg_path = Rails.root.join("app/assets/images/brand/recify-logo-wordmark.svg")

    aggregate_failures do
      expect(png_info(ogp_path)).to include(width: 1200, height: 630, bit_depth: 8, color_type: 2)
      expect(File.size(ogp_path)).to be <= 500.kilobytes
      expect(png_info(full_logo_png_path)).to include(width: 1200, height: 360, bit_depth: 8, color_type: 6)
      expect(png_info(wordmark_png_path)).to include(width: 1200, height: 260, bit_depth: 8, color_type: 6)
      expect(full_logo_svg_path.read).to include("RECEIPT MANAGEMENT")
      expect(wordmark_svg_path.read).not_to include("RECEIPT MANAGEMENT")
      expect(full_logo_svg_path.read).not_to match(/<script|<image|foreignObject|\b(?:href|xlink:href)=["']https?:/i)
      expect(wordmark_svg_path.read).not_to match(/<script|<image|foreignObject|\b(?:href|xlink:href)=["']https?:/i)
    end
  end
end
