# Example Salt state: Deploy NGINX web server
# This can be converted to Ansible, Terraform, or other formats using HAR

nginx_package:
  pkg.installed:
    - name: nginx

required_packages:
  pkg.installed:
    - pkgs:
      - curl
      - git
      - vim

web_root_directory:
  file.directory:
    - name: /var/www/html
    - mode: '0755'
    - user: www-data
    - group: www-data
    - makedirs: True

nginx_config:
  file.managed:
    - name: /etc/nginx/nginx.conf
    - source: salt://webserver/nginx.conf
    - mode: '0644'
    - user: root
    - group: root
    - require:
      - pkg: nginx_package

index_html:
  file.managed:
    - name: /var/www/html/index.html
    - contents: |
        <!DOCTYPE html>
        <html>
        <head><title>HAR Demo</title></head>
        <body>
          <h1>Welcome to HAR!</h1>
          <p>This server was configured using Hybrid Automation Router.</p>
        </body>
        </html>
    - mode: '0644'
    - user: www-data
    - group: www-data
    - require:
      - file: web_root_directory

nginx_service:
  service.running:
    - name: nginx
    - enable: True
    - require:
      - pkg: nginx_package
      - file: nginx_config
    - watch:
      - file: nginx_config

deployment_user:
  user.present:
    - name: deployer
    - shell: /bin/bash
    - groups:
      - www-data

verify_nginx:
  cmd.run:
    - name: systemctl status nginx
    - require:
      - service: nginx_service
