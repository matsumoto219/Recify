require 'rails_helper'

RSpec.describe Receipts::Registrations::Fingerprint do
  let(:user) { build_stubbed(:user) }

  def fingerprint(input, kind: 'manual')
    described_class.call(user: user, kind: kind, input: input)
  end

  it 'hash key順序に依存せず正規化したsourceのdigestだけを返す' do
    source = { 'memo' => '架空入力', 'amount' => BigDecimal('120.00'), 'items' => [ { 'name' => '検証品' } ] }

    aggregate_failures do
      expect(fingerprint(source)).to match(/\A[0-9a-f]{64}\z/)
      expect(fingerprint(source)).to eq(fingerprint(source.to_a.reverse.to_h))
      expect(fingerprint(source)).to eq(fingerprint(source.merge('amount' => BigDecimal('120'))))
      expect(fingerprint(source)).not_to include('架空入力', '検証品')
    end
  end

  it '入力値と配列順と登録経路の違いを区別する' do
    source = { 'items' => [ 'A', 'B' ], 'memo' => '入力' }

    aggregate_failures do
      expect(fingerprint(source)).not_to eq(fingerprint(source.merge('memo' => '変更')))
      expect(fingerprint(source)).not_to eq(fingerprint(source.merge('items' => [ 'B', 'A' ])))
      expect(fingerprint(source)).not_to eq(fingerprint(source, kind: 'upload'))
    end
  end

  it '画像名や一時pathではなく全bytesで照合しIO位置を戻す' do
    first = Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/receipt_sample.jpg'), 'image/jpeg')
    second = Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/receipt_sample.jpg'), 'image/jpeg')
    first.tempfile.seek(10)
    allow(second).to receive(:original_filename).and_return('renamed.jpg')

    aggregate_failures do
      expect(fingerprint({ 'image' => first }, kind: 'upload'))
        .to eq(fingerprint({ 'image' => second }, kind: 'upload'))
      expect(first.tempfile.pos).to eq(10)
    end
  end

  it '循環と不明型と長大入力を安全なエラーだけで拒否する' do
    circular = []
    circular << circular

    [ circular, Object.new, { 'memo' => 'private' * 10_000 }, { 'amount' => Float::NAN } ].each do |input|
      expect { fingerprint(input) }.to raise_error(ArgumentError, 'invalid registration input')
    end
  end
end
