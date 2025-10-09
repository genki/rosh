require 'uri'
require 'resolv'
require 'net/ssh/config'
require 'optparse'
require 'socket'
require File.join(File.dirname(__FILE__), %w[rosh version])

class Rosh
  def initialize(*args)
    @interval = 3
    @ssh_opts = []
    alive_interval = 5
    @escape = '^t'
    OptionParser.new("test").tap do |opt|
      opt.banner = 'Usage: rosh [options] hostname [session-name]'
      opt.on('-a alive-interval'){|v| alive_interval = v.to_i}
      opt.on('-e escape'){|v| @escape = v}
      opt.on('-I interval'){|v| @interval = v.to_f}
      opt.on('-V'){|v| @verbose = true}
      opt.on('-S'){|v| @screen = true}
    end.parse! args
    @host, @name = *args, :default
    abort 'hostname is required' if @host == :default
    @ssh_opts << "-o ServerAliveInterval=#{alive_interval}"
    @ssh_opts << "-o ServerAliveCountMax=1"

    # check ~/.ssh/config to resolve alias name
    alias_name = @host
    config = Net::SSH::Config.for(@host)
    if @verbose
      puts "ssh-config: #{config}"
    end
    @forward_opts = []
    @forwarding_disabled = false
    @oom_reported = false
    @last_exit_status = nil
    local_forwards(alias_name).each do |f|
      add_forward_option(:local, f)
    end
    remote_forwards(alias_name).each do |f|
      add_forward_option(:remote, f)
    end
    @host = config[:host_name] if config[:host_name]
    @ssh_opts << "-l #{config[:user]}" if config[:user]
    @ssh_opts << "-p #{config[:port]}" if config[:port]
    @ssh_opts << "-J #{config[:proxy].jump_proxies}" if config[:proxy]
    if keys = config[:keys]
      keys.each{|k| @ssh_opts << "-i #{k}"}
    end
    if @verbose
      puts "host: #{@host}"
      puts "name: #{@name}"
      puts "interval: #{@interval}"
      puts "alive_interval: #{alive_interval}"
      puts "options: #{@ssh_opts*' '}"
    end
    @first_try = true
  end

  def connect
    cmd = if @screen
      ["ssh", *@ssh_opts, resolv,
        '-t', "'screen -rx #{@name}'", '2>/dev/null']*' '
    else
      ["ssh", *@ssh_opts, resolv,
        '-t', "'tmux attach -t #{@name}'", '2>/dev/null']*' '
    end
    if @verbose
      puts "connecting to #{@host}..."
      puts cmd
    end
    begin
      reconnect
    end until execute_attach(cmd)
    report_session_end(cmd)
  end

  def reconnect
    if @first_try
      session_exists = if @screen
        sh('-p 0 -X echo ok', '2>&1 >/dev/null')
      else
        sh_has_session?
      end
      unless session_exists
        type = @screen ? 'screen' : 'tmux'
        print "creating new #{type} session #{@name}..."
        new_session = if @screen
          sh %{-c /dev/null -e "#{@escape*2}" -dm} and
            sh '-p 0 -X eval "stuff STY=\\040screen\\015"'
        else
          sh_new_session?
        end
        if new_session
          puts "done."
        else
          puts "failed."
        end
      end
      @first_try = false
    else
      sleep [@last_try - Time.now + @interval, 0].max if @last_try
      puts "reconnecting..."
      @last_try = Time.now
    end
  end

private
  def execute_attach(cmd)
    result = system cmd
    @last_exit_status = $?
    report_oom_if_needed(cmd)
    if @verbose && !result
      log_failed_command(cmd)
    end
    result
  end

  def add_forward_option(kind, spec)
    return if forwarding_disabled?
    if kind == :local && !local_forward_available?(spec)
      puts "skip forwarding: #{spec} is already in use"
      disable_forwarding!
      return
    end
    opt = kind == :local ? "-L #{spec}" : "-R #{spec}"
    @ssh_opts << opt
    @forward_opts << opt
  end

  def disable_forwarding!
    return if @forwarding_disabled
    @forwarding_disabled = true
    @forward_opts.each { |opt| @ssh_opts.delete(opt) }
    @forward_opts.clear
  end

  def forwarding_disabled?
    @forwarding_disabled
  end

  def local_forward_available?(spec)
    host, port = parse_local_forward(spec)
    return true unless host && port
    server = TCPServer.new(host, port)
    server.close
    true
  rescue Errno::EADDRINUSE, Errno::EACCES, Errno::EADDRNOTAVAIL
    false
  rescue Errno::EPERM
    true
  rescue SocketError, ArgumentError
    true
  end

  def parse_local_forward(spec)
    parts = spec.split(':')
    host = parts.length >= 4 ? parts.first : '127.0.0.1'
    port = parts.length >= 4 ? parts[1] : parts.first
    port_num = Integer(port)
    [host.empty? ? '127.0.0.1' : host, port_num]
  rescue ArgumentError
    [nil, nil]
  end

  def report_session_end(cmd)
    report_oom_if_needed(cmd)
    log_session_end(cmd) if @verbose
  end

  def report_oom_if_needed(cmd)
    return if @oom_reported
    return unless oom_killed?(@last_exit_status)
    @oom_reported = true
    puts "tmux session #{@name} が SIGKILL (OOM の可能性) で終了しました。" +
      " (command: #{cmd})"
  end

  def oom_killed?(status)
    return false unless status
    sig9 = status.respond_to?(:termsig) && status.termsig == 9
    exit_137 = status.respond_to?(:exitstatus) && status.exitstatus == 137
    sig9 || exit_137
  end

  def log_failed_command(cmd)
    status = @last_exit_status
    detail = format_status(status)
    if detail
      puts "ssh command failed (#{detail}) while executing: #{cmd}"
    else
      puts "ssh command failed while executing: #{cmd}"
    end
  end

  def log_session_end(cmd)
    status = @last_exit_status
    detail = format_status(status)
    puts "ssh command finished (#{detail}) for: #{cmd}"
    return unless status && status.success?
    prev_status = @last_exit_status
    session_alive = sh_has_session?
    @last_exit_status = prev_status
    if session_alive
      puts "tmux session #{@name} は継続中です。ユーザーデタッチまたはSSH切断で終了しました。"
    else
      puts "tmux session #{@name} が見つかりません。リモートシェルが即終了した可能性があります。"
    end
  end

  def format_status(status)
    return nil unless status
    parts = []
    parts << "exit #{status.exitstatus}" if status.exitstatus
    parts << "signal #{status.termsig}" if status.signaled?
    parts << "stopped #{status.stopsig}" if status.stopped?
    parts.empty? ? nil : parts.join(', ')
  end

  def sh(a, r=nil)
    cmd = "ssh #{resolv} #{@ssh_opts*' '} 'screen -S #{@name} #{a}' #{r}"
    if @verbose
      puts cmd
    end
    system cmd
  end

  def sh_has_session?
    # tmux has-session -t <session_name>
    ssh_tmux("tmux has-session -t #{@name} 2>/dev/null")
  end

  def sh_new_session?
    # tmux new-session -s <session_name> -d
    create_with_override = "tmux new-session -s #{@name} -d \\; set-option -t #{@name} destroy-unattached off"
    return true if ssh_tmux(create_with_override)

    puts "retrying tmux new-session without destroy-unattached override" if @verbose
    ssh_tmux("tmux new-session -s #{@name} -d")
  end

  def ssh_tmux(command)
    cmd = [
      "ssh",
      *@ssh_opts,
      resolv,
      "'#{command}'"
    ]*' '
    puts cmd if @verbose
    system cmd
  end

  def local_forwards(host)
    file = File.expand_path("~/.ssh/config")
    return [] unless File.readable?(file)
    forwards = []
    current = false
    File.foreach(file) do |line|
      line = line.sub(/#.*/, '').strip
      next if line.empty?
      if line =~ /^Host\s+(.*)/i
        patterns = $1.split(/\s+/)
        current = patterns.any? { |p| host =~ Net::SSH::Config.send(:pattern2regex, p) }
      elsif current && line =~ /^LocalForward\s+(.*)/i
                        forwards << $1.strip.gsub(/\s+/, ':')
      end
    end
    forwards
  end

  def remote_forwards(host)
    file = File.expand_path("~/.ssh/config")
    return [] unless File.readable?(file)
    forwards = []
    current = false
    File.foreach(file) do |line|
      line = line.sub(/#.*/, '').strip
      next if line.empty?
      if line =~ /^Host\s+(.*)/i
        patterns = $1.split(/\s+/)
        current = patterns.any? { |p| host =~ Net::SSH::Config.send(:pattern2regex, p) }
      elsif current && line =~ /^RemoteForward\s+(.*)/i
                        forwards << $1.strip.gsub(/\s+/, ':')
      end
    end
    forwards
  end

  def resolv
    uri = URI("//#{@host}")
    uri.host = Resolv::DNS.new.getaddress(uri.host).to_s
    uri.to_s[2..-1]
  rescue Exception
    @host
  end
end
