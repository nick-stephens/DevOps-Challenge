#!/bin/bash
# The contents of this file are subject to the Common Public Attribution
# License Version 1.0. (the "License"); you may not use this file except in
# compliance with the License. You may obtain a copy of the License at
# http://code.reddit.com/LICENSE. The License is based on the Mozilla Public
# License Version 1.1, but Sections 14 and 15 have been added to cover use of
# software over a computer network and provide for limited attribution for the
# Original Developer. In addition, Exhibit A has been modified to be consistent
# with Exhibit B.
#
# Software distributed under the License is distributed on an "AS IS" basis,
# WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License for
# the specific language governing rights and limitations under the License.
#
# The Original Code is reddit.
#
# The Original Developer is the Initial Developer.  The Initial Developer of
# the Original Code is reddit Inc.
#
# All portions of the code written by reddit are Copyright (c) 2006-2015 reddit
# Inc. All Rights Reserved.
###############################################################################

###############################################################################
# reddit dev environment installer
# --------------------------------
# This script installs a reddit stack suitable for development. DO NOT run this
# on a system that you use for other purposes as it might delete important
# files, truncate your databases, and otherwise do mean things to you.
#
# By default, this script will install the reddit code in the current user's
# home directory and all of its dependencies (including libraries and database
# servers) at the system level. The installed reddit will expect to be visited
# on the domain "reddit.local" unless specified otherwise.  Configuring name
# resolution for the domain is expected to be done outside the installed
# environment (e.g. in your host machine's /etc/hosts file) and is not
# something this script handles.
#
# Several configuration options (listed in the "Configuration" section below)
# are overridable with environment variables. e.g.
#
#    sudo REDDIT_DOMAIN=example.com ./install-reddit.sh
#
###############################################################################
set -e

###############################################################################
# Configuration
###############################################################################
# which user to install the code for; defaults to the user invoking this script
REDDIT_USER=${REDDIT_USER:-$SUDO_USER}

# the group to run reddit code as; must exist already
REDDIT_GROUP=${REDDIT_GROUP:-nogroup}

# the root directory to base the install in. must exist already
REDDIT_HOME=${REDDIT_HOME:-/home/$REDDIT_USER}

# the domain that you will connect to your reddit install with.
# MUST contain a . in it somewhere as browsers won't do cookies for dotless
# domains. an IP address will suffice if nothing else is available.
REDDIT_DOMAIN=${REDDIT_DOMAIN:-reddit.local}

#The plugins to clone and register in the ini file
REDDIT_PLUGINS=${REDDIT_PLUGINS:-meatspace about liveupdate}

###############################################################################
# Sanity Checks
###############################################################################
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must be run with root privileges."
    exit 1
fi

# seriously! these checks are here for a reason. the packages from the
# reddit ppa aren't built for anything but precise (12.04) right now, so
# if you try and use this install script on another release you're gonna
# have a bad time.
source /etc/lsb-release
if [ "$DISTRIB_ID" != "Ubuntu" -o "$DISTRIB_RELEASE" != "12.04" ]; then
    echo "ERROR: Only Ubuntu 12.04 is supported."
    exit 1
fi

if [[ "2000000" -gt $(awk '/MemTotal/{print $2}' /proc/meminfo) ]]; then
    LOW_MEM_PROMPT="reddit requires at least 2GB of memory to work properly, continue anyway? [y/n] "
    read -er -n1 -p "$LOW_MEM_PROMPT" response
    if [[ "$response" != "y" ]]; then
      echo "Quitting."
      exit 1
    fi
fi

###############################################################################
# Install prerequisites
###############################################################################
set -x

# aptitude configuration
APTITUDE_OPTIONS="-y"
export DEBIAN_FRONTEND=noninteractive

# run an aptitude update to make sure python-software-properties
# dependencies are found
apt-get update

# add the reddit ppa for some custom packages
apt-get install $APTITUDE_OPTIONS python-software-properties
apt-add-repository -y ppa:reddit/ppa

# pin the ppa -- packages present in the ppa will take precedence over
# ones in other repositories (unless further pinning is done)
cat <<HERE > /etc/apt/preferences.d/reddit
Package: *
Pin: release o=LP-PPA-reddit
Pin-Priority: 600
HERE

# grab the new ppas' package listings
apt-get update

# install prerequisites
cat <<PACKAGES | xargs apt-get install $APTITUDE_OPTIONS
netcat-openbsd
git-core

python-dev
python-setuptools
python-routes
python-pylons
python-boto
python-tz
python-crypto
python-babel
cython
python-sqlalchemy
python-beautifulsoup
python-chardet
python-psycopg2
python-pycassa
python-imaging
python-pycaptcha
python-amqplib
python-pylibmc
python-bcrypt
python-snudown
python-l2cs
python-lxml
python-zope.interface
python-kazoo
python-stripe
python-tinycss2
python-unidecode
python-mock
python-yaml

python-flask
geoip-bin
geoip-database
python-geoip

nodejs
node-less
node-uglify
gettext
make
optipng
jpegoptim

memcached
postgresql
postgresql-client
rabbitmq-server
cassandra=1.2.19
haproxy
nginx
stunnel
gunicorn
sutro
libpcre3-dev
PACKAGES
