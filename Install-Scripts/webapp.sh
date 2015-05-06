###############################################################################
# Install the reddit source repositories
###############################################################################
if [ ! -d $REDDIT_HOME/src ]; then
    mkdir -p $REDDIT_HOME/src
    chown $REDDIT_USER $REDDIT_HOME/src
fi

function clone_reddit_repo {
    local destination=$REDDIT_HOME/src/${1}
    local repository_url=https://github.com/${2}.git

    if [ ! -d $destination ]; then
        sudo -u $REDDIT_USER git clone $repository_url $destination
    fi

    if [ -d $destination/upstart ]; then
        cp $destination/upstart/* /etc/init/
    fi
}

function clone_reddit_plugin_repo {
    clone_reddit_repo $1 reddit/reddit-plugin-$1
}

clone_reddit_repo reddit reddit/reddit
clone_reddit_repo i18n reddit/reddit-i18n
for plugin in $REDDIT_PLUGINS; do
    clone_reddit_plugin_repo $plugin
done


###############################################################################
# Install and configure the reddit code
###############################################################################
function install_reddit_repo {
    cd $REDDIT_HOME/src/$1
    sudo -u $REDDIT_USER python setup.py build
    python setup.py develop --no-deps
}

install_reddit_repo reddit/r2
install_reddit_repo i18n
for plugin in $REDDIT_PLUGINS; do
    install_reddit_repo $plugin
done

# generate binary translation files from source
cd $REDDIT_HOME/src/i18n/
sudo -u $REDDIT_USER make clean all

# this builds static files and should be run *after* languages are installed
# so that the proper language-specific static files can be generated and after
# plugins are installed so all the static files are available.
cd $REDDIT_HOME/src/reddit/r2
sudo -u $REDDIT_USER make clean all

plugin_str=$(echo -n "$REDDIT_PLUGINS" | tr " " ,)
if [ ! -f development.update ]; then
    cat > development.update <<DEVELOPMENT
# after editing this file, run "make ini" to
# generate a new development.ini

[DEFAULT]
# global debug flag -- displays pylons stacktrace rather than 500 page on error when true
# WARNING: a pylons stacktrace allows remote code execution. Make sure this is false
# if your server is publicly accessible.
debug = true

disable_ads = true
disable_captcha = true
disable_ratelimit = true
disable_require_admin_otp = true

page_cache_time = 0

domain = $REDDIT_DOMAIN
oauth_domain = $REDDIT_DOMAIN

plugins = $plugin_str

media_provider = filesystem
media_fs_root = /srv/www/media
media_fs_base_url_http = http://%(domain)s/media/

[server:main]
port = 8001
DEVELOPMENT
    chown $REDDIT_USER development.update
else
    sed -i "s/^plugins = .*$/plugins = $plugin_str/" $REDDIT_HOME/src/reddit/r2/development.update
    sed -i "s/^domain = .*$/domain = $REDDIT_DOMAIN/" $REDDIT_HOME/src/reddit/r2/development.update
    sed -i "s/^oauth_domain = .*$/oauth_domain = $REDDIT_DOMAIN/" $REDDIT_HOME/src/reddit/r2/development.update
fi

sudo -u $REDDIT_USER make ini

if [ ! -L run.ini ]; then
    sudo -u $REDDIT_USER ln -nsf development.ini run.ini
fi

###############################################################################
# some useful helper scripts
###############################################################################
function helper-script() {
    cat > $1
    chmod 755 $1
}

helper-script /usr/local/bin/reddit-run <<REDDITRUN
#!/bin/bash
exec paster --plugin=r2 run $REDDIT_HOME/src/reddit/r2/run.ini "\$@"
REDDITRUN

helper-script /usr/local/bin/reddit-shell <<REDDITSHELL
#!/bin/bash
exec paster --plugin=r2 shell $REDDIT_HOME/src/reddit/r2/run.ini
REDDITSHELL

helper-script /usr/local/bin/reddit-start <<REDDITSTART
#!/bin/bash
initctl emit reddit-start
REDDITSTART

helper-script /usr/local/bin/reddit-stop <<REDDITSTOP
#!/bin/bash
initctl emit reddit-stop
REDDITSTOP

helper-script /usr/local/bin/reddit-restart <<REDDITRESTART
#!/bin/bash
initctl emit reddit-restart TARGET=${1:-all}
REDDITRESTART

helper-script /usr/local/bin/reddit-flush <<REDDITFLUSH
#!/bin/bash
echo flush_all | nc localhost 11211
REDDITFLUSH

###############################################################################
# pixel and click server
###############################################################################
mkdir -p /var/opt/reddit/
chown $REDDIT_USER:$REDDIT_GROUP /var/opt/reddit/

mkdir -p /srv/www/pixel
chown $REDDIT_USER:$REDDIT_GROUP /srv/www/pixel
cp $REDDIT_HOME/src/reddit/r2/r2/public/static/pixel.png /srv/www/pixel

if [ ! -f /etc/gunicorn.d/click.conf ]; then
    cat > /etc/gunicorn.d/click.conf <<CLICK
CONFIG = {
    "mode": "wsgi",
    "working_dir": "$REDDIT_HOME/src/reddit/scripts",
    "user": "$REDDIT_USER",
    "group": "$REDDIT_USER",
    "args": (
        "--bind=unix:/var/opt/reddit/click.sock",
        "--workers=1",
        "tracker:application",
    ),
}
CLICK
fi

service gunicorn start

###############################################################################
# nginx
###############################################################################

mkdir -p /srv/www/media
chown $REDDIT_USER:$REDDIT_GROUP /srv/www/media

cat > /etc/nginx/sites-available/reddit-media <<MEDIA
server {
    listen 9000;

    expires max;

    location /media/ {
        alias /srv/www/media/;
    }
}
MEDIA

cat > /etc/nginx/sites-available/reddit-pixel <<PIXEL
upstream click_server {
  server unix:/var/opt/reddit/click.sock fail_timeout=0;
}

server {
  listen 8082;

  log_format directlog '\$remote_addr - \$remote_user [\$time_local] '
                      '"\$request_method \$request_uri \$server_protocol" \$status \$body_bytes_sent '
                      '"\$http_referer" "\$http_user_agent"';
  access_log      /var/log/nginx/traffic/traffic.log directlog;

  location / {

    rewrite ^/pixel/of_ /pixel.png;

    add_header Last-Modified "";
    add_header Pragma "no-cache";

    expires -1;
    root /srv/www/pixel/;
  }

  location /click {
    proxy_pass http://click_server;
  }
}
PIXEL

# remove the default nginx site that may conflict with haproxy
rm -rf /etc/nginx/sites-enabled/default
# put our config in place
ln -nsf /etc/nginx/sites-available/reddit-media /etc/nginx/sites-enabled/
ln -nsf /etc/nginx/sites-available/reddit-pixel /etc/nginx/sites-enabled/

# make the pixel log directory
mkdir -p /var/log/nginx/traffic

# link the ini file for the Flask click tracker
ln -nsf $REDDIT_HOME/src/reddit/r2/development.ini $REDDIT_HOME/src/reddit/scripts/production.ini

service nginx restart

###############################################################################
# geoip service
###############################################################################
if [ ! -f /etc/gunicorn.d/geoip.conf ]; then
    cat > /etc/gunicorn.d/geoip.conf <<GEOIP
CONFIG = {
    "mode": "wsgi",
    "working_dir": "$REDDIT_HOME/src/reddit/scripts",
    "user": "$REDDIT_USER",
    "group": "$REDDIT_USER",
    "args": (
        "--bind=127.0.0.1:5000",
        "--workers=1",
         "--limit-request-line=8190",
         "geoip_service:application",
    ),
}
GEOIP
fi

service gunicorn start

###############################################################################
# Job Environment
###############################################################################
CONSUMER_CONFIG_ROOT=$REDDIT_HOME/consumer-count.d

if [ ! -f /etc/default/reddit ]; then
    cat > /etc/default/reddit <<DEFAULT
export REDDIT_ROOT=$REDDIT_HOME/src/reddit/r2
export REDDIT_INI=$REDDIT_HOME/src/reddit/r2/run.ini
export REDDIT_USER=$REDDIT_USER
export REDDIT_GROUP=$REDDIT_GROUP
export REDDIT_CONSUMER_CONFIG=$CONSUMER_CONFIG_ROOT
alias wrap-job=$REDDIT_HOME/src/reddit/scripts/wrap-job
alias manage-consumers=$REDDIT_HOME/src/reddit/scripts/manage-consumers
DEFAULT
fi

###############################################################################
# Queue Processors
###############################################################################
mkdir -p $CONSUMER_CONFIG_ROOT

function set_consumer_count {
    if [ ! -f $CONSUMER_CONFIG_ROOT/$1 ]; then
        echo $2 > $CONSUMER_CONFIG_ROOT/$1
    fi
}

set_consumer_count log_q 0
set_consumer_count cloudsearch_q 0
set_consumer_count del_account_q 1
set_consumer_count scraper_q 1
set_consumer_count markread_q 1
set_consumer_count commentstree_q 1
set_consumer_count newcomments_q 1
set_consumer_count vote_link_q 1
set_consumer_count vote_comment_q 1
set_consumer_count automoderator_q 0

chown -R $REDDIT_USER:$REDDIT_GROUP $CONSUMER_CONFIG_ROOT/

initctl emit reddit-stop
initctl emit reddit-start

###############################################################################
# Cron Jobs
###############################################################################
if [ ! -f /etc/cron.d/reddit ]; then
    cat > /etc/cron.d/reddit <<CRON
0    3 * * * root /sbin/start --quiet reddit-job-update_sr_names
30  16 * * * root /sbin/start --quiet reddit-job-update_reddits
0    * * * * root /sbin/start --quiet reddit-job-update_promos
*/5  * * * * root /sbin/start --quiet reddit-job-clean_up_hardcache
*/2  * * * * root /sbin/start --quiet reddit-job-broken_things
*/2  * * * * root /sbin/start --quiet reddit-job-rising
0    * * * * root /sbin/start --quiet reddit-job-trylater

# liveupdate
*    * * * * root /sbin/start --quiet reddit-job-liveupdate_activity

# jobs that recalculate time-limited listings (e.g. top this year)
PGPASSWORD=password
*/15 * * * * $REDDIT_USER $REDDIT_HOME/src/reddit/scripts/compute_time_listings link year '("hour", "day", "week", "month", "year")'
*/15 * * * * $REDDIT_USER $REDDIT_HOME/src/reddit/scripts/compute_time_listings comment year '("hour", "day", "week", "month", "year")'

# disabled by default, uncomment if you need these jobs
#*    * * * * root /sbin/start --quiet reddit-job-email
#0    0 * * * root /sbin/start --quiet reddit-job-update_gold_users
CRON
fi

###############################################################################
# All done!
###############################################################################
cd $REDDIT_HOME

cat <<CONCLUSION

Congratulations! reddit is now installed.

The reddit application code is managed with upstart, to see what's currently
running, run

    sudo initctl list | grep reddit

Cron jobs start with "reddit-job-" and queue processors start with
"reddit-consumer-". The crons are managed by /etc/cron.d/reddit. You can
initiate a restart of all the consumers by running:

    sudo reddit-restart

or target specific ones:

    sudo reddit-restart scraper_q

See the GitHub wiki for more information on these jobs:

* https://github.com/reddit/reddit/wiki/Cron-jobs
* https://github.com/reddit/reddit/wiki/Services

The reddit code can be shut down or started up with

    sudo reddit-stop
    sudo reddit-start

And if you think caching might be hurting you, you can flush memcache with

    reddit-flush

Now that the core of reddit is installed, you may want to do some additional
steps:

* Ensure that $REDDIT_DOMAIN resolves to this machine.

* To populate the database with test data, run:

    cd $REDDIT_HOME/src/reddit
    reddit-run scripts/inject_test_data.py -c 'inject_test_data()'

* Manually run reddit-job-update_reddits immediately after populating the db
  or adding your own subreddits.
CONCLUSION
