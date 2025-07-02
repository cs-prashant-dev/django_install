#!/bin/bash
set -e

# -- Configuration variables (edit these) --
GIT_REPO="https://github.com/username/repo.git"    # Git repo URL of your Django project
PROJECT_NAME="myproject"                           # Django project (WSGI) name
DB_NAME="mydatabase"
DB_USER="dbuser"
DB_PASS="dbpassword"
DOMAIN="example.com"                               # Domain name for the app
# Determine the user to run the app (default to current sudo or login user)
APP_USER="${SUDO_USER:-$USER}"

PROJECT_DIR="/home/$APP_USER/$PROJECT_NAME"        # project directory path

# 1. Clone the Django project (if not already present)
if [ ! -d "$PROJECT_DIR" ]; then
    sudo -u "$APP_USER" git clone "$GIT_REPO" "$PROJECT_DIR"
else
    echo "Project directory already exists. Skipping clone."
fi

# 2. Install PostgreSQL if not already installed
if ! command -v psql >/dev/null; then
    sudo apt update
    sudo apt -y install postgresql postgresql-contrib
    sudo systemctl enable --now postgresql
fi

# 3. Create PostgreSQL database and user if they do not exist
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1 || sudo -u postgres psql -c "CREATE DATABASE $DB_NAME;"
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname = '$DB_USER'" | grep -q 1 || sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';"
sudo -u postgres psql -c "ALTER ROLE $DB_USER SET client_encoding TO 'utf8';"
sudo -u postgres psql -c "ALTER ROLE $DB_USER SET default_transaction_isolation TO 'read committed';"
sudo -u postgres psql -c "ALTER ROLE $DB_USER SET timezone TO 'UTC';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;"

# 4. Install system dependencies
sudo apt update
sudo apt -y install build-essential python3-pip python3-venv python3-dev libpq-dev nginx curl

# 5. Set up Python virtual environment and install requirements
sudo -u "$APP_USER" -H bash <<EOF
cd "$PROJECT_DIR"
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install django gunicorn psycopg2-binary
if [ -f requirements.txt ]; then
    pip install -r requirements.txt
fi
# Run Django management commands
python manage.py migrate --noinput
python manage.py collectstatic --noinput
EOF

# 6. Create a Gunicorn systemd service
SOCKET_DIR="/run/$PROJECT_NAME"
sudo mkdir -p "$SOCKET_DIR"
sudo chown "$APP_USER":www-data "$SOCKET_DIR"
sudo chmod 775 "$SOCKET_DIR"

sudo tee /etc/systemd/system/gunicorn.service > /dev/null <<EOL
[Unit]
Description=gunicorn daemon for $PROJECT_NAME
After=network.target

[Service]
User=$APP_USER
Group=www-data
WorkingDirectory=$PROJECT_DIR
Environment="PATH=$PROJECT_DIR/venv/bin"
ExecStart=$PROJECT_DIR/venv/bin/gunicorn \
    --access-logfile - \
    --workers 3 \
    --bind unix:$SOCKET_DIR/gunicorn.sock \
    ${PROJECT_NAME}.wsgi:application

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable --now gunicorn

# 7. Configure Nginx server block
sudo tee /etc/nginx/sites-available/$DOMAIN > /dev/null <<EOL
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;

    location = /favicon.ico { access_log off; log_not_found off; }
    
    location /static/ {
        alias $PROJECT_DIR/static/;
    }

    location / {
        include proxy_params;
        proxy_pass http://unix:$SOCKET_DIR/gunicorn.sock;
    }
}
EOL

sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl restart nginx

# 8. SSL with Certbot (if domain is configured)
if [ "$DOMAIN" != "example.com" ]; then
    sudo apt update
    sudo apt install -y certbot python3-certbot-nginx
    sudo certbot --nginx -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN
fi

echo "Deployment complete. Access your site at: http://$DOMAIN"
