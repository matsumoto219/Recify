require "rails_helper"
require "tmpdir"

RSpec.describe Admin::Operations::AnnouncementMutation do
  let(:admin) { create(:user, :admin) }

  describe ".create" do
    it "draftとactorを固定してAnnouncementとAuditLogを原子的に作成する" do
      expect {
        @result = described_class.create(
          attributes: attributes,
          actor: admin,
          request: nil,
          security_context: { controller: "admin/announcements", action: "create" }
        )
      }.to change(Announcement, :count).by(1)
        .and change(AuditLog.where(action: "announcement.create"), :count).by(1)

      announcement = @result.announcement
      audit_log = AuditLog.find_by!(action: "announcement.create", target_id: announcement.id)

      aggregate_failures do
        expect(@result).to be_saved
        expect(announcement).to have_attributes(
          status: "draft",
          created_by: admin,
          updated_by: admin
        )
        expect(audit_log.before_state).to eq({})
        expect(audit_log.after_state).to include("status" => "draft", "kind" => "release")
        expect(audit_log.metadata.to_json).not_to include(attributes.fetch("body"))
      end
    end

    it "validation失敗時は保存もAuditLog記録もしない" do
      expect {
        @result = described_class.create(
          attributes: attributes.merge("title" => ""),
          actor: admin,
          request: nil,
          security_context: { controller: "admin/announcements", action: "create" }
        )
      }.not_to change(Announcement, :count)

      aggregate_failures do
        expect(@result).not_to be_saved
        expect(@result.announcement.errors[:title]).to be_present
        expect(AuditLog).not_to exist(action: "announcement.create")
      end
    end

    it "AuditLog失敗時は作成をrollbackして例外を伝播する" do
      allow(AuditLogs).to receive(:record_admin_action!).and_raise(StandardError, "audit failed")

      expect {
        expect {
          described_class.create(
            attributes: attributes,
            actor: admin,
            request: nil,
            security_context: { controller: "admin/announcements", action: "create" }
          )
        }.to raise_error(StandardError, "audit failed")
      }.not_to change(Announcement, :count)
    end

    it "lock後のglobal quota再判定で超過した画像を保存せず監査成功を残さない" do
      uploaded_image = Rack::Test::UploadedFile.new(
        Rails.root.join("spec/fixtures/files/receipt_sample.jpg"),
        "image/jpeg"
      )
      allow(Storage).to receive(:with_prepared_images)
        .and_raise(Storage::QuotaExceeded.new(scope: :global))

      result = described_class.create(
        attributes: attributes.merge("image" => uploaded_image),
        actor: admin,
        request: nil,
        uploaded_image: uploaded_image,
        security_context: { controller: "admin/announcements", action: "create" }
      )

      aggregate_failures do
        expect(result).not_to be_saved
        expect(result.announcement.errors).to be_of_kind(:image, :storage_quota_exceeded)
        expect(Announcement).not_to exist(title: attributes.fetch("title"))
        expect(AuditLog).not_to exist(action: "announcement.create")
      end
    end
  end

  describe ".update" do
    it "draftを更新してAuditLogを残す" do
      announcement = create(:announcement, status: "draft", title: "更新前")

      result = described_class.update(
        announcement: announcement,
        attributes: attributes.merge("title" => "更新後"),
        actor: admin,
        request: nil,
        security_context: { controller: "admin/announcements", action: "update" }
      )

      aggregate_failures do
        expect(result).to be_saved
        expect(announcement.reload).to have_attributes(title: "更新後", status: "draft", updated_by: admin)
        expect(AuditLog).to exist(
          action: "announcement.update",
          target_type: "Announcement",
          target_id: announcement.id
        )
      end
    end
  end

  context "画像差し替えの実transaction" do
    self.use_transactional_tests = false

    around do |example|
      Dir.mktmpdir("recify-announcement-storage-spec") do |directory|
        @service = ActiveStorage::Service::DiskService.new(root: directory)
        @service.name = "test"
        example.run
      end
    end

    before do
      allow(ActiveStorage::Blob).to receive(:service).and_return(@service)
      allow(ActiveStorage::Blob.services).to receive(:fetch).with("test").and_return(@service)
      @original_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.dup
      @blob_ids = []
      @uploaded_keys = []
      @uploaded_signed_ids = []
      @announcement = create(:announcement, title: "差し替え前", image_alt_text: "説明")
      @announcement.image.attach(uploaded_image)
      @old_blob = @announcement.image.blob
      @old_attachment_id = @announcement.image.attachment.id
      @old_bytes = @old_blob.download
      @blob_ids << @old_blob.id
      allow(@service).to receive(:upload).and_wrap_original do |method, key, io, **options|
        @uploaded_keys << key
        @blob_ids << ActiveStorage::Blob.find_by!(key: key).id
        expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
        method.call(key, io, **options)
      end
    end

    after do
      AuditLog.where(target_type: "Announcement", target_id: @announcement&.id).delete_all
      Announcement.find_by(id: @announcement&.id)&.destroy!
      ActiveStorage::Blob.where(id: @blob_ids).find_each(&:purge)
      User.find_by(id: admin.id)&.destroy!
      ActiveJob::Base.queue_adapter.enqueued_jobs.replace(@original_jobs) if @original_jobs
    end

    def uploaded_image
      Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/receipt_sample.jpg"), "image/jpeg")
    end

    def replace_image
      image = uploaded_image
      Admin::Operations.update_announcement(
        announcement: @announcement,
        attributes: { "title" => "差し替え後", "image" => image },
        actor: admin,
        request: nil,
        remove_image_requested: false,
        uploaded_image: image,
        security_context: { controller: "admin/announcements", action: "update" }
      )
    end

    def expect_original_image
      aggregate_failures do
        expect(@announcement.reload.title).to eq("差し替え前")
        expect(@announcement.image.attachment.id).to eq(@old_attachment_id)
        expect(@announcement.image.blob).to eq(@old_blob)
        expect(@old_blob.download).to eq(@old_bytes)
        expect(ActiveStorage::Blob.where(id: @blob_ids - [ @old_blob.id ])).to be_empty
        expect(@uploaded_keys).to all(satisfy { |key| !@service.exist?(key) })
        expect(AuditLog.where(action: "announcement.update", target_id: @announcement.id)).to be_empty
      end
    end

    def expect_image_preview(announcement, blob)
      rendered = ApplicationController.render(
        partial: "admin/announcements/form", locals: { announcement: announcement, link_rows: [] }
      )
      preview = Nokogiri::HTML(rendered).at_css('img[data-attachment-preview-target="image"]')
      aggregate_failures do
        expect(preview).to be_present
        expect(preview&.[]("src")).to include(blob.signed_id)
        expect(preview&.[]("data-persisted-url")).to eq(preview&.[]("src"))
        @uploaded_signed_ids.each { |signed_id| expect(rendered).not_to include(signed_id) }
      end
    end

    it "新本体のI/O失敗では旧画像と本文を残して成功監査を作らない" do
      allow(@service).to receive(:upload).and_wrap_original do |method, key, io, **options|
        @uploaded_keys << key
        blob = ActiveStorage::Blob.find_by!(key: key)
        @blob_ids << blob.id
        @uploaded_signed_ids << blob.signed_id
        method.call(key, io, **options)
        raise Errno::ENOSPC
      end

      result = replace_image

      expect(result).not_to be_saved
      expect(result.announcement.errors).to be_of_kind(:image, :upload_failed)
      expect(result.announcement.title).to eq("差し替え後")
      expect_image_preview(result.announcement, @old_blob)
      expect_original_image
    end

    it "本体保存中に先行した差し替えを上書きせず競合を表示する" do
      winner_blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(@old_bytes), filename: "winner.jpg", content_type: "image/jpeg"
      )
      loser_blob = nil
      allow(@service).to receive(:upload).and_wrap_original do |method, key, io, **options|
        loser_blob = ActiveStorage::Blob.find_by!(key: key)
        @blob_ids << loser_blob.id
        @uploaded_signed_ids << loser_blob.signed_id
        method.call(key, io, **options)
        winner = Announcement.find(@announcement.id)
        winner.image.attach(winner_blob)
        winner.update!(title: "先行した更新")
      end

      result = replace_image

      aggregate_failures do
        expect(result).not_to be_saved
        expect(result.announcement.errors).to be_of_kind(:image, :stale_image)
        expect_image_preview(result.announcement, winner_blob)
        expect(@announcement.reload.title).to eq("先行した更新")
        expect(@announcement.image.blob).to eq(winner_blob)
        expect(@announcement.image.download).to eq(@old_bytes)
        expect(ActiveStorage::Attachment.where(record: @announcement, name: "image").count).to eq(1)
        expect(ActiveStorage::Blob.exists?(loser_blob.id)).to be(false)
        expect(@service.exist?(loser_blob.key)).to be(false)
        expect(AuditLog.where(action: "announcement.update", target_id: @announcement.id)).to be_empty
      end
    end

    it "最終保存失敗では旧添付を復元して新しい本体だけを破棄する" do
      allow(@announcement).to receive(:save).and_wrap_original do |method, *arguments|
        method.call(*arguments)
        raise ActiveRecord::RecordNotSaved, "synthetic announcement save failure"
      end

      expect { replace_image }.to raise_error(ActiveRecord::RecordNotSaved, "synthetic announcement save failure")

      expect(@uploaded_keys.size).to eq(1)
      expect_original_image
    end

    it "監査保存失敗でも画像とAnnouncementとAuditLogをまとめてrollbackする" do
      allow(AuditLogs).to receive(:record_admin_action!).and_wrap_original do |method, **arguments|
        method.call(**arguments)
        raise ActiveRecord::RecordNotSaved, "synthetic audit save failure"
      end

      expect { replace_image }.to raise_error(ActiveRecord::RecordNotSaved, "synthetic audit save failure")

      expect_original_image
    end

    it "正常保存では新本体と添付と既存の成功監査を1件ずつ確定する" do
      result = replace_image
      audit_log = AuditLog.find_by!(action: "announcement.update", target_id: @announcement.id)

      aggregate_failures do
        expect(result).to be_saved
        expect(@announcement.reload.title).to eq("差し替え後")
        expect(@announcement.image.blob.id).not_to eq(@old_blob.id)
        expect(@announcement.image.download).to eq(File.binread(uploaded_image.path))
        expect(@announcement.image.blob.metadata).not_to have_key("upload_preparation")
        expect(ActiveStorage::Attachment.exists?(@old_attachment_id)).to be(false)
        expect(ActiveStorage::Attachment.where(record: @announcement, name: "image").count).to eq(1)
        expect(@uploaded_keys.size).to eq(1)
        expect(audit_log).to have_attributes(outcome: "succeeded", actor_user: admin)
        expect(AuditLog.where(action: "announcement.update", target_id: @announcement.id).count).to eq(1)
        expect(audit_log.metadata).to include("image_attached" => true, "image_byte_size" => @announcement.image.blob.byte_size)
        expect(audit_log.metadata.to_json).not_to include(@old_blob.key, @announcement.image.blob.key)
      end
    end

    it "旧画像と新画像の両方でglobal上限を超える場合は旧画像を保持する" do
      allowed_bytes = ActiveStorage::Blob.sum(:byte_size) + uploaded_image.size - 1
      allow(SystemSettings).to receive(:limit_for).and_call_original
      allow(SystemSettings).to receive(:limit_for).with("storage.global_hard_stop_bytes").and_return(allowed_bytes)
      expect(@service).not_to receive(:upload)

      result = replace_image

      expect(result).not_to be_saved
      expect(result.announcement.errors).to be_of_kind(:image, :storage_quota_exceeded)
      expect_original_image
    end
  end

  describe ".publish / .archive" do
    it "status transitionとAuditLogを一つのoperationで保存する" do
      announcement = create(:announcement, status: "draft")

      publish_result = described_class.publish(announcement: announcement, actor: admin, request: nil)
      archive_result = described_class.archive(announcement: announcement, actor: admin, request: nil)

      aggregate_failures do
        expect(publish_result).to be_saved
        expect(archive_result).to be_saved
        expect(announcement.reload.status).to eq("archived")
        expect(AuditLog.where(target_type: "Announcement", target_id: announcement.id).pluck(:action)).to include(
          "announcement.publish",
          "announcement.archive"
        )
      end
    end
  end

  def attributes
    {
      "title" => "公開するお知らせ",
      "body" => "監査payloadへ入れない本文",
      "kind" => "release",
      "pinned" => true,
      "priority" => 10,
      "starts_at" => nil,
      "ends_at" => nil,
      "announcement_links_attributes" => {
        "0" => { "label" => "詳細", "url" => "/contact", "position" => 0 }
      }
    }
  end
end
