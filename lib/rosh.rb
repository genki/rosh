require 'uri'
require 'resolv'
require 'net/ssh/config'
require 'optparse'
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
    config = Net::SSH::Config.for(@host)
    if @verbose
      puts "ssh-config: #{config}"
    end
    @host = config[:host_name] if config[:host_name]
    @ssh_opts << "-l #{config[:user]}" if config[:user]
    @ssh_opts << "-p #{config[:port]}" if config[:port]
    @ssh_opts << "-J #{config[:proxy].jump_proxies}" if config[:proxy]
    if keys = config[:keys]
      keys.each{|k| @ssh_opts << "-i #{k}"}
    end

    local_forwards(config[:host] || @host).each do |f|
      @ssh_opts << "-L #{f}"
    end
    remote_forwards(config[:host] || @host).each do |f|
      @ssh_opts << "-R #{f}"
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
    reconnect until system cmd
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
  def sh(a, r=nil)
    cmd = "ssh #{resolv} #{@ssh_opts*' '} 'screen -S #{@name} #{a}' #{r}"
    if @verbose
      puts cmd
    end
    system cmd
  end

  def sh_has_session?
    # tmux has-session -t <session_name>
    cmd = [
      "ssh",
      *@ssh_opts,
      resolv,
      "'tmux has-session -t #{@name} 2>/dev/null'"
    ]*' '
    puts cmd if @verbose
    system cmd
  end

  def sh_new_session?
    # tmux new-session -s <session_name> -d
    cmd = [
      "ssh",
      *@ssh_opts,
      resolv,
      "'tmux new-session -s #{@name} -d'"
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
        forwards << $1.strip
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
        forwards << $1.strip
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
