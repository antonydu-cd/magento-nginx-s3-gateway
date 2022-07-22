#!/usr/bin/env bash
sudo yum remove -y nginx
sudo yum install -y https://nginx.org/packages/mainline/centos/7/x86_64/RPMS/nginx-1.21.6-1.el7.ngx.x86_64.rpm
sudo yum install -y https://nginx.org/packages/mainline/centos/7/x86_64/RPMS/nginx-module-image-filter-1.21.6-1.el7.ngx.x86_64.rpm
sudo yum install -y https://nginx.org/packages/mainline/centos/7/x86_64/RPMS/nginx-module-njs-1.21.6%2B0.7.4-1.el7.ngx.x86_64.rpm
sudo yum install -y https://nginx.org/packages/mainline/centos/7/x86_64/RPMS/nginx-module-xslt-1.21.6-1.el7.ngx.x86_64.rpm

export S3_BUCKET_NAME='your_bucket'
export S3_ACCESS_KEY_ID='your_access_key'
export S3_SECRET_KEY='your_secret_key'
export S3_SERVER='s3.ap-southeast-1.amazonaws.com'
export PROXY_CACHE_VALID_OK='1h'
export PROXY_CACHE_VALID_NOTFOUND='1m'
export PROXY_CACHE_VALID_FORBIDDEN='30s'
export S3_SERVER_PORT='443'
export S3_SERVER_PROTO='https'
export S3_REGION='ap-southeast-1'
export S3_STYLE='virtual'
export S3_DEBUG='true'
export AWS_SIGS_VERSION='4'
export ALLOW_DIRECTORY_LIST='false'

set -o errexit   # abort on nonzero exit status
set -o pipefail  # don't hide errors within pipes

if [ "$EUID" -ne 0 ];then
  >&2 echo "This script requires root level access to run"
  exit 1
fi

failed=0

required=("S3_BUCKET_NAME" "S3_SERVER" "S3_SERVER_PORT" "S3_SERVER_PROTO"
"S3_REGION" "S3_STYLE" "ALLOW_DIRECTORY_LIST" "AWS_SIGS_VERSION")

if [ ! -z ${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI+x} ]; then
  echo "Running inside an ECS task, using container credentials"
  uses_iam_creds=1
elif curl --output /dev/null --silent --head --fail --connect-timeout 2 "http://169.254.169.254"; then
  echo "Running inside an EC2 instance, using IMDS for credentials"
  uses_iam_creds=1
else
  required+=("S3_ACCESS_KEY_ID" "S3_SECRET_KEY")
  uses_iam_creds=0
fi

for name in ${required[@]}; do
  if [ -z ${!name+x} ]; then
      >&2 echo "Required ${name} environment variable missing"
      failed=1
  fi
done

if [ "${S3_SERVER_PROTO}" != "http" ] && [ "${S3_SERVER_PROTO}" != "https" ]; then
    >&2 echo "S3_SERVER_PROTO contains an invalid value (${S3_SERVER_PROTO}). Valid values: http, https"
    failed=1
fi

if [ "${AWS_SIGS_VERSION}" != "2" ] && [ "${AWS_SIGS_VERSION}" != "4" ]; then
  >&2 echo "AWS_SIGS_VERSION contains an invalid value (${AWS_SIGS_VERSION}). Valid values: 2, 4"
  failed=1
fi

if [ $failed -gt 0 ]; then
  exit 1
fi

mkdir -p /var/cache/nginx/s3_proxy
chown nginx:nginx /var/cache/nginx/s3_proxy

echo "▶ Adding environment variables to NGINX configuration file: /etc/nginx/environment"
cat > "/etc/nginx/environment" << EOF
# Enables or disables directory listing for the S3 Gateway (1=enabled, 0=disabled)
ALLOW_DIRECTORY_LIST=${ALLOW_DIRECTORY_LIST}
# AWS Authentication signature version (2=v2 authentication, 4=v4 authentication)
AWS_SIGS_VERSION=${AWS_SIGS_VERSION}
# Name of S3 bucket to proxy requests to
S3_BUCKET_NAME=${S3_BUCKET_NAME}
# Region associated with API
S3_REGION=${S3_REGION}
# SSL/TLS port to connect to
S3_SERVER_PORT=${S3_SERVER_PORT}
# Protocol to used connect to S3 server - 'http' or 'https'
S3_SERVER_PROTO=${S3_SERVER_PROTO}
# S3 host to connect to
S3_SERVER=${S3_SERVER}
# S3 credentials
S3_ACCESS_KEY_ID=${S3_ACCESS_KEY_ID}
S3_SECRET_KEY=${S3_SECRET_KEY}
# The S3 host/path method - 'virtual', 'path' or 'default'
S3_STYLE=${S3_STYLE}
# Flag (true/false) enabling AWS signatures debug output (default: false)
S3_DEBUG=${S3_DEBUG}
# Proxy Cache Values
PROXY_CACHE_VALID_OK=${PROXY_CACHE_VALID_OK}
PROXY_CACHE_VALID_NOTFOUND=${PROXY_CACHE_VALID_NOTFOUND}
PROXY_CACHE_VALID_FORBIDDEN=${PROXY_CACHE_VALID_FORBIDDEN}
EOF

# Only include these env vars if we are not using a instance profile credential
# to obtain S3 permissions.
if [ $uses_iam_creds -eq 0 ]; then
  cat >> "/etc/nginx/environment" << EOF
# AWS Access key
S3_ACCESS_KEY_ID=${S3_ACCESS_KEY_ID}
# AWS Secret access key
S3_SECRET_KEY=${S3_SECRET_KEY}
EOF
fi

set +o nounset   # don't abort on unbound variable
if [ -z ${DNS_RESOLVERS+x} ]; then
  cat >> "/etc/default/nginx" << EOF
# DNS resolvers (separated by single spaces) to configure NGINX with
DNS_RESOLVERS=${DNS_RESOLVERS}
EOF
fi
set -o nounset   # abort on unbound variable

# Make sure that only the root user can access the environment variables file
chown root:root /etc/nginx/environment
chmod og-rwx /etc/nginx/environment

cat > /usr/local/bin/template_nginx_config.sh << 'EOF'
#!/usr/bin/env bash
ME=$(basename $0)
auto_envsubst() {
  local template_dir="${NGINX_ENVSUBST_TEMPLATE_DIR:-/etc/nginx/templates}"
  local suffix="${NGINX_ENVSUBST_TEMPLATE_SUFFIX:-.template}"
  local output_dir="${NGINX_ENVSUBST_OUTPUT_DIR:-/etc/nginx/conf.d}"
  local template defined_envs relative_path output_path subdir
  defined_envs=$(printf '${%s} ' $(env | cut -d= -f1))
  [ -d "$template_dir" ] || return 0
  if [ ! -w "$output_dir" ]; then
    echo "$ME: ERROR: $template_dir exists, but $output_dir is not writable"
    return 0
  fi
  find "$template_dir" -follow -type f -name "*$suffix" -print | while read -r template; do
    relative_path="${template#$template_dir/}"
    output_path="$output_dir/${relative_path%$suffix}"
    subdir=$(dirname "$relative_path")
    # create a subdirectory where the template file exists
    mkdir -p "$output_dir/$subdir"
    echo "$ME: Running envsubst on $template to $output_path"
    envsubst "$defined_envs" < "$template" > "$output_path"
  done
}
# Attempt to read DNS Resolvers from /etc/resolv.conf
if [ -z ${DNS_RESOLVERS+x} ]; then
  export DNS_RESOLVERS="$(cat /etc/resolv.conf | grep nameserver | cut -d' ' -f2 | xargs)"
fi
auto_envsubst
EOF
chmod +x /usr/local/bin/template_nginx_config.sh

echo "▶ Reconfiguring systemd for S3 Gateway"
mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/override.conf << 'EOF'
[Service]
EnvironmentFile=/etc/nginx/environment
ExecStartPre=/usr/local/bin/template_nginx_config.sh
EOF
sudo systemctl daemon-reload

echo "▶ Creating NGINX configuration for S3 Gateway"
mkdir -p /etc/nginx/include
mkdir -p /etc/nginx/conf.d/gateway
mkdir -p /etc/nginx/templates/gateway

function download() {
  wget --quiet --output-document="$2" "https://raw.githubusercontent.com/antonydu-cd/magento-nginx-s3-gateway/master/$1"
}

if [ ! -f /etc/nginx/nginx.conf.orig ]; then
  mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig
fi

if [ ! -f /etc/nginx/conf.d/default.conf.orig ]; then
  mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.orig
fi

cat > /etc/nginx/nginx.conf << 'EOF'
user  centos;
worker_processes  auto;
error_log  /var/log/nginx/error.log;
pid        /var/run/nginx.pid;


# NJS module used for implementing S3 authentication
load_module modules/ngx_http_js_module.so;
load_module modules/ngx_stream_js_module.so;
# IMAGE FILTER module
load_module modules/ngx_http_image_filter_module.so;
# XML module
load_module modules/ngx_http_xslt_filter_module.so;
# Load dynamic modules. See /usr/share/doc/nginx/README.dynamic.
include /usr/share/nginx/modules/*.conf;
# Preserve S3 environment variables for worker threads
EOF

# Only include these env vars if we are not using a instance profile credential
# to obtain S3 permissions.
if [ $uses_iam_creds -eq 0 ]; then
  cat >> "/etc/nginx/environment" << EOF
env S3_ACCESS_KEY_ID;
env S3_SECRET_KEY;
EOF
fi

cat >> /etc/nginx/nginx.conf << 'EOF'
env S3_BUCKET_NAME;
env S3_SERVER;
env S3_SERVER_PORT;
env S3_SERVER_PROTO;
env S3_REGION;
env AWS_SIGS_VERSION;
env S3_DEBUG;
env S3_STYLE;
env ALLOW_DIRECTORY_LIST;

events {
    worker_connections  1024;
}

http {
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile       on;
    tcp_nopush     on;
    tcp_nodelay    on;
    keepalive_timeout  65;
    types_hash_max_size 4096;
    client_max_body_size 8M;
    #gzip  on;

    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    
    # Settings for S3 cache
    proxy_cache_path /var/cache/nginx/s3_proxy
    levels=1:2
    keys_zone=s3_cache:10m
    max_size=10g
    inactive=60m
    use_temp_path=off;
    server_tokens off;
    
    server {
        listen 80;
        set $MAGE_ROOT /var/www/html;
        include /var/www/html/nginx.conf;
    }

    # Load modular configuration files from the /etc/nginx/conf.d directory.
    # See http://nginx.org/en/docs/ngx_core_module.html#include
    # for more information.
    include /etc/nginx/conf.d/*.conf;
}
EOF

download "include/listing.xsl" "/etc/nginx/include/listing.xsl"
download "include/s3gateway.js" "/etc/nginx/include/s3gateway.js"
download "templates/default.conf.template" "/etc/nginx/templates/default.conf.template"
download "templates/gateway/v4_headers.conf.template" "/etc/nginx/templates/gateway/v4_headers.conf.template"
download "templates/gateway/v4_js_vars.conf.template" "/etc/nginx/templates/gateway/v4_js_vars.conf.template"
download "templates/upstreams.conf.template" "/etc/nginx/templates/upstreams.conf.template"
download "gateway/server_variables.conf" "/etc/nginx/conf.d/gateway/server_variables.conf"

#We overwrite the default.conf.template file to add listen to a defined port
# echo "▶ Overwriting S3 port to 8080"
# printf "%s\n" "/server {/a" "    listen 8080;" . w | ed -s /etc/nginx/templates/default.conf.template

echo "▶ Creating directory for proxy cache"
mkdir -p /var/cache/nginx/s3_proxy
chown centos:centos /var/cache/nginx/s3_proxy

echo "▶ Stopping NGINX"
sudo systemctl stop nginx

echo "▶ Starting NGINX"
sudo systemctl start nginx