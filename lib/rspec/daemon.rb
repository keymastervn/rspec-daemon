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

    RELOAD_POLL_INTERVAL = 3 # seconds between file change checks

    def initialize(bind_address, port)
      @bind_address = bind_address
      @port = port
      @last_checked_at = Time.now
      @run_count = 0
    end

    def start
      $LOAD_PATH << "./spec"

      RSpec::Core::Runner.disable_autorun!
      preload

      server = TCPServer.open(@bind_address, @port)
      log "Listening on tcp://#{server.addr[2]}:#{server.addr[1]} (pid: #{Process.pid}, pgid: #{Process.getpgrp})"

      loop do
        handle_request(server.accept)
      rescue Interrupt
        log "quit"
        server.close
        break
      rescue SignalException => e
        log "quit (#{e.signm})"
        server.close
        break
      rescue Exception => e
        log "Unexpected error in server loop: #{e.class}: #{e.message}", :error
        $stderr.puts e.backtrace.first(5).join("\n")
      end
    end

    private

    def log(message, level = :info)
      timestamp = Time.now.strftime("%H:%M:%S.%L")
      prefix = "[rspec-daemon #{timestamp}]"
      if level == :error
        $stderr.puts "#{prefix} #{message}"
      else
        $stdout.puts "#{prefix} #{message}"
      end
    end

    def child_exit_info(status)
      if status.signaled?
        "killed by SIG#{Signal.signame(status.termsig)}#{status.coredump? ? ' (core dumped)' : ''}"
      else
        "status #{status.exitstatus}"
      end
    end

    def preload
      unless RSpec::Core::Configuration.method_defined?(:__command_overridden__)
        RSpec::Core::Configuration.class_eval do
          define_method(:command) { "rspec" }
          define_method(:__command_overridden__) { true }
        end
      end

      cached_config.record_configuration(&rspec_configuration)
      log "Application preloaded."
    end

    def handle_request(socket)
      msg = socket.gets
      return if msg.nil?

      @run_count += 1
      run_id = @run_count
      log "[run:#{run_id}] Received: #{msg.strip}"

      reload_if_changed

      pid = fork do
        Process.setpgrp # isolate child from parent's process group
        run_in_child(socket, msg, run_id)
      end

      socket.close # parent closes its copy; child owns it
      log "[run:#{run_id}] Forked child pid:#{pid} (parent pgid: #{Process.getpgrp})"

      _, status = Process.wait2(pid)
      log "[run:#{run_id}] Child pid:#{pid} exited: #{child_exit_info(status)}"
    rescue Errno::ECHILD
      log "[run:#{run_id}] Child already reaped (ECHILD)"
    end

    def run_in_child(socket, msg, run_id)
      log "[run:#{run_id}] Child started pid:#{Process.pid} pgid:#{Process.getpgrp}"

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
      log "[run:#{run_id}] Child finished with rspec status:#{status}"
    rescue Exception => e
      log "[run:#{run_id}] Child error: #{e.class}: #{e.message}", :error
      socket.puts(e.full_message) rescue nil
    ensure
      socket.close rescue nil
      exit!(0) # skip at_exit handlers (SimpleCov, etc.)
    end

    def reconnect_active_record
      return unless defined?(ActiveRecord::Base)

      if ActiveRecord::Base.connection_handler.respond_to?(:clear_all_connections!)
        ActiveRecord::Base.connection_handler.clear_all_connections!
      elsif ActiveRecord.respond_to?(:connection_handler)
        ActiveRecord.connection_handler.clear_all_connections!
      end
      ActiveRecord::Base.establish_connection
    end

    def reload_if_changed
      return unless defined?(::Rails) && ::Rails.application.respond_to?(:reloader)
      return if Time.now - @last_checked_at < RELOAD_POLL_INTERVAL

      @last_checked_at = Time.now

      reloaded = false
      ::Rails.application.reloaders.each do |reloader|
        next unless reloader.respond_to?(:execute_if_updated)
        reloaded = true if reloader.execute_if_updated
      end

      log "Application reloaded." if reloaded
    rescue StandardError => e
      log "Reload warning: #{e.message}", :error
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
