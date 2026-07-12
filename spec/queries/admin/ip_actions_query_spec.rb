# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::IpActionsQuery do
  describe ".call" do
    it "IP単位でlast_seen_at desc / id descの履歴を返す" do
      older = create(:security_ip_action, ip_address: "8.8.8.8", last_seen_at: 2.hours.ago)
      newer = create(:security_ip_action, ip_address: "8.8.8.8", last_seen_at: 1.hour.ago, action_type: "rate_limit_triggered", status: "observed")
      create(:security_ip_action, ip_address: "1.1.1.1")

      result = described_class.call(ip_address: "8.8.8.8")

      expect(result.records.map { |record| record[:id] }).to eq([ newer.id, older.id ])
    end

    it "関連SecurityEvent / IP制限 / actorを表示用payloadに含める" do
      actor = create(:user, :admin)
      event = create(:security_event, ip_address: "8.8.8.8")
      block = create(:security_ip_block, ip_address: "8.8.8.8", source_security_event: event)
      action = create(
        :security_ip_action,
        ip_address: "8.8.8.8",
        source_security_event: event,
        security_ip_block: block,
        actor_user: actor
      )

      record = described_class.call(ip_address: "8.8.8.8").records.first

      aggregate_failures do
        expect(record[:id]).to eq(action.id)
        expect(record.dig(:source_security_event, :id)).to eq(event.id)
        expect(record.dig(:security_ip_block, :id)).to eq(block.id)
        expect(record.dig(:actor_user, :id)).to eq(actor.id)
      end
    end

    it "invalid IPは空結果にする" do
      create(:security_ip_action, ip_address: "8.8.8.8")

      result = described_class.call(ip_address: "not-an-ip")

      expect(result.records).to be_empty
    end
  end
end
