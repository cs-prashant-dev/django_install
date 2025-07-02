#!/bin/bash
set -e

# -- Configuration variables (edit these) --
GIT_REPO="https://github.com/username/repo.git"    # Git repo URL of your Django project
PROJECT_NAME="myproject"                           # Django project (WSGI) name
DB_NAME="mydatabase"
DB_USER="dbuser"
DB_PASS="dbpassword"
DOMAIN="example.com"                               # Domain name for the app (for SSL)
# Determine the user to run the app (default to current sudo or login user)
APP_USER="${SUDO_USER:-$USER}"

PROJECT_DIR="/home/$APP_USER/$PROJECT_NAME"        # project directory path

# 1. Clone the Django project (if not already present):
if [ ! -d "$PROJECT_DIR" ]; then
    sudo -u "$APP_USER" git clone "$GIT_REPO" "$PROJECT_DIR"
fi

# 2. Install PostgreSQL if not already installed:contentReference[oaicite:6]{index=6}:
if ! command -v psql >/dev/null; then
    sudo apt update
    sudo apt -y install postgresql postgresql-contrib
fi

# 3. Create PostgreSQL database and user if they do not exist:contentReference[oaicite:7]{index=7}:
sudo -u postgres psql -c "CREATE DATABASE $DB_NAME;" 2>/dev/null || true
sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" 2>/dev/null || true
sudo -u postgres psql -c "ALTER ROLE $DB_USER SET client_encoding TO 'utf8';"
sudo -u postgres psql -c "ALTER ROLE $DB_USER SET default_transaction_isolation TO 'read committed';"
sudo -u postgres psql -c "ALTER ROLE $DB_USER SET timezone TO 'UTC';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;"

# 4. Install Python build tools, pip, and Nginx:contentReference[oaicite:8]{index=8}:contentReference[oaicite:9]{index=9}:
sudo apt update   # Update package list:contentReference[oaicite:10]{index=10}
sudo apt -y install build-essential python3-pip python3-venv python3-dev libpq-dev nginx curl

# 5. Set up Python virtual environment and install requirements:contentReference[oaicite:11]{index=11}:contentReference[oaicite:12]{index=12}:
#    All commands below run as APP_USER to avoid permission issues.
sudo -u "$APP_USER" -H bash <<EOF
cd "$PROJECT_DIR"
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install django gunicorn psycopg2-binary   # install Django, Gunicorn, and PostgreSQL adapter:contentReference[oaicite:13]{index=13}
if [ -f requirements.txt ]; then
    pip install -r requirements.txt           # install any project-specific dependencies:contentReference[oaicite:14]{index=14}
fi
EOF

# 6. Create a Gunicorn systemd service to run the app:contentReference[oaicite:15]{index=15}:
if [ ! -f /etc/systemd/system/gunicorn.service ]; then
sudo tee /etc/systemd/system/gunicorn.service > /dev/null <<EOL
[Unit]
Description=gunicorn daemon
After=network.target

[Service]
User=$APP_USER
Group=www-data
WorkingDirectory=$PROJECT_DIR
ExecStart=$PROJECT_DIR/venv/bin/gunicorn --access-logfile - --workers 3 --bind unix:/run/gunicorn.sock ${PROJECT_NAME}.wsgi:application

[Install]
WantedBy=multi-user.target
EOL
  sudo systemctl daemon-reload
  sudo systemctl start gunicorn
  sudo systemctl enable gunicorn
fi

# 7. Configure Nginx server block for the Django app:contentReference[oaicite:16]{index=16}:
if [ ! -f /etc/nginx/sites-available/$DOMAIN ]; then
    # Remove default site to ensure our app is served:contentReference[oaicite:17]{index=17}:
    sudo rm -f /etc/nginx/sites-enabled/default

    sudo tee /etc/nginx/sites-available/$DOMAIN > /dev/null <<EOL
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;

    location = /favicon.ico { access_log off; log_not_found off; }
    location /static/ {
        root $PROJECT_DIR;
    }

    location / {
        include proxy_params;
        proxy_pass http://unix:/run/gunicorn.sock;
    }
}
EOL

    sudo ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
    sudo nginx -t
    sudo systemctl restart nginx
fi

# 8. Obtain and install SSL certificate via Certbot (if a real domain is set):contentReference[oaicite:18]{index=18}:contentReference[oaicite:19]{index=19}:
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "example.com" ]; then
    sudo snap install core; sudo snap refresh core
    sudo apt remove -y certbot || true
    sudo snap install --classic certbot
    sudo ln -sf /snap/bin/certbot /usr/bin/certbot
    sudo certbot --nginx -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN
fi

echo "Deployment complete. Your Django app should now be served by Gunicorn and Nginx."
