# frozen_string_literal: true

require "rails_helper"

require "erb"
require "yaml"

RSpec.describe "Solid Queue production configuration" do
  let(:queue_config) do
    YAML.safe_load(ERB.new(Rails.root.join("config/queue.yml").read).result, aliases: true)
  end
  let(:recurring_config) do
    YAML.safe_load(ERB.new(Rails.root.join("config/recurring.yml").read).result, aliases: true)
  end
  let(:workers) { Array(queue_config.dig("production", "workers")) }
  let(:worker_queue_names) do
    workers.flat_map do |worker|
      Array(worker["queues"]).flat_map { |queues| queues.to_s.split(",") }
    end.map(&:strip)
  end

  def recurring_queue_name(task)
    return task["queue"].to_s if task["queue"].present?
    return SolidQueue::RecurringJob.queue_name if task["command"].present?

    nil
  end

  it "recurring scheduleが使用する全queueをproduction workerが処理する" do
    recurring_queues = recurring_config.fetch("production").values.filter_map do |task|
      recurring_queue_name(task)
    end.uniq

    uncovered_queues = recurring_queues.reject { |queue_name| worker_queue_names.include?(queue_name) }

    expect(uncovered_queues).to be_empty
  end

  it "command形式のrecurring queueを専用の低並列workerで処理する" do
    worker = workers.find { |candidate| candidate["queues"] == SolidQueue::RecurringJob.queue_name }

    expect(worker).to include(
      "threads" => 1,
      "processes" => 1,
      "polling_interval" => 1
    )
  end

  it "timezone未指定のdaily scheduleをTokyoの次回時刻として解釈する" do
    original_system_time_zone = ENV["TZ"]
    ENV["TZ"] = "UTC"
    tokyo = ActiveSupport::TimeZone[Rails.application.config.time_zone]
    schedule = recurring_config.dig("production", "notification_cleanup", "schedule")
    task = SolidQueue::RecurringTask.allocate
    task.define_singleton_method(:schedule) { schedule }

    aggregate_failures do
      expect(Rails.application.config.solid_queue.time_zone).to eq(Rails.application.config.time_zone)
      expect(SolidQueue.time_zone).to eq(tokyo.tzinfo.name)
      expect(task.next_time_after(tokyo.local(2026, 8, 11, 2))).to eq(tokyo.local(2026, 8, 11, 3).utc)
    end
  ensure
    ENV["TZ"] = original_system_time_zone
  end

  it "production worker selectorでcommand形式のrecurring jobを一度だけ実行できる" do
    command = <<~RUBY.squish
      Rails.application.config.x.recurring_queue_contract_runs =
        Rails.application.config.x.recurring_queue_contract_runs.to_i + 1
    RUBY
    Rails.application.config.x.recurring_queue_contract_runs = 0
    relation = Class.new do
      def queued_as(queue_name)
        queue_name
      end
    end.new
    pause_relation = Struct.new(:queue_names) do
      def pluck(*)
        queue_names
      end
    end.new([])
    pause_model = Class.new do
      define_singleton_method(:all) { pause_relation }
    end
    stub_const("SolidQueue::Pause", pause_model)
    selected_queues = SolidQueue::QueueSelector.new(worker_queue_names, relation).scoped_relations

    SolidQueue::RecurringJob.perform_now(command)

    aggregate_failures do
      expect(selected_queues).to include(SolidQueue::RecurringJob.queue_name)
      expect(Rails.application.config.x.recurring_queue_contract_runs).to eq(1)
    end
  ensure
    Rails.application.config.x.recurring_queue_contract_runs = nil
  end
end
