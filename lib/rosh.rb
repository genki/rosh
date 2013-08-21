require 'uri'
require 'resolv'
require 'net/ssh/config'

class Rosh
  def initialize(host, name = :default, *opts)
    @host, @name = host, name
    @first_try = true
    config = Net::SSH::Config.for(@host)
    @host = config[:host_name] if config[:host_name]
    @opts = ["-o ServerAliveInterval=5", "-o ServerAliveCountMax=1"]
    opts.each do |opt|
      case opt
      when '-n' 
        @opts << '-o UserKnownHostsFile=/dev/null'
        @opts << '-o StrictHostKeyChecking=no'
      end
    end
  end

  def connect
    reconnect until system ["ssh", *@opts, resolv,
      '-t', "'screen -rx #{@name}'", '2>/dev/null']*' '
  end

  def reconnect
    if @first_try
      if !sh('-p 0 -X echo ok', '2>&1 >/dev/null')
        print "creating new screen session #{@name}... "
        if sh '-c /dev/null -e "^t^t" -dm' and
          sh '-p 0 -X eval "stuff STY=\\040screen\\015"'
          puts "done."
        else
          puts "failed."
        end
      end
      @first_try = false
    else
      sleep [@last_try - Time.now + 1, 0].max if @last_try
      puts "reconnecting..."
      @last_try = Time.now
    end
  end

private
  def sh(a, r=nil) system "ssh #{resolv} 'screen -S #{@name} #{a}' #{r}" end

  def resolv
    uri = URI("//#{@host}")
    uri.host = Resolv.getaddress uri.host
    uri.to_s[2..-1]
  rescue Exception
    @host
  end
end
