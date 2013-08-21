class Bosh
  def initialize(host, name = :default)
    @host, @name = host, name
  end

  def connect
    reconnect until @connected = system(["ssh",
      "-o ServerAliveInterval=5", "-o ServerAliveCountMax=1",
      #"-o UserKnownHostsFile=/dev/null", "-o StrictHostKeyChecking=no",
      @host , '-t', "'screen -rx #{@name}'", '2>/dev/null']*' ') || @connected
  end

  def reconnect
    if @connected
      sleep [@last_try - Time.now + 1, 0].max if @last_try
      puts "reconnecting..."
      @last_try = Time.now
    else
      puts "creating remote screen session '#{@name}'"
      system "ssh #{@host} screen -c /dev/null -e '^t^t' -dmS #{@name}" or abort
      system "ssh #{@host} 'screen -S #{@name} -p 0 -X eval " +
          '"stuff STY=\\040screen\\015"' + "'" or abort
    end
  end
end
