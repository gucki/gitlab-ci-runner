require_relative 'build'
require_relative 'network'

module GitlabCi
  class Runner
    attr_accessor :current_build, :thread

    def initialize
      puts '* Gitlab CI Runner started'
      puts '* Waiting for builds'
      loop do
        if running?
          update_build
        else
          get_build
        end
        sleep 5
      end
    end

    private

    def running?
      current_build
    end

    def get_build
      build_data = network.get_build
      if build_data
        run(build_data)
      else
        false
      end
    end

    def update_build
      state = current_build.state
      puts "#{Time.now.to_s} | Build #{current_build.id}, state #{state}."

      if network.update_build(current_build.id, state, current_build.trace) == :aborted
        puts "#{Time.now.to_s} | Build #{current_build.id} was aborted by the user."
        current_build.abort
      end

      unless state == :running
        puts "#{Time.now.to_s} | Build #{current_build.id} completed."
        current_build.cleanup
        self.current_build = nil
      end
    end

    def network
      @network ||= Network.new
    end

    def run(build_data)
      current_build = GitlabCi::Build.new(build_data)
      puts "#{Time.now.to_s} | Starting new build #{current_build.id}..."
      current_build.run
    end

    def collect_trace
      current_build.trace
    end
  end
end
