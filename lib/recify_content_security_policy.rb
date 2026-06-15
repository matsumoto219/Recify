# frozen_string_literal: true

module RecifyContentSecurityPolicy
  TURNSTILE_SOURCE = "https://challenges.cloudflare.com"
  GOOGLE_STYLES_SOURCE = "https://fonts.googleapis.com"
  GOOGLE_FONTS_SOURCE = "https://fonts.gstatic.com"

  class << self
    def apply(policy)
      policy.default_src :self
      policy.base_uri :self
      policy.object_src :none
      policy.frame_ancestors :none
      policy.form_action :self
      policy.connect_src :self, TURNSTILE_SOURCE
      policy.img_src :self, :data, :blob
      policy.script_src :self, TURNSTILE_SOURCE
      policy.style_src :self, :unsafe_inline, GOOGLE_STYLES_SOURCE
      policy.font_src :self, :data, GOOGLE_FONTS_SOURCE
      policy.frame_src TURNSTILE_SOURCE
      policy.manifest_src :self
      policy.media_src :self, :blob
      policy.worker_src :self, :blob
    end

    def configure(config, report_only:)
      config.content_security_policy { |policy| apply(policy) }
      config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
      config.content_security_policy_nonce_directives = %w[script-src]
      config.content_security_policy_nonce_auto = true
      config.content_security_policy_report_only = report_only
    end
  end
end
