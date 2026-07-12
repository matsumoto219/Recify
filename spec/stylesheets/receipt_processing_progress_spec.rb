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

  it 'uses an indeterminate active glint without representing a completion percentage' do
    aggregate_failures do
      expect(source).to include('@keyframes receipt-processing-interval-flow')
      expect(source).to include('@keyframes receipt-processing-interval-flow-vertical')
      expect(source).to include('animation: receipt-processing-interval-flow 1.8s linear infinite;')
      expect(source).to include('background-size: 220% 100%;')
      expect(source).not_to include('transition: width')
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
