#!/bin/sh

# Author: peter.yjzh@gmail.com
# Date: 20191005

# This script generates local dev environment for git pages.


######## 1. install ruby environment
sudo apt install ruby-full build-essential zlib1g-dev

## settings of gem

echo '# Install Ruby Gems to ~/gems' >> ~/.myscript
echo 'export GEM_HOME="$HOME/gems"' >> ~/.myscript
echo 'export PATH="$HOME/gems/bin:$PATH"' >> ~/.myscript

## using gem mirror

gem sources --add https://gems.ruby-china.com/ --remove https://rubygems.org/
gem sources -l

## config bundler mirrors
bundle config mirror.https://rubygems.org https://gems.ruby-china.com



######## 2. install github pages templating sw, jekyll
sudo gem install jekyll bundler



########################
# User Guide
########################

# Change theme
