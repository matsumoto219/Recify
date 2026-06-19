module SecurityEvents
  module Rules
    class InputRule < Base
      RULES = [
        {
          event_type: "sql_injection_attempt",
          severity: "high",
          matched_rule: "sql_union_or_tautology",
          pattern: /(?:\bunion\s+select\b|\bor\s+1\s*=\s*1\b|\band\s+1\s*=\s*1\b|'\s*or\s*'1'\s*=\s*'1)/i
        },
        {
          event_type: "sql_injection_attempt",
          severity: "high",
          matched_rule: "sql_destructive_statement",
          pattern: /(?:;\s*)?\b(?:drop|alter|truncate)\s+(?:table|database)\b/i
        },
        {
          event_type: "nosql_injection_attempt",
          severity: "medium",
          matched_rule: "nosql_operator_marker",
          pattern: /(?:["']?\$(?:ne|gt|gte|lt|lte|in|nin|where|regex)["']?\s*:|\b\$where\b)/i
        },
        {
          event_type: "xss_attempt",
          severity: "high",
          matched_rule: "script_or_javascript",
          pattern: /(?:<\s*script\b|javascript\s*:|on(?:error|load|click|mouseover)\s*=)/i
        },
        {
          event_type: "html_injection_attempt",
          severity: "medium",
          matched_rule: "active_html_element",
          pattern: /<\s*(?:iframe|object|embed|svg|meta|link|style)\b/i
        },
        {
          event_type: "path_traversal_attempt",
          severity: "high",
          matched_rule: "dot_dot_path",
          pattern: /(?:\.\.\/|\.\.\\|%2e%2e|%252e%252e|%2fetc%2fpasswd|\/etc\/passwd)/i
        },
        {
          event_type: "crlf_injection_attempt",
          severity: "medium",
          matched_rule: "encoded_or_literal_crlf_header",
          pattern: /(?:%0d%0a|\r\n|\n(?:set-cookie|location|content-length)\s*:)/i
        },
        {
          event_type: "command_injection_attempt",
          severity: "high",
          matched_rule: "shell_metachar_or_command",
          pattern: /(?:[`|;&]\s*(?:curl|wget|bash|sh|powershell|cmd\.exe)\b|\$\([^)]{1,100}\))/i
        },
        {
          event_type: "log_injection_attempt",
          severity: "low",
          matched_rule: "log_line_breakout",
          pattern: /(?:\r|\n)(?:\s*(?:error|warn|fatal|info)\b|\[[A-Z]+\])/i
        },
        {
          event_type: "template_injection_attempt",
          severity: "medium",
          matched_rule: "template_expression_marker",
          pattern: /(?:\{\{[^}]{1,120}\}\}|\{%[^%]{1,120}%\}|<%=?[^%]{1,120}%>)/i
        },
        {
          event_type: "redos_attempt",
          severity: "medium",
          matched_rule: "nested_quantifier_regex",
          pattern: /\((?:[^()]{1,40}[+*])\)[+*]/
        },
        {
          event_type: "csv_injection_attempt",
          severity: "medium",
          matched_rule: "spreadsheet_formula_marker",
          pattern: /\A[=+@]\s*(?:cmd|powershell|hyperlink|importxml|importdata|webservice|[A-Z]+\s*\()/i
        },
        {
          event_type: "xml_injection_attempt",
          severity: "medium",
          matched_rule: "xml_doctype_or_entity",
          pattern: /(?:<!DOCTYPE\b|<!ENTITY\b|<\?xml\b.{0,200}<!DOCTYPE\b)/im
        },
        {
          event_type: "xpath_injection_attempt",
          severity: "medium",
          matched_rule: "xpath_boolean_bypass",
          pattern: /(?:\bor\s+count\s*\(|\bor\s+name\s*\(|\]\s*\[|\bor\s+['"]1['"]\s*=\s*['"]1['"])/i
        },
        {
          event_type: "ldap_injection_attempt",
          severity: "medium",
          matched_rule: "ldap_filter_breakout",
          pattern: /(?:\*\)\s*\(|\(\|\s*\([^)]*\*\)|\(\&\s*\([^)]*\*\))/
        },
        {
          event_type: "schema_abuse_attempt",
          severity: "medium",
          matched_rule: "json_schema_control_key",
          pattern: /["'](?:__proto__|constructor|prototype|\$schema|\$ref)["']\s*:/i
        }
      ].freeze

      def call(param_path:, value:, context: nil)
        RULES.filter_map do |rule|
          next unless rule.fetch(:pattern).match?(value)

          build_candidate(
            event_type: rule.fetch(:event_type),
            severity: rule.fetch(:severity),
            category: "input",
            matched_rule: rule.fetch(:matched_rule),
            field_name: param_path,
            value_excerpt: value
          )
        end
      end
    end
  end
end
