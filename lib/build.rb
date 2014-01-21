require_relative 'encode'
require_relative 'config'

require 'childprocess'
require 'tempfile'
require 'fileutils'
require 'bundler'
require 'shellwords'

module GitlabCi
  class Build
    TIMEOUT = 7200

    attr_accessor :id, :commands, :ref, :before_sha

    def initialize(data)
      @commands = data[:commands].to_a
      @ref = data[:ref]
      @ref_name = data[:ref_name]
      @id = data[:id]
      @project_id = data[:project_id]
      @repo_url = data[:repo_url]
      @before_sha = data[:before_sha]
      @timeout = data[:timeout] || TIMEOUT
      @allow_git_fetch = data[:allow_git_fetch]
    end

    def run
      @executor_file = Tempfile.new("executor")
      @executor_file.chmod(0755)

      @commands.unshift(checkout_cmd)

      if repo_exists? && @allow_git_fetch
        @commands.unshift(fetch_cmd)
      else
        FileUtils.rm_rf(project_dir)
        FileUtils.mkdir_p(project_dir)
        @commands.unshift(clone_cmd)
      end

      @executor_file.puts %|#!/bin/bash|
      @executor_file.puts %|set -e|
      @executor_file.puts %|trap 'kill -s INT 0' EXIT|

      @commands.each do |command|
        @executor_file.puts %|echo #{command.shellescape}|
        @executor_file.puts(command)
      end
      @executor_file.close

      Bundler.with_clean_env { execute("setsid #{@executor_file.path}") }
    end

    def state
      return :success if success?
      return :failed if failed?
      :running
    end

    def completed?
      @process.exited?
    end

    def success?
      return nil unless completed?
      @process.exit_code == 0
    end

    def failed?
      return nil unless completed?
      @process.exit_code != 0
    end

    def running?
      @process.alive?
    end

    def abort
      @process.stop
    end

    def output
      GitlabCi::Encode.encode!(File.binread(@output_file.path))
    end

    def cleanup
      @output_file.close
      @executor_file.unlink
    end

    private

    def execute(cmd)
      cmd = cmd.strip

      FileUtils.mkdir_p(config.logs_dir)
      @output_file = File.new(File.join(config.logs_dir, "build-#{id}"), "w", :binmode => true)
      @output_file.sync = true

      @process = ChildProcess.build('bash', '--login', '-c', cmd)
      @process.io.stdout = @output_file
      @process.io.stderr = @output_file
      @process.cwd = project_dir

      @process.environment['CI_SERVER'] = 'yes'
      @process.environment['CI_SERVER_NAME'] = 'GitLab CI'
      @process.environment['CI_SERVER_VERSION'] = nil# GitlabCi::Version
      @process.environment['CI_SERVER_REVISION'] = nil# GitlabCi::Revision

      @process.environment['CI_BUILD_REF'] = @ref
      @process.environment['CI_BUILD_BEFORE_SHA'] = @before_sha
      @process.environment['CI_BUILD_REF_NAME'] = @ref_name
      @process.environment['CI_BUILD_ID'] = @id

      @process.start
    end

    def checkout_cmd
      cmd = []
      cmd << "cd #{project_dir}"
      cmd << "git reset --hard"
      cmd << "git checkout #{@ref}"
      cmd.join(" && ")
    end

    def clone_cmd
      cmd = []
      cmd << "cd #{config.builds_dir}"
      cmd << "git clone #{@repo_url} project-#{@project_id}"
      cmd << "cd project-#{@project_id}"
      cmd << "git checkout #{@ref}"
      cmd.join(" && ")
    end

    def fetch_cmd
      cmd = []
      cmd << "cd #{project_dir}"
      cmd << "git reset --hard"
      cmd << "git clean -fdx"
      cmd << "git remote set-url origin #{@repo_url}"
      cmd << "git fetch origin"
      cmd.join(" && ")
    end

    def repo_exists?
      File.exists?(File.join(project_dir, '.git'))
    end

    def config
      @config ||= Config.new
    end

    def project_dir
      File.join(config.builds_dir, "project-#{@project_id}")
    end
  end
end
