# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Deploy-prep security hardening', type: :request do
  PUBLIC_HTML_ENTRYPOINTS = [
    :root_path,
    :terms_path,
    :privacy_path,
    :contact_path,
    :announcements_path
  ].freeze

  PRIVATE_HTML_PREFIXES = %w[
    /admin
    /receipts
    /settings
    /notifications
  ].freeze

  INTERNAL_MARKERS = [
    'SECRET_KEY_BASE',
    'RAILS_MASTER_KEY',
    'DATABASE_URL',
    'Rails.root',
    'ActiveStorage::',
    'ActionController::',
    'translation missing'
  ].freeze

  STATIC_ERROR_PAGES = %w[
    400.html
    404.html
    406-unsupported-browser.html
    422.html
    500.html
    502.html
    503.html
    504.html
  ].freeze

  def private_public_targets(document)
    document.css('a[href], form[action]').filter_map do |node|
      target = node['href'] || node['action']
      next if target.blank?

      target if PRIVATE_HTML_PREFIXES.any? { |prefix| target == prefix || target.start_with?("#{prefix}/") }
    end
  end

  def expect_no_internal_markers(body)
    INTERNAL_MARKERS.each do |marker|
      expect(body).not_to include(marker)
    end
  end

  it '未ログインの公開HTML入口にprivate/admin導線や内部情報を混ぜない' do
    announcement = create(:announcement, :published, title: '公開お知らせ')
    paths = PUBLIC_HTML_ENTRYPOINTS.map { |helper_name| public_send(helper_name) } + [ announcement_path(announcement) ]

    paths.each do |path|
      get path
      document = Nokogiri::HTML(response.body)

      aggregate_failures path do
        expect(response).to have_http_status(:ok)
        expect(document.at_css('main')).to be_present
        expect(document.at_css('#desktop-sidebar')).to be_nil
        expect(private_public_targets(document)).to be_empty
        expect_no_internal_markers(response.body)
      end
    end
  end

  it '静的エラーページにHTML注入APIや内部情報を置かない' do
    STATIC_ERROR_PAGES.each do |filename|
      html = Rails.root.join('public', filename).read

      aggregate_failures filename do
        expect(html).to include('textContent')
        expect(html).not_to include('innerHTML')
        expect(html).not_to include('document.write')
        expect(html).not_to include('eval(')
        expect(html).not_to include('SECRET_KEY_BASE')
        expect(html).not_to include('RAILS_MASTER_KEY')
        expect(html).not_to include('DATABASE_URL')
        expect(html).not_to include('Rails.root')
        expect(html).not_to include('backtrace')
        expect(html).not_to include('stack trace')
      end
    end
  end

  it 'お知らせ画像表示でActive Storage variant/representationを使わない' do
    view_files = Dir[Rails.root.join('app/views/{announcements,admin/announcements}/**/*.{erb,rb}')]
    offenders = view_files.filter_map do |path|
      path.to_s if File.read(path).match?(/\.(?:variant|representation)\(/)
    end

    expect(offenders).to be_empty
  end
end
