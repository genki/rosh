require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'

require_relative '../lib/rosh'

class RoshForwardingTest < Minitest::Test
  def setup
    @original_home = ENV['HOME']
    @tmp_home = Dir.mktmpdir('rosh-test-home-')
    ssh_dir = File.join(@tmp_home, '.ssh')
    FileUtils.mkdir_p(ssh_dir)
    File.write(File.join(ssh_dir, 'config'), <<~CONFIG)
      Host grav
        LocalForward 127.0.0.1 3131 localhost 3131
        RemoteForward 8082 localhost 8082
    CONFIG
    ENV['HOME'] = @tmp_home
  end

  def teardown
    ENV['HOME'] = @original_home
    FileUtils.remove_entry(@tmp_home) if @tmp_home && File.exist?(@tmp_home)
  end

  def test_ssh_opts_include_local_forwarding_from_ssh_config
    klass = Class.new(Rosh) do
      def local_forward_available?(_spec)
        true
      end
    end
    rosh = klass.new('grav')
    ssh_opts = rosh.instance_variable_get(:@ssh_opts)

    assert_includes ssh_opts, '-L 127.0.0.1:3131:localhost:3131'
  end

  def test_ssh_opts_include_remote_forwarding_from_ssh_config
    klass = Class.new(Rosh) do
      def local_forward_available?(_spec)
        true
      end
    end
    rosh = klass.new('grav')
    ssh_opts = rosh.instance_variable_get(:@ssh_opts)

    assert_includes ssh_opts, '-R 8082:localhost:8082'
  end

  def test_forwarding_is_skipped_when_local_port_is_in_use
    klass = Class.new(Rosh) do
      def local_forward_available?(_spec)
        false
      end
    end
    rosh = klass.new('grav')
    ssh_opts = rosh.instance_variable_get(:@ssh_opts)

    refute_includes ssh_opts, '-L 127.0.0.1:3131:localhost:3131'
    assert_includes ssh_opts, '-R 8082:localhost:8082'
  end

  def test_verbose_logs_when_session_is_missing
    rosh = Rosh.new('grav')
    rosh.instance_variable_set(:@verbose, true)
    rosh.instance_variable_set(:@name, 'grav')
    system('true')
    status = $?
    rosh.instance_variable_set(:@last_exit_status, status)

    out, _ = capture_io do
      rosh.stub(:sh_has_session?, false) do
        rosh.send(:log_session_end, 'ssh grav')
      end
    end

    assert_includes out, 'ssh command finished (exit 0)'
    assert_includes out, 'tmux session grav が見つかりません'
  end

  def test_oom_kill_warning_is_printed_once
    rosh = Rosh.new('grav')
    status = Struct.new(:termsig, :exitstatus) do
      def success?; false; end
      def signaled?; true; end
      def stopped?; false; end
      def stopsig; nil; end
    end.new(9, nil)
    rosh.instance_variable_set(:@last_exit_status, status)

    out, _ = capture_io { rosh.send(:report_oom_if_needed, 'ssh grav') }
    assert_includes out, 'SIGKILL (OOM の可能性)'

    out_again, _ = capture_io { rosh.send(:report_oom_if_needed, 'ssh grav') }
    assert_equal '', out_again
  end

  def test_tmux_new_session_disables_destroy_unattached
    rosh = Rosh.new('grav', 'grav')
    commands = []
    rosh.stub(:system, ->(cmd) { commands << cmd; true }) do
      assert rosh.send(:sh_new_session?)
    end

    assert_equal 1, commands.size
    assert_includes commands.first, 'set-option -t grav destroy-unattached off'
  end

  def test_tmux_new_session_fallback_without_override
    rosh = Rosh.new('grav', 'grav')
    commands = []
    results = [false, true].each

    rosh.stub(:system, ->(cmd) { commands << cmd; results.next rescue true }) do
      assert rosh.send(:sh_new_session?)
    end

    assert_includes commands.first, 'set-option -t grav destroy-unattached off'
    refute_includes commands.last, 'set-option -t grav destroy-unattached off'
  end

  def test_tmux_commands_include_socket_name_when_specified
    socket_name = 'work'
    rosh = Rosh.new('-L', socket_name, 'grav')
    rosh.instance_variable_set(:@name, 'grav')

    assert_includes rosh.send(:tmux_attach_command), "-L #{socket_name}"

    commands = []
    rosh.stub(:system, ->(cmd) { commands << cmd; true }) do
      rosh.send(:sh_has_session?)
    end

    assert_includes commands.first, "-L #{socket_name}"
  end

  def test_tmux_default_socket_used_when_not_specified
    rosh = Rosh.new('grav')
    command = rosh.send(:tmux_attach_command)

    refute_includes command, '-L'
  end
end
