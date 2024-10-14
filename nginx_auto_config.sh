#!/bin/bash

GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
RESET='\033[0m'

echo_green() {
    echo -e "${GREEN}${1}${RESET}"
}

echo_red() {
    echo -e "${RED}${1}${RESET}"
}

echo_yellow() {
    echo -e "${YELLOW}${1}${RESET}"
}


clear

check_url() {
    local url="$1"
    local token="$2"
    local status_code
    status_code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: $token" "$url")
    echo "$status_code"
}

if ! which nginx > /dev/null 2>&1; then
    echo_red "还未安装nginx！"
    exit 1
fi

if ! pgrep nginx > /dev/null 2>&1; then
    echo_yellow "nginx没有启动，正在启动..."
    sudo nginx
fi

while true; do
    echo "请选择私有仓库类型:"
    echo "1) Gitlab私有仓库"
    echo "2) Github私有仓库"
    read -p "请输入你的选择: " choice

    echo

    if [ "$choice" == "2" ]; then
        read -p "请输入你的二级域名: " DOMAIN
        read -p "请输入Github私有仓库令牌：" TOKEN
        read -p "请输入反向代理配置的数量: " CONFIG_COUNT
        read -p "请输入Github用户名：" USERNAME
        read -p "请输入Github私有仓库名：" PROJECTNAME
        break
    elif [ "$choice" == "1" ]; then
        read -p "请输入你的二级域名: " DOMAIN
        read -p "请输入Gitlab私有仓库令牌：" TOKEN
        read -p "请输入反向代理配置的数量: " CONFIG_COUNT
        read -p "请输入Gitlab用户名：" USERNAME
        read -p "请输入Gitlab私有仓库名：" PROJECTNAME
        break
    else
        clear
        echo_red "无效的选择，请输入1或2。"
        echo
    fi
done

if [ "$choice" == "1" ]; then
    PROXY_SET_HEADER_HOST="gitlab.com"
    PROXY_SSL_NAME="gitlab.com"
    PREFIX="Bearer"
else
    PROXY_SET_HEADER_HOST="api.github.com"
    PROXY_SSL_NAME="api.github.com"
    PREFIX="token"
fi

TEMP_FILE=$(mktemp)

for ((i=1; i<=CONFIG_COUNT; )); do
    read -p "请输入第 $i 个配置的访问路径（例如/test）： " LOCATION
    read -p "请输入第 $i 个配置的GitHub文件路径（例如/test.txt）： " FILE_PASS
    read -p "是否允许浏览器访问该文件？(y/n): " ALLOW_BROWSER_ACCESS

    if [ "$choice" == "1" ]; then
        FILE_PASS_CONVERTED=$(echo "$FILE_PASS" | sed 's@/@%2F@g' | sed 's@^%2F@/@')
        PROXY_URL="https://gitlab.com/api/v4/projects/$USERNAME%2F$PROJECTNAME/repository/files$FILE_PASS_CONVERTED/raw?ref=main"
    else
        PROXY_URL="https://api.github.com/repos/$USERNAME/$PROJECTNAME/contents$FILE_PASS"
    fi

    STATUS_CODE=$(check_url "$PROXY_URL" "$PREFIX $TOKEN")
    if [ "$STATUS_CODE" -ne 200 ]; then
        echo_red "第 $i 个配置有误，状态码: $STATUS_CODE，若域名，用户名，仓库名，令牌无误，请重新输入访问路径和文件路径，否则请重新运行脚本。"
        continue
    else
        echo
        echo_green "第 $i 个配置访问路径： https://$DOMAIN$LOCATION   状态码: $STATUS_CODE"
        echo
    fi

    if [[ "$ALLOW_BROWSER_ACCESS" == "y" || "$ALLOW_BROWSER_ACCESS" == "Y" ]]; then
        cat <<EOF >> "$TEMP_FILE"
    location $LOCATION/ {
        proxy_pass $PROXY_URL;
    }
EOF
    else
        cat <<EOF >> "$TEMP_FILE"
    location $LOCATION/ {
        if (\$http_user_agent ~* "Mozilla|Chrome|Safari|Opera|Edge|MSIE|Trident|Baiduspider|Yandex|Sogou|360SE|Qihoo|UCBrowser|WebKit|Bing|Googlebot|Yahoo|Bot|Crawler") {
            return 403;
        }
        proxy_pass $PROXY_URL;
    }
EOF
    fi
    ((i++))
done

nginx_config=$(cat <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /root/$DOMAIN.crt;
    ssl_certificate_key /root/$DOMAIN.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt; 
    proxy_ssl_verify on;   
    proxy_ssl_verify_depth 2;

    proxy_set_header Authorization "$PREFIX $TOKEN";
    proxy_set_header Host $PROXY_SET_HEADER_HOST;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_ssl_server_name on;
    proxy_ssl_name $PROXY_SSL_NAME;
    proxy_http_version 1.1;
    proxy_set_header Connection "keep-alive"; 
    proxy_connect_timeout 60s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;
    proxy_cache_bypass \$http_upgrade;
EOF
)

if [ "$choice" == "2" ]; then
    nginx_config+=$'\n    proxy_set_header Accept "application/vnd.github.v3.raw";\n'
fi

nginx_config+=$'\n'
nginx_config+=$(cat "$TEMP_FILE")

nginx_config+=$'\n}\n'

nginx_config+=$(cat <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _; 
    return 444;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_certificate /root/$DOMAIN.crt;
    ssl_certificate_key /root/$DOMAIN.key;
    return 444;
}
EOF
)

rm -f "$TEMP_FILE"

sudo cp /etc/nginx/sites-available/default /etc/nginx/sites-available/default.bak

echo "$nginx_config" | sudo tee /etc/nginx/sites-available/default > /dev/null

echo

sudo nginx -t

if [ $? -eq 0 ]; then
    sudo nginx -s reload 
    echo
    echo_green "配置正确,nginx已重新加载并应用新的配置!"
    echo
else
    sudo cp /etc/nginx/sites-available/default.bak /etc/nginx/sites-available/default
    sudo nginx -s reload
    echo
    echo_red "Nginx 配置有错误，请检查后重试，已恢复原有配置并应用!"
    echo
fi
