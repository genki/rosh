class Rosh
  def initialize(host, name = :default)
    @host, @name = host, name
    @first_try = true
  end

  def connect
    reconnect until system ["ssh",
      "-o ServerAliveInterval=5", "-o ServerAliveCountMax=1",
      #"-o UserKnownHostsFile=/dev/null", "-o StrictHostKeyChecking=no",
      @host , '-t', "'screen -rx #{@name}'", '2>/dev/null']*' '
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
  def sh(a, r=nil) system "ssh #{@host} 'screen -S #{@name} #{a}' #{r}" end
end
