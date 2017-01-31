#!/usr/bin/env ruby
# coding: utf-8

# 1. Get top subreddit posts
# 2. Get list of commenters
# 3. Go through each commenters post history
# 4. If they are active in a certain other subreddit mark them as good

require 'byebug'

require 'nokogiri'
require 'open-uri'
require_relative 'cache'

THREADS = 16

SUBREDDIT_LINK = 'https://reddit.com/r/teenagers'

POSITIVE_SUBREDDITS = ['LearnToProgram', 'programming' ,'golang', 'ruby', 'javascript', 'coding', 'compsci', 'dailyprogrammer', 'webdev', 'reverseengineering', 'startups',
                       'python', 'cpp', 'haskell', 'php', 'lisp', 'perl', 'erlang', 'java', 'c_programming', 'scheme', 'asm', 'c_language', 'scala', 'cplusplus', 'ocaml', 'gamedev',
                       'rails', 'django', 'databases', 'hacking', 'machinelearning', 'iOSProgramming', 'javahelp', 'learnprogramming', 'learnpython', 'linux', 'web_design', 'web_dev']
NEXT_LIMIT = 10

def get_top_posts
  doc = doc_from_url(SUBREDDIT_LINK)

  filter_doc_for_hrefs(doc, '.comments')
end

def get_profile_urls(post_url)
  doc = doc_from_url(post_url)

  doc.css('.author').map do |e| e.attributes['href'] end

  filter_doc_for_hrefs(doc, '.author')
end

def get_recent_subreddits(profile_url)
  subreddits = []
  next_counter = 0

  doc = doc_from_url(profile_url)

  while true
    subreddits += filter_doc_for_hrefs(doc, '.subreddit')

    buttons = doc.css('.next-button').children
    if buttons.length == 0 || next_counter > NEXT_LIMIT
      break
    end

    next_button = buttons[0]

    doc = doc_from_url(next_button.attributes['href'])
    next_counter += 1
  end

  subreddits
end

def get_overlapping_subreddits(subreddits)
  match = subreddits.map do |s| s.downcase end

  match_against = POSITIVE_SUBREDDITS.map do |s| 'https://www.reddit.com/r/' + s.downcase + '/' end

  match_against & match
end

def filter_doc_for_hrefs(doc, selector)
  hrefs = doc.css(selector).map do |e|
    if !e.attributes['href'].nil? 
      e.attributes['href'].value
    end
  end

  hrefs.compact
end

def doc_from_url(url)
  Nokogiri::HTML(open_url(url))
end

semaphore = Mutex.new
pool = Concurrent::FixedThreadPool.new(THREADS)

puts "Starting scrape (#{THREADS} threads)..."
profiles = ['https://reddit.com/u/hcwool']

posts = get_top_posts

puts 'Getting profiles...'
for post in posts
  profiles += get_profile_urls(post)
end

puts "#{profiles.length} profile(s) collected"

puts 'Getting subreddits...'
for profile in profiles
  pool.post {
    subreddits = get_recent_subreddits(profile)

    overlapping = get_overlapping_subreddits(subreddits)

    if overlapping.length > 0
      semaphore.synchronize { puts profile }
    end
  }
end


while pool.completed_task_count != profiles.length
  semaphore.synchronize { puts "Pool is still running (#{pool.completed_task_count} V #{profiles.length})..." }

  sleep 10
end

puts "Done"
