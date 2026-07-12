require 'rails_helper'

RSpec.describe Receipts::ProcessingPhasePresenter do
  describe '#key' do
    it 'falls back to processing when a processing receipt has no active run' do
      receipt = create(:receipt, :processing, :with_image)

      presenter = described_class.new(receipt:)

      expect(presenter.key).to eq(:processing)
    end

    it 'uses queued for a queued active run' do
      receipt = create(:receipt, :processing, :with_image)
      create(:receipt_analysis_run, receipt:, status: 'queued', stage: 'queued')

      presenter = described_class.new(receipt:)

      expect(presenter.key).to eq(:queued)
    end

    it 'uses ocr while OCR has started and not finished' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(
        :receipt_analysis_run,
        receipt:,
        status: 'running',
        stage: 'ocr',
        ocr_started_at: Time.current,
        ocr_finished_at: nil
      )

      presenter = described_class.new(receipt:, analysis_run: run)

      expect(presenter.key).to eq(:ocr)
    end

    it 'uses organizing after OCR finishes and before AI starts' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(
        :receipt_analysis_run,
        receipt:,
        status: 'running',
        stage: 'ocr_validation',
        ocr_started_at: 2.seconds.ago,
        ocr_finished_at: Time.current,
        ai_started_at: nil
      )

      presenter = described_class.new(receipt:, analysis_run: run)

      expect(presenter.key).to eq(:organizing)
    end

    it 'uses ai only after AI has actually started' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(
        :receipt_analysis_run,
        receipt:,
        status: 'running',
        stage: 'ai',
        ocr_finished_at: 2.seconds.ago,
        ai_started_at: Time.current,
        ai_finished_at: nil
      )

      presenter = described_class.new(receipt:, analysis_run: run)

      expect(presenter.key).to eq(:ai)
    end

    it 'does not claim AI enrichment when AI has not started' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(
        :receipt_analysis_run,
        receipt:,
        status: 'running',
        stage: 'ai',
        ocr_finished_at: Time.current,
        ai_started_at: nil,
        ai_finished_at: nil
      )

      presenter = described_class.new(receipt:, analysis_run: run)

      expect(presenter.key).to eq(:organizing)
    end

    it 'uses finalize while results are being saved' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(
        :receipt_analysis_run,
        receipt:,
        status: 'running',
        stage: 'finalize',
        ocr_finished_at: 3.seconds.ago,
        ai_started_at: 2.seconds.ago,
        ai_finished_at: Time.current
      )

      presenter = described_class.new(receipt:, analysis_run: run)

      expect(presenter.key).to eq(:finalize)
    end

    it 'uses receipt final statuses before run phase' do
      receipt = create(:receipt, :review_needed)
      run = create(:receipt_analysis_run, :running, receipt:)

      presenter = described_class.new(receipt:, analysis_run: run)

      expect(presenter.key).to eq(:review_needed)
    end
  end

  describe '#steps' do
    it 'marks the current and completed steps' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(
        :receipt_analysis_run,
        receipt:,
        status: 'running',
        stage: 'ai',
        ocr_finished_at: 2.seconds.ago,
        ai_started_at: Time.current
      )

      presenter = described_class.new(receipt:, analysis_run: run)

      expect(presenter.steps.map(&:state)).to eq(%w[done done active pending])
    end

    it 'separates node state from the outgoing interval state for every processing phase' do
      receipt = build_stubbed(:receipt, :processing)
      now = Time.current
      cases = {
        queued: {
          run: build_stubbed(:receipt_analysis_run, receipt:, status: 'queued', stage: 'queued'),
          nodes: %w[active pending pending pending],
          intervals: [ 'active', 'pending', 'pending', nil ]
        },
        ocr: {
          run: build_stubbed(
            :receipt_analysis_run,
            receipt:,
            status: 'running',
            stage: 'ocr',
            ocr_started_at: now,
            ocr_finished_at: nil
          ),
          nodes: %w[done active pending pending],
          intervals: [ 'completed', 'active', 'pending', nil ]
        },
        organizing: {
          run: build_stubbed(
            :receipt_analysis_run,
            receipt:,
            status: 'running',
            stage: 'ocr_validation',
            ocr_started_at: now - 2.seconds,
            ocr_finished_at: now,
            ai_started_at: nil
          ),
          nodes: %w[done active pending pending],
          intervals: [ 'completed', 'active', 'pending', nil ]
        },
        ai: {
          run: build_stubbed(
            :receipt_analysis_run,
            receipt:,
            status: 'running',
            stage: 'ai',
            ocr_finished_at: now - 2.seconds,
            ai_started_at: now,
            ai_finished_at: nil
          ),
          nodes: %w[done done active pending],
          intervals: [ 'completed', 'completed', 'active', nil ]
        },
        finalize: {
          run: build_stubbed(
            :receipt_analysis_run,
            receipt:,
            status: 'running',
            stage: 'finalize',
            ocr_finished_at: now - 3.seconds,
            ai_started_at: now - 2.seconds,
            ai_finished_at: now - 1.second
          ),
          nodes: %w[done done done active],
          intervals: [ 'completed', 'completed', 'completed', nil ]
        }
      }

      aggregate_failures do
        cases.each do |expected_key, attributes|
          presenter = described_class.new(receipt:, analysis_run: attributes.fetch(:run))

          expect(presenter.key).to eq(expected_key)
          expect(presenter.steps.map(&:state)).to eq(attributes.fetch(:nodes))
          expect(presenter.steps.map(&:interval_state)).to eq(attributes.fetch(:intervals))
        end
      end
    end

    it 'keeps the fallback processing phase at the upload node and interval' do
      receipt = create(:receipt, :processing, :with_image)
      presenter = described_class.new(receipt:)

      aggregate_failures do
        expect(presenter.key).to eq(:processing)
        expect(presenter.steps.map(&:state)).to eq(%w[active pending pending pending])
        expect(presenter.steps.map(&:interval_state)).to eq([ 'active', 'pending', 'pending', nil ])
      end
    end
  end

  describe 'stream ordering metadata' do
    it 'exposes a monotonic revision and phase order for processing updates' do
      receipt = create(:receipt, :processing, :with_image)
      run = create(
        :receipt_analysis_run,
        receipt:,
        status: 'running',
        stage: 'ocr',
        ocr_started_at: Time.current
      )
      presenter = described_class.new(receipt:, analysis_run: run)

      aggregate_failures do
        expect(presenter.phase_order).to be > described_class.new(
          receipt:,
          analysis_run: run.dup.tap { |copy| copy.stage = 'queued'; copy.status = 'queued' }
        ).phase_order
        expect(presenter.state_revision).to eq((run.updated_at.to_r * 1_000_000).to_i)
        expect(presenter).not_to be_terminal
      end
    end

    it 'marks final receipt states as terminal' do
      receipt = create(:receipt, :completed)
      presenter = described_class.new(receipt:)

      aggregate_failures do
        expect(presenter).to be_terminal
        expect(presenter.phase_order).to be > described_class.new(
          receipt: build_stubbed(:receipt, :processing),
          analysis_run: nil
        ).phase_order
      end
    end
  end
end
