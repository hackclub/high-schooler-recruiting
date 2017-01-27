#!/usr/bin/env ruby
# coding: utf-8

require 'byebug'

require 'nokogiri'
require 'open-uri'
require 'open_uri_redirections'
require 'tmpdir'
require 'concurrent'
require 'mail'

THREADS = 16

GITHUB_PROFILE_WEBSITE_XPATH = '//*[@id="js-pjax-container"]/div/div[1]/ul/li[4]/a'.freeze
GITHUB_PROFILE_BIO_SELECTOR = '.user-profile-bio > div'.freeze
GITHUB_FOLLOWER_LIST_ITEM_SELECTOR = '.follow-list-item'.freeze
GITHUB_FOLLOWER_LIST_NEXT_ITEM_DISABLED_XPATH = '//*[@id="js-pjax-container"]/div[2]/div[3]/div/span'.freeze
GITHUB_SOURCE_REPOS_LIST_SELECTOR = '#user-repositories-list .js-repo-list li'.freeze
GITHUB_SOURCE_REPOS_CURRENT_PAGE_BTN_SELECTOR = '#user-repositories-list > div.paginate-container > div > em'.freeze
GITHUB_SOURCE_REPOS_NEXT_PAGE_DISABLED_XPATH = '//*[@id="user-repositories-list"]/div[3]/div/span'.freeze
GITHUB_REPO_BRANCHES_DEFAULT_XPATH = '//*[@id="branch-autoload-container"]/div[1]/div[2]/div/span[1]/a'
GITHUB_COMMITS_COMMIT_ITEM_SELECTOR = '.commit-group > li.commit.commits-list-item'.freeze

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

def doc_from_url(url)
  Nokogiri::HTML(open_url(url))
end

def github_url_from_username(username)
  "https://github.com/#{username}"
end

def website_url_from_github(username)
  doc = doc_from_url(github_url_from_username(username))

  url = doc.xpath(GITHUB_PROFILE_WEBSITE_XPATH).text

  return nil if url == ''

  url
end

# Given a Nokogiri document, this method gets its text and strips extra newlines.
def text_of(nokogiri_doc)
  nokogiri_doc.text.gsub("\n", ' ')
end

def bio_from_github_username(username)
  doc = doc_from_url(github_url_from_username(username))

  bio = doc.css(GITHUB_PROFILE_BIO_SELECTOR).first
  return nil unless bio

  bio.text.strip
end

def likely_high_schooler?(github_username)
  bio = bio_from_github_username(github_username)
  return true if bio =~ /high school/i

  website_url = website_url_from_github(github_username)
  return false unless website_url

  website = doc_from_url(website_url)
  return false unless website

  text = text_of(website)

  text.include?('high school') || text =~ /\w+ at \w+ high school/i
end

def every_follower_of(github_username, page = 1, &block)
  doc = doc_from_url(
    github_url_from_username(github_username) + "/followers?page=#{page}"
  )

  followers = doc.css(GITHUB_FOLLOWER_LIST_ITEM_SELECTOR)

  followers.each do |follower_node|
    name_link = follower_node.search('a').first
    profile_uri = name_link.attributes['href'].value

    # Strip first character, which is a /
    #
    # Ex. /prophetorpheus -> prophetorpheus
    username = profile_uri[1..-1]

    yield username
  end

  # Check to see if the next button is disabled. If it's not disabled, run this
  # function on the next page. If it is disabled, stop the recursion.
  disabled_next_btn_elems =
    doc.xpath(GITHUB_FOLLOWER_LIST_NEXT_ITEM_DISABLED_XPATH)

  every_follower_of(github_username, page + 1, &block) if
    disabled_next_btn_elems.empty?
end

def repos_from_github_profile_page(username, page = 1)
  doc = doc_from_url(github_url_from_username(username) +
                     "?page=#{page}&tab=repositories&type=source")

  repo_list = doc.css(GITHUB_SOURCE_REPOS_LIST_SELECTOR)

  repos = repo_list.map do |repo_node|
    # Find the link to the repo's page and then get the repo's name from the
    # link's text.
    repo_node.search('a').first.text.strip
  end

  disabled_next_btn = doc.xpath(GITHUB_SOURCE_REPOS_NEXT_PAGE_DISABLED_XPATH).first

  is_last_page = (disabled_next_btn != nil &&
                  disabled_next_btn.text.strip.downcase == 'next')

  [repos, !is_last_page]
end

def repos_from_github_username(username)
  page = 1
  has_next_page = true

  Enumerator.new do |enum|
    while has_next_page
      repos, has_next_page = repos_from_github_profile_page(username, page)

      repos.each { |r| enum.yield r }

      page += 1
    end
  end
end

def default_branch_for_repo(username, repo_name)
  doc = doc_from_url(
    github_url_from_username(username) + "/#{repo_name}/branches"
  )

  doc.xpath(GITHUB_REPO_BRANCHES_DEFAULT_XPATH).text
end

# Currently does not paginate, only returns most recent page. Pagination on
# commits page is strange.
def latest_commits_from_repo(username, repo_name, author: nil, branch: nil)
  branch ||= default_branch_for_repo(username, repo_name)

  doc = doc_from_url(
    github_url_from_username(username) + "/#{repo_name}/commits/#{branch}?author=#{author}"
  )

  commit_list = doc.css(GITHUB_COMMITS_COMMIT_ITEM_SELECTOR)

  commit_list.map do |commit_node|
    copy_to_clipboard_btn = commit_node.search('button.zeroclipboard-button').first

    sha = copy_to_clipboard_btn.attributes['data-clipboard-text'].value

    sha
  end
end

def commits_in_repo(username, repo_name, author: nil, branch: nil)
  commit_shas = latest_commits_from_repo(
    username,
    repo_name,
    author: author,
    branch: branch
  )

  Enumerator.new { |e| commit_shas.each { |sha| e.yield sha } }
end

def raw_commit_patch(username, repo_name, commit_sha)
  patch = open_url(github_url_from_username(username) +
                   "/#{repo_name}/commit/#{commit_sha}.patch").read

  Mail::Encodings.value_decode(patch)
end

def info_from_github_username(username)
  latest_repo = repos_from_github_username(username).first
  return nil unless latest_repo

  latest_commit = commits_in_repo(username, latest_repo, author: username).first
  return nil unless latest_commit

  latest_patch = raw_commit_patch(username, latest_repo, latest_commit)
  # Patches can be empty, if an empty commit was created. Skip if we get our
  # hands on an empty patch file.
  return nil unless latest_patch && !latest_patch.empty?

  # Extracted from the "From:" section of the patch file
  match = latest_patch.match(/^From: (.+)\n? <(.*)>$/)
  return nil unless match

  match.captures
end

def usernames_from_page_of_search_query(query, page = 1)
  doc = doc_from_url("https://github.com/search?p=#{page}&q=#{query}&type=Users")

  user_items = doc.css('.user-list-item')

  # Filter out GitHub orgs. Actual users have a follow button on the right of
  # their item in the list, so filter out anything that doesn't have a follow
  # button.
  actual_users = user_items.select do |user_item|
    follow_btn = user_item.search('span.follow').first

    !follow_btn.nil?
  end

  # Extract their usernames
  usernames = actual_users.map do |user|
    user.search('.user-list-info > a').first.text
  end

  next_page_disabled_btn = doc.css('#user_search_results > div.paginate-container > div > span.next_page.disabled').first

  has_next_page = next_page_disabled_btn.nil?

  [usernames, has_next_page]
end

def usernames_from_search(query)
  page = 1
  has_next_page = true

  Enumerator.new do |enum|
    while has_next_page
      usernames, has_next_page = usernames_from_page_of_search_query(query, page)

      usernames.each { |u| enum.yield u }

      # Try to be at least somewhat aware of their rate limiting
      sleep 3

      page += 1
    end
  end
end

puts "Name\tEmail\tGitHub"

pool = Concurrent::FixedThreadPool.new(THREADS)
semaphore = Mutex.new

usernames_from_search('high+school').each do |username|
  pool.post do
    probably_high_schooler = likely_high_schooler? username
    next unless probably_high_schooler

    name, email = info_from_github_username(username)
    next unless name && email

    semaphore.synchronize { puts "#{name}\t#{email}\t#{username}" }
  end
end
