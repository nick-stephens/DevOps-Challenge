echo "Waiting for PostgreSQL service to be available on port 5432"

while ! nc -vz localhost 5432; do
	sleep 1
done

SQL="SELECT COUNT(1) FROM pg_catalog.pg_database WHERE datname = 'reddit';"
IS_DATABASE_CREATED=$(sudo -u postgres psql -t -c "$SQL")

if [ $IS_DATABASE_CREATED -ne 1 ]; then
    cat <<PGSCRIPT | sudo -u postgres psql
CREATE DATABASE reddit WITH ENCODING = 'utf8' TEMPLATE template0 LC_COLLATE='en_US.utf8' LC_CTYPE='en_US.utf8';
CREATE USER reddit WITH PASSWORD 'password';
PGSCRIPT
fi

sudo -u postgres psql reddit < $REDDIT_HOME/src/reddit/sql/functions.sql
