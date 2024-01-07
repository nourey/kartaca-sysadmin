
# To create a user, first creating the group
create_group:
  group.present:
    - gid: 2023

# Creating kartaca user with pillar data
{% set kartaca_user = salt['pillar.get']('kartaca:lookup:name') %}
{% set kartaca_password = salt['pillar.get']('kartaca:lookup:password') %}

create_user_and_set_password:
  user.present:
    - name: {{ kartaca_user }}
    - password: {{kartaca_password}}
    - uid: 2023
    - gid: 2023
    - home: /home/krt
    - shell: /bin/bash

# Add user to sudoers
configure_sudo:
  file.append:
    - name: /etc/sudoers
    - text: |
        {% if grains['os'] == 'Ubuntu' %}
        {{ kartaca_user }} ALL=(ALL) NOPASSWD: /usr/bin/apt
        {% elif grains['os'] == 'CentOS Stream' %}
        {{ kartaca_user }} ALL=(ALL) NOPASSWD: /usr/bin/yum
        {% endif %}

# Set timezone
set_timezone:
  timezone.system:
    - name: Europe/Istanbul

# IP Forwarding
enable_ip_forwarding:
  sysctl.present:
    - name: net.ipv4.ip_forward
    - value: 1

# Insall packages

install_required_packages:
  pkg.installed:
    - names:
        {% if grains['os'] == 'Ubuntu' %}
        - htop
        - tcptraceroute
        - net-tools
        - dnsutils
        - sysstat
        - unzip
        - curl
        {% elif grains['os'] == 'CentOS Stream' %}
        - wget
        - htop
        - traceroute
        - iputils
        - bind-utils  # Equivalent to dnsutils on CentOS
        - sysstat
        {% endif %}

# Add IP addresses 
add_hosts_records:
  file.blockreplace:
    - name: /etc/hosts
    - marker_start: '# START - kartaca.local hosts'
    - marker_end: '# END - kartaca.local hosts'
    - content: |
        {% for i in range(128, 144) %}
        192.168.168.{{ i }} kartaca.local
        {% endfor %}
    - append_if_not_found: True
    - backup: '.bak' # Including recovery option

# OS selection
{% if grains['os'] == 'CentOS Stream' %}

install_hashicorp_terraform:
  cmd.run:
    - name: |
        wget -O- https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo | sudo tee /etc/yum.repos.d/hashicorp.repo
        sudo yum install -y yum-utils
        sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
        sudo yum -y install terraform-1.6.4
    - shell: /bin/bash

install_nginx_on_centos:
  pkg.installed:
    - name: nginx

system_update:
  cmd.run:
    - name: sudo yum update -y

install_repositories:
  cmd.run:
    - name: |
        sudo yum install -y epel-release
        sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
        sudo dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm
    - require:
      - cmd: system_update

enable_php_module:
  cmd.run:
    - name: sudo dnf module -y enable php:remi-8.2
    - require:
      - cmd: install_repositories

install_php_packages:
  pkg.installed:
    - names:
      - php
      - php-cli
      - php-common
      - php-fpm
      - php-mysqlnd
    - require:
      - cmd: enable_php_module    

# Download Wordpress
download_wordpress_archive:
  cmd.run:
    - name: |
        if [ -d "/var/www/wordpress2023" ]; then
          curl -o /tmp/wordpress.tar.gz https://wordpress.org/latest.tar.gz
          tar -zxvf /tmp/wordpress.tar.gz -C /var/www/
          chown -R www-data:www-data /var/www/wordpress2023
          chmod -R 755 /var/www/wordpress2023
        else
          mkdir -p /var/www/wordpress2023
          curl -o /tmp/wordpress.tar.gz https://wordpress.org/latest.tar.gz
          tar -zxvf /tmp/wordpress.tar.gz -C /var/www/
          chown -R www-data:www-data /var/www/wordpress2023
          chmod -R 755 /var/www/wordpress2023
        fi

# Every time nginx.conf is updated 
# nginx service will be restarted 
nginx-config-test:
  module.wait:
    - name: nginx.configtest
    - watch:
      - file: manage_nginx_conf

manage_nginx_conf:
  file.managed:
    - name: /etc/nginx/nginx.conf 
    - source: salt://nginx/nginx.conf
    - source_hash_name: sha256  
    - makedirs: True
    - watch_in:
      - service: reload-nginx

reload-nginx:
  service.running:
    - name: nginx
    - enable: True
    - reload: True
    - watch:
      - module: nginx-config-test

manage_wp_config:
  file.managed:
    - name: /var/www/wordpress2023/wordpress/wp-config-sample.php
    - mode: 644  

{% set wordpress_config_file = '/var/www/wordpress2023/wordpress/wp-config-sample.php' %}
{% set mysql_user = salt['pillar.get']('mysql:lookup:user') %}
{% set mysql_password = salt['pillar.get']('mysql:lookup:password') %}
{% set mysql_host = salt['pillar.get']('mysql:lookup:host') %}
{% set mysql_name = salt['pillar.get']('mysql:lookup:name') %}

update_wp_pillar:
  cmd.run:
    - name: |
        sed -i "s|define( 'DB_NAME', '.*' );|define( 'DB_NAME', '{{ mysql_name }}' );|" {{ wordpress_config_file }}
        sed -i "s|define( 'DB_USER', '.*' );|define( 'DB_USER', '{{ mysql_user }}' );|" {{ wordpress_config_file }}
        sed -i "s|define( 'DB_PASSWORD', '.*' );|define( 'DB_PASSWORD', '{{ mysql_password }}' );|" {{ wordpress_config_file }}
        sed -i "s|define( 'DB_HOST', '.*' );|define( 'DB_HOST', '{{ mysql_host }}' );|" {{ wordpress_config_file }}
        which sed
    - require:
      - file: {{ wordpress_config_file }}

{% set api_url = 'https://api.wordpress.org/secret-key/1.1/salt/' %}
create_wordpress_config:
  cmd.run:
    - name: |
        cat << 'EOF' > /tmp/wordpress_config.sh
        data=$(curl -s {{ api_url }})

        # Function to extract value based on key name
        extract_value() {
            key=$1
            echo "$data" | grep -o "define('$key',\s*'\(.*\)');" | sed "s/define('$key',\s*'\(.*\)');/\1/"
        }

        # Extract values using the function
        auth_key=$(extract_value "AUTH_KEY")
        secure_auth_key=$(extract_value "SECURE_AUTH_KEY")
        logged_in_key=$(extract_value "LOGGED_IN_KEY")
        nonce_key=$(extract_value "NONCE_KEY")
        auth_salt=$(extract_value "AUTH_SALT")
        secure_auth_salt=$(extract_value "SECURE_AUTH_SALT")
        logged_in_salt=$(extract_value "LOGGED_IN_SALT")
        nonce_salt=$(extract_value "NONCE_SALT")

        echo "AUTH_KEY: $auth_key"
        echo "SECURE_AUTH_KEY: $secure_auth_key"
        echo "LOGGED_IN_KEY: $logged_in_key"
        echo "NONCE_KEY: $nonce_key"
        echo "AUTH_SALT: $auth_salt"
        echo "SECURE_AUTH_SALT: $secure_auth_salt"
        echo "LOGGED_IN_SALT: $logged_in_salt"
        echo "NONCE_SALT: $nonce_salt"

        config_file="/var/www/wordpress2023/wordpress/wp-config-sample.php"

        # Defining patterns to delete
        patterns=(
          "define( 'AUTH_KEY',         '.*' );"
          "define( 'SECURE_AUTH_KEY',  '.*' );"
          "define( 'LOGGED_IN_KEY',    '.*' );"
          "define( 'NONCE_KEY',        '.*' );"
          "define( 'AUTH_SALT',        '.*' );"
          "define( 'SECURE_AUTH_SALT',  '.*' );"
          "define( 'LOGGED_IN_SALT',   '.*' );"
          "define( 'NONCE_SALT',       '.*' );"
        )

        for pattern in "${patterns[@]}"; do
            sed -i "/${pattern}/d" "$config_file"
        done

        echo "define( 'AUTH_KEY',         '$auth_key' );" >> "$config_file"
        echo "define( 'SECURE_AUTH_KEY',  '$secure_auth_key' );" >> "$config_file"
        echo "define( 'LOGGED_IN_KEY',    '$logged_in_key' );" >> "$config_file"
        echo "define( 'NONCE_KEY',        '$nonce_key' );" >> "$config_file"
        echo "define( 'AUTH_SALT',        '$auth_salt' );" >> "$config_file"
        echo "define( 'SECURE_AUTH_SALT',  '$secure_auth_salt' );" >> "$config_file"
        echo "define( 'LOGGED_IN_SALT',   '$logged_in_salt' );" >> "$config_file"
        echo "define( 'NONCE_SALT',       '$nonce_salt' );" >> "$config_file"

        EOF

execute_wordpress_config:
  cmd.run:
    - name: /bin/bash /tmp/wordpress_config.sh
    - require:
      - cmd: create_wordpress_config

{% set ssl_dir = '/etc/nginx/ssl' %}
{% set cert_name = 'example.com' %}
create_ssl_certificate:
  cmd.run:
    - name: |
        mkdir -p {{ ssl_dir }}
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout {{ ssl_dir }}/{{ cert_name }}.key -out {{ ssl_dir }}/{{ cert_name }}.crt -subj "/C=US/ST=State/L=City/O=Organization/OU=Unit/CN={{ cert_name }}"

nginx_config_edit:
  file.line:
    - name: /etc/nginx/nginx.conf
    - content: |
            listen 443 ssl;
            server_name localhost;

            ssl_certificate {{ ssl_dir }}/{{ cert_name }}.crt;
            ssl_certificate_key {{ ssl_dir }}/{{ cert_name }}.key;

            location / {
                root /usr/share/nginx/html;
                index index.html index.htm;
                }
    - before: '        location ~ \.php$ {'
    - mode: insert
    - show_changes: True

nginx_restart:
  service.running:
    - name: nginx
    - watch:
      - cmd: create_ssl_certificate

{% set cron_command = '/bin/systemctl restart nginx' %}
nginx_cron:
  cron.present:
    - name: {{ cron_command }}
    - user: root
    - minute: 0
    - hour: 0
    - daymonth: 1

logrotate_installed:
  pkg.installed:
    - name: logrotate

/etc/logrotate.d/nginx:
  file.managed:
    - source: salt://files/nginx_logrotate.conf
    - user: root
    - group: root
    - mode: 644
    - require:
      - pkg: logrotate

{% elif grains['os'] == 'Ubuntu' %}

install_hashicorp_terraform:
  cmd.run:
    - name: |
        sudo apt-get update && sudo apt-get install -y gnupg software-properties-common
        wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
        sudo apt update -y 
        curl -o /tmp/terraform.zip https://releases.hashicorp.com/terraform/1.6.4/terraform_1.6.4_linux_amd64.zip
        unzip /tmp/terraform.zip
        mv /tmp/terraform /usr/local/bin
    - shell: /bin/bash

install_mysql_on_ubuntu:
  pkg.installed:
    - names: 
      - pkg-config
      - mysql-server
      - mysql-client
      - python3-dev 
      - default-libmysqlclient-dev 
      - build-essential

install_mysql_python_packages:
  pip.installed:
    - names:
      - pymysql
      - mysqlclient

configure_mysql_autostart:
  service.running:
    - name: mysql
    - enable: True

{% set mysql_user = salt['pillar.get']('mysql:lookup:user') %}
{% set mysql_password = salt['pillar.get']('mysql:lookup:password') %}
{% set mysql_host = salt['pillar.get']('mysql:lookup:host') %}
{% set mysql_name = salt['pillar.get']('mysql:lookup:name') %}

testdb:
  mysql_database.present:
    - name: {{ mysql_name }}

testdb_user:
  mysql_user.present:
    - name: {{ mysql_user }}
    - password: {{ mysql_password }}
    - host: {{ mysql_host }}

grant_mysql_permissions:
  mysql_grants.present:
    - grant: ALL PRIVILEGES
    - database: {{ mysql_name }}.*
    - user: {{ mysql_user }}
    - host: localhost
    - password: {{ mysql_password }}
    - require:
      - mysql_database: testdb

backup_directory:
  file.directory:
    - name: /backup
    - require:
      - pkg: mysql-client

backup_cron:
  cron.present:
    - name: "/usr/bin/mysqldump -u {{ mysql_user }} -p {{ mysql_password }} {{ mysql_name }} > /backup/mysql_backup_$(date +\\%Y\\%m\\%d).sql"
    - user: root
    - minute: '*'
    - hour: '*'
    - require:
      - pkg: mysql-client
      - file: backup_directory

{% endif %}

