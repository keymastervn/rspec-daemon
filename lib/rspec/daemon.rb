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
      preload

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

    private

    def preload
      unless RSpec::Core::Configuration.method_defined?(:__command_overridden__)
        RSpec::Core::Configuration.class_eval do
          define_method(:command) { "rspec" }
          define_method(:__command_overridden__) { true }
        end
      end

      cached_config.record_configuration(&rspec_configuration)
      puts "Application preloaded."
    end

    def handle_request(socket)
      msg = socket.gets
      return if msg.nil?

      pid = fork do
        run_in_child(socket, msg)
      end

      socket.close # parent closes its copy; child owns it
      Process.wait(pid)
    rescue Errno::ECHILD
      # child already reaped
    end

    def run_in_child(socket, msg)
      reconnect_active_record

      RSpec::Core::Runner.disable_autorun!
      RSpec.reset
      cached_config.replay_configuration

      options = ["--force-color", "--format", "documentation"]
      argv = msg.strip.split(" ")

      out = StringIO.new
      status = RSpec::Core::Runner.run(options + argv, out, out)

      socket.puts(status)
      socket.puts(out.string)
      $stdout.puts out.string
      socket.puts(__FILE__)
    rescue Exception => e
      $stderr.puts "Child error: #{e.class}: #{e.message}"
      socket.puts(e.full_message) rescue nil
    ensure
      socket.close rescue nil
      exit!(0) # skip at_exit handlers (SimpleCov, etc.)
    end

    def reconnect_active_record
      return unless defined?(ActiveRecord::Base)

      ActiveRecord::Base.clear_all_connections!
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
