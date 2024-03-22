#!/bin/bash

set -o allexport
SCRIPT_PATH=$(realpath .)
SCRIPT_DIR=$(dirname $SCRIPT_PATH)
LOCAL_SCRIPT_PATH=$(realpath $0)
LOCAL_SCRIPT_DIR=$(dirname $LOCAL_SCRIPT_PATH)
PROJECT_ROOT=/var/www/html
set +o allexport


# Load .env or .env.dist if not present
# NOTE: all config values will be in process.env when starting
# the services and will therefore take precedence over the .env
if [ -f "$SCRIPT_PATH/.env" ]; then
    set -o allexport
    source $SCRIPT_PATH/.env
    set +o allexport
else
    set -o allexport
    source $SCRIPT_PATH/.env.dist
    set +o allexport
fi

# Configure git
git config pull.ff only

# Secure mysql https://gist.github.com/Mins/4602864
SECURE_MYSQL=$(expect -c "

set timeout 10
spawn mysql_secure_installation

expect \"Enter current password for root (enter for none):\"
send \"\r\"

expect \"Switch to unix_socket authentication:\"
send \"Y\r\"

expect \"Change the root password?\"
send \"n\r\"

expect \"Remove anonymous users?\"
send \"y\r\"

expect \"Disallow root login remotely?\"
send \"y\r\"

expect \"Remove test database and access to it?\"
send \"y\r\"

expect \"Reload privilege tables now?\"
send \"y\r\"

expect eof
")
echo "$SECURE_MYSQL"

# Configure fail2ban, seems to not run out of the box on Debian 12
echo -e "[sshd]\nbackend = systemd" | tee /etc/fail2ban/jail.d/sshd.conf
# enable nginx-limit-req filter to block also user which exceed nginx request limiter
echo -e "[nginx-limit-req]\nenabled = true\nlogpath  = $SCRIPT_PATH/log/nginx-error.*.log" | tee /etc/fail2ban/jail.d/nginx-limit-req.conf
# enable nginx bad request filter 
echo -e "[nginx-bad-request]\nenabled = true\nlogpath  = $SCRIPT_PATH/log/nginx-error.*.log" | tee /etc/fail2ban/jail.d/nginx-bad-request.conf
systemctl restart fail2ban

# setup https with certbot
certbot certonly --nginx --non-interactive --agree-tos --domains $COMMUNITY_HOST --email $COMMUNITY_SUPPORT_MAIL

# Configure nginx
cp $SCRIPT_PATH/nginx/common/* /etc/nginx/common/
# set env variables dynamic if not already set in .env or .env.dist
: ${NGINX_SSL_CERTIFICATE:=/etc/letsencrypt/live/$COMMUNITY_HOST/fullchain.pem}
: ${NGINX_SSL_CERTIFICATE_KEY:=/etc/letsencrypt/live/$COMMUNITY_HOST/privkey.pem}

envsubst "$(env | sed -e 's/=.*//' -e 's/^/\$/g')" < $SCRIPT_PATH/nginx/sites-available/humhub.conf.template > /etc/nginx/sites-available/humhub.conf
ln -s /etc/nginx/sites-available/humhub.conf /etc/nginx/sites-enabled/
rm /etc/nginx/sites-enabled/default

# Make nginx restart automatic
mkdir /etc/systemd/system/nginx.service.d
# Define the content to be put into the override.conf file
CONFIG_CONTENT="[Unit]
StartLimitIntervalSec=500
StartLimitBurst=5

[Service]
Restart=on-failure
RestartSec=5s"

# Write the content to the override.conf file
echo "$CONFIG_CONTENT" | sudo tee /etc/systemd/system/nginx.service.d/override.conf >/dev/null

# Reload systemd to apply the changes
sudo systemctl daemon-reload

# create db user
export DB_USER=humhub
export DB_NAME=humhub
# create a new password only if it not already exist
if [ -z "${DB_PASSWORD}" ]; then
    export DB_PASSWORD=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-32};echo);
fi
mysql <<EOFMYSQL
    CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
    CREATE DATABASE '$DB_NAME' CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    GRANT ALL ON '$DB_NAME'.* TO '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
    FLUSH PRIVILEGES;
EOFMYSQL

# install humhub
cd /tmp
wget https://download.humhub.com/downloads/install/humhub-1.15.3.tar.gz
tar xvfz humhub-1.15.3.tar.gz
mv /tmp/humhub-1.15.3 $PROJECT_ROOT/humhub

NOW=$(date +%s)
envsubst "$(env | sed -e 's/=.*//' -e 's/^/\$/g')" < $SCRIPT_PATH/humhub/protected/config/dynamic.php.template > $SCRIPT_PATH/humhub/protected/config/dynamic.php
cp $SCRIPT_PATH/humhub/protected/config/*.php $PROJECT_ROOT/humhub/protected/config/

# install modules
cd $PROJECT_ROOT/humhub/protected/modules
git clone https://github.com/gradido/gradido-humhub-module.git
git clone https://github.com/gradido/block-profile-changes.git
git clone https://github.com/gradido/customize-tags.git
git clone https://github.com/cuzy-app/humhub-modules-clean-theme clean-theme
# themes: clean-base  clean-bordered  clean-contrasted
# gradido-humhub-module/themes/gradido-humhub/views/user/widgets/peopleCard.php
# clean-theme/themes/clean-base/views/user/widgets/peopleCard.php
# Define the source file path
source_file="gradido-humhub-module/themes/gradido-humhub/views/user/widgets/peopleCard.php"

# Define the destination directory for each theme
themes=("clean-base" "clean-bordered" "clean-contrasted")

# Loop through each theme and copy the file
for theme in "${themes[@]}"
do
    destination_dir="clean-theme/themes/$theme/views/user/widgets/"

    # Create the widgets directory if it doesn't exist
    mkdir -p "$destination_dir"

    # Copy the file to the destination directory
    cp "$source_file" "$destination_dir"
    echo "Copied $source_file to $destination_dir"
done

# set all created or modified files back to belonging to www-data
chown -R www-data:www-data $PROJECT_ROOT

# crontabs for humhub
sudo -u www-data crontab < $LOCAL_SCRIPT_DIR/crontabs.txt


