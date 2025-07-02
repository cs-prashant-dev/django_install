#!/bin/bash
set -e

# -- Configuration variables (edit these) --
GIT_REPO="https://github.com/username/repo.git"    # Git repo URL
PROJECT_NAME="myproject"                           # Django project name
CONFIGURE_DB=true                                  # Set to false to skip DB setup
DB_NAME="mydatabase"                               # Only used if CONFIGURE_DB=true
DB_USER="dbuser"                                   # Only used if CONFIGURE_DB=true
DB_PASS="dbpassword"                               # Only used if CONFIGURE_DB=true
DOMAIN="example.com"                               # Domain name for the app
APP_USER="${SUDO_USER:-$USER}"                     # User to run the app
PROJECT_DIR="/home/$APP_USER/$PROJECT_NAME"        # Project directory path

# 1. Clone the Django project
if [ ! -d "$PROJECT_DIR" ]; then
    sudo -u "$APP_USER" git clone "$GIT_REPO" "$PROJECT_DIR"
else
    echo "Project directory already exists. Skipping clone."
fi

# 2. Conditionally install and configure PostgreSQL
if [ "$CONFIGURE_DB" = true ]; then
    # Install PostgreSQL if not present
    if ! command -v psql >/dev/null; then
        sudo apt update
        sudo apt -y install postgresql postgresql-contrib
        sudo systemctl enable --now postgresql
    fi

    # Create database and user
    sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1 || \
        sudo -u postgres psql -c "CREATE DATABASE $DB_NAME;"
    sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname = '$DB_USER'" | grep -q 1 || \
        sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';"
    sudo -u postgres psql -c "ALTER ROLE $DB_USER SET client_encoding TO 'utf8';"
    sudo -u postgres psql -c "ALTER ROLE $DB_USER SET default_transaction_isolation TO 'read committed';"
    sudo -u postgres psql -c "ALTER ROLE $DB_USER SET timezone TO 'UTC';"
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;"
else
    echo "Skipping database setup as CONFIGURE_DB=false"
fi

# 3. Install system dependencies
sudo apt update
sudo apt -y install build-essential python3-pip python3-venv python3-dev libpq-dev nginx curl

# 4. Set up Python virtual environment
sudo -u "$APP_USER" -H bash <<EOF
cd "$PROJECT_DIR"
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install django gunicorn psycopg2-binary
if [ -f requirements.txt ]; then
    pip install -r requirements.txt
fi
EOF

# 5. Conditionally run database migrations
if [ "$CONFIGURE_DB" = true ]; then
    sudo -u "$APP_USER" -H bash <<EOF
cd "$PROJECT_DIR"
source venv/bin/activate
python manage.py migrate --noinput
python manage.py collectstatic --noinput
EOF
else
    echo "Skipping database migrations as CONFIGURE_DB=false"
fi

# 6. Create Gunicorn systemd service
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
ExecStart=$PROJECT_DIR/venv/bin/gunicorn \\
    --access-logfile - \\
    --workers 3 \\
    --bind unix:$SOCKET_DIR/gunicorn.sock \\
    ${PROJECT_NAME}.wsgi:application

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable --now gunicorn

# 7. Configure Nginx
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
