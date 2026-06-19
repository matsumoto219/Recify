require 'rails_helper'
require 'zlib'

RSpec.describe Announcement, type: :model do
  def png_bytes(width:, height:, minimum_byte_size: nil)
    chunk = lambda do |type, data|
      [ data.bytesize ].pack('N') + type + data + [ Zlib.crc32(type + data) ].pack('N')
    end
    header = [ width, height, 8, 2, 0, 0, 0 ].pack('NNCCCCC')
    row = "\x00".b + ("\xFF\xFF\xFF".b * width)
    compressed = Zlib::Deflate.deflate(row * height)

    png = "\x89PNG\r\n\x1A\n".b +
      chunk.call('IHDR'.b, header) +
      chunk.call('IDAT'.b, compressed) +
      chunk.call('IEND'.b, ''.b)
    return png if minimum_byte_size.blank? || png.bytesize >= minimum_byte_size

    png + ("\0".b * (minimum_byte_size - png.bytesize))
  end

  def uint24_le(value)
    [ value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF ].pack('C3')
  end

  def webp_vp8x_bytes(width:, height:)
    payload = "\0\0\0\0".b + uint24_le(width - 1) + uint24_le(height - 1)

    "RIFF".b +
      [ 4 + 8 + payload.bytesize ].pack('V') +
      "WEBP".b +
      "VP8X".b +
      [ payload.bytesize ].pack('V') +
      payload
  end

  def attach_announcement_image(announcement, bytes:, filename:, content_type:)
    announcement.image.attach(
      io: StringIO.new(bytes),
      filename: filename,
      content_type: content_type
    )
  end

  describe 'validations' do
    it 'valid factory' do
      expect(build(:announcement)).to be_valid
    end

    it 'public_idを自動生成し、公開URL向けの形式にする' do
      announcement = create(:announcement)

      aggregate_failures do
        expect(announcement.public_id).to match(/\Aann_[A-Za-z0-9]{16}\z/)
        expect(announcement.to_param).to eq(announcement.public_id)
      end
    end

    it 'public_idの重複を不正にする' do
      existing = create(:announcement)
      duplicate = build(:announcement, public_id: existing.public_id)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:public_id]).to be_present
    end

    it 'public_id生成時に既存値との衝突を避ける' do
      duplicate_random = 'ABCDEFGHJKLMNPQR'
      unique_random = 'STUVWXYZabcdefgh'
      create(:announcement, public_id: "ann_#{duplicate_random}")

      allow(SecureRandom).to receive(:base58).and_return(duplicate_random, unique_random)

      announcement = create(:announcement)

      expect(announcement.public_id).to eq("ann_#{unique_random}")
    end

    it 'public_idのDB unique index衝突時はpublic_idを再生成して保存する' do
      existing = create(:announcement)
      unique_random = 'STUVWXYZabcdefgh'
      announcement = build(:announcement, public_id: existing.public_id)

      allow(SecureRandom).to receive(:base58).and_return(unique_random)

      expect(announcement.save!(validate: false)).to be(true)
      expect(announcement.public_id).to eq("ann_#{unique_random}")
    end

    it 'titleは必須かつ120文字まで' do
      blank = build(:announcement, title: '')
      too_long = build(:announcement, title: 'a' * 121)

      aggregate_failures do
        expect(blank).not_to be_valid
        expect(blank.errors[:title]).to be_present
        expect(too_long).not_to be_valid
        expect(too_long.errors[:title]).to be_present
      end
    end

    it 'bodyは必須かつ2000文字まで' do
      blank = build(:announcement, body: '')
      too_long = build(:announcement, body: 'a' * 2001)

      aggregate_failures do
        expect(blank).not_to be_valid
        expect(blank.errors[:body]).to be_present
        expect(too_long).not_to be_valid
        expect(too_long.errors[:body]).to be_present
      end
    end

    it 'statusはallowlistだけを許可する' do
      valid = build(:announcement, status: 'published')
      invalid = build(:announcement, status: 'unknown')

      aggregate_failures do
        expect(valid).to be_valid
        expect(invalid).not_to be_valid
        expect(invalid.errors[:status]).to be_present
      end
    end

    it 'kindはallowlistだけを許可する' do
      valid = build(:announcement, kind: 'maintenance')
      invalid = build(:announcement, kind: 'unknown')

      aggregate_failures do
        expect(valid).to be_valid
        expect(invalid).not_to be_valid
        expect(invalid.errors[:kind]).to be_present
      end
    end

    it 'priorityは-100から100までの整数にする' do
      low = build(:announcement, priority: -101)
      high = build(:announcement, priority: 101)
      decimal = build(:announcement, priority: 1.5)

      aggregate_failures do
        expect(build(:announcement, priority: -100)).to be_valid
        expect(build(:announcement, priority: 100)).to be_valid
        expect(low).not_to be_valid
        expect(high).not_to be_valid
        expect(decimal).not_to be_valid
      end
    end

    it 'ends_atはstarts_atより後にする' do
      announcement = build(:announcement, starts_at: Time.zone.local(2026, 7, 1, 10), ends_at: Time.zone.local(2026, 7, 1, 9))

      expect(announcement).not_to be_valid
      expect(announcement.errors[:ends_at]).to be_present
    end

    it 'created_by / updated_by は任意にする' do
      announcement = build(:announcement, created_by: nil, updated_by: nil)

      expect(announcement).to be_valid
    end

    it '画像なしの場合は画像代替テキストなしでも有効にする' do
      announcement = build(:announcement, image_alt_text: '')

      expect(announcement).to be_valid
    end

    it 'JPEG画像を許可する' do
      announcement = build(:announcement, image_alt_text: 'キャンペーン画像')
      attach_announcement_image(
        announcement,
        bytes: File.binread(Rails.root.join('spec/fixtures/files/receipt_sample.jpg')),
        filename: 'announcement.jpg',
        content_type: 'image/jpeg'
      )

      expect(announcement).to be_valid
    end

    it 'PNG画像を許可する' do
      announcement = build(:announcement, image_alt_text: 'メンテナンス告知画像')
      attach_announcement_image(
        announcement,
        bytes: png_bytes(width: 320, height: 180),
        filename: 'announcement.png',
        content_type: 'image/png'
      )

      expect(announcement).to be_valid
    end

    it 'WebP画像を許可する' do
      announcement = build(:announcement, image_alt_text: 'リリース告知画像')
      attach_announcement_image(
        announcement,
        bytes: webp_vp8x_bytes(width: 320, height: 180),
        filename: 'announcement.webp',
        content_type: 'image/webp'
      )

      expect(announcement).to be_valid
    end

    it 'SVG / GIF / text/plainを拒否する' do
      cases = [
        {
          bytes: '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>',
          filename: 'announcement.svg',
          content_type: 'image/svg+xml'
        },
        {
          bytes: 'GIF89a',
          filename: 'announcement.gif',
          content_type: 'image/gif'
        },
        {
          bytes: 'not image',
          filename: 'announcement.txt',
          content_type: 'text/plain'
        }
      ]

      cases.each do |entry|
        announcement = build(:announcement, image_alt_text: '不正な画像')
        attach_announcement_image(announcement, **entry)

        expect(announcement).not_to be_valid
        expect(announcement.errors.of_kind?(:image, :invalid_content_type)).to be(true)
      end
    end

    it '2MBを超える画像を拒否する' do
      announcement = build(:announcement, image_alt_text: '大きすぎる画像')
      attach_announcement_image(
        announcement,
        bytes: png_bytes(width: 320, height: 180, minimum_byte_size: described_class::MAX_IMAGE_FILE_SIZE + 1),
        filename: 'large-announcement.png',
        content_type: 'image/png'
      )

      expect(announcement).not_to be_valid
      expect(announcement.errors.of_kind?(:image, :file_too_large)).to be(true)
    end

    it '100px未満の画像を拒否する' do
      announcement = build(:announcement, image_alt_text: '小さすぎる画像')
      attach_announcement_image(
        announcement,
        bytes: png_bytes(width: described_class::MIN_IMAGE_DIMENSION - 1, height: 120),
        filename: 'small-announcement.png',
        content_type: 'image/png'
      )

      expect(announcement).not_to be_valid
      expect(announcement.errors.of_kind?(:image, :image_too_small)).to be(true)
    end

    it '4096pxを超える画像を拒否する' do
      announcement = build(:announcement, image_alt_text: '大きすぎる寸法の画像')
      attach_announcement_image(
        announcement,
        bytes: png_bytes(width: described_class::MAX_IMAGE_DIMENSION + 1, height: 120),
        filename: 'wide-announcement.png',
        content_type: 'image/png'
      )

      expect(announcement).not_to be_valid
      expect(announcement.errors.of_kind?(:image, :image_too_large)).to be(true)
    end

    it '壊れた画像を拒否する' do
      announcement = build(:announcement, image_alt_text: '壊れた画像')
      attach_announcement_image(
        announcement,
        bytes: 'not image',
        filename: 'broken-announcement.png',
        content_type: 'image/png'
      )

      expect(announcement).not_to be_valid
      expect(announcement.errors.of_kind?(:image, :invalid_content_type)).to be(true)
    end

    it 'JPEGとして送られたSVG偽装画像を拒否する' do
      announcement = build(:announcement, image_alt_text: '偽装画像')
      attach_announcement_image(
        announcement,
        bytes: '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>',
        filename: 'spoofed-announcement.jpg',
        content_type: 'image/jpeg'
      )

      expect(announcement).not_to be_valid
      expect(announcement.errors.of_kind?(:image, :invalid_content_type)).to be(true)
    end

    it '画像ありの場合は画像代替テキストを必須にする' do
      announcement = build(:announcement, image_alt_text: '')
      attach_announcement_image(
        announcement,
        bytes: png_bytes(width: 320, height: 180),
        filename: 'announcement.png',
        content_type: 'image/png'
      )

      expect(announcement).not_to be_valid
      expect(announcement.errors[:image_alt_text]).to be_present
    end

    it '画像代替テキストは160文字までにする' do
      valid = build(:announcement, image_alt_text: 'a' * 160)
      too_long = build(:announcement, image_alt_text: 'a' * 161)

      aggregate_failures do
        expect(valid).to be_valid
        expect(too_long).not_to be_valid
        expect(too_long.errors[:image_alt_text]).to be_present
      end
    end
  end

  describe 'scopes' do
    it 'visible_on_publicは公開中のお知らせだけを返す' do
      current = Time.current
      visible = create(:announcement, :published, starts_at: current - 1.day, ends_at: current + 1.day)
      no_window = create(:announcement, :published, starts_at: nil, ends_at: nil)
      draft = create(:announcement, status: 'draft')
      archived = create(:announcement, status: 'archived')
      scheduled = create(:announcement, :published, starts_at: current + 1.day, ends_at: nil)
      expired = create(:announcement, :published, starts_at: current - 2.days, ends_at: current - 1.day)

      aggregate_failures do
        expect(described_class.visible_on_public(current)).to contain_exactly(visible, no_window)
        expect(described_class.draft).to include(draft)
        expect(described_class.archived).to include(archived)
        expect(described_class.scheduled).to include(scheduled)
        expect(described_class.expired).to include(expired)
      end
    end

    it 'ordered_for_publicはpinned、priority、published_at、created_atの順にする' do
      old = create(:announcement, :published, priority: 1, published_at: 3.days.ago, created_at: 3.days.ago)
      newer = create(:announcement, :published, priority: 1, published_at: 1.day.ago, created_at: 1.day.ago)
      high_priority = create(:announcement, :published, priority: 50, published_at: 4.days.ago, created_at: 4.days.ago)
      pinned = create(:announcement, :published, pinned: true, priority: -1, published_at: 5.days.ago, created_at: 5.days.ago)
      no_published_at = create(:announcement, status: 'published', published_at: nil, created_at: Time.current)

      expect(described_class.ordered_for_public).to eq([ pinned, high_priority, newer, old, no_published_at ])
    end

    it 'ordered_for_adminは作成日の新しい順にする' do
      old = create(:announcement, created_at: 2.days.ago)
      new_record = create(:announcement, created_at: Time.current)

      expect(described_class.ordered_for_admin).to eq([ new_record, old ])
    end
  end
end
