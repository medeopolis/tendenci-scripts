#!/bin/bash -x

### Variables

# project path requires underscore not dash due to python
project_path_prod=/srv/tendenci
project_path_dev=/srv/tendenci_test

# Suffix for files for dev (pid, logs, ...)
file_suffix_dev='-test'

website_path_prod=$project_path_prod/website
website_path_dev=$project_path_dev/website

service_path_prod=/etc/systemd/system/tendenci.service
service_path_dev=/etc/systemd/system/tendenci$file_suffix_dev.service

env_path_prod=$project_path_prod/environment
env_path_dev=$project_path_dev/environment

log_path_prod=$project_path_prod/logs
log_path_dev=$project_path_dev/logs

db_name_prod='tendenci_prod'
db_name_dev='tendenci_test'

cd /

# Make the log path for the dev env with its parents. Environment and site have
# their dirs created mid script.
mkdir -p $log_path_dev

service nginx reload

# Sync systemd config from prod to dev 
cp $service_path_prod $service_path_dev
if ! [ 0 -eq $? ]; then echo "$service_path_dev wasn't created."; exit 1; fi

# Update references in service file
sed -i -e "s|$website_path_prod|$website_path_dev|g" $service_path_dev
sed -i -e "s|tendenci.pid|tendenci$file_suffix_dev.pid|g" $service_path_dev
sed -i -e "s|$env_path_prod|$env_path_dev|g" $service_path_dev
sed -i -e "s|127.0.0.1:8000|127.0.0.1:8080|" $service_path_dev
# Why do this when its in a separate folder? In case logs are aggregated.
sed -i -e "s|tendenci.access.log|tendenci$file_suffix_dev.access.log|g" $service_path_dev
sed -i -e "s|tendenci.error.log|tendenci$file_suffix_dev.error.log|g" $service_path_dev
sed -i -e 's|"tendenci"|"tendenci"|g' $service_path_dev

systemctl daemon-reload

# Copy Python environment
rm -rf $env_path_dev
rsync -a $env_path_prod/ $env_path_dev
if ! [ 0 -eq $? ]; then echo "$env_path_dev wasn't created."; exit 1; fi

find $env_path_dev -name '*.pyc' -delete
# Hacky equivalent of virtualenv --relocatable, but actually works for my use case
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

# TODO: add paypal overrides when known
# Update settings
sed -i -e "s/^# DEBUG = True/DEBUG = True/" $website_path_dev/conf/settings.py
sed -i -e "s/^DATABASES.*$db_name_prod.*/DATABASES['default']['NAME'] = '$db_name_dev'/" $website_path_dev/conf/settings.py
sed -i -e "s/^SECRET_KEY.*/SECRET_KEY='$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1)'/" $website_path_dev/conf/settings.py
# sed -i -e "s/^SITE_SETTINGS_KEY.*/SITE_SETTINGS_KEY='$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1)'/" $website_path_dev/conf/settings.py
sed -i -e "s/^EMAIL_BACKEND.*/EMAIL_BACKEND = 'django_log_email.backends.EmailBackend'/" $website_path_dev/conf/settings.py
sed -i -e "s/^CELERY_EMAIL_BACKEND.*/CELERY_EMAIL_BACKEND = 'django_log_email.backends.EmailBackend'/" $website_path_dev/conf/settings.py
sed -i -e "s|^EMAIL_LOG_FILE.*|EMAIL_LOG_FILE = '$log_path_dev/email$file_suffix_dev.log'|" $website_path_dev/conf/settings.py
sed -i -e "/^EMAIL_LOG_BACKEND.*/d" $website_path_dev/conf/settings.py
sed -i -e "/^NEWSLETTER_EMAIL_.*/d" $website_path_dev/conf/settings.py
sed -i -e "s/^STRIPE_SECRET_KEY.*/STRIPE_SECRET_KEY = 'sk_test_[blah blah]'/" $website_path_dev/conf/settings.py
sed -i -e "s/^STRIPE_PUBLISHABLE_KEY.*/STRIPE_PUBLISHABLE_KEY = 'pk_test_[blah blah]'/" $website_path_dev/conf/settings.py
sed -i -e "s/^SITE_CACHE_KEY.*/SITE_CACHE_KEY = 'tendenci$file_suffix_dev'/" $website_path_dev/conf/settings.py
sed -i -e "s|^set_app_log_filename.*|set_app_log_filename('$log_path_dev/app$file_suffix_dev.log')|" $website_path_dev/conf/settings.py
sed -i -e "s|^set_debug_log_filename.*|set_debug_log_filename('$log_path_dev/debug$file_suffix_dev.log')|" $website_path_dev/conf/settings.py
sed -i -e "s/^CSRF_TRUSTED_ORIGINS.*/CSRF_TRUSTED_ORIGINS = ['byo list of domains']/" $website_path_dev/conf/settings.py
sed -i -e "s/^ALLOWED_HOSTS.*/ALLOWED_HOSTS = ['byo list of domains']/" $website_path_dev/conf/settings.py
sed -i -e "s/^SERVER_EMAIL.*/SERVER_EMAIL = '$db_name_dev@localhost'/"  $website_path_dev/conf/settings.py

