#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
xui_service="${XUI_SERVICE:=/etc/systemd/system}"

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}Lỗi: ${plain} Vui lòng chạy lệnh bằng quyền root \n " && exit 1

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
  source /etc/os-release
  release=$ID
  elif [[ -f /usr/lib/os-release ]]; then
  source /usr/lib/os-release
  release=$ID
else
  echo "Không thể kiểm tra hệ điều hành, vui lòng liên hệ admin!" >&2
  exit 1
fi
echo "Hệ điều hành hiện tại: $release"

arch() {
  case "$(uname -m)" in
    x86_64 | x64 | amd64) echo 'amd64' ;;
    i*86 | x86) echo '386' ;;
    armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
    armv7* | armv7 | arm) echo 'armv7' ;;
    armv6* | armv6) echo 'armv6' ;;
    armv5* | armv5) echo 'armv5' ;;
    s390x) echo 's390x' ;;
    *) echo -e "${green}Không hỗ trợ kiến trúc CPU này! ${plain}" && rm -f install.sh && exit 1 ;;
  esac
}

echo "Kiến trúc CPU: $(arch)"

# Simple helpers
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0 || return 1
}
is_ipv6() {
    [[ "$1" =~ : ]] && return 0 || return 1
}
is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}
is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+(xn--[a-z0-9]{2,}|[A-Za-z]{2,})$ ]] && return 0 || return 1
}

# Port helpers
is_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | awk -v p=":${port} " '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:${port} -sTCP:LISTEN >/dev/null 2>&1 && return 0
    fi
    return 1
}

install_base() {
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update && apt-get install -y -q cron curl tar tzdata socat ca-certificates openssl
        ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf -y update && dnf install -y -q curl tar tzdata socat ca-certificates openssl
        ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum -y update && yum install -y curl tar tzdata socat ca-certificates openssl
            else
                dnf -y update && dnf install -y -q curl tar tzdata socat ca-certificates openssl
            fi
        ;;
        arch | manjaro | parch)
            pacman -Syu && pacman -Syu --noconfirm curl tar tzdata socat ca-certificates openssl
        ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh && zypper -q install -y curl tar timezone socat ca-certificates openssl
        ;;
        alpine)
            apk update && apk add curl tar tzdata socat ca-certificates openssl
        ;;
        *)
            apt-get update && apt-get install -y -q curl tar tzdata socat ca-certificates openssl
        ;;
    esac
}

gen_random_string() {
    local length="$1"
    openssl rand -base64 $(( length * 2 )) \
        | tr -dc 'a-zA-Z0-9' \
        | head -c "$length"
}

install_acme() {
  echo -e "${green}Đang cài đặt acme.sh để quản lý chứng chỉ SSL...${plain}"
  cd ~ || return 1
  curl -s https://get.acme.sh | sh >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo -e "${red}Cài đặt acme.sh thất bại${plain}"
    return 1
  else
    echo -e "${green}Đã cài đặt acme.sh thành công${plain}"
  fi
  return 0
}

setup_ssl_certificate() {
  local domain="$1"
  local server_ip="$2"
  local existing_port="$3"
  local existing_webBasePath="$4"
  
  echo -e "${green}Đang thiết lập chứng chỉ SSL...${plain}"

   # Check if acme.sh is installed
  if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
    install_acme
    if [ $? -ne 0 ]; then
      echo -e "${yellow}Cài đặt acme.sh thất bại, bỏ qua thiết lập SSL${plain}"
      return 1
    fi
  fi
  
  # Create certificate directory
  local certPath="/root/cert/${domain}"
  mkdir -p "$certPath"
  
  # Issue certificate
  echo -e "${green}Đang cấp chứng chỉ SSL cho ${domain}...${plain}"
  echo -e "${yellow}Lưu ý: Cổng (Port) 80 phải được mở và có thể truy cập từ internet${plain}"
  
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force >/dev/null 2>&1
  ~/.acme.sh/acme.sh --issue -d ${domain} --listen-v6 --standalone --httpport 80 --force
  
  if [ $? -ne 0 ]; then
    echo -e "${yellow}Cấp chứng chỉ cho ${domain} thất bại${plain}"
    echo -e "${yellow}Vui lòng đảm bảo cổng 80 đã mở và thử lại sau bằng lệnh: x-ui${plain}"
    rm -rf ~/.acme.sh/${domain} 2>/dev/null
    rm -rf "$certPath" 2>/dev/null
    return 1
  fi
  
  # Install certificate
  ~/.acme.sh/acme.sh --installcert -d ${domain} \
    --key-file /root/cert/${domain}/privkey.pem \
    --fullchain-file /root/cert/${domain}/fullchain.pem \
    --reloadcmd "systemctl restart x-ui" >/dev/null 2>&1
  
  if [ $? -ne 0 ]; then
    echo -e "${yellow}Cài đặt chứng chỉ thất bại${plain}"
    return 1
  fi
  # Enable auto-renew
  ~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
  # Secure permissions: private key readable only by owner
  chmod 600 $certPath/privkey.pem 2>/dev/null
  chmod 644 $certPath/fullchain.pem 2>/dev/null
  
  # Set certificate for panel
  local webCertFile="/root/cert/${domain}/fullchain.pem"
  local webKeyFile="/root/cert/${domain}/privkey.pem"
  
  if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
    ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile" >/dev/null 2>&1
    echo -e "${green}Đã cài đặt và cấu hình chứng chỉ SSL thành công rực rỡ!${plain}"
    return 0
  else
    echo -e "${yellow}Không tìm thấy file chứng chỉ SSL${plain}"
    return 1
  fi
}

# Issue Let's Encrypt IP certificate with shortlived profile (~6 days validity)
# Requires acme.sh and port 80 open for HTTP-01 challenge
setup_ip_certificate() {
  local ipv4="$1"
  local ipv6="$2" # optional

  echo -e "${green}Đang thiết lập chứng chỉ IP Let's Encrypt (loại ngắn hạn)...${plain}"
  echo -e "${yellow}Lưu ý: Chứng chỉ IP có thời hạn khoảng 6 ngày và sẽ tự động gia hạn.${plain}"
  echo -e "${yellow}Cổng mặc định là 80. Nếu chọn cổng khác, hãy đảm bảo cổng 80 đã được chuyển tiếp (forward) sang cổng đó.${plain}"

  # Check for acme.sh
  if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
    install_acme
    if [ $? -ne 0 ]; then
      echo -e "${red}Cài đặt acme.sh thất bại${plain}"
      return 1
    fi
  fi

  # Validate IP address
  if [[ -z "$ipv4" ]]; then
    echo -e "${red}Bắt buộc phải có địa chỉ IPv4${plain}"
    return 1
  fi

  if ! is_ipv4 "$ipv4"; then
    echo -e "${red}Địa chỉ IPv4 không hợp lệ: $ipv4${plain}"
    return 1
  fi

  # Create certificate directory
  local certDir="/root/cert/ip"
  mkdir -p "$certDir"

  # Build domain arguments
  local domain_args="-d ${ipv4}"
  if [[ -n "$ipv6" ]] && is_ipv6 "$ipv6"; then
    domain_args="${domain_args} -d ${ipv6}"
    echo -e "${green}Đã bao gồm cả địa chỉ IPv6: ${ipv6}${plain}"
  fi

  # Set reload command for auto-renewal (add || true so it doesn't fail during first install)
  local reloadCmd="systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null || true"

  # Choose port for HTTP-01 listener (default 80, prompt override)
  local WebPort=""
  read -rp "Chọn Cổng (Port) để xác thực ACME HTTP-01 (Mặc định là 80, ấn Enter để bỏ qua): " WebPort
  WebPort="${WebPort:-80}"
  if ! [[ "${WebPort}" =~ ^[0-9]+$ ]] || ((WebPort < 1 || WebPort > 65535)); then
    echo -e "${red}Cổng không hợp lệ. Hệ thống sẽ tự dùng cổng 80.${plain}"
    WebPort=80
  fi
  echo -e "${green}Đang dùng cổng ${WebPort} để xác thực độc lập.${plain}"
  if [[ "${WebPort}" -ne 80 ]]; then
    echo -e "${yellow}Nhắc nhẹ: Let's Encrypt vẫn kết nối qua cổng 80; hãy chuyển tiếp (forward) cổng 80 bên ngoài vào cổng ${WebPort}.${plain}"
  fi

  # Ensure chosen port is available
  while true; do
    if is_port_in_use "${WebPort}"; then
      echo -e "${yellow}Cổng ${WebPort} đang bị chiếm dụng.${plain}"

      local alt_port=""
      read -rp "Vui lòng nhập một Cổng (Port) khác để xác thực (Hoặc để trống và ấn Enter để hủy bỏ): " alt_port
      alt_port="${alt_port// /}"
      if [[ -z "${alt_port}" ]]; then
        echo -e "${red}Cổng ${WebPort} đang bận; không thể tiếp tục.${plain}"
        return 1
      fi
      if ! [[ "${alt_port}" =~ ^[0-9]+$ ]] || ((alt_port < 1 || alt_port > 65535)); then
        echo -e "${red}Cổng không hợp lệ.${plain}"
        return 1
      fi
      WebPort="${alt_port}"
      continue
    else
      echo -e "${green}Cổng ${WebPort} đang rảnh rỗi, sẵn sàng để xác thực.${plain}"
      break
    fi
  done

# Issue certificate with shortlived profile
  echo -e "${green}Đang cấp chứng chỉ IP cho ${ipv4}...${plain}"
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force >/dev/null 2>&1
  
  ~/.acme.sh/acme.sh --issue \
    ${domain_args} \
    --standalone \
    --server letsencrypt \
    --certificate-profile shortlived \
    --days 6 \
    --httpport ${WebPort} \
    --force

  if [ $? -ne 0 ]; then
    echo -e "${red}Cấp chứng chỉ IP thất bại${plain}"
    echo -e "${yellow}Vui lòng đảm bảo cổng ${WebPort} có thể truy cập (hoặc đã chuyển tiếp từ cổng 80)${plain}"
    # Cleanup acme.sh data for both IPv4 and IPv6 if specified
    rm -rf ~/.acme.sh/${ipv4} 2>/dev/null
    [[ -n "$ipv6" ]] && rm -rf ~/.acme.sh/${ipv6} 2>/dev/null
    rm -rf ${certDir} 2>/dev/null
    return 1
  fi

  echo -e "${green}Đã cấp chứng chỉ thành công, đang tiến hành cài đặt...${plain}"

  # Install certificate
  # Note: acme.sh may report "Reload error" and exit non-zero if reloadcmd fails,
  # but the cert files are still installed. We check for files instead of exit code.
  ~/.acme.sh/acme.sh --installcert -d ${ipv4} \
    --key-file "${certDir}/privkey.pem" \
    --fullchain-file "${certDir}/fullchain.pem" \
    --reloadcmd "${reloadCmd}" 2>&1 || true

  # Verify certificate files exist (don't rely on exit code - reloadcmd failure causes non-zero)
  if [[ ! -f "${certDir}/fullchain.pem" || ! -f "${certDir}/privkey.pem" ]]; then
    echo -e "${red}Không tìm thấy file chứng chỉ sau khi cài đặt${plain}"
    # Cleanup acme.sh data for both IPv4 and IPv6 if specified
    rm -rf ~/.acme.sh/${ipv4} 2>/dev/null
    [[ -n "$ipv6" ]] && rm -rf ~/.acme.sh/${ipv6} 2>/dev/null
    rm -rf ${certDir} 2>/dev/null
    return 1
  fi
  
  echo -e "${green}Đã cài đặt file chứng chỉ thành công${plain}"

  # Enable auto-upgrade for acme.sh (ensures cron job runs)
  ~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1

  # Secure permissions: private key readable only by owner
  chmod 600 ${certDir}/privkey.pem 2>/dev/null
  chmod 644 ${certDir}/fullchain.pem 2>/dev/null

  # Configure panel to use the certificate
  echo -e "${green}Đang thiết lập đường dẫn chứng chỉ cho Panel...${plain}"
  ${xui_folder}/x-ui cert -webCert "${certDir}/fullchain.pem" -webCertKey "${certDir}/privkey.pem"
  
  if [ $? -ne 0 ]; then
    echo -e "${yellow}Cảnh báo: Không thể tự động thiết lập đường dẫn chứng chỉ${plain}"
    echo -e "${yellow}Các file chứng chỉ nằm tại:${plain}"
    echo -e " Chứng chỉ (Cert): ${certDir}/fullchain.pem"
    echo -e " Khóa (Key): ${certDir}/privkey.pem"
  else
    echo -e "${green}Đã cấu hình đường dẫn chứng chỉ thành công${plain}"
  fi

  echo -e "${green}Đã cài đặt và cấu hình chứng chỉ IP thành công rực rỡ!${plain}"
  echo -e "${green}Chứng chỉ có thời hạn ~6 ngày, sẽ tự động gia hạn ngầm qua hệ thống.${plain}"
  echo -e "${yellow}Hệ thống sẽ tự động gia hạn và tải lại Panel trước khi hết hạn.${plain}"
  return 0
}

# Comprehensive manual SSL certificate issuance via acme.sh
ssl_cert_issue() {
  local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep 'webBasePath:' | awk -F': ' '{print $2}' | tr -d '[:space:]' | sed 's#^/##')
  local existing_port=$(${xui_folder}/x-ui setting -show true | grep 'port:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
  
  # check for acme.sh first
  if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
    echo "Không tìm thấy acme.sh. Đang tiến hành cài đặt..."
    cd ~ || return 1
    curl -s https://get.acme.sh | sh
    if [ $? -ne 0 ]; then
      echo -e "${red}Cài đặt acme.sh thất bại${plain}"
      return 1
    else
      echo -e "${green}Đã cài đặt acme.sh thành công${plain}"
    fi
  fi

  # get the domain here, and we need to verify it
  local domain=""
  while true; do
    read -rp "Vui lòng nhập Tên miền (Domain) của bạn: " domain
    domain="${domain// /}" # Trim whitespace
    
    if [[ -z "$domain" ]]; then
      echo -e "${red}Tên miền không được để trống. Vui lòng thử lại.${plain}"
      continue
    fi
    
    if ! is_domain "$domain"; then
      echo -e "${red}Định dạng không hợp lệ: ${domain}. Vui lòng nhập đúng tên miền.${plain}"
      continue
    fi
    
    break
  done
  echo -e "${green}Tên miền của bạn là: ${domain}, hệ thống đang kiểm tra...${plain}"

  # check if there already exists a certificate
  local currentCert=$(~/.acme.sh/acme.sh --list | tail -1 | awk '{print $1}')
  if [ "${currentCert}" == "${domain}" ]; then
    local certInfo=$(~/.acme.sh/acme.sh --list)
    echo -e "${red}Hệ thống đã có sẵn chứng chỉ cho tên miền này. Không thể cấp lại.${plain}"
    echo -e "${yellow}Chi tiết chứng chỉ hiện tại:${plain}"
    echo "$certInfo"
    return 1
  else
    echo -e "${green}Tên miền hợp lệ, chuẩn bị cấp chứng chỉ...${plain}"
  fi

  # create a directory for the certificate
  certPath="/root/cert/${domain}"
  if [ ! -d "$certPath" ]; then
    mkdir -p "$certPath"
  else
    rm -rf "$certPath"
    mkdir -p "$certPath"
  fi

  # get the port number for the standalone server
  local WebPort=80
  read -rp "Vui lòng chọn Cổng (Port) để cấp SSL (Mặc định là 80): " WebPort
  if [[ ${WebPort} -gt 65535 || ${WebPort} -lt 1 ]]; then
    echo -e "${yellow}Cổng ${WebPort} không hợp lệ, hệ thống sẽ tự động dùng cổng 80.${plain}"
    WebPort=80
  fi
  echo -e "${green}Sẽ sử dụng cổng: ${WebPort} để cấp SSL. Vui lòng đảm bảo cổng này đã được mở.${plain}"

  # Stop panel temporarily
  echo -e "${yellow}Đang tạm dừng Panel để cấp SSL...${plain}"
  systemctl stop x-ui 2>/dev/null || rc-service x-ui stop 2>/dev/null

  # issue the certificate
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
  ~/.acme.sh/acme.sh --issue -d ${domain} --listen-v6 --standalone --httpport ${WebPort} --force
  if [ $? -ne 0 ]; then
    echo -e "${red}Cấp chứng chỉ SSL thất bại, vui lòng kiểm tra lại log.${plain}"
    rm -rf ~/.acme.sh/${domain}
    systemctl start x-ui 2>/dev/null || rc-service x-ui start 2>/dev/null
    return 1
  else
    echo -e "${green}Cấp chứng chỉ SSL thành công, đang tiến hành cài đặt...${plain}"
  fi

    # Setup reload command
  reloadCmd="systemctl restart x-ui || rc-service x-ui restart"
  echo -e "${green}Lệnh mặc định để tải lại (reload) sau khi cấp SSL là: ${yellow}systemctl restart x-ui || rc-service x-ui restart${plain}"
  echo -e "${green}Lệnh này sẽ tự động chạy mỗi khi cấp mới hoặc gia hạn SSL.${plain}"
  read -rp "Bạn có muốn thay đổi lệnh tải lại này không? (y/n): " setReloadcmd
  if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
    echo -e "\n${green}\t1.${plain} Mẫu có sẵn: systemctl reload nginx ; systemctl restart x-ui"
    echo -e "${green}\t2.${plain} Tự nhập lệnh thủ công theo ý bạn"
    echo -e "${green}\t0.${plain} Giữ nguyên lệnh mặc định"
    read -rp "Vui lòng chọn: " choice
    case "$choice" in
    1)
      echo -e "${green}Đã chọn lệnh: systemctl reload nginx ; systemctl restart x-ui${plain}"
      reloadCmd="systemctl reload nginx ; systemctl restart x-ui"
      ;;
    2)
      echo -e "${yellow}Khuyên dùng: Nên để lệnh restart x-ui ở cuối cùng${plain}"
      read -rp "Vui lòng nhập lệnh tùy chỉnh của bạn: " reloadCmd
      echo -e "${green}Đã ghi nhận lệnh: ${reloadCmd}${plain}"
      ;;
    *)
      echo -e "${green}Đang giữ nguyên lệnh mặc định${plain}"
      ;;
    esac
  fi

  # install the certificate
  ~/.acme.sh/acme.sh --installcert -d ${domain} \
    --key-file /root/cert/${domain}/privkey.pem \
    --fullchain-file /root/cert/${domain}/fullchain.pem --reloadcmd "${reloadCmd}"

  if [ $? -ne 0 ]; then
    echo -e "${red}Cài đặt chứng chỉ SSL thất bại, đang thoát.${plain}"
    rm -rf ~/.acme.sh/${domain}
    systemctl start x-ui 2>/dev/null || rc-service x-ui start 2>/dev/null
    return 1
  else
    echo -e "${green}Cài đặt chứng chỉ thành công, đang bật tự động gia hạn...${plain}"
  fi

  # enable auto-renew
  ~/.acme.sh/acme.sh --upgrade --auto-upgrade
  if [ $? -ne 0 ]; then
    echo -e "${yellow}Có lỗi khi bật tự động gia hạn, chi tiết chứng chỉ:${plain}"
    ls -lah /root/cert/${domain}/
    # Secure permissions: private key readable only by owner
    chmod 600 $certPath/privkey.pem 2>/dev/null
    chmod 644 $certPath/fullchain.pem 2>/dev/null
  else
    echo -e "${green}Đã bật tự động gia hạn thành công, chi tiết chứng chỉ:${plain}"
    ls -lah /root/cert/${domain}/
    # Secure permissions: private key readable only by owner
    chmod 600 $certPath/privkey.pem 2>/dev/null
    chmod 644 $certPath/fullchain.pem 2>/dev/null
  fi

  # start panel
  systemctl start x-ui 2>/dev/null || rc-service x-ui start 2>/dev/null

  # Prompt user to set panel paths after successful certificate installation
  read -rp "Bạn có muốn áp dụng ngay chứng chỉ này cho Panel không? (y/n): " setPanel
  if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
    local webCertFile="/root/cert/${domain}/fullchain.pem"
    local webKeyFile="/root/cert/${domain}/privkey.pem"

    if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
      ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
      echo -e "${green}Đã nạp đường dẫn chứng chỉ vào Panel thành công${plain}"
      echo -e "${green}File Chứng chỉ (Cert): $webCertFile${plain}"
      echo -e "${green}File Khóa (Key): $webKeyFile${plain}"
      echo ""
      echo -e "${green}Link truy cập: https://${domain}:${existing_port}/${existing_webBasePath}${plain}"
      echo -e "${yellow}Panel đang khởi động lại để nhận SSL mới...${plain}"
      systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null
    else
      echo -e "${red}Lỗi: Không tìm thấy file chứng chỉ hoặc khóa cho tên miền: $domain.${plain}"
    fi
  else
    echo -e "${yellow}Đã bỏ qua bước cấu hình chứng chỉ cho Panel.${plain}"
  fi
  
  return 0
}

# Reusable interactive SSL setup (domain or IP)
# Sets global `SSL_HOST` to the chosen domain/IP for Access URL usage
prompt_and_setup_ssl() {
  local panel_port="$1"
  local web_base_path="$2"  # expected without leading slash
  local server_ip="$3"

  local ssl_choice=""

  echo -e "${yellow}Vui lòng chọn phương thức cài đặt chứng chỉ SSL:${plain}"
  echo -e "${green}1.${plain} Let's Encrypt cho Tên miền (Hạn 90 ngày, tự động gia hạn)"
  echo -e "${green}2.${plain} Let's Encrypt cho Địa chỉ IP (Hạn 6 ngày, tự động gia hạn)"
  echo -e "${green}3.${plain} Dùng chứng chỉ SSL có sẵn (Tự nhập đường dẫn file)"
  echo -e "${blue}Lưu ý:${plain} Lựa chọn 1 & 2 yêu cầu phải mở cổng (port) 80. Lựa chọn 3 cần nhập tay đường dẫn."
  read -rp "Vui lòng chọn (Mặc định là 2 - Dùng IP): " ssl_choice
  ssl_choice="${ssl_choice// /}" # Trim whitespace
  
  # Default to 2 (IP cert) if input is empty or invalid (not 1 or 3)
  if [[ "$ssl_choice" != "1" && "$ssl_choice" != "3" ]]; then
    ssl_choice="2"
  fi

  case "$ssl_choice" in
  1)
    # User chose Let's Encrypt domain option
    echo -e "${green}Đang sử dụng Let's Encrypt để cấp SSL cho Tên miền...${plain}"
    ssl_cert_issue
    # Extract the domain that was used from the certificate
    local cert_domain=$(~/.acme.sh/acme.sh --list 2>/dev/null | tail -1 | awk '{print $1}')
    if [[ -n "${cert_domain}" ]]; then
      SSL_HOST="${cert_domain}"
      echo -e "${green}✓ Đã cấu hình SSL thành công cho tên miền: ${cert_domain}${plain}"
    else
      echo -e "${yellow}SSL có thể đã cài xong, nhưng hệ thống không trích xuất được tên miền${plain}"
      SSL_HOST="${server_ip}"
    fi
    ;;
  2)
    # User chose Let's Encrypt IP certificate option
    echo -e "${green}Đang sử dụng Let's Encrypt để cấp SSL cho IP (loại ngắn hạn)...${plain}"
    
    # Ask for optional IPv6
    local ipv6_addr=""
    read -rp "Bạn có muốn thêm địa chỉ IPv6 không? (Ấn Enter để bỏ qua): " ipv6_addr
    ipv6_addr="${ipv6_addr// /}" # Trim whitespace
    
    # Stop panel if running (port 80 needed)
    if [[ $release == "alpine" ]]; then
      rc-service x-ui stop >/dev/null 2>&1
    else
      systemctl stop x-ui >/dev/null 2>&1
    fi
    
    setup_ip_certificate "${server_ip}" "${ipv6_addr}"
    if [ $? -eq 0 ]; then
      SSL_HOST="${server_ip}"
      echo -e "${green}✓ Đã cấu hình chứng chỉ SSL cho IP thành công rực rỡ${plain}"
    else
      echo -e "${red}✗ Cài đặt SSL cho IP thất bại. Vui lòng kiểm tra xem cổng 80 đã mở chưa.${plain}"
      SSL_HOST="${server_ip}"
    fi
    ;;
  3)
    # User chose Custom Paths (User Provided) option
    echo -e "${green}Đang sử dụng chứng chỉ SSL tùy chỉnh...${plain}"
    local custom_cert=""
    local custom_key=""
    local custom_domain=""

    # 3.1 Request Domain to compose Panel URL later
    read -rp "Vui lòng nhập Tên miền (Domain) đã đăng ký chứng chỉ này: " custom_domain
    custom_domain="${custom_domain// /}" # Убираем пробелы

    # 3.2 Loop for Certificate Path
    while true; do
      read -rp "Nhập đường dẫn đến file Chứng chỉ (thường có đuôi .crt hoặc fullchain): " custom_cert
      # Strip quotes if present
      custom_cert=$(echo "$custom_cert" | tr -d '"' | tr -d "'")

      if [[ -f "$custom_cert" && -r "$custom_cert" && -s "$custom_cert" ]]; then
        break
      elif [[ ! -f "$custom_cert" ]]; then
        echo -e "${red}Lỗi: File không tồn tại! Vui lòng thử lại.${plain}"
      elif [[ ! -r "$custom_cert" ]]; then
        echo -e "${red}Lỗi: File có tồn tại nhưng không thể đọc (kiểm tra lại quyền - permissions)!${plain}"
      else
        echo -e "${red}Lỗi: File bị trống!${plain}"
      fi
    done

       # 3.3 Loop for Private Key Path
    while true; do
      read -rp "Nhập đường dẫn đến file Khóa riêng tư (thường có đuôi .key hoặc privatekey): " custom_key
      # Strip quotes if present
      custom_key=$(echo "$custom_key" | tr -d '"' | tr -d "'")

      if [[ -f "$custom_key" && -r "$custom_key" && -s "$custom_key" ]]; then
        break
      elif [[ ! -f "$custom_key" ]]; then
        echo -e "${red}Lỗi: File không tồn tại! Vui lòng thử lại.${plain}"
      elif [[ ! -r "$custom_key" ]]; then
        echo -e "${red}Lỗi: File có tồn tại nhưng không thể đọc (kiểm tra lại quyền - permissions)!${plain}"
      else
        echo -e "${red}Lỗi: File bị trống!${plain}"
      fi
    done

    # 3.4 Apply Settings via x-ui binary
    ${xui_folder}/x-ui cert -webCert "$custom_cert" -webCertKey "$custom_key" >/dev/null 2>&1
    
    # Set SSL_HOST for composing Panel URL
    if [[ -n "$custom_domain" ]]; then
      SSL_HOST="$custom_domain"
    else
      SSL_HOST="${server_ip}"
    fi

    echo -e "${green}✓ Đã áp dụng đường dẫn chứng chỉ tùy chỉnh thành công.${plain}"
    echo -e "${yellow}Lưu ý: Bạn sẽ phải tự gia hạn các file chứng chỉ này khi hết hạn.${plain}"

    systemctl restart x-ui >/dev/null 2>&1 || rc-service x-ui restart >/dev/null 2>&1
    ;;
  *)
    echo -e "${red}Lựa chọn không hợp lệ. Đang bỏ qua bước cài đặt SSL.${plain}"
    SSL_HOST="${server_ip}"
    ;;
  esac
}

config_after_install() {
  local existing_hasDefaultCredential=$(${xui_folder}/x-ui setting -show true | grep -Eo 'hasDefaultCredential: .+' | awk '{print $2}')
  local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}' | sed 's#^/##')
  local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
  # Properly detect empty cert by checking if cert: line exists and has content after it
  local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
  local URL_lists=(
    "https://api4.ipify.org"
    "https://ipv4.icanhazip.com"
    "https://v4.api.ipinfo.io/ip"
    "https://ipv4.myexternalip.com/raw"
    "https://4.ident.me"
    "https://check-host.net/ip"
  )
  local server_ip=""
  for ip_address in "${URL_lists[@]}"; do
    local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2>/dev/null)
    local http_code=$(echo "$response" | tail -n1)
    local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]')
    if [[ "${http_code}" == "200" && -n "${ip_result}" ]]; then
      server_ip="${ip_result}"
      break
    fi
  done
  
  if [[ ${#existing_webBasePath} -lt 4 ]]; then
    if [[ "$existing_hasDefaultCredential" == "true" ]]; then
      local config_webBasePath=$(gen_random_string 18)
      local config_username=$(gen_random_string 10)
      local config_password=$(gen_random_string 10)
      
      read -rp "Bạn có muốn tự thiết lập Cổng (Port) cho Panel không? (Nếu không, hệ thống sẽ tạo ngẫu nhiên) [y/n]: " config_confirm
      if [[ "${config_confirm}" == "y" || "${config_confirm}" == "Y" ]]; then
        read -rp "Vui lòng nhập Cổng (Port) cho Panel: " config_port
        echo -e "${yellow}Cổng Panel của bạn là: ${config_port}${plain}"
      else
        local config_port=$(shuf -i 1024-62000 -n 1)
        echo -e "${yellow}Đã tạo Cổng ngẫu nhiên: ${config_port}${plain}"
      fi
      
      ${xui_folder}/x-ui setting -username "${config_username}" -password "${config_password}" -port "${config_port}" -webBasePath "${config_webBasePath}"
      
      echo ""
      echo -e "${green}═══════════════════════════════════════════${plain}"
      echo -e "${green}   Cài đặt Chứng chỉ SSL (BẮT BUỘC)   ${plain}"
      echo -e "${green}═══════════════════════════════════════════${plain}"
      echo -e "${yellow}Để bảo mật, Chứng chỉ SSL là bắt buộc cho tất cả các Panel.${plain}"
      echo -e "${yellow}Let's Encrypt hiện đã hỗ trợ cấp SSL cho cả Tên miền và IP!${plain}"
      echo ""

      prompt_and_setup_ssl "${config_port}" "${config_webBasePath}" "${server_ip}"
      
      # Display final credentials and access information
      echo ""
      echo -e "${green}═══════════════════════════════════════════${plain}"
      echo -e "${green}   Cài đặt Panel Thành Công!       ${plain}"
      echo -e "${green}═══════════════════════════════════════════${plain}"
      echo -e "${green}Tài khoản:   ${config_username}${plain}"
      echo -e "${green}Mật khẩu:   ${config_password}${plain}"
      echo -e "${green}Cổng (Port):  ${config_port}${plain}"
      echo -e "${green}Đường dẫn gốc: ${config_webBasePath}${plain}"
      echo -e "${green}Link truy cập: https://${SSL_HOST}:${config_port}/${config_webBasePath}${plain}"
      echo -e "${green}═══════════════════════════════════════════${plain}"
      echo -e "${yellow}⚠ QUAN TRỌNG: Vui lòng lưu lại thông tin đăng nhập này!${plain}"
      echo -e "${yellow}⚠ Chứng chỉ SSL: Đã bật và cấu hình thành công${plain}"
    else
      local config_webBasePath=$(gen_random_string 18)
      echo -e "${yellow}WebBasePath bị thiếu hoặc quá ngắn. Đang tạo mới...${plain}"
      ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}"
      echo -e "${green}WebBasePath mới: ${config_webBasePath}${plain}"

      # If the panel is already installed but no certificate is configured, prompt for SSL now
      if [[ -z "${existing_cert}" ]]; then
        echo ""
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${green}   Cài đặt Chứng chỉ SSL (KHUYÊN DÙNG)  ${plain}"
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${yellow}Let's Encrypt hiện đã hỗ trợ cấp SSL cho cả Tên miền và IP!${plain}"
        echo ""
        prompt_and_setup_ssl "${existing_port}" "${config_webBasePath}" "${server_ip}"
        echo -e "${green}Link truy cập: https://${SSL_HOST}:${existing_port}/${config_webBasePath}${plain}"
      else
        # If a cert already exists, just show the access URL
        echo -e "${green}Link truy cập: https://${server_ip}:${existing_port}/${config_webBasePath}${plain}"
      fi
    fi
  else
    if [[ "$existing_hasDefaultCredential" == "true" ]]; then
      local config_username=$(gen_random_string 10)
      local config_password=$(gen_random_string 10)
      
      echo -e "${yellow}Phát hiện tài khoản mặc định. Cần cập nhật bảo mật...${plain}"
      ${xui_folder}/x-ui setting -username "${config_username}" -password "${config_password}"
      echo -e "Đã tạo thông tin đăng nhập ngẫu nhiên mới:"
      echo -e "###############################################"
      echo -e "${green}Tài khoản: ${config_username}${plain}"
      echo -e "${green}Mật khẩu:  ${config_password}${plain}"
      echo -e "###############################################"
    else
      echo -e "${green}Tài khoản, Mật khẩu và WebBasePath đã được thiết lập chuẩn.${plain}"
    fi
# Existing install: if no cert configured, prompt user for SSL setup
    # Properly detect empty cert by checking if cert: line exists and has content after it
    existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    if [[ -z "$existing_cert" ]]; then
      echo ""
      echo -e "${green}═══════════════════════════════════════════${plain}"
      echo -e "${green}   Cài đặt Chứng chỉ SSL (KHUYÊN DÙNG)  ${plain}"
      echo -e "${green}═══════════════════════════════════════════${plain}"
      echo -e "${yellow}Let's Encrypt hiện đã hỗ trợ cấp SSL cho cả Tên miền và IP!${plain}"
      echo ""
      prompt_and_setup_ssl "${existing_port}" "${existing_webBasePath}" "${server_ip}"
      echo -e "${green}Link truy cập: https://${SSL_HOST}:${existing_port}/${existing_webBasePath}${plain}"
    else
      echo -e "${green}Chứng chỉ SSL đã được cấu hình từ trước. Bỏ qua bước này.${plain}"
    fi
  fi
  
  ${xui_folder}/x-ui migrate
}

install_x-ui() {
  cd ${xui_folder%/x-ui}/
  
  # Download resources
  if [ $# == 0 ]; then
    tag_version=$(curl -Ls "https://api.github.com/repos/vietnamvpn/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ ! -n "$tag_version" ]]; then
      echo -e "${yellow}Đang thử lấy phiên bản thông qua IPv4...${plain}"
      tag_version=$(curl -4 -Ls "https://api.github.com/repos/vietnamvpn/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
      if [[ ! -n "$tag_version" ]]; then
        echo -e "${red}Không lấy được phiên bản x-ui, có thể do GitHub đang hạn chế API, vui lòng thử lại sau${plain}"
        exit 1
      fi
    fi
    echo -e "Đã lấy được phiên bản mới nhất: ${tag_version}, bắt đầu tiến trình cài đặt..."
    curl -4fLRo ${xui_folder}-linux-$(arch).tar.gz https://github.com/vietnamvpn/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz
    if [[ $? -ne 0 ]]; then
      echo -e "${red}Tải xuống x-ui thất bại, vui lòng đảm bảo máy chủ VPS của bạn có thể kết nối với GitHub ${plain}"
      exit 1
    fi
  else
    tag_version=$1
    tag_version_numeric=${tag_version#v}
    min_version="2.3.5"
    
    if [[ "$(printf '%s\n' "$min_version" "$tag_version_numeric" | sort -V | head -n1)" != "$min_version" ]]; then
      echo -e "${red}Vui lòng dùng phiên bản mới hơn (ít nhất từ v2.3.5 trở lên). Đang dừng cài đặt.${plain}"
      exit 1
    fi
    
    url="https://github.com/vietnamvpn/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz"
    echo -e "Đang bắt đầu cài đặt phiên bản x-ui $1"
    curl -4fLRo ${xui_folder}-linux-$(arch).tar.gz ${url}
    if [[ $? -ne 0 ]]; then
      echo -e "${red}Tải xuống x-ui $1 thất bại, vui lòng kiểm tra xem phiên bản này có tồn tại không ${plain}"
      exit 1
    fi
  fi
  curl -4fLRo /usr/bin/x-ui-temp https://raw.githubusercontent.com/vietnamvpn/3x-ui/main/x-ui.sh
  if [[ $? -ne 0 ]]; then
    echo -e "${red}Tải file x-ui.sh thất bại${plain}"
    exit 1
  fi
 # Stop x-ui service and remove old resources
  if [[ -e ${xui_folder}/ ]]; then
    if [[ $release == "alpine" ]]; then
      rc-service x-ui stop
    else
      systemctl stop x-ui
    fi
    rm ${xui_folder}/ -rf
  fi
  
  # Extract resources and set permissions
  tar zxvf x-ui-linux-$(arch).tar.gz
  rm x-ui-linux-$(arch).tar.gz -f
  
  cd x-ui
  chmod +x x-ui
  chmod +x x-ui.sh
  
  # Check the system's architecture and rename the file accordingly
  if [[ $(arch) == "armv5" || $(arch) == "armv6" || $(arch) == "armv7" ]]; then
    mv bin/xray-linux-$(arch) bin/xray-linux-arm
    chmod +x bin/xray-linux-arm
  fi
  chmod +x x-ui bin/xray-linux-$(arch)
  
  # Update x-ui cli and se set permission
  mv -f /usr/bin/x-ui-temp /usr/bin/x-ui
  chmod +x /usr/bin/x-ui
  mkdir -p /var/log/x-ui
  config_after_install

  # Etckeeper compatibility
  if [ -d "/etc/.git" ]; then
    if [ -f "/etc/.gitignore" ]; then
      if ! grep -q "x-ui/x-ui.db" "/etc/.gitignore"; then
        echo "" >> "/etc/.gitignore"
        echo "x-ui/x-ui.db" >> "/etc/.gitignore"
        echo -e "${green}Đã thêm x-ui.db vào /etc/.gitignore cho etckeeper${plain}"
      fi
    else
      echo "x-ui/x-ui.db" > "/etc/.gitignore"
      echo -e "${green}Đã tạo /etc/.gitignore và thêm x-ui.db cho etckeeper${plain}"
    fi
  fi
  
  if [[ $release == "alpine" ]]; then
    curl -4fLRo /etc/init.d/x-ui https://raw.githubusercontent.com/vietnamvpn/3x-ui/main/x-ui.rc
    if [[ $? -ne 0 ]]; then
      echo -e "${red}Tải file x-ui.rc thất bại${plain}"
      exit 1
    fi
    chmod +x /etc/init.d/x-ui
    rc-update add x-ui
    rc-service x-ui start
  else
    # Install systemd service file
    service_installed=false
    
    if [ -f "x-ui.service" ]; then
      echo -e "${green}Đã tìm thấy x-ui.service trong file giải nén, đang tiến hành cài đặt...${plain}"
      cp -f x-ui.service ${xui_service}/ >/dev/null 2>&1
      if [[ $? -eq 0 ]]; then
        service_installed=true
      fi
    fi
    
    if [ "$service_installed" = false ]; then
      case "${release}" in
        ubuntu | debian | armbian)
          if [ -f "x-ui.service.debian" ]; then
            echo -e "${green}Đã tìm thấy x-ui.service.debian trong file giải nén, đang tiến hành cài đặt...${plain}"
            cp -f x-ui.service.debian ${xui_service}/x-ui.service >/dev/null 2>&1
            if [[ $? -eq 0 ]]; then
              service_installed=true
            fi
          fi
        ;;
        arch | manjaro | parch)
          if [ -f "x-ui.service.arch" ]; then
            echo -e "${green}Đã tìm thấy x-ui.service.arch trong file giải nén, đang tiến hành cài đặt...${plain}"
            cp -f x-ui.service.arch ${xui_service}/x-ui.service >/dev/null 2>&1
            if [[ $? -eq 0 ]]; then
              service_installed=true
            fi
          fi
        ;;
        *)
          if [ -f "x-ui.service.rhel" ]; then
            echo -e "${green}Đã tìm thấy x-ui.service.rhel trong file giải nén, đang tiến hành cài đặt...${plain}"
            cp -f x-ui.service.rhel ${xui_service}/x-ui.service >/dev/null 2>&1
            if [[ $? -eq 0 ]]; then
              service_installed=true
            fi
          fi
        ;;
      esac
    fi
 # If service file not found in tar.gz, download from GitHub
    if [ "$service_installed" = false ]; then
      echo -e "${yellow}Không tìm thấy file dịch vụ trong file cài đặt, đang tải từ GitHub...${plain}"
      case "${release}" in
        ubuntu | debian | armbian)
          curl -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/vietnamvpn/3x-ui/main/x-ui.service.debian >/dev/null 2>&1
        ;;
        arch | manjaro | parch)
          curl -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/vietnamvpn/3x-ui/main/x-ui.service.arch >/dev/null 2>&1
        ;;
        *)
          curl -4fLRo ${xui_service}/x-ui.service https://raw.githubusercontent.com/vietnamvpn/3x-ui/main/x-ui.service.rhel >/dev/null 2>&1
        ;;
      esac
      
      if [[ $? -ne 0 ]]; then
        echo -e "${red}Cài đặt x-ui.service từ GitHub thất bại${plain}"
        exit 1
      fi
      service_installed=true
    fi
    
    if [ "$service_installed" = true ]; then
      echo -e "${green}Đang thiết lập dịch vụ chạy ngầm...${plain}"
      chown root:root ${xui_service}/x-ui.service >/dev/null 2>&1
      chmod 644 ${xui_service}/x-ui.service >/dev/null 2>&1
      systemctl daemon-reload
      systemctl enable x-ui
      
      # --- BẮT ĐẦU TẠO LOG XRAY TỰ ĐỘNG ---
      echo -e "${green}Đang khoi tao thu muc log cho Xray...${plain}"
      mkdir -p /var/log/xray/
      touch /var/log/xray/access.log
      touch /var/log/xray/error.log
      chmod -R 777 /var/log/xray/
      # --- KET THUC TAO LOG ---

      systemctl start x-ui
    else
      echo -e "${red}Cài đặt file x-ui.service thất bại${plain}"
      exit 1
    fi
  fi
  
  echo -e "${green}Đã cài đặt xong x-ui ${tag_version}${plain}, hệ thống đang hoạt động..."
  echo -e ""
  echo -e "┌───────────────────────────────────────────────────────┐
│  ${blue}Menu Lệnh Điều Khiển Panel (Gõ vào Terminal):${plain}          │
│                                                       │
│  ${blue}x-ui${plain}              - Mở Menu Quản Lý Tổng Hợp         │
│  ${blue}x-ui start${plain}        - Khởi động Panel                  │
│  ${blue}x-ui stop${plain}         - Dừng Panel                       │
│  ${blue}x-ui restart${plain}      - Khởi động lại Panel              │
│  ${blue}x-ui status${plain}       - Xem trạng thái hoạt động         │
│  ${blue}x-ui settings${plain}     - Xem cài đặt hiện tại             │
│  ${blue}x-ui enable${plain}       - Bật tự chạy khi khởi động VPS    │
│  ${blue}x-ui disable${plain}      - Tắt tự chạy khi khởi động VPS    │
│  ${blue}x-ui log${plain}          - Xem nhật ký hệ thống (Logs)      │
│  ${blue}x-ui banlog${plain}       - Xem danh sách bị chặn (Fail2ban) │
│  ${blue}x-ui update${plain}       - Cập nhật phiên bản mới           │
│  ${blue}x-ui legacy${plain}       - Cài đặt bản cũ                   │
│  ${blue}x-ui install${plain}      - Cài đặt lại                      │
│  ${blue}x-ui uninstall${plain}    - Gỡ cài đặt hoàn toàn             │
└───────────────────────────────────────────────────────┘"
}

echo -e "${green}Đang chạy lệnh cài đặt...${plain}"
install_base
install_x-ui $1
