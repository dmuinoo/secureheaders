require 'uri'
require 'brwsr'

module SecureHeaders
  class ContentSecurityPolicyBuildError < StandardError; end
  class ContentSecurityPolicy
    module Constants
      WEBKIT_CSP_HEADER = "default-src https: data: 'unsafe-inline' 'unsafe-eval'; frame-src https://* about: javascript:; img-src chrome-extension:"
      FIREFOX_CSP_HEADER = "options eval-script inline-script; allow https://* data:; frame-src https://* about: javascript:; img-src chrome-extension:"

      FIREFOX_CSP_HEADER_NAME = 'X-Content-Security-Policy'
      WEBKIT_CSP_HEADER_NAME = 'X-WebKit-CSP'
      STANDARD_HEADER_NAME = "Content-Security-Policy"

      FF_CSP_ENDPOINT = "/content_security_policy/forward_report"
      WEBKIT_DIRECTIVES = DIRECTIVES = [:default_src, :script_src, :frame_src, :style_src, :img_src, :media_src, :font_src, :object_src, :connect_src]
      FIREFOX_DIRECTIVES = DIRECTIVES + [:xhr_src, :frame_ancestors] - [:connect_src]
      META = [:enforce, :http_additions, :disable_chrome_extension, :disable_fill_missing, :forward_endpoint]
    end
    include Constants

    attr_accessor *META
    attr_reader :browser, :ssl_request, :report_uri, :request_uri, :experimental, :config

    alias :disable_chrome_extension? :disable_chrome_extension
    alias :disable_fill_missing? :disable_fill_missing
    alias :ssl_request? :ssl_request

    def initialize(request=nil, config=nil, options={})
      @experimental = !!options.delete(:experimental)
      if config
        configure request, config
      elsif request
        parse_request request
      end
    end

    def configure request, opts
      @config = opts.dup

      experimental_config = @config.delete(:experimental)
      if @experimental && experimental_config
        @config[:http_additions] = experimental_config[:http_additions]
        @config.merge!(experimental_config)
      end

      parse_request request
      META.each do |meta|
        self.send(meta.to_s + "=", @config.delete(meta))
      end

      @report_uri = @config.delete(:report_uri)

      normalize_csp_options
      normalize_reporting_endpoint
      filter_unsupported_directives
    end

    def name
      browser_strategy.name
    end

    def value
      return @config if @config.is_a?(String)

      if @config.nil?
        browser_strategy.csp_header
      else
        build_value
      end
    end

    private

    def browser_strategy
      @browser_strategy ||= BrowserStrategy.build(self)
    end

    def directives
      browser_strategy.directives
    end

    def build_value
      fill_directives unless disable_fill_missing?
      add_missing_chrome_extension_values unless disable_chrome_extension?
      append_http_additions unless ssl_request?

      header_value = [
        build_impl_specific_directives,
        generic_directives(@config),
        report_uri_directive(@report_uri)
      ].join

      #store the value for next time
      @config = header_value
      header_value.strip
    rescue StandardError => e
      raise ContentSecurityPolicyBuildError.new("Couldn't build CSP header :( #{e}")
    end

    def fill_directives
      return unless @config[:default_src]

      default = @config[:default_src]
      directives.each do |directive|
        unless @config[directive]
          @config[directive] = default
        end
      end
      @config
    end

    def add_missing_chrome_extension_values
      directives.each do |directive|
        next unless @config[directive]
        if !@config[directive].include?('chrome-extension:')
          @config[directive] << 'chrome-extension:'
        end
      end
    end

    def append_http_additions
      return unless http_additions

      http_additions.each do |k, v|
        @config[k] ||= []
        @config[k] << v
      end
    end

    def normalize_csp_options
      @config.each do |k,v|
        @config[k] = v.split if v.is_a? String
        @config[k] = @config[k].map do |val|
          translate_dir_value(val)
        end
      end
    end

    def filter_unsupported_directives
      @config = browser_strategy.filter_unsupported_directives(@config)
    end

    # translates 'inline','self', 'none' and 'eval' to their respective impl-specific values.
    def translate_dir_value val
      if %w{inline eval}.include?(val)
        translate_inline_or_eval(val)
        # self/none are special sources/src-dir-values and need to be quoted in chrome
      elsif %{self none}.include?(val)
        "'#{val}'"
      else
        val
      end
    end

    def translate_inline_or_eval val
      browser_strategy.translate_inline_or_eval(val)
    end

    # if we have a forwarding endpoint setup and we are not on the same origin as our report_uri
    # or only a path was supplied (in which case we assume cross-host)
    # we need to forward the request for Firefox.
    def normalize_reporting_endpoint
      return unless browser_strategy.normalize_reporting_endpoint?
      return unless !same_origin? || URI.parse(report_uri).host.nil?

      if forward_endpoint
        @report_uri = FF_CSP_ENDPOINT
      else
        @report_uri = nil
      end
    end

    def build_impl_specific_directives
      default = expect_directive_value(:default_src)
      browser_strategy.build_impl_specific_directives(default)
    end

    def expect_directive_value key
      @config.delete(key) {|k| raise ContentSecurityPolicyBuildError.new("Expected to find #{k} directive value")}
    end

    def same_origin?
      return if report_uri.nil?

      origin = URI.parse(request_uri)
      uri = URI.parse(report_uri)
      uri.host == origin.host && origin.port == uri.port && origin.scheme == uri.scheme
    end

    def directive? val, name
      val.to_s.casecmp(name) == 0
    end

    def report_uri_directive(report_uri)
      report_uri.nil? ? '' : "report-uri #{report_uri};"
    end


    def generic_directives(config)
      header_value = ''
      if config[:img_src]
        config[:img_src] = config[:img_src] + ['data:'] unless config[:img_src].include?('data:')
      else
        config[:img_src] = ['data:']
      end

      config.keys.sort_by{|k| k.to_s}.each do |k| # ensure consistent ordering
        header_value += "#{symbol_to_hyphen_case(k)} #{config[k].join(" ")}; "
      end

      header_value
    end

    def symbol_to_hyphen_case sym
      sym.to_s.gsub('_', '-')
    end

    def parse_request request
      @browser = Brwsr::Browser.new(:ua => request.env['HTTP_USER_AGENT'])
      @ssl_request = request.ssl?
      @request_uri = if request.respond_to?(:original_url)
        # rails 3.1+
        request.original_url
      else
        # rails 2/3.0
        request.url
      end
    end
  end
end
