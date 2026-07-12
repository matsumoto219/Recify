require "rails_helper"

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
