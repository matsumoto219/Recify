require 'rails_helper'

RSpec.describe 'Receipt processing progress stylesheet' do
  let(:source) { expanded_tailwind_source }

  it 'keeps pending and active interval bases neutral while completed intervals use the brand token' do
    aggregate_failures do
      expect(source).to include('.receipt-processing-step:not(:last-child)::after')
      expect(source).to include('.receipt-processing-interval-completed:not(:last-child)::after')
      expect(source).to include('.receipt-processing-interval-active:not(:last-child)::before')
      expect(source).not_to include(<<~CSS.strip)
        .receipt-processing-step-done:not(:last-child)::after,
        .receipt-processing-step-active:not(:last-child)::after
      CSS
    end
  end

  it 'uses one non-repeating active glint without representing a completion percentage' do
    aggregate_failures do
      expect(source).to include('@keyframes receipt-processing-interval-flow')
      expect(source).to include('@keyframes receipt-processing-interval-flow-vertical')
      expect(source).to include('animation: receipt-processing-interval-flow 2s linear 0s infinite normal;')
      expect(source).to include('background-repeat: no-repeat;')
      expect(source).to include('background-size: 220% 100%;')
      expect(source.scan('animation: receipt-processing-interval-flow ').size).to eq(1)
      expect(source).not_to include('transition: width')
    end
  end

  it 'resets the horizontal and vertical glints only while they are invisible' do
    horizontal_start = source.index('@keyframes receipt-processing-interval-flow {')
    vertical_start = source.index('@keyframes receipt-processing-interval-flow-vertical {')
    keyframes_end = source.index('@keyframes receipt-processing-icon-glow', vertical_start)
    horizontal = source[horizontal_start...vertical_start]
    vertical = source[vertical_start...keyframes_end]

    aggregate_failures do
      expect(horizontal).to include('background-position: 115% 0;')
      expect(horizontal).to include('background-position: -15% 0;')
      expect(horizontal).to include("0%,\n  5%")
      expect(horizontal.scan('opacity: 0;').size).to be >= 2
      expect(vertical).to include('background-position: 0 115%;')
      expect(vertical).to include('background-position: 0 -15%;')
      expect(vertical).to include("0%,\n  5%")
      expect(vertical.scan('opacity: 0;').size).to be >= 2
    end
  end

  it 'distinguishes the active ring from a solid completed node' do
    aggregate_failures do
      expect(source).to include('.receipt-processing-step-done .receipt-processing-step-dot')
      expect(source).to include('.receipt-processing-step-active .receipt-processing-step-dot')
      expect(source).to include('background: var(--bg-card);')
      expect(source).not_to include(<<~CSS.strip)
        .receipt-processing-step-done .receipt-processing-step-dot,
        .receipt-processing-step-active .receipt-processing-step-dot
      CSS
    end
  end

  it 'adapts the active glint to the narrow vertical step layout' do
    start_index = source.index('@media (width <= 380px)')
    end_index = source.index('@keyframes receipt-processing-ai-dot', start_index)
    narrow_layout = source[start_index...end_index]

    aggregate_failures do
      expect(narrow_layout).to include('.receipt-processing-interval-active:not(:last-child)::before')
      expect(narrow_layout).to include('background-size: 100% 220%;')
      expect(narrow_layout).to include('animation-name: receipt-processing-interval-flow-vertical;')
    end
  end

  it 'does not animate completed or pending intervals' do
    aggregate_failures do
      expect(source).not_to match(/receipt-processing-interval-completed[^}]*animation:/m)
      expect(source).not_to match(/receipt-processing-interval-pending[^}]*animation:/m)
    end
  end

  it 'stops both active interval movement and node pulse for reduced motion' do
    cards_index = source.index('/* ===== Receipt Card Utilities ===== */')
    start_index = source.index('@media (prefers-reduced-motion: reduce)', cards_index)
    end_index = source.index('/* ===== Receipt Status Badge Utilities ===== */', start_index)
    reduced_motion = source[start_index...end_index]

    aggregate_failures do
      expect(reduced_motion).to include('.receipt-processing-interval-active:not(:last-child)::before')
      expect(reduced_motion).to include('.receipt-processing-step-active .receipt-processing-step-dot')
      expect(reduced_motion).to include('animation: none;')
    end
  end
end
