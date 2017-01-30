require 'open-uri'
require 'open_uri_redirections'
require 'concurrent'

module Cache
  @@store = {}
  @@mutex = Mutex.new

  def self.set(key, val, expires = nil)
    expire!

    access_store do |store|
      store[key] = {
        val: val,
        expires: expires
      }
    end
  end

  def self.get(key)
    expire!

    access_store do |store|
      stored = store[key]
      return nil unless stored

      stored[:val]
    end
  end

  def self.expire!
    access_store do |store|
      to_delete = store.select { |_k, v| v[:expires] < Time.now }
      to_delete.each { |k, _v| store.delete(k) }
    end
  end

  def self.access_store
    @@mutex.synchronize { yield @@store }
  end
end

def open_url(url)
  retries = 3

  begin
    resp = Cache.get(url) || open(url, allow_redirections: :all, 'User-Agent' => rand(5000).to_s)

    Cache.set(url, resp, Time.now + 30)

    resp
  rescue OpenURI::HTTPError => e # Rescue and allow HTTP errors, like a 404
    # If it's because of rate limiting, retry in a second.
    sleep 1 && retry if e.message.include? '429'

    e.io
  rescue Net::OpenTimeout, Errno::ECONNREFUSED, OpenSSL::SSL::SSLError
    if retries > 0
      retries -= 1
      retry
    else
      nil
    end
  end
end
