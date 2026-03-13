# frozen_string_literal: true

require_relative "daemon/version"
require_relative "daemon/configuration"

require "socket"
require "stringio"
require "rspec"

module RSpec
  class Daemon
    SCRIPT_NAME = File.basename(__FILE__).freeze

    class Error < StandardError; end

    def initialize(bind_address, port)
      @bind_address = bind_address
      @port = port
    end

    def start
      $LOAD_PATH << "./spec"

      RSpec::Core::Runner.disable_autorun!
      server = TCPServer.open(@bind_address, @port)
      puts "Listening on tcp://#{server.addr[2]}:#{server.addr[1]}"

      loop do
        handle_request(server.accept)
      rescue Interrupt
        puts "quit"
        server.close
        break
      rescue SignalException => e
        puts "quit (#{e.signm})"
        server.close
        break
      rescue Exception => e
        $stderr.puts "Unexpected error in server loop: #{e.class}: #{e.message}"
        $stderr.puts e.backtrace.first(5).join("\n")
      end
    end

    def handle_request(socket)
      status, out = run(socket.gets)

      socket.puts(status)
      socket.puts(out)
      puts out
      socket.puts(__FILE__)
    rescue SystemExit => e
      $stderr.puts "Caught SystemExit (status: #{e.status}) — daemon continues"
      socket.puts e.full_message rescue nil
    rescue StandardError => e
      socket.puts e.full_message
    ensure
      socket.close
    end

    def run(msg, options = [])
      options += ["--force-color", "--format", "documentation"]
      argv = msg.strip.split(" ")

      reset
      out = StringIO.new
      status = RSpec::Core::Runner.run(options + argv, out, out)

      [status, out.string]
    end

    def reset
      unless RSpec::Core::Configuration.method_defined?(:__command_overridden__)
        RSpec::Core::Configuration.class_eval do
          define_method(:command) { "rspec" }
          define_method(:__command_overridden__) { true }
        end
      end
      RSpec::Core::Runner.disable_autorun!
      RSpec.reset
      reset_simplecov

      if cached_config.has_recorded_config?
        # Reload configuration from the first time
        cached_config.replay_configuration
        # Invoke auto reload (if Rails is in Zeitwerk mode and autoloading is enabled)
        if defined?(::Rails) && ::Rails.respond_to?(:autoloaders) && !::Rails.configuration.cache_classes
          puts "Reloading..."
          if ::Rails.application.respond_to?(:reloader)
            ::Rails.application.reloader.reload!
          else
            ::Rails.autoloaders.main.reload
          end
        end
      else
        # This is the first spec run
        cached_config.record_configuration(&rspec_configuration)
      end
    end

    def reset_simplecov
      return unless defined?(::SimpleCov)

      SimpleCov.result if SimpleCov.running
      SimpleCov.instance_variable_set(:@result, nil)
      SimpleCov.pid = Process.pid
    rescue StandardError => e
      $stderr.puts "SimpleCov reset warning: #{e.message}"
    end

    def rspec_configuration
      proc do
        ENV['RSPEC_DAEMON'] = "1"
        if File.exist? "spec/rails_helper.rb"
          require "rails_helper"
        end
      end
    end

    def cached_config
      @cached_config ||= RSpec::Daemon::Configuration.new
    end

    RSpec::Core::BacktraceFormatter.class_eval do
      def format_backtrace(backtrace, options = {})
        return [] unless backtrace
        return backtrace if options[:full_backtrace] || backtrace.empty?

        backtrace.map { |l| backtrace_line(l) }.compact.inject([]) do |result, line|
          break result if line.include?(SCRIPT_NAME)

          result << line
        end
      end
    end
  end
end
