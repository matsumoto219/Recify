require 'rails_helper'

RSpec.describe SecurityEvents::MetadataSanitizer do
  it 'secret系keyをnested metadataから除去する' do
    metadata = described_class.call(
      safe: 'value',
      token: 'SECRET',
      nested: {
        api_key: 'KEY',
        count: 1
      }
    )

    expect(metadata).to eq(
      'safe' => 'value',
      'nested' => { 'count' => 1 }
    )
  end

  it '文字列内のPIIやsecret風値をredactする' do
    metadata = described_class.call(
      message: 'email=user@example.com Authorization: Bearer abcdefghijklmnopqrstuvwxyz token=secret-value'
    )

    expect(metadata.fetch('message')).to include('[REDACTED_EMAIL]')
    expect(metadata.fetch('message')).to include('Authorization: [FILTERED]')
    expect(metadata.fetch('message')).to include('token=[FILTERED]')
    expect(metadata.fetch('message')).not_to include('user@example.com', 'secret-value')
  end

  it 'URL値のuserinfo/query/fragmentを除去する' do
    metadata = described_class.call(
      target_url: 'https://user:pass@example.com/path?token=secret#fragment'
    )

    expect(metadata.fetch('target_url')).to eq('https://example.com/path')
  end

  it 'Active Storage由来のkeyやURLをmetadataから除外またはredactする' do
    metadata = described_class.call(
      blob_key: 'raw-storage-key',
      signed_id: 'signed-id',
      checksum: 'checksum',
      attachment_url: 'https://app.example.com/rails/active_storage/blobs/redirect/signed-id/file.png',
      public_path: '/rails/active_storage/representations/redirect/signed-id/preview.png'
    )

    aggregate_failures do
      expect(metadata).not_to include('blob_key', 'signed_id', 'checksum')
      expect(metadata.fetch('attachment_url')).to eq('[FILTERED_STORAGE_URL]')
      expect(metadata.fetch('public_path')).to eq('[FILTERED_STORAGE_URL]')
    end
  end

  it '配列とhashの保存量を制限する' do
    metadata = described_class.call(
      list: Array.new(60) { |index| index },
      many_keys: 120.times.to_h { |index| [ "key_#{index}", index ] }
    )

    expect(metadata.fetch('list').size).to eq(described_class::MAX_ARRAY_ITEMS)
    expect(metadata.fetch('many_keys').size).to eq(described_class::MAX_HASH_ENTRIES)
  end

  it '深すぎるmetadataを打ち切る' do
    nested = { value: 'leaf' }
    8.times { nested = { child: nested } }

    metadata = described_class.call(nested)

    expect(metadata.dig('child', 'child', 'child', 'child', 'child', 'child', 'child')).to eq('[TRUNCATED]')
  end
end
