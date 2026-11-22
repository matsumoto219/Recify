require "capybara"
require "selenium/webdriver"
require "capybara/selenium/patches/persistent_client"

class SystemTestWebDriverClient < Capybara::Selenium::PersistentClient
  def call(verb, path, payload)
    @request_count = @request_count.to_i + 1
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
    super
  rescue Net::ReadTimeout
    elapsed_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - started_at
    warn "WebDriver read timeout: command=#{command_name(verb, path)} request=#{@request_count} elapsed_ms=#{elapsed_ms} selenium=#{Selenium::WebDriver::VERSION}"
    raise
  end

  private

  def command_name(verb, path)
    return "unknown" unless path.is_a?(String)

    template = path.sub(%r{\Asession/[^/]+}, "session/:session_id")
    Selenium::WebDriver::Remote::Bridge::COMMANDS.key([ verb, template ]) || "unknown"
  end
end
