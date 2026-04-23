require_relative '../daemon'

module RSpec
  class Daemon
    class Cli
      DEFAULT_OPTIONS = {
        bind_address: "0.0.0.0",
        port: 3002,
        fork: false,
      }

      def self.start(...)
        new.start(...)
      end

      def start(argv)
        options = DEFAULT_OPTIONS.dup
        if ENV['RSPEC_DAEMON_BIND_ADDRESS']
          options[:bind_address] = ENV['RSPEC_DAEMON_BIND_ADDRESS']
        end
        if ENV['RSPEC_DAEMON_PORT']
          options[:port] = ENV['RSPEC_DAEMON_PORT'].to_i
        end
        if ENV['RSPEC_DAEMON_FORK']
          options[:fork] = true
        end

        option_parser = OptionParser.new do |opts|
          opts.on('-v', '--version', 'Prints version') do
            puts RSpec::Daemon::VERSION
            exit
          end

          opts.on('-b', '--bind ADDRESS', 'address to bind (default: 0.0.0.0)') do |address|
            options[:bind_address] = address
          end

          opts.on('-p', '--port PORT', 'port to listen on (default: 3002)') do |port|
            options[:port] = port
          end

          opts.on('--fork', 'Run tests in a forked process (stronger isolation, Linux only for gRPC)') do
            options[:fork] = true
          end
        end
        option_parser.parse!(argv)

        RSpec::Daemon.new(options[:bind_address], options[:port], fork: options[:fork]).start
        0
      end
    end
  end
end
