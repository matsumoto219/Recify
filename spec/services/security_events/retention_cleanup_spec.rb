require 'rails_helper'

RSpec.describe SecurityEvents::RetentionCleanup do
  describe '.call' do
    it 'severity別保持期間でdry-run対象を返し、削除しない' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      low = create(:security_event, severity: 'low', last_seen_at: now - 31.days)
      medium = create(:security_event, severity: 'medium', last_seen_at: now - 91.days)
      high = create(:security_event, severity: 'high', last_seen_at: now - 181.days)
      critical = create(:security_event, severity: 'critical', last_seen_at: now - 181.days)
      create(:security_event, severity: 'low', last_seen_at: now - 29.days)
      create(:security_event, severity: 'high', last_seen_at: now - 179.days)

      result = described_class.call(dry_run: true, now: now, limit: 100)

      aggregate_failures do
        expect(result[:dry_run]).to eq(true)
        expect(result[:expired_count]).to eq(4)
        expect(result[:deleted_count]).to eq(0)
        expect(result[:sample_event_ids]).to match_array([ low.id, medium.id, high.id, critical.id ])
        expect(result[:retentions]).to eq('critical' => 180, 'high' => 180, 'medium' => 90, 'low' => 30)
        expect(SecurityEvent.where(id: result[:sample_event_ids]).count).to eq(4)
      end
    end

    it 'execute時だけ対象を削除する' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      expired = create(:security_event, severity: 'low', last_seen_at: now - 31.days)
      retained = create(:security_event, severity: 'low', last_seen_at: now - 29.days)

      result = described_class.call(dry_run: false, now: now, limit: 100)

      aggregate_failures do
        expect(result[:expired_count]).to eq(1)
        expect(result[:deleted_count]).to eq(1)
        expect(SecurityEvent.exists?(expired.id)).to eq(false)
        expect(SecurityEvent.exists?(retained.id)).to eq(true)
      end
    end

    it 'retention期限を超えたRack::Attack由来のIP actionをeventと同時に削除する' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      expired = create(:security_event, severity: 'low', last_seen_at: now - 31.days)
      action = create(
        :security_ip_action,
        source_security_event: expired,
        source: 'rack_attack',
        status: 'active',
        last_seen_at: now - 31.days,
        expires_at: now - 30.days
      )

      result = described_class.call(dry_run: false, now: now, limit: 100)

      aggregate_failures do
        expect(result).to include(
          expired_count: 1,
          expired_ip_action_count: 1,
          deleted_count: 1,
          deleted_ip_action_count: 1,
          skipped_count: 0,
          failed_count: 0
        )
        expect(SecurityEvent.where(id: expired.id)).not_to exist
        expect(SecurityIpAction.where(id: action.id)).not_to exist
      end
    end

    it 'dry-runは削除可能なRack::Attack由来IP action数を返すが削除しない' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      expired = create(:security_event, severity: 'low', last_seen_at: now - 31.days)
      action = create(
        :security_ip_action,
        source_security_event: expired,
        source: 'rack_attack',
        status: 'observed',
        last_seen_at: now - 31.days,
        expires_at: nil
      )

      result = described_class.call(dry_run: true, now: now, limit: 100)

      aggregate_failures do
        expect(result).to include(
          expired_count: 1,
          expired_ip_action_count: 1,
          deleted_count: 0,
          deleted_ip_action_count: 0
        )
        expect(SecurityEvent.where(id: expired.id)).to exist
        expect(SecurityIpAction.where(id: action.id)).to exist
      end
    end

    it 'SecurityEvent参照のない期限切れRack::Attack IP actionもdry-run集計後に実行削除する' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      stale_action = create(
        :security_ip_action,
        source_security_event: nil,
        source: 'rack_attack',
        status: 'observed',
        first_seen_at: now - 91.days,
        last_seen_at: now - 91.days,
        expires_at: nil
      )

      dry_run_result = described_class.call(dry_run: true, now: now, limit: 100)

      aggregate_failures 'dry-run' do
        expect(dry_run_result).to include(
          expired_count: 0,
          expired_ip_action_count: 1,
          deleted_count: 0,
          deleted_ip_action_count: 0
        )
        expect(SecurityIpAction.where(id: stale_action.id)).to exist
      end

      execute_result = described_class.call(dry_run: false, now: now, limit: 100)

      aggregate_failures 'execute' do
        expect(execute_result).to include(
          expired_count: 0,
          expired_ip_action_count: 1,
          deleted_count: 0,
          deleted_ip_action_count: 1,
          skipped_count: 0,
          failed_count: 0
        )
        expect(SecurityIpAction.where(id: stale_action.id)).not_to exist
      end
    end

    it 'SecurityEvent参照のないIP actionでもfresh・active・manual・block参照中は保護する' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      fresh_action = create(
        :security_ip_action,
        source_security_event: nil,
        source: 'rack_attack',
        status: 'observed',
        first_seen_at: now - 89.days,
        last_seen_at: now - 89.days,
        expires_at: nil
      )
      unexpired_action = create(
        :security_ip_action,
        source_security_event: nil,
        source: 'rack_attack',
        status: 'active',
        first_seen_at: now - 91.days,
        last_seen_at: now - 91.days,
        expires_at: now + 1.minute
      )
      indefinite_action = create(
        :security_ip_action,
        source_security_event: nil,
        source: 'rack_attack',
        status: 'active',
        first_seen_at: now - 91.days,
        last_seen_at: now - 91.days,
        expires_at: nil
      )
      manual_action = create(
        :security_ip_action,
        source_security_event: nil,
        source: 'manual_admin',
        action_type: 'manual_ip_unblock',
        status: 'revoked',
        first_seen_at: now - 91.days,
        last_seen_at: now - 91.days,
        expires_at: nil
      )
      block = create(:security_ip_block, source_security_event: nil)
      block_linked_action = create(
        :security_ip_action,
        source_security_event: nil,
        security_ip_block: block,
        source: 'rack_attack',
        status: 'observed',
        first_seen_at: now - 91.days,
        last_seen_at: now - 91.days,
        expires_at: nil
      )

      result = described_class.call(dry_run: false, now: now, limit: 100)

      aggregate_failures do
        expect(result).to include(expired_count: 0, expired_ip_action_count: 0, deleted_ip_action_count: 0)
        expect(
          SecurityIpAction.where(
            id: [ fresh_action.id, unexpired_action.id, indefinite_action.id, manual_action.id, block_linked_action.id ]
          ).count
        ).to eq(5)
      end
    end

    it 'SecurityEvent参照のないIP actionもlimit内だけ古い順に削除する' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      older = create(
        :security_ip_action,
        source_security_event: nil,
        source: 'rack_attack',
        status: 'observed',
        first_seen_at: now - 92.days,
        last_seen_at: now - 92.days,
        expires_at: nil
      )
      newer = create(
        :security_ip_action,
        source_security_event: nil,
        source: 'rack_attack',
        status: 'observed',
        first_seen_at: now - 91.days,
        last_seen_at: now - 91.days,
        expires_at: nil
      )

      result = described_class.call(dry_run: false, now: now, limit: 1)

      aggregate_failures do
        expect(result).to include(expired_count: 0, expired_ip_action_count: 1, deleted_ip_action_count: 1)
        expect(SecurityIpAction.where(id: older.id)).not_to exist
        expect(SecurityIpAction.where(id: newer.id)).to exist
      end
    end

    it 'SecurityEvent候補でlimitを使い切る場合は後続の単独IP actionを次回へ残す' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      expired_event = create(:security_event, severity: 'low', last_seen_at: now - 31.days)
      orphan_action = create(
        :security_ip_action,
        source_security_event: nil,
        source: 'rack_attack',
        status: 'observed',
        first_seen_at: now - 91.days,
        last_seen_at: now - 91.days,
        expires_at: nil
      )

      result = described_class.call(dry_run: false, now: now, limit: 1)

      aggregate_failures do
        expect(result).to include(
          expired_count: 1,
          expired_ip_action_count: 0,
          deleted_count: 1,
          deleted_ip_action_count: 0
        )
        expect(SecurityEvent.where(id: expired_event.id)).not_to exist
        expect(SecurityIpAction.where(id: orphan_action.id)).to exist
      end
    end

    it 'selection後に単独IP actionが再度activeになった場合はlock後の再検査で保護する' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      action = create(
        :security_ip_action,
        source_security_event: nil,
        source: 'rack_attack',
        status: 'active',
        first_seen_at: now - 91.days,
        last_seen_at: now - 91.days,
        expires_at: now - 1.day
      )
      cleanup = described_class.new(dry_run: false, now: now, limit: 100)

      allow(cleanup).to receive(:target_orphan_ip_actions).and_wrap_original do |original, **arguments|
        records = original.call(**arguments)
        action.update!(last_seen_at: now, expires_at: now + 30.minutes)
        records
      end

      result = cleanup.call

      aggregate_failures do
        expect(result).to include(
          expired_count: 0,
          expired_ip_action_count: 1,
          deleted_ip_action_count: 0,
          skipped_count: 1,
          failed_count: 0
        )
        expect(SecurityIpAction.where(id: action.id)).to exist
      end
    end

    it '有効期限内または期限なしactiveのRack::Attack IP actionを保護する' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      unexpired_event = create(:security_event, severity: 'low', last_seen_at: now - 31.days)
      indefinite_event = create(:security_event, severity: 'low', last_seen_at: now - 31.days)
      unexpired = create(
        :security_ip_action,
        source_security_event: unexpired_event,
        source: 'rack_attack',
        status: 'active',
        last_seen_at: now - 31.days,
        expires_at: now + 1.minute
      )
      indefinite = create(
        :security_ip_action,
        source_security_event: indefinite_event,
        source: 'rack_attack',
        status: 'active',
        last_seen_at: now - 31.days,
        expires_at: nil
      )

      result = described_class.call(dry_run: false, now: now, limit: 100)

      aggregate_failures do
        expect(result).to include(expired_count: 0, deleted_count: 0, deleted_ip_action_count: 0)
        expect(SecurityEvent.where(id: [ unexpired_event.id, indefinite_event.id ]).count).to eq(2)
        expect(SecurityIpAction.where(id: [ unexpired.id, indefinite.id ]).count).to eq(2)
      end
    end

    it 'eventより新しく観測されたRack::Attack IP actionを保護する' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      expired = create(:security_event, severity: 'low', last_seen_at: now - 31.days)
      action = create(
        :security_ip_action,
        source_security_event: expired,
        source: 'rack_attack',
        status: 'observed',
        last_seen_at: now - 29.days,
        expires_at: nil
      )

      result = described_class.call(dry_run: false, now: now, limit: 100)

      aggregate_failures do
        expect(result).to include(expired_count: 0, deleted_count: 0, deleted_ip_action_count: 0)
        expect(SecurityEvent.where(id: expired.id)).to exist
        expect(SecurityIpAction.where(id: action.id)).to exist
      end
    end

    it 'manual admin由来のIP actionと参照元eventは保護する' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      expired = create(:security_event, severity: 'low', last_seen_at: now - 31.days)
      action = create(
        :security_ip_action,
        source_security_event: expired,
        source: 'manual_admin',
        action_type: 'manual_ip_unblock',
        status: 'revoked',
        last_seen_at: now - 31.days,
        expires_at: nil
      )

      result = described_class.call(dry_run: false, now: now, limit: 100)

      aggregate_failures do
        expect(result).to include(expired_count: 0, deleted_count: 0, deleted_ip_action_count: 0)
        expect(SecurityEvent.where(id: expired.id)).to exist
        expect(SecurityIpAction.where(id: action.id)).to exist
      end
    end

    it 'IP blockに紐づくIP actionと参照元eventはsource表示値にかかわらず保護する' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      expired = create(:security_event, severity: 'low', last_seen_at: now - 31.days)
      block = create(:security_ip_block, source_security_event: nil)
      action = create(
        :security_ip_action,
        source_security_event: expired,
        security_ip_block: block,
        source: 'rack_attack',
        status: 'observed',
        last_seen_at: now - 31.days,
        expires_at: nil
      )

      result = described_class.call(dry_run: false, now: now, limit: 100)

      aggregate_failures do
        expect(result).to include(expired_count: 0, deleted_count: 0, deleted_ip_action_count: 0)
        expect(SecurityEvent.where(id: expired.id)).to exist
        expect(SecurityIpAction.where(id: action.id)).to exist
        expect(SecurityIpBlock.where(id: block.id)).to exist
      end
    end

    it '保護対象がlimitを使い切らず後続の削除可能eventを選択する' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      protected_event = create(:security_event, severity: 'low', last_seen_at: now - 40.days)
      create(
        :security_ip_action,
        source_security_event: protected_event,
        source: 'manual_admin',
        action_type: 'manual_ip_unblock',
        status: 'revoked',
        last_seen_at: now - 40.days,
        expires_at: nil
      )
      deletable_event = create(:security_event, severity: 'low', last_seen_at: now - 31.days)
      deletable_action = create(
        :security_ip_action,
        source_security_event: deletable_event,
        source: 'rack_attack',
        status: 'observed',
        last_seen_at: now - 31.days,
        expires_at: nil
      )

      result = described_class.call(dry_run: false, now: now, limit: 1)

      aggregate_failures do
        expect(result).to include(expired_count: 1, deleted_count: 1, deleted_ip_action_count: 1)
        expect(SecurityEvent.where(id: protected_event.id)).to exist
        expect(SecurityEvent.where(id: deletable_event.id)).not_to exist
        expect(SecurityIpAction.where(id: deletable_action.id)).not_to exist
      end
    end

    it 'selection後にrecentへ変わったeventは実行直前の再検査で保護する' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      expired = create(:security_event, severity: 'low', last_seen_at: now - 31.days)
      cleanup = described_class.new(dry_run: false, now: now, limit: 100)

      allow(cleanup).to receive(:target_records).and_wrap_original do |original|
        records = original.call
        expired.update!(last_seen_at: now - 1.day)
        records
      end

      result = cleanup.call

      aggregate_failures do
        expect(result).to include(expired_count: 1, deleted_count: 0, skipped_count: 1, failed_count: 0)
        expect(SecurityEvent.where(id: expired.id)).to exist
      end
    end

    it 'selection後にIP actionが再度activeになったらeventとactionを保護する' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      expired = create(:security_event, severity: 'low', last_seen_at: now - 31.days)
      action = create(
        :security_ip_action,
        source_security_event: expired,
        source: 'rack_attack',
        status: 'active',
        last_seen_at: now - 31.days,
        expires_at: now - 30.days
      )
      cleanup = described_class.new(dry_run: false, now: now, limit: 100)

      allow(cleanup).to receive(:target_records).and_wrap_original do |original|
        records = original.call
        action.update!(last_seen_at: now, expires_at: now + 30.minutes)
        records
      end

      result = cleanup.call

      aggregate_failures do
        expect(result).to include(
          expired_count: 1,
          expired_ip_action_count: 0,
          deleted_count: 0,
          deleted_ip_action_count: 0,
          skipped_count: 1,
          failed_count: 0
        )
        expect(SecurityEvent.where(id: expired.id)).to exist
        expect(SecurityIpAction.where(id: action.id)).to exist
      end
    end

    it 'event削除失敗時は先に削除したIP actionもrollbackする' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      expired = create(:security_event, severity: 'low', last_seen_at: now - 31.days)
      action = create(
        :security_ip_action,
        source_security_event: expired,
        source: 'rack_attack',
        status: 'observed',
        last_seen_at: now - 31.days,
        expires_at: nil
      )
      allow_any_instance_of(SecurityEvent).to receive(:delete).and_raise(ActiveRecord::StatementInvalid, 'forced')

      result = described_class.call(dry_run: false, now: now, limit: 100)

      aggregate_failures do
        expect(result).to include(
          expired_count: 1,
          deleted_count: 0,
          deleted_ip_action_count: 0,
          skipped_count: 0,
          failed_count: 1
        )
        expect(result[:errors]).to eq([ { event_id: expired.id, error_class: 'ActiveRecord::StatementInvalid' } ])
        expect(SecurityEvent.where(id: expired.id)).to exist
        expect(SecurityIpAction.where(id: action.id)).to exist
      end
    end

    it 'Receipt・IP blockから参照中のeventは削除対象にしない' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      receipt_event = create(:security_event, severity: 'low', last_seen_at: now - 31.days)
      block_event = create(:security_event, severity: 'low', last_seen_at: now - 31.days)
      create(:receipt, quarantine_source_security_event: receipt_event)
      create(:security_ip_block, source_security_event: block_event)

      result = described_class.call(dry_run: false, now: now, limit: 100)

      aggregate_failures do
        expect(result[:expired_count]).to eq(0)
        expect(result[:deleted_count]).to eq(0)
        expect(SecurityEvent.where(id: [ receipt_event.id, block_event.id ]).count).to eq(2)
      end
    end

    it 'selection後に参照されたeventは実行直前の再検査で保護する' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      expired = create(:security_event, severity: 'low', last_seen_at: now - 31.days)
      cleanup = described_class.new(dry_run: false, now: now, limit: 100)

      allow(cleanup).to receive(:target_records).and_wrap_original do |original|
        records = original.call
        create(:receipt, quarantine_source_security_event: expired)
        records
      end

      result = cleanup.call

      aggregate_failures do
        expect(result).to include(expired_count: 1, deleted_count: 0, skipped_count: 1, failed_count: 0)
        expect(SecurityEvent.where(id: expired.id)).to exist
      end
    end

    it 'dry_run nilは安全側のdry-runとして扱う' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      expired = create(:security_event, severity: 'low', last_seen_at: now - 31.days)

      result = described_class.call(dry_run: nil, now: now, limit: 100)

      aggregate_failures do
        expect(result[:dry_run]).to be(true)
        expect(result[:deleted_count]).to eq(0)
        expect(SecurityEvent.where(id: expired.id)).to exist
      end
    end

    it 'limitで削除対象数を丸める' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      create_list(:security_event, 3, severity: 'low', last_seen_at: now - 31.days)

      result = described_class.call(dry_run: true, now: now, limit: 2)

      expect(result[:expired_count]).to eq(2)
    end

    it 'SystemSettingsのseverity別保持期間を使う' do
      now = Time.zone.parse('2026-06-16 12:00:00')
      create(:system_setting, key: 'retention.security_events_medium_days', value: SystemSettings.stored_value(45))
      expired = create(:security_event, severity: 'medium', last_seen_at: now - 46.days)
      create(:security_event, severity: 'medium', last_seen_at: now - 44.days)

      result = described_class.call(dry_run: true, now: now, limit: 100)

      aggregate_failures do
        expect(result[:expired_count]).to eq(1)
        expect(result[:sample_event_ids]).to eq([ expired.id ])
        expect(result[:retentions]['medium']).to eq(45)
      end
    end
  end
end
