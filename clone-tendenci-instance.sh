#!/bin/bash -x

# Variables
website_path_prod=/srv/tendenci/website
website_path_dev=/srv/tendenci/devsite

nginx_config_prod=/etc/nginx/sites-available/tendenci
nginx_config_dev=/etc/nginx/sites-available/tendenci-dev

service_path_prod=/etc/systemd/system/tendenci.service
service_path_dev=/etc/systemd/system/tendenci-dev.service

env_path_prod=/srv/tendenci/environment
env_path_dev=/srv/tendenci/devenv

db_name_prod='tendenci_prod'
db_name_dev='tendenci_dev'

cd /

# Sync nginx config from prod to dev 
cp $nginx_config_prod $nginx_config_dev
if ! [ 0 -eq $? ]; then echo "$nginx_config_dev wasn't created."; exit 1; fi

# Update references
sed -i -e "s|$website_path_prod|$website_path_dev|g" $nginx_config_dev
sed -i -e "s|127.0.0.1:8000|127.0.0.1:8080|" $nginx_config_dev
sed -i -e "s|listen 443|listen 8443|" $nginx_config_dev

service nginx reload

# Sync systemd config from prod to dev 
cp $service_path_prod $service_path_dev
if ! [ 0 -eq $? ]; then echo "$service_path_dev wasn't created."; exit 1; fi

# Update references
sed -i -e "s|$website_path_prod|$website_path_dev|g" $service_path_dev
sed -i -e "s|tendenci.pid|tendenci-dev.pid|g" $service_path_dev
sed -i -e "s|$env_path_prod|$env_path_dev|g" $service_path_dev
sed -i -e "s|127.0.0.1:8000|127.0.0.1:8080|" $service_path_dev
sed -i -e "s|tendenci.access.log|dev-tendenci.access.log|g" $service_path_dev
sed -i -e "s|tendenci.error.log|dev-tendenci.error.log|g" $service_path_dev
sed -i -e 's|"tendenci"|"dev-tendenci"|g' $service_path_dev

systemctl daemon-reload

# Copy Python environment
rm -rf $env_path_dev
rsync -a $env_path_prod/ $env_path_dev
if ! [ 0 -eq $? ]; then echo "$env_path_dev wasn't created."; exit 1; fi

find $env_path_dev -name '*.pyc' -delete
# Hacky equivalent of virtualenv --relocable, but actually works for my use case
for file_path in $(grep -l -r "$env_path_prod" $env_path_dev); do
	sed -i -e "s|$env_path_prod|$env_path_dev|g" $file_path
done

# Copy site files
rm -rf $website_path_dev
rsync -a $website_path_prod/ $website_path_dev
if ! [ 0 -eq $? ]; then echo "$website_path_dev wasn't created."; exit 1; fi

# Copy production database replacing data in dev at that point in time 
su -c "dropdb --if-exists $db_name_dev" postgres
if ! [ 0 -eq $? ]; then echo "$db_name_dev wasn't dropped; unable to recreate."; exit 1; fi

# Now the next step can be done in a couple of ways.
# https://stackoverflow.com/questions/876522/creating-a-copy-of-a-database-in-postgresql
su -c "createdb --owner=tendenci $db_name_dev" postgres
su -c "pg_dump $db_name_prod | psql --quiet -o /dev/null $db_name_dev" postgres
if ! [ 0 -eq $? ]; then echo "$db_name_dev wasn't created."; exit 1; fi

# Delete settings which should not match
sed -i -e "/^DATABASES.*$db_name_prod.*/d" $website_path_dev/conf/settings.py
sed -i -e '/^SECRET_KEY.*/d' $website_path_dev/conf/settings.py
sed -i -e '/^SITE_SETTINGS_KEY.*/d' $website_path_dev/conf/settings.py
sed -i -e '/^EMAIL_.*/d' $website_path_dev/conf/settings.py
sed -i -e '/^NEWSLETTER_EMAIL_.*/d' $website_path_dev/conf/settings.py

# TODO: Change payment gateway to test endpoint
cat << "EOT" >> $website_path_dev/conf/settings.py
DATABASES['default']['NAME'] = 'tendenci_dev'
SECRET_KEY=''
SITE_SETTINGS_KEY=''
EMAIL_BACKEND = 'django_log_email.backends.EmailBackend'
EMAIL_LOG_FILE = '/srv/tendenci/log/email.log'
SITE_CACHE_KEY = ''
CACHE_PRE_KEY = SITE_CACHE_KEY
set_app_log_filename('/srv/tendenci/logs/dev-app.log')
set_debug_log_filename('/srv/tendenci/logs/dev-debug.log')
# Populate with required domains if encountering 403's on login
# CSRF_TRUSTED_ORIGINS = []
EOT

# Make and run migrations in dev environment 
$env_path_dev/bin/python $website_path_dev/manage.py makemigrations --noinput
$env_path_dev/bin/python $website_path_dev/manage.py migrate --noinput

