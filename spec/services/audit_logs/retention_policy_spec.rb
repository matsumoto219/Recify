require 'rails_helper'

RSpec.describe AuditLogs::RetentionPolicy do
  describe '.category_for' do
    it 'actionを保持分類へ割り当てる' do
      aggregate_failures do
        expect(described_class.category_for(action: 'admin.users.delete')).to eq(:user_delete)
        expect(described_class.category_for(action: 'admin.users.lock')).to eq(:high_risk_admin)
        expect(described_class.category_for(action: 'admin.users.force_two_factor_reset')).to eq(:high_risk_admin)
        expect(described_class.category_for(action: 'system_settings.update')).to eq(:high_risk_admin)
        expect(described_class.category_for(action: 'contact_requests.retention_cleanup.execute')).to eq(:cleanup_execute)
        expect(described_class.category_for(action: 'receipt_analysis_runs.cleanup_stale.execute')).to eq(:cleanup_execute)
        expect(described_class.category_for(action: 'receipt_images.purge.execute')).to eq(:cleanup_execute)
        expect(described_class.category_for(action: 'admin.passkey_reauthentication.succeeded')).to eq(:passkey_reauth)
        expect(described_class.category_for(action: 'contact_requests.retention_cleanup.dry_run')).to eq(:system_dry_run)
        expect(described_class.category_for(action: 'receipt_analysis_runs.cleanup_stale.dry_run')).to eq(:system_dry_run)
        expect(described_class.category_for(action: 'receipt_images.purge.dry_run')).to eq(:system_dry_run)
      end
    end

    it 'cleanup系failed auditはcleanup_failedへ割り当てる' do
      expect(
        described_class.category_for(action: 'contact_requests.retention_cleanup.dry_run', outcome: 'failed')
      ).to eq(:cleanup_failed)
    end

    it 'unknown actionは削除対象分類にしない' do
      expect(described_class.category_for(action: 'unknown.action')).to be_nil
    end
  end

  describe '.retention_for' do
    it '分類ごとの保持期間を返す' do
      aggregate_failures do
        expect(described_class.retention_for(:high_risk_admin)).to eq(365.days)
        expect(described_class.retention_for(:cleanup_execute)).to eq(365.days)
        expect(described_class.retention_for(:cleanup_failed)).to eq(180.days)
        expect(described_class.retention_for(:passkey_reauth)).to eq(90.days)
        expect(described_class.retention_for(:system_dry_run)).to eq(30.days)
        expect(described_class.retention_for(:routine_system)).to eq(90.days)
      end
    end

    it 'admin.users.delete はretention除外にする' do
      aggregate_failures do
        expect(described_class.excluded?(:user_delete)).to be(true)
        expect(described_class.retention_for(:user_delete)).to be_nil
      end
    end
  end

  describe '.cutoff_for' do
    it '保持期間からcutoffを計算する' do
      now = Time.zone.parse('2026-05-27 12:00:00')

      expect(described_class.cutoff_for(:system_dry_run, now: now)).to eq(now - 30.days)
    end
  end
end
