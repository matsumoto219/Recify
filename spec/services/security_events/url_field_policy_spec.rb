require 'rails_helper'

RSpec.describe SecurityEvents::UrlFieldPolicy do
  it 'admin announcements write requestのlink URLを保存用途として扱う' do
    policy = described_class.new(path: '/admin/announcements', method: 'POST')

    aggregate_failures do
      expect(policy.link_storage_field?('announcement.announcement_links_attributes.0.url')).to eq(true)
      expect(policy.open_redirect_candidate?('announcement.announcement_links_attributes.0.url', 'https://example.com/news')).to eq(false)
      expect(policy.open_redirect_candidate?('announcement.announcement_links_attributes.0.url', '/contact')).to eq(false)
    end
  end

  it 'admin announcements以外では同じparam pathも通常のURL fieldとして安全側に扱う' do
    policy = described_class.new(path: '/settings', method: 'POST')

    aggregate_failures do
      expect(policy.link_storage_field?('announcement.announcement_links_attributes.0.url')).to eq(false)
      expect(policy.open_redirect_candidate?('announcement.announcement_links_attributes.0.url', 'https://example.com/news')).to eq(true)
    end
  end

  it 'redirect / callback系のcamelCase fieldもopen redirect候補として扱う' do
    policy = described_class.new

    aggregate_failures do
      expect(policy.open_redirect_candidate?('redirectUrl', 'https://evil.example')).to eq(true)
      expect(policy.open_redirect_candidate?('returnUrl', 'https://evil.example')).to eq(true)
      expect(policy.open_redirect_candidate?('callbackUrl', 'https://evil.example')).to eq(true)
    end
  end
end
