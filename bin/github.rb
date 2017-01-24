#!/usr/bin/env ruby

require 'byebug'

require 'nokogiri'
require 'open-uri'

GITHUB_PROFILE_WEBSITE_XPATH = '//*[@id="js-pjax-container"]/div/div[1]/ul/li[4]/a'.freeze

def doc_from_url(url)
  Nokogiri::HTML(open(url))
end

def github_url_from_username(username)
  "https://github.com/#{username}"
end

def website_url_from_github(username)
  doc = doc_from_url(github_url_from_username(username))

  doc.xpath(GITHUB_PROFILE_WEBSITE_XPATH).text
end

def contains_text?(nokogiri_doc, text)
  nokogiri_doc.text.gsub("\n", ' ').include? text
end

def likely_high_schooler?(github_username)
  website_url = website_url_from_github(github_username)

  website = doc_from_url(website_url)

  contains_text? website, 'high school'
end

puts likely_high_schooler?('zachlatta')
