#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

#Add some basic function here
function LOGD() {
    echo -e "${yellow}[DEG] $* ${plain}"
}

function LOGE() {
    echo -e "${red}[ERR] $* ${plain}"
}

function LOGI() {
    echo -e "${green}[INF] $* ${plain}"
}

# Port helpers: detect listener and owning process (best effort)
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

# Simple helpers for domain/IP validation
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

# kiểm tra quyền root
[[ $EUID -ne 0 ]] && LOGE "LỖI: Bạn phải có quyền root để chạy script này! \n" && exit 1

# Kiểm tra hệ điều hành và đặt biến release
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "Không thể kiểm tra hệ điều hành, vui lòng liên hệ tác giả!" >&2
    exit 1
fi
echo "Hệ điều hành hiện tại là: $release"

os_version=""
os_version=$(grep "^VERSION_ID" /etc/os-release | cut -d '=' -f2 | tr -d '"' | tr -d '.')

# Declare Variables
xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
xui_service="${XUI_SERVICE:=/etc/systemd/system}"
log_folder="${XUI_LOG_FOLDER:=/var/log/x-ui}"
mkdir -p "${log_folder}"
iplimit_log_path="${log_folder}/3xipl.log"
iplimit_banned_log_path="${log_folder}/3xipl-banned.log"

confirm() {
    if [[ $# > 1 ]]; then
        echo && read -rp "$1 [Default $2]: " temp
        if [[ "${temp}" == "" ]]; then
            temp=$2
        fi
    else
        read -rp "$1 [y/n]: " temp
    fi
    if [[ "${temp}" == "y" || "${temp}" == "Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    confirm "Khởi động lại panel, Chú ý: Khởi động lại panel cũng sẽ khởi động lại xray" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}Nhấn Enter để quay lại menu chính: ${plain}" && read -r temp
    show_menu
}

install() {
    bash <(curl -Ls https://raw.githubusercontent.com/vietnamvpn/3x-ui/main/install.sh)
    if [[ $? == 0 ]]; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    confirm "Chức năng này sẽ cập nhật tất cả các thành phần x-ui lên phiên bản mới nhất, dữ liệu của bạn sẽ KHÔNG bị mất. Bạn có muốn tiếp tục không?" "y"
    if [[ $? != 0 ]]; then
        LOGE "Đã hủy cập nhật"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    bash <(curl -Ls https://raw.githubusercontent.com/vietnamvpn/3x-ui/main/update.sh)
    if [[ $? == 0 ]]; then
        LOGI "Cập nhật hoàn tất, Panel đã tự động khởi động lại"
        before_show_menu
    fi
}

update_menu() {
    echo -e "${yellow}Đang cập nhật Menu...${plain}"
    confirm "Chức năng này sẽ tải về bản dịch Menu mới nhất. Bạn có muốn tiếp tục?" "y"
    if [[ $? != 0 ]]; then
        LOGE "Đã hủy cập nhật Menu"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi

    curl -fLRo /usr/bin/x-ui https://raw.githubusercontent.com/vietnamvpn/3x-ui/main/x-ui.sh
    chmod +x ${xui_folder}/x-ui.sh
    chmod +x /usr/bin/x-ui

    if [[ $? == 0 ]]; then
        echo -e "${green}Cập nhật Menu thành công. Panel đã tự động khởi động lại.${plain}"
        exit 0
    else
        echo -e "${red}Cập nhật Menu thất bại. Vui lòng kiểm tra lại mạng hoặc link GitHub.${plain}"
        return 1
    fi
}

legacy_version() {
    echo -n "Nhập phiên bản panel (ví dụ: 2.4.0): "
    read -r tag_version

    if [ -z "$tag_version" ]; then
        echo "Phiên bản panel không được để trống. Đang thoát."
        exit 1
    fi
    # Sử dụng phiên bản panel đã nhập vào liên kết tải xuống
    install_command="bash <(curl -Ls "https://raw.githubusercontent.com/vietnamvpn/3x-ui/v$tag_version/install.sh") v$tag_version"

    echo "Đang tải xuống và cài đặt phiên bản panel $tag_version..."
    eval $install_command
}

# Hàm xử lý việc tự xóa file script
delete_script() {
    rm "$0" # Tự xóa chính file script này
    exit 1
}

uninstall() {
    confirm "Bạn có chắc chắn muốn gỡ cài đặt panel không? xray cũng sẽ bị gỡ cài đặt theo!" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi

    if [[ $release == "alpine" ]]; then
        rc-service x-ui stop
        rc-update del x-ui
        rm /etc/init.d/x-ui -f
    else
        systemctl stop x-ui
        systemctl disable x-ui
        rm ${xui_service}/x-ui.service -f
        systemctl daemon-reload
        systemctl reset-failed
    fi

    rm /etc/x-ui/ -rf
    rm ${xui_folder}/ -rf

    echo ""
    echo -e "Gỡ cài đặt thành công.\n"
    echo "Nếu bạn cần cài đặt lại panel này, bạn có thể sử dụng lệnh dưới đây:"
    echo -e "${green}bash <(curl -Ls https://raw.githubusercontent.com/vietnamvpn/3x-ui/master/install.sh)${plain}"
    echo ""
    # Bẫy tín hiệu SIGTERM
    trap delete_script SIGTERM
    delete_script
}

reset_user() {
    confirm "Bạn có chắc chắn muốn đặt lại tên người dùng và mật khẩu của panel không?" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    
    read -rp "Vui lòng đặt tên đăng nhập [mặc định là tên ngẫu nhiên]: " config_account
    [[ -z $config_account ]] && config_account=$(gen_random_string 10)
    read -rp "Vui lòng đặt mật khẩu đăng nhập [mặc định là mật khẩu ngẫu nhiên]: " config_password
    [[ -z $config_password ]] && config_password=$(gen_random_string 18)

    read -rp "Bạn có muốn tắt xác thực hai yếu tố (2FA) đang được cấu hình không? (y/n): " twoFactorConfirm
    if [[ $twoFactorConfirm != "y" && $twoFactorConfirm != "Y" ]]; then
        ${xui_folder}/x-ui setting -username "${config_account}" -password "${config_password}" -resetTwoFactor false >/dev/null 2>&1
    else
        ${xui_folder}/x-ui setting -username "${config_account}" -password "${config_password}" -resetTwoFactor true >/dev/null 2>&1
        echo -e "Xác thực hai yếu tố đã bị tắt."
    fi
    
    echo -e "Tên đăng nhập panel đã được đặt lại thành: ${green} ${config_account} ${plain}"
    echo -e "Mật khẩu đăng nhập panel đã được đặt lại thành: ${green} ${config_password} ${plain}"
    echo -e "${green} Vui lòng sử dụng tên đăng nhập và mật khẩu mới để truy cập panel X-UI. Và nhớ lưu lại nhé! ${plain}"
    confirm_restart
}

gen_random_string() {
    local length="$1"
    openssl rand -base64 $(( length * 2 )) \
        | tr -dc 'a-zA-Z0-9' \
        | head -c "$length"
}

reset_webbasepath() {
    echo -e "${yellow}Đang đặt lại Web Base Path (Đường dẫn gốc)${plain}"

    read -rp "Bạn có chắc chắn muốn đặt lại đường dẫn gốc (web base path) không? (y/n): " confirm
    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        echo -e "${yellow}Đã hủy thao tác.${plain}"
        return
    fi

    config_webBasePath=$(gen_random_string 18)

    # Apply the new web base path setting
    ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}" >/dev/null 2>&1

    echo -e "Đường dẫn gốc (web base path) đã được đặt lại thành: ${green}${config_webBasePath}${plain}"
    echo -e "${green}Vui lòng sử dụng đường dẫn gốc mới để truy cập panel.${plain}"
    restart
}

reset_config() {
    confirm "Bạn có chắc chắn muốn đặt lại tất cả cài đặt panel không? Dữ liệu tài khoản sẽ KHÔNG bị mất, Tên người dùng và mật khẩu sẽ KHÔNG thay đổi" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    ${xui_folder}/x-ui setting -reset
    echo -e "Tất cả cài đặt panel đã được đặt lại về mặc định."
    restart
}

check_config() {
    local info=$(${xui_folder}/x-ui setting -show true)
    if [[ $? != 0 ]]; then
        LOGE "Lỗi khi lấy cài đặt hiện tại, vui lòng kiểm tra log (nhật ký)"
        show_menu
        return
    fi
    LOGI "${info}"

    local existing_webBasePath=$(echo "$info" | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(echo "$info" | grep -Eo 'port: .+' | awk '{print $2}')
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    local server_ip=$(curl -s --max-time 3 https://api.ipify.org)
    if [ -z "$server_ip" ]; then
        server_ip=$(curl -s --max-time 3 https://4.ident.me)
    fi

    if [[ -n "$existing_cert" ]]; then
        local domain=$(basename "$(dirname "$existing_cert")")

        if [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            echo -e "${green}Đường dẫn truy cập: https://${domain}:${existing_port}${existing_webBasePath}${plain}"
        else
            echo -e "${green}Đường dẫn truy cập: https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
        fi
    else
        echo -e "${red}⚠ CẢNH BÁO: Chưa cấu hình chứng chỉ SSL!${plain}"
        echo -e "${yellow}Bạn có thể lấy chứng chỉ Let's Encrypt cho địa chỉ IP của mình (có giá trị ~6 ngày, tự động gia hạn).${plain}"
        read -rp "Tạo chứng chỉ SSL cho IP ngay bây giờ? [y/N]: " gen_ssl
        if [[ "$gen_ssl" == "y" || "$gen_ssl" == "Y" ]]; then
            stop >/dev/null 2>&1
            ssl_cert_issue_for_ip
            if [[ $? -eq 0 ]]; then
                echo -e "${green}Đường dẫn truy cập: https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
                # ssl_cert_issue_for_ip đã khởi động lại panel, nhưng cứ đảm bảo nó đang chạy
                start >/dev/null 2>&1
            else
                LOGE "Thiết lập chứng chỉ IP thất bại."
                echo -e "${yellow}Bạn có thể thử lại qua tùy chọn 19 (Quản lý chứng chỉ SSL).${plain}"
                start >/dev/null 2>&1
            fi
        else
            echo -e "${yellow}Đường dẫn truy cập: http://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
            echo -e "${yellow}Để bảo mật, vui lòng cấu hình chứng chỉ SSL bằng tùy chọn 19 (Quản lý chứng chỉ SSL)${plain}"
        fi
    fi
}

set_port() {
    echo -n "Nhập số cổng (Port) [1-65535]: "
    read -r port
    if [[ -z "${port}" ]]; then
        LOGD "Đã hủy"
        before_show_menu
    else
        ${xui_folder}/x-ui setting -port ${port}
        echo -e "Cổng đã được thiết lập. Vui lòng khởi động lại panel ngay bây giờ và sử dụng cổng mới ${green}${port}${plain} để truy cập web panel."
        confirm_restart
    fi
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        LOGI "Panel đang chạy, không cần khởi động lại. Nếu bạn muốn khởi động lại, vui lòng chọn mục Khởi động lại."
    else
        if [[ $release == "alpine" ]]; then
            rc-service x-ui start
        else
            systemctl start x-ui
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            LOGI "Đã khởi động x-ui thành công"
        else
            LOGE "Khởi động panel thất bại. Có thể do thời gian khởi động lâu hơn 2 giây. Vui lòng kiểm tra log (nhật ký) sau!"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

stop() {
    check_status
    if [[ $? == 1 ]]; then
        echo ""
        LOGI "Panel đã dừng, không cần dừng lại nữa!"
    else
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop
        else
            systemctl stop x-ui
        fi
        sleep 2
        check_status
        if [[ $? == 1 ]]; then
            LOGI "Đã dừng x-ui và xray thành công"
        else
            LOGE "Dừng panel thất bại. Có thể do thời gian dừng lâu hơn 2 giây. Vui lòng kiểm tra log (nhật ký) sau!"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart() {
    if [[ $release == "alpine" ]]; then
        rc-service x-ui restart
    else
        systemctl restart x-ui
    fi
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        LOGI "Đã khởi động lại x-ui và xray thành công"
    else
        LOGE "Khởi động lại panel thất bại. Có thể do thời gian khởi động lâu hơn 2 giây. Vui lòng kiểm tra log (nhật ký) sau!"
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart_xray() {
    systemctl reload x-ui
    LOGI "Đã gửi tín hiệu khởi động lại xray-core thành công, vui lòng kiểm tra log để xác nhận xray đã khởi động lại hoàn tất"
    sleep 2
    show_xray_status
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

status() {
    if [[ $release == "alpine" ]]; then
        rc-service x-ui status
    else
        systemctl status x-ui -l
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    if [[ $release == "alpine" ]]; then
        rc-update add x-ui default
    else
        systemctl enable x-ui
    fi
    if [[ $? == 0 ]]; then
        LOGI "Đã thiết lập x-ui tự động chạy khi khởi động VPS thành công"
    else
        LOGE "Thiết lập tự động chạy (Autostart) thất bại"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

disable() {
    if [[ $release == "alpine" ]]; then
        rc-update del x-ui
    else
        systemctl disable x-ui
    fi
    if [[ $? == 0 ]]; then
        LOGI "Đã hủy tự động chạy x-ui khi khởi động VPS thành công"
    else
        LOGE "Hủy tự động chạy thất bại"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_log() {
    if [[ $release == "alpine" ]]; then
        echo -e "${green}\t1.${plain} Nhật ký Debug"
        echo -e "${green}\t0.${plain} Quay lại Menu chính"
        read -rp "Vui lòng chọn một mục: " choice

        case "$choice" in
        0)
            show_menu
            ;;
        1)
            grep -F 'x-ui[' /var/log/messages
            if [[ $# == 0 ]]; then
                before_show_menu
            fi
            ;;
        *)
            echo -e "${red}Lựa chọn không hợp lệ. Vui lòng nhập đúng số tương ứng.${plain}\n"
            show_log
            ;;
        esac
    else
        echo -e "${green}\t1.${plain} Nhật ký Debug"
        echo -e "${green}\t2.${plain} Xóa tất cả nhật ký"
        echo -e "${green}\t0.${plain} Quay lại Menu chính"
        read -rp "Vui lòng chọn một mục: " choice

        case "$choice" in
        0)
            show_menu
            ;;
        1)
            journalctl -u x-ui -e --no-pager -f -p debug
            if [[ $# == 0 ]]; then
                before_show_menu
            fi
            ;;
        2)
            sudo journalctl --rotate
            sudo journalctl --vacuum-time=1s
            echo "Đã xóa toàn bộ nhật ký."
            restart
            ;;
        *)
            echo -e "${red}Lựa chọn không hợp lệ. Vui lòng nhập đúng số tương ứng.${plain}\n"
            show_log
            ;;
        esac
    fi
}

bbr_menu() {
    echo -e "${green}\t1.${plain} Bật BBR (Tăng tốc mạng)"
    echo -e "${green}\t2.${plain} Tắt BBR"
    echo -e "${green}\t0.${plain} Quay lại Menu chính"
    read -rp "Vui lòng chọn một mục: " choice
    case "$choice" in
    0)
        show_menu
        ;;
    1)
        enable_bbr
        bbr_menu
        ;;
    2)
        disable_bbr
        bbr_menu
        ;;
    *)
        echo -e "${red}Lựa chọn không hợp lệ. Vui lòng nhập đúng số tương ứng.${plain}\n"
        bbr_menu
        ;;
    esac
}

disable_bbr() {

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]] || [[ ! $(sysctl -n net.core.default_qdisc) =~ ^(fq|cake)$ ]]; then
        echo -e "${yellow}BBR hiện chưa được bật.${plain}"
        before_show_menu
    fi

    if [ -f "/etc/sysctl.d/99-bbr-x-ui.conf" ]; then
        old_settings=$(head -1 /etc/sysctl.d/99-bbr-x-ui.conf | tr -d '#')
        sysctl -w net.core.default_qdisc="${old_settings%:*}"
        sysctl -w net.ipv4.tcp_congestion_control="${old_settings#*:}"
        rm /etc/sysctl.d/99-bbr-x-ui.conf
        sysctl --system
    else
        # Thay thế cấu hình BBR bằng CUBIC
        if [ -f "/etc/sysctl.conf" ]; then
            sed -i 's/net.core.default_qdisc=fq/net.core.default_qdisc=pfifo_fast/' /etc/sysctl.conf
            sed -i 's/net.ipv4.tcp_congestion_control=bbr/net.ipv4.tcp_congestion_control=cubic/' /etc/sysctl.conf
            sysctl -p
        fi
    fi

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]]; then
        echo -e "${green}Đã thay thế BBR bằng CUBIC thành công.${plain}"
    else
        echo -e "${red}Thay thế BBR bằng CUBIC thất bại. Vui lòng kiểm tra lại cấu hình hệ thống.${plain}"
    fi
}

enable_bbr() {
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]] && [[ $(sysctl -n net.core.default_qdisc) =~ ^(fq|cake)$ ]]; then
        echo -e "${green}BBR đã được bật sẵn rồi!${plain}"
        before_show_menu
    fi

    # Kích hoạt BBR
    if [ -d "/etc/sysctl.d/" ]; then
        {
            echo "#$(sysctl -n net.core.default_qdisc):$(sysctl -n net.ipv4.tcp_congestion_control)"
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        } > "/etc/sysctl.d/99-bbr-x-ui.conf"
        if [ -f "/etc/sysctl.conf" ]; then
            # Sao lưu cài đặt cũ từ sysctl.conf nếu có
            sed -i 's/^net.core.default_qdisc/# &/'          /etc/sysctl.conf
            sed -i 's/^net.ipv4.tcp_congestion_control/# &/' /etc/sysctl.conf
        fi
        sysctl --system
    else
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        echo "net.core.default_qdisc=fq" | tee -a /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" | tee -a /etc/sysctl.conf
        sysctl -p
    fi

    # Kiểm tra xem BBR đã thực sự được bật chưa
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]]; then
        echo -e "${green}Đã kích hoạt BBR thành công.${plain}"
    else
        echo -e "${red}Kích hoạt BBR thất bại. Vui lòng kiểm tra lại cấu hình hệ thống của sếp.${plain}"
    fi
}

update_shell() {
    # Tải file x-ui.sh mới nhất từ kho của sếp
    curl -fLRo /usr/bin/x-ui -z /usr/bin/x-ui https://github.com/vietnamvpn/3x-ui/raw/main/x-ui.sh
    if [[ $? != 0 ]]; then
        echo ""
        LOGE "Tải script thất bại, vui lòng kiểm tra xem VPS có kết nối được tới Github không sếp ơi!"
        before_show_menu
    else
        chmod +x /usr/bin/x-ui
        LOGI "Nâng cấp script thành công, sếp vui lòng chạy lại lệnh x-ui để hưởng thụ nhé!"
        before_show_menu
    fi
}

# 0: đang chạy, 1: không chạy, 2: chưa cài đặt
check_status() {
    if [[ $release == "alpine" ]]; then
        if [[ ! -f /etc/init.d/x-ui ]]; then
            return 2
        fi
        if [[ $(rc-service x-ui status | grep -F 'status: started' -c) == 1 ]]; then
            return 0
        else
            return 1
        fi
    else
        if [[ ! -f ${xui_service}/x-ui.service ]]; then
            return 2
        fi
        temp=$(systemctl status x-ui | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ "${temp}" == "running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

check_enabled() {
    if [[ $release == "alpine" ]]; then
        if [[ $(rc-update show | grep -F 'x-ui' | grep default -c) == 1 ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl is-enabled x-ui)
        if [[ "${temp}" == "enabled" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        LOGE "Panel đã được cài đặt, vui lòng không cài đặt lại sếp ơi!"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        LOGE "Vui lòng cài đặt panel trước khi thực hiện thao tác này."
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
    0)
        echo -e "Trạng thái Panel: ${green}Đang chạy${plain}"
        show_enable_status
        ;;
    1)
        echo -e "Trạng thái Panel: ${yellow}Không chạy${plain}"
        show_enable_status
        ;;
    2)
        echo -e "Trạng thái Panel: ${red}Chưa cài đặt${plain}"
        ;;
    esac
    show_xray_status
}

show_enable_status() {
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "Tự động chạy khi khởi động: ${green}Có${plain}"
    else
        echo -e "Tự động chạy khi khởi động: ${red}Không${plain}"
    fi
}

check_xray_status() {
    count=$(ps -ef | grep "xray-linux" | grep -v "grep" | wc -l)
    if [[ count -ne 0 ]]; then
        return 0
    else
        return 1
    fi
}

show_xray_status() {
    check_xray_status
    if [[ $? == 0 ]]; then
        echo -e "Trạng thái xray: ${green}Đang chạy${plain}"
    else
        echo -e "Trạng thái xray: ${red}Không chạy${plain}"
    fi
}

firewall_menu() {
    echo -e "${green}\t1.${plain} ${green}Cài đặt${plain} Firewall (Tường lửa)"
    echo -e "${green}\t2.${plain} Danh sách Port [đánh số]"
    echo -e "${green}\t3.${plain} ${green}Mở${plain} Ports"
    echo -e "${green}\t4.${plain} ${red}Xóa${plain} Port khỏi danh sách"
    echo -e "${green}\t5.${plain} ${green}Bật${plain} Firewall"
    echo -e "${green}\t6.${plain} ${red}Tắt${plain} Firewall"
    echo -e "${green}\t7.${plain} Trạng thái Firewall"
    echo -e "${green}\t0.${plain} Quay lại Menu chính"
    read -rp "Vui lòng chọn một mục: " choice
    case "$choice" in
    0)
        show_menu
        ;;
    1)
        install_firewall
        firewall_menu
        ;;
    2)
        ufw status numbered
        firewall_menu
        ;;
    3)
        open_ports
        firewall_menu
        ;;
    4)
        delete_ports
        firewall_menu
        ;;
    5)
        ufw enable
        firewall_menu
        ;;
    6)
        ufw disable
        firewall_menu
        ;;
    7)
        ufw status verbose
        firewall_menu
        ;;
    *)
        echo -e "${red}Lựa chọn không hợp lệ. Vui lòng nhập đúng số tương ứng.${plain}\n"
        firewall_menu
        ;;
    esac
}

install_firewall() {
    if ! command -v ufw &>/dev/null; then
        echo "Firewall UFW chưa được cài đặt. Đang tiến hành cài đặt..."
        apt-get update
        apt-get install -y ufw
    else
        echo "Firewall UFW đã được cài đặt sẵn rồi."
    fi

    # Kiểm tra xem firewall đã hoạt động chưa
    if ufw status | grep -q "Status: active"; then
        echo "Firewall hiện đang hoạt động."
    else
        echo "Đang kích hoạt Firewall..."
        # Mở các port cần thiết để không bị khóa SSH
        ufw allow ssh
        ufw allow http
        ufw allow https
        ufw allow 2053/tcp #webPort mặc định
        ufw allow 2096/tcp #subport mặc định

        # Kích hoạt firewall
        ufw --force enable
        echo "Firewall đã được kích hoạt và các port cơ bản đã được mở."
    fi
}

open_ports() {
    # Yêu cầu người dùng nhập các cổng muốn mở
    read -rp "Nhập các cổng sếp muốn mở (vídụ: 80,443,2053 hoặc dải cổng 400-500): " ports

    # Kiểm tra xem đầu vào có hợp lệ không
    if ! [[ $ports =~ ^([0-9]+|[0-9]+-[0-9]+)(,([0-9]+|[0-9]+-[0-9]+))*$ ]]; then
        echo -e "${red}Lỗi: Đầu vào không hợp lệ. Vui lòng nhập danh sách cổng cách nhau bằng dấu phẩy hoặc một dải cổng (ví dụ: 80,443,2053 hoặc 400-500).${plain}" >&2
        exit 1
    fi

    # Mở các cổng đã chỉ định bằng ufw
    IFS=',' read -ra PORT_LIST <<<"$ports"
    for port in "${PORT_LIST[@]}"; do
        if [[ $port == *-* ]]; then
            # Chia dải cổng thành cổng bắt đầu và cổng kết thúc
            start_port=$(echo $port | cut -d'-' -f1)
            end_port=$(echo $port | cut -d'-' -f2)
            # Mở dải cổng cho cả tcp và udp
            ufw allow $start_port:$end_port/tcp
            ufw allow $start_port:$end_port/udp
        else
            # Mở cổng đơn lẻ
            ufw allow "$port"
        fi
    done

    # Xác nhận các cổng đã được mở
    echo "Đã mở các cổng sau:"
    for port in "${PORT_LIST[@]}"; do
        if [[ $port == *-* ]]; then
            start_port=$(echo $port | cut -d'-' -f1)
            end_port=$(echo $port | cut -d'-' -f2)
            # Kiểm tra xem dải cổng đã được mở thành công chưa
            (ufw status | grep -q "$start_port:$end_port") && echo "$start_port-$end_port"
        else
            # Kiểm tra xem cổng đơn lẻ đã được mở thành công chưa
            (ufw status | grep -q "$port") && echo "$port"
        fi
    done
}

delete_ports() {
    # Hiển thị các quy tắc hiện tại kèm số thứ tự
    echo "Các quy tắc UFW hiện tại:"
    ufw status numbered

    # Hỏi người dùng muốn xóa quy tắc theo cách nào
    echo "Sếp muốn xóa quy tắc theo:"
    echo "1) Số thứ tự quy tắc"
    echo "2) Số cổng (Port)"
    read -rp "Nhập lựa chọn của sếp (1 hoặc 2): " choice

    if [[ $choice -eq 1 ]]; then
        # Xóa theo số thứ tự quy tắc
        read -rp "Nhập số thứ tự quy tắc muốn xóa (ví dụ: 1,2,5): " rule_numbers

        # Kiểm tra đầu vào
        if ! [[ $rule_numbers =~ ^([0-9]+)(,[0-9]+)*$ ]]; then
            echo -e "${red}Lỗi: Đầu vào không hợp lệ. Vui lòng nhập danh sách số thứ tự cách nhau bằng dấu phẩy.${plain}" >&2
            exit 1
        fi

        # Chia các số vào một mảng
        IFS=',' read -ra RULE_NUMBERS <<<"$rule_numbers"
        for rule_number in "${RULE_NUMBERS[@]}"; do
            # Xóa quy tắc theo số thứ tự
            ufw delete "$rule_number" || echo "Không thể xóa quy tắc số $rule_number"
        done

        echo "Các quy tắc đã chọn đã được xóa."

    elif [[ $choice -eq 2 ]]; then
        # Xóa theo số cổng
        read -rp "Nhập các cổng sếp muốn xóa (ví dụ: 80,443 hoặc dải 400-500): " ports

        # Kiểm tra đầu vào
        if ! [[ $ports =~ ^([0-9]+|[0-9]+-[0-9]+)(,([0-9]+|[0-9]+-[0-9]+))*$ ]]; then
            echo -e "${red}Lỗi: Đầu vào không hợp lệ. Vui lòng nhập danh sách cổng hoặc dải cổng.${plain}" >&2
            exit 1
        fi

        # Chia các cổng vào một mảng
        IFS=',' read -ra PORT_LIST <<<"$ports"
        for port in "${PORT_LIST[@]}"; do
            if [[ $port == *-* ]]; then
                # Chia dải cổng
                start_port=$(echo $port | cut -d'-' -f1)
                end_port=$(echo $port | cut -d'-' -f2)
                # Xóa dải cổng
                ufw delete allow $start_port:$end_port/tcp
                ufw delete allow $start_port:$end_port/udp
            else
                # Xóa cổng đơn lẻ
                ufw delete allow "$port"
            fi
        done

        # Xác nhận việc xóa
        echo "Đã xóa các cổng đã chỉ định:"
        for port in "${PORT_LIST[@]}"; do
            if [[ $port == *-* ]]; then
                start_port=$(echo $port | cut -d'-' -f1)
                end_port=$(echo $port | cut -d'-' -f2)
                # Kiểm tra xem dải cổng đã thực sự được xóa chưa
                (ufw status | grep -q "$start_port:$end_port") || echo "$start_port-$end_port"
            else
                # Kiểm tra xem cổng đơn lẻ đã thực sự được xóa chưa
                (ufw status | grep -q "$port") || echo "$port"
            fi
        done
    else
        echo -e "${red}Lỗi:${plain} Lựa chọn không hợp lệ. Vui lòng nhập 1 hoặc 2." >&2
        exit 1
    fi
}

update_all_geofiles() {
    update_geofiles "main"
    update_geofiles "IR"
    update_geofiles "RU"
}

update_geofiles() {
    case "${1}" in
      "main") dat_files=(geoip geosite); dat_source="Loyalsoldier/v2ray-rules-dat";;
        "IR") dat_files=(geoip_IR geosite_IR); dat_source="chocolate4u/Iran-v2ray-rules" ;;
        "RU") dat_files=(geoip_RU geosite_RU); dat_source="runetfreedom/russia-v2ray-rules-dat";;
    esac
    for dat in "${dat_files[@]}"; do
        # Xóa hậu tố cho tên tệp từ xa (ví dụ: geoip_IR -> geoip)
        remote_file="${dat%%_*}"
        curl -fLRo ${xui_folder}/bin/${dat}.dat -z ${xui_folder}/bin/${dat}.dat \
            https://github.com/${dat_source}/releases/latest/download/${remote_file}.dat
    done
}

update_geo() {
    echo -e "${green}\t1.${plain} Loyalsoldier (geoip.dat, geosite.dat)"
    echo -e "${green}\t2.${plain} chocolate4u (geoip_IR.dat, geosite_IR.dat)"
    echo -e "${green}\t3.${plain} runetfreedom (geoip_RU.dat, geosite_RU.dat)"
    echo -e "${green}\t4.${plain} Cập nhật tất cả"
    echo -e "${green}\t0.${plain} Quay lại Menu chính"
    read -rp "Vui lòng chọn một mục: " choice

    case "$choice" in
    0)
        show_menu
        ;;
    1)
        update_geofiles "main"
        echo -e "${green}Dữ liệu Loyalsoldier đã được cập nhật thành công!${plain}"
        restart
        ;;
    2)
        update_geofiles "IR"
        echo -e "${green}Dữ liệu chocolate4u đã được cập nhật thành công!${plain}"
        restart
        ;;
    3)
        update_geofiles "RU"
        echo -e "${green}Dữ liệu runetfreedom đã được cập nhật thành công!${plain}"
        restart
        ;;
    4)
        update_all_geofiles
        echo -e "${green}Tất cả các tệp Geo đã được cập nhật thành công!${plain}"
        restart
        ;;
    *)
        echo -e "${red}Lựa chọn không hợp lệ. Vui lòng nhập đúng số tương ứng sếp ơi!${plain}\n"
        update_geo
        ;;
    esac

    before_show_menu
}

install_acme() {
    # Kiểm tra xem acme.sh đã được cài đặt chưa
    if command -v ~/.acme.sh/acme.sh &>/dev/null; then
        LOGI "acme.sh đã được cài đặt sẵn rồi."
        return 0
    fi

    LOGI "Đang tiến hành cài đặt acme.sh..."
    cd ~ || return 1 # Đảm bảo có thể chuyển về thư mục home

    curl -s https://get.acme.sh | sh
    if [ $? -ne 0 ]; then
        LOGE "Cài đặt acme.sh thất bại."
        return 1
    else
        LOGI "Cài đặt acme.sh thành công rực rỡ!"
    fi

    return 0
}

ssl_cert_issue_main() {
    echo -e "${green}\t1.${plain} Lấy SSL cho Tên miền (Domain)"
    echo -e "${green}\t2.${plain} Thu hồi chứng chỉ (Revoke)"
    echo -e "${green}\t3.${plain} Gia hạn cưỡng bức (Force Renew)"
    echo -e "${green}\t4.${plain} Xem danh sách Tên miền hiện có"
    echo -e "${green}\t5.${plain} Thiết lập đường dẫn Cert cho Panel"
    echo -e "${green}\t6.${plain} Lấy SSL cho địa chỉ IP (Cert 6 ngày, tự động gia hạn)"
    echo -e "${green}\t0.${plain} Quay lại Menu chính"

    read -rp "Vui lòng chọn một mục: " choice
    case "$choice" in
    0)
        show_menu
        ;;
    1)
        ssl_cert_issue
        ssl_cert_issue_main
        ;;
    2)
        local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
        if [ -z "$domains" ]; then
            echo "Không tìm thấy chứng chỉ nào để thu hồi."
        else
            echo "Các tên miền hiện có:"
            echo "$domains"
            read -rp "Vui lòng nhập tên miền từ danh sách để thu hồi chứng chỉ: " domain
            if echo "$domains" | grep -qw "$domain"; then
                ~/.acme.sh/acme.sh --revoke -d ${domain}
                LOGI "Đã thu hồi chứng chỉ cho tên miền: $domain"
            else
                echo "Tên miền nhập vào không hợp lệ."
            fi
        fi
        ssl_cert_issue_main
        ;;
    3)
        local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
        if [ -z "$domains" ]; then
            echo "Không tìm thấy chứng chỉ nào để gia hạn."
        else
            echo "Các tên miền hiện có:"
            echo "$domains"
            read -rp "Vui lòng nhập tên miền từ danh sách để gia hạn chứng chỉ SSL: " domain
            if echo "$domains" | grep -qw "$domain"; then
                ~/.acme.sh/acme.sh --renew -d ${domain} --force
                LOGI "Đã cưỡng bức gia hạn chứng chỉ thành công cho tên miền: $domain"
            else
                echo "Tên miền nhập vào không hợp lệ."
            fi
        fi
        ssl_cert_issue_main
        ;;
    4)
        local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
        if [ -z "$domains" ]; then
            echo "Không tìm thấy chứng chỉ nào."
        else
            echo "Các tên miền hiện có và đường dẫn của chúng:"
            for domain in $domains; do
                local cert_path="/root/cert/${domain}/fullchain.pem"
                local key_path="/root/cert/${domain}/privkey.pem"
                if [[ -f "${cert_path}" && -f "${key_path}" ]]; then
                    echo -e "Tên miền: ${domain}"
                    echo -e "\tĐường dẫn Chứng chỉ: ${cert_path}"
                    echo -e "\tĐường dẫn Khóa riêng: ${key_path}"
                else
                    echo -e "Tên miền: ${domain} - Thiếu Chứng chỉ hoặc Khóa."
                fi
            done
        fi
        ssl_cert_issue_main
        ;;
    5)
        local domains=$(find /root/cert/ -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)
        if [ -z "$domains" ]; then
            echo "Không tìm thấy chứng chỉ nào."
        else
            echo "Các tên miền khả dụng:"
            echo "$domains"
            read -rp "Vui lòng chọn một tên miền để thiết lập đường dẫn cho panel: " domain

            if echo "$domains" | grep -qw "$domain"; then
                local webCertFile="/root/cert/${domain}/fullchain.pem"
                local webKeyFile="/root/cert/${domain}/privkey.pem"

                if [[ -f "${webCertFile}" && -f "${webKeyFile}" ]]; then
                    ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
                    echo "Đã thiết lập đường dẫn panel cho tên miền: $domain"
                    echo "  - Tệp Chứng chỉ: $webCertFile"
                    echo "  - Tệp Khóa riêng: $webKeyFile"
                    restart
                else
                    echo "Không tìm thấy chứng chỉ hoặc khóa riêng cho tên miền: $domain."
                fi
            else
                echo "Tên miền nhập vào không hợp lệ."
            fi
        fi
        ssl_cert_issue_main
        ;;
    6)
        echo -e "${yellow}Chứng chỉ SSL Let's Encrypt cho địa chỉ IP${plain}"
        echo -e "Thao tác này sẽ lấy chứng chỉ cho IP máy chủ của sếp bằng cấu hình 'shortlived'."
        echo -e "${yellow}Chứng chỉ có hiệu lực ~6 ngày, tự động gia hạn qua cron job của acme.sh.${plain}"
        echo -e "${yellow}Lưu ý: Cổng 80 phải được mở và có thể truy cập từ internet.${plain}"
        confirm "Sếp có muốn tiếp tục không?" "y"
        if [[ $? == 0 ]]; then
            ssl_cert_issue_for_ip
        fi
        ssl_cert_issue_main
        ;;

    *)
        echo -e "${red}Lựa chọn không hợp lệ. Vui lòng nhập đúng số sếp ơi!${plain}\n"
        ssl_cert_issue_main
        ;;
    esac
}

ssl_cert_issue_for_ip() {
    LOGI "Bắt đầu quy trình tự động tạo chứng chỉ SSL cho IP máy chủ..."
    LOGI "Sử dụng cấu hình Let's Encrypt shortlived (có hiệu lực ~6 ngày, tự động gia hạn)"
    
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    
    # Lấy địa chỉ IP máy chủ
    local server_ip=$(curl -s --max-time 3 https://api.ipify.org)
    if [ -z "$server_ip" ]; then
        server_ip=$(curl -s --max-time 3 https://4.ident.me)
    fi
    
    if [ -z "$server_ip" ]; then
        LOGE "Không thể lấy địa chỉ IP của máy chủ sếp ơi!"
        return 1
    fi
    
    LOGI "Đã phát hiện IP máy chủ: ${server_ip}"
    
    # Hỏi về địa chỉ IPv6 (tùy chọn)
    local ipv6_addr=""
    read -rp "Sếp có địa chỉ IPv6 nào muốn thêm vào không? (để trống nếu muốn bỏ qua): " ipv6_addr
    ipv6_addr="${ipv6_addr// /}"  # Xóa khoảng trắng
    
    # Kiểm tra acme.sh trước
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
        LOGI "Không tìm thấy acme.sh, đang tiến hành cài đặt..."
        install_acme
        if [ $? -ne 0 ]; then
            LOGE "Cài đặt acme.sh thất bại rồi sếp!"
            return 1
        fi
    fi
    
    # Cài đặt socat
    case "${release}" in
    ubuntu | debian | armbian)
        apt-get update >/dev/null 2>&1 && apt-get install socat -y >/dev/null 2>&1
        ;;
    fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
        dnf -y update >/dev/null 2>&1 && dnf -y install socat >/dev/null 2>&1
        ;;
    centos)
        if [[ "${VERSION_ID}" =~ ^7 ]]; then
            yum -y update >/dev/null 2>&1 && yum -y install socat >/dev/null 2>&1
        else
            dnf -y update >/dev/null 2>&1 && dnf -y install socat >/dev/null 2>&1
        fi
        ;;
    arch | manjaro | parch)
        pacman -Sy --noconfirm socat >/dev/null 2>&1
        ;;
    opensuse-tumbleweed | opensuse-leap)
        zypper refresh >/dev/null 2>&1 && zypper -q install -y socat >/dev/null 2>&1
        ;;
    alpine)
        apk add socat curl openssl >/dev/null 2>&1
        ;;
    *)
        LOGW "Hệ điều hành này không hỗ trợ cài đặt socat tự động"
        ;;
    esac
    
    # Tạo thư mục chứa chứng chỉ
    certPath="/root/cert/ip"
    mkdir -p "$certPath"
    
    # Xây dựng các tham số tên miền (IP)
    local domain_args="-d ${server_ip}"
    if [[ -n "$ipv6_addr" ]] && is_ipv6 "$ipv6_addr"; then
        domain_args="${domain_args} -d ${ipv6_addr}"
        LOGI "Đã bao gồm địa chỉ IPv6: ${ipv6_addr}"
    fi
 # Chọn cổng cho bộ lắng nghe HTTP-01 (mặc định 80)
    local WebPort=""
    read -rp "Cổng sử dụng cho bộ lắng nghe ACME HTTP-01 (mặc định 80): " WebPort
    WebPort="${WebPort:-80}"
    if ! [[ "${WebPort}" =~ ^[0-9]+$ ]] || ((WebPort < 1 || WebPort > 65535)); then
        LOGE "Cổng không hợp lệ. Đang quay lại cổng mặc định 80."
        WebPort=80
    fi
    LOGI "Đang sử dụng cổng ${WebPort} để cấp chứng chỉ cho IP: ${server_ip}"
    if [[ "${WebPort}" -ne 80 ]]; then
        LOGI "Lưu ý: Let's Encrypt vẫn sẽ truy cập qua cổng 80; sếp cần chuyển hướng (forward) cổng 80 bên ngoài về cổng ${WebPort} để xác thực nhé."
    fi

    while true; do
        if is_port_in_use "${WebPort}"; then
            LOGI "Cổng ${WebPort} hiện đang được sử dụng rồi sếp ơi."

            local alt_port=""
            read -rp "Nhập cổng khác cho acme.sh (để trống để hủy bỏ): " alt_port
            alt_port="${alt_port// /}"
            if [[ -z "${alt_port}" ]]; then
                LOGE "Cổng ${WebPort} đang bận; không thể tiếp tục cấp chứng chỉ."
                return 1
            fi
            if ! [[ "${alt_port}" =~ ^[0-9]+$ ]] || ((alt_port < 1 || alt_port > 65535)); then
                LOGE "Cổng sếp nhập không hợp lệ."
                return 1
            fi
            WebPort="${alt_port}"
            continue
        else
            LOGI "Cổng ${WebPort} đang trống và sẵn sàng để xác thực."
            break
        fi
    done
    
    # Lệnh nạp lại - khởi động lại panel sau khi gia hạn
    local reloadCmd="systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null"
    
    # Tiến hành cấp chứng chỉ cho IP với cấu hình shortlived
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
    ~/.acme.sh/acme.sh --issue \
        ${domain_args} \
        --standalone \
        --server letsencrypt \
        --certificate-profile shortlived \
        --days 6 \
        --httpport ${WebPort} \
        --force
    
    if [ $? -ne 0 ]; then
        LOGE "Cấp chứng chỉ thất bại cho IP: ${server_ip}"
        LOGE "Sếp hãy đảm bảo cổng ${WebPort} đã được mở và máy chủ có thể truy cập được từ internet."
        # Dọn dẹp dữ liệu tạm nếu thất bại
        rm -rf ~/.acme.sh/${server_ip} 2>/dev/null
        [[ -n "$ipv6_addr" ]] && rm -rf ~/.acme.sh/${ipv6_addr} 2>/dev/null
        rm -rf ${certPath} 2>/dev/null
        return 1
    else
        LOGI "Chúc mừng sếp! Đã cấp chứng chỉ thành công cho IP: ${server_ip}"
    fi
    # Cài đặt chứng chỉ
    # Lưu ý: acme.sh có thể báo "Reload error" nếu reloadcmd thất bại,
    # nhưng tệp cert vẫn được cài đặt. Chúng ta kiểm tra tệp thay vì mã thoát (exit code).
    ~/.acme.sh/acme.sh --installcert -d ${server_ip} \
        --key-file "${certPath}/privkey.pem" \
        --fullchain-file "${certPath}/fullchain.pem" \
        --reloadcmd "${reloadCmd}" 2>&1 || true
    
    # Xác minh tệp chứng chỉ tồn tại
    if [[ ! -f "${certPath}/fullchain.pem" || ! -f "${certPath}/privkey.pem" ]]; then
        LOGE "Không tìm thấy tệp chứng chỉ sau khi cài đặt sếp ơi!"
        # Dọn dẹp dữ liệu acme.sh
        rm -rf ~/.acme.sh/${server_ip} 2>/dev/null
        [[ -n "$ipv6_addr" ]] && rm -rf ~/.acme.sh/${ipv6_addr} 2>/dev/null
        rm -rf ${certPath} 2>/dev/null
        return 1
    fi
    
    LOGI "Đã cài đặt các tệp chứng chỉ thành công."
    
    # Bật tự động gia hạn
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
    chmod 600 $certPath/privkey.pem 2>/dev/null
    chmod 644 $certPath/fullchain.pem 2>/dev/null
    
    # Thiết lập đường dẫn chứng chỉ cho panel
    local webCertFile="${certPath}/fullchain.pem"
    local webKeyFile="${certPath}/privkey.pem"
    
    if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
        ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
        LOGI "Đã cấu hình chứng chỉ cho panel."
        LOGI "  - Tệp Chứng chỉ: $webCertFile"
        LOGI "  - Tệp Khóa riêng: $webKeyFile"
        LOGI "  - Thời hạn: ~6 ngày (tự động gia hạn qua acme.sh cron)"
        echo -e "${green}Đường dẫn truy cập: https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
        LOGI "Panel sẽ khởi động lại để áp dụng chứng chỉ SSL..."
        restart
        return 0
    else
        LOGE "Không tìm thấy tệp chứng chỉ sau khi cài đặt."
        return 1
    fi
}

ssl_cert_issue() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    
    # Kiểm tra acme.sh trước
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
        echo "Không tìm thấy acme.sh. Hệ thống sẽ tiến hành cài đặt..."
        install_acme
        if [ $? -ne 0 ]; then
            LOGE "Cài đặt acme.sh thất bại, vui lòng kiểm tra log sếp nhé."
            exit 1
        fi
    fi

    # Cài đặt socat
    case "${release}" in
    ubuntu | debian | armbian)
        apt-get update >/dev/null 2>&1 && apt-get install socat -y >/dev/null 2>&1
        ;;
    fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
        dnf -y update >/dev/null 2>&1 && dnf -y install socat >/dev/null 2>&1
        ;;
    centos)
        if [[ "${VERSION_ID}" =~ ^7 ]]; then
            yum -y update >/dev/null 2>&1 && yum -y install socat >/dev/null 2>&1
        else
            dnf -y update >/dev/null 2>&1 && dnf -y install socat >/dev/null 2>&1
        fi
        ;;
    arch | manjaro | parch)
        pacman -Sy --noconfirm socat >/dev/null 2>&1
        ;;
    opensuse-tumbleweed | opensuse-leap)
        zypper refresh >/dev/null 2>&1 && zypper -q install -y socat >/dev/null 2>&1
        ;;
    alpine)
        apk add socat curl openssl >/dev/null 2>&1
        ;;
    *)
        LOGW "Hệ điều hành này không hỗ trợ cài đặt socat tự động."
        ;;
    esac

    if [ $? -ne 0 ]; then
        LOGE "Cài đặt socat thất bại, vui lòng kiểm tra lại sếp ơi!"
        exit 1
    else
        LOGI "Cài đặt socat thành công..."
    fi
# Lấy tên miền và xác thực
    local domain=""
    while true; do
        read -rp "Vui lòng nhập tên miền của sếp: " domain
        domain="${domain// /}"  # Xóa khoảng trắng
        
        if [[ -z "$domain" ]]; then
            LOGE "Tên miền không được để trống. Vui lòng thử lại sếp ơi."
            continue
        fi
        
        if ! is_domain "$domain"; then
            LOGE "Định dạng tên miền không hợp lệ: ${domain}. Sếp kiểm tra lại nhé."
            continue
        fi
        
        break
    done
    LOGD "Tên miền của sếp là: ${domain}, đang tiến hành kiểm tra..."

    # Kiểm tra xem chứng chỉ đã tồn tại chưa
    local currentCert=$(~/.acme.sh/acme.sh --list | tail -1 | awk '{print $1}')
    if [ "${currentCert}" == "${domain}" ]; then
        local certInfo=$(~/.acme.sh/acme.sh --list)
        LOGE "Hệ thống đã có chứng chỉ cho tên miền này rồi, không cần cấp lại đâu sếp. Chi tiết hiện tại:"
        LOGI "$certInfo"
        exit 1
    else
        LOGI "Tên miền của sếp đã sẵn sàng để cấp chứng chỉ mới..."
    fi

    # Tạo thư mục lưu trữ chứng chỉ
    certPath="/root/cert/${domain}"
    if [ ! -d "$certPath" ]; then
        mkdir -p "$certPath"
    else
        rm -rf "$certPath"
        mkdir -p "$certPath"
    fi

    # Lấy số cổng cho chế độ standalone
    local WebPort=80
    read -rp "Vui lòng chọn cổng sếp muốn sử dụng (mặc định là 80): " WebPort
    if [[ ${WebPort} -gt 65535 || ${WebPort} -lt 1 ]]; then
        LOGE "Cổng ${WebPort} không hợp lệ, hệ thống sẽ dùng cổng mặc định 80."
        WebPort=80
    fi
    LOGI "Sẽ sử dụng cổng: ${WebPort} để cấp chứng chỉ. Sếp nhớ mở cổng này trên Firewall nhé!"

    # Tiến hành cấp chứng chỉ
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
    ~/.acme.sh/acme.sh --issue -d ${domain} --listen-v6 --standalone --httpport ${WebPort} --force
    if [ $? -ne 0 ]; then
        LOGE "Cấp chứng chỉ thất bại rồi sếp, vui lòng kiểm tra lại log xem sao."
        rm -rf ~/.acme.sh/${domain}
        exit 1
    else
        LOGI "Cấp chứng chỉ thành công rực rỡ! Đang tiến hành cài đặt..."
    fi

    reloadCmd="x-ui restart"

    LOGI "Lệnh nạp lại (--reloadcmd) mặc định là: ${yellow}x-ui restart${plain}"
    LOGI "Lệnh này sẽ chạy mỗi khi chứng chỉ được cấp mới hoặc gia hạn."
    read -rp "Sếp có muốn thay đổi lệnh nạp lại này không? (y/n): " setReloadcmd
    if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
        echo -e "\n${green}\t1.${plain} Mẫu sẵn: systemctl reload nginx ; x-ui restart"
        echo -e "${green}\t2.${plain} Sếp tự nhập lệnh mới"
        echo -e "${green}\t0.${plain} Giữ lệnh mặc định"
        read -rp "Vui lòng chọn một mục: " choice
        case "$choice" in
        1)
            LOGI "Lệnh nạp lại là: systemctl reload nginx ; x-ui restart"
            reloadCmd="systemctl reload nginx ; x-ui restart"
            ;;
        2)  
            LOGD "Gợi ý: Sếp nên để 'x-ui restart' ở cuối cùng để tránh lỗi nếu các dịch vụ khác gặp sự cố."
            read -rp "Vui lòng nhập lệnh của sếp (ví dụ: systemctl reload nginx ; x-ui restart): " reloadCmd
            LOGI "Lệnh của sếp là: ${reloadCmd}"
            ;;
        *)
            LOGI "Giữ nguyên lệnh mặc định."
            ;;
        esac
    fi
 # Cài đặt chứng chỉ
    # Lưu ý: acme.sh có thể báo lỗi nạp lại (Reload error) nếu reloadcmd thất bại,
    # nhưng tệp chứng chỉ vẫn được cài đặt. Chúng ta kiểm tra tệp thay vì mã thoát.
    ~/.acme.sh/acme.sh --installcert -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem --reloadcmd "${reloadCmd}"

    if [ $? -ne 0 ]; then
        LOGE "Cài đặt chứng chỉ thất bại, đang thoát..."
        rm -rf ~/.acme.sh/${domain}
        exit 1
    else
        LOGI "Cài đặt chứng chỉ thành công, đang bật tự động gia hạn..."
    fi

    # Bật tự động gia hạn
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        LOGE "Tự động gia hạn thất bại, chi tiết chứng chỉ:"
        ls -lah cert/*
        chmod 600 $certPath/privkey.pem
        chmod 644 $certPath/fullchain.pem
        exit 1
    else
        LOGI "Tự động gia hạn thành công, chi tiết chứng chỉ:"
        ls -lah cert/*
        chmod 600 $certPath/privkey.pem
        chmod 644 $certPath/fullchain.pem
    fi

    # Hỏi người dùng thiết lập đường dẫn cho panel sau khi cài đặt thành công
    read -rp "Sếp có muốn thiết lập chứng chỉ này cho panel luôn không? (y/n): " setPanel
    if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
        local webCertFile="/root/cert/${domain}/fullchain.pem"
        local webKeyFile="/root/cert/${domain}/privkey.pem"

        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            LOGI "Đã thiết lập đường dẫn panel cho tên miền: $domain"
            LOGI "  - Tệp Chứng chỉ: $webCertFile"
            LOGI "  - Tệp Khóa riêng: $webKeyFile"
            echo -e "${green}Đường dẫn truy cập: https://${domain}:${existing_port}${existing_webBasePath}${plain}"
            restart
        else
            LOGE "Lỗi: Không tìm thấy tệp chứng chỉ hoặc khóa riêng cho tên miền: $domain."
        fi
    else
        LOGI "Bỏ qua thiết lập đường dẫn panel."
    fi
}

ssl_cert_issue_CF() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    LOGI "****** Hướng dẫn sử dụng ******"
    LOGI "Sếp thực hiện theo các bước dưới đây để hoàn tất quá trình:"
    LOGI "1. Chuẩn bị Email đăng ký Cloudflare."
    LOGI "2. Chuẩn bị Cloudflare Global API Key."
    LOGI "3. Nhập đúng Tên miền (Domain) đã trỏ về máy chủ."
    LOGI "4. Sau khi cấp xong, sếp sẽ được hỏi để thiết lập SSL cho panel (tùy chọn)."
    LOGI "5. Script hỗ trợ tự động gia hạn chứng chỉ SSL sau khi cài đặt."

    confirm "Sếp xác nhận thông tin và muốn tiếp tục chứ? [y/n]" "y"

    if [ $? -eq 0 ]; then
        # Kiểm tra acme.sh trước
        if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
            echo "Không tìm thấy acme.sh. Hệ thống sẽ tiến hành cài đặt cho sếp."
            install_acme
            if [ $? -ne 0 ]; then
                LOGE "Cài đặt acme thất bại, sếp vui lòng kiểm tra log nhé."
                exit 1
            fi
        fi

        CF_Domain=""

        LOGD "Thiết lập tên miền (Domain):"
        read -rp "Nhập tên miền của sếp vào đây: " CF_Domain
        LOGD "Tên miền đã đặt là: ${CF_Domain}"

        # Thiết lập chi tiết Cloudflare API
        CF_GlobalKey=""
        CF_AccountEmail=""
        LOGD "Thiết lập API Key:"
        read -rp "Nhập Global API Key của sếp vào đây: " CF_GlobalKey
        LOGD "API Key đã nhận: ${CF_GlobalKey}"

        LOGD "Thiết lập Email đăng ký:"
        read -rp "Nhập Email Cloudflare của sếp vào đây: " CF_AccountEmail
        LOGD "Email đã nhận: ${CF_AccountEmail}"

     # Thiết lập CA mặc định sang Let's Encrypt
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
        if [ $? -ne 0 ]; then
            LOGE "Thiết lập CA mặc định Let's Encrypt thất bại, đang thoát script..."
            exit 1
        fi

        export CF_Key="${CF_GlobalKey}"
        export CF_Email="${CF_AccountEmail}"

        # Cấp chứng chỉ sử dụng Cloudflare DNS
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${CF_Domain} -d *.${CF_Domain} --log --force
        if [ $? -ne 0 ]; then
            LOGE "Cấp chứng chỉ thất bại, đang thoát script..."
            exit 1
        else
            LOGI "Cấp chứng chỉ thành công, đang tiến hành cài đặt..."
        fi

         # Cài đặt chứng chỉ
        certPath="/root/cert/${CF_Domain}"
        if [ -d "$certPath" ]; then
            rm -rf ${certPath}
        fi

        mkdir -p ${certPath}
        if [ $? -ne 0 ]; then
            LOGE "Không thể tạo thư mục: ${certPath}"
            exit 1
        fi

        reloadCmd="x-ui restart"

        LOGI "Lệnh nạp lại (--reloadcmd) mặc định cho ACME là: ${yellow}x-ui restart${plain}"
        LOGI "Lệnh này sẽ chạy mỗi khi cấp mới hoặc gia hạn chứng chỉ."
        read -rp "Sếp có muốn thay đổi lệnh nạp lại (--reloadcmd) không? (y/n): " setReloadcmd
        if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
            echo -e "\n${green}\t1.${plain} Mẫu sẵn: systemctl reload nginx ; x-ui restart"
            echo -e "${green}\t2.${plain} Sếp tự nhập lệnh"
            echo -e "${green}\t0.${plain} Giữ lệnh mặc định"
            read -rp "Vui lòng chọn một mục: " choice
            case "$choice" in
            1)
                LOGI "Lệnh nạp lại là: systemctl reload nginx ; x-ui restart"
                reloadCmd="systemctl reload nginx ; x-ui restart"
                ;;
            2)  
                LOGD "Gợi ý: Sếp nên để 'x-ui restart' ở cuối cùng để tránh lỗi nếu các dịch vụ khác gặp sự cố."
                read -rp "Vui lòng nhập lệnh của sếp (ví dụ: systemctl reload nginx ; x-ui restart): " reloadCmd
                LOGI "Lệnh của sếp là: ${reloadCmd}"
                ;;
            *)
                LOGI "Giữ lệnh mặc định."
                ;;
            esac
        fi
        ~/.acme.sh/acme.sh --installcert -d ${CF_Domain} -d *.${CF_Domain} \
            --key-file ${certPath}/privkey.pem \
            --fullchain-file ${certPath}/fullchain.pem --reloadcmd "${reloadCmd}"
        
        if [ $? -ne 0 ]; then
            LOGE "Cài đặt chứng chỉ thất bại, đang thoát script..."
            exit 1
        else
            LOGI "Cài đặt chứng chỉ thành công, đang bật tự động cập nhật..."
        fi

        # Bật tự động cập nhật
        ~/.acme.sh/acme.sh --upgrade --auto-upgrade
        if [ $? -ne 0 ]; then
            LOGE "Thiết lập tự động cập nhật thất bại, đang thoát script..."
            exit 1
        else
            LOGI "Chứng chỉ đã được cài đặt và tính năng tự động gia hạn đã được bật. Thông tin chi tiết như sau:"
            ls -lah ${certPath}/*
            chmod 600 ${certPath}/privkey.pem
            chmod 644 ${certPath}/fullchain.pem
        fi

        # Hỏi người dùng thiết lập đường dẫn cho panel sau khi cài đặt thành công
        read -rp "Sếp có muốn thiết lập chứng chỉ này cho panel luôn không? (y/n): " setPanel
        if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
            local webCertFile="${certPath}/fullchain.pem"
            local webKeyFile="${certPath}/privkey.pem"

            if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
                ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
                LOGI "Đã thiết lập đường dẫn panel cho tên miền: $CF_Domain"
                LOGI "  - Tệp Chứng chỉ: $webCertFile"
                LOGI "  - Tệp Khóa riêng: $webKeyFile"
                echo -e "${green}Đường dẫn truy cập: https://${CF_Domain}:${existing_port}${existing_webBasePath}${plain}"
                LOGI "Panel sẽ khởi động lại để áp dụng chứng chỉ SSL..."
                restart
            else
                LOGE "Lỗi: Không tìm thấy tệp chứng chỉ hoặc khóa riêng cho tên miền: $CF_Domain."
            fi
        else
            LOGI "Bỏ qua thiết lập đường dẫn panel."
        fi
    else
        show_menu
    fi
}

run_speedtest() {
    # Kiểm tra xem Speedtest đã được cài đặt chưa
    if ! command -v speedtest &>/dev/null; then
        # Nếu chưa cài đặt, xác định phương thức cài đặt
        if command -v snap &>/dev/null; then
            # Sử dụng snap để cài đặt Speedtest
            echo "Đang cài đặt Speedtest bằng snap sếp ơi..."
            snap install speedtest
        else
            # Chuyển sang sử dụng trình quản lý gói của hệ điều hành
            local pkg_manager=""
            local speedtest_install_script=""

            if command -v dnf &>/dev/null; then
                pkg_manager="dnf"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh"
            elif command -v yum &>/dev/null; then
                pkg_manager="yum"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh"
            elif command -v apt-get &>/dev/null; then
                pkg_manager="apt-get"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"
            elif command -v apt &>/dev/null; then
                pkg_manager="apt"
                speedtest_install_script="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"
            fi

            if [[ -z $pkg_manager ]]; then
                echo -e "${red}Lỗi: Không tìm thấy trình quản lý gói. Sếp có thể cần cài đặt Speedtest thủ công nhé.${plain}"
                return 1
            else
                echo "Đang cài đặt Speedtest bằng $pkg_manager..."
                curl -s $speedtest_install_script | bash
                $pkg_manager install -y speedtest
            fi
        fi
    fi

    # Tiến hành đo tốc độ
    speedtest
}

ip_validation() {
    ipv6_regex="^(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))$"
    ipv4_regex="^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)$"
}

iplimit_main() {
    echo -e "\n${green}\t1.${plain} Cài đặt Fail2ban và cấu hình Giới hạn IP"
    echo -e "${green}\t2.${plain} Thay đổi thời gian chặn (Ban Duration)"
    echo -e "${green}\t3.${plain} Bỏ chặn tất cả mọi người"
    echo -e "${green}\t4.${plain} Nhật ký chặn (Ban Logs)"
    echo -e "${green}\t5.${plain} Chặn một địa chỉ IP thủ công"
    echo -e "${green}\t6.${plain} Bỏ chặn một địa chỉ IP thủ công"
    echo -e "${green}\t7.${plain} Nhật ký thời gian thực (Real-Time)"
    echo -e "${green}\t8.${plain} Trạng thái dịch vụ"
    echo -e "${green}\t9.${plain} Khởi động lại dịch vụ"
    echo -e "${green}\t10.${plain} Gỡ cài đặt Fail2ban và Giới hạn IP"
    echo -e "${green}\t0.${plain} Quay lại Menu chính"
    read -rp "Vui lòng chọn một mục: " choice
    case "$choice" in
    0)
        show_menu
        ;;
    1)
        confirm "Tiến hành cài đặt Fail2ban & Giới hạn IP chứ sếp?" "y"
        if [[ $? == 0 ]]; then
            install_iplimit
        else
            iplimit_main
        fi
        ;;
    2)
        read -rp "Vui lòng nhập thời gian chặn mới (đơn vị: Phút) [mặc định 30]: " NUM
        if [[ $NUM =~ ^[0-9]+$ ]]; then
            create_iplimit_jails ${NUM}
            if [[ $release == "alpine" ]]; then
                rc-service fail2ban restart
            else
                systemctl restart fail2ban
            fi
            echo -e "${green}Đã thay đổi thời gian chặn thành ${NUM} phút.${plain}"
        else
            echo -e "${red}${NUM} không phải là một con số! Vui lòng thử lại sếp ơi.${plain}"
        fi
        iplimit_main
        ;;
    3)
        confirm "Sếp chắc chắn muốn bỏ chặn TẤT CẢ mọi người chứ?" "y"
        if [[ $? == 0 ]]; then
            fail2ban-client reload --restart --unban 3x-ipl
            truncate -s 0 "${iplimit_banned_log_path}"
            echo -e "${green}Đã bỏ chặn tất cả người dùng thành công.${plain}"
            iplimit_main
        else
            echo -e "${yellow}Đã hủy thao tác.${plain}"
        fi
        iplimit_main
        ;;
    4)
        show_banlog
        iplimit_main
        ;;
    5)
        read -rp "Nhập địa chỉ IP sếp muốn chặn: " ban_ip
        ip_validation
        if [[ $ban_ip =~ $ipv4_regex || $ban_ip =~ $ipv6_regex ]]; then
            fail2ban-client set 3x-ipl banip "$ban_ip"
            echo -e "${green}Địa chỉ IP ${ban_ip} đã được chặn thành công.${plain}"
        else
            echo -e "${red}Định dạng IP không hợp lệ! Vui lòng kiểm tra lại sếp nhé.${plain}"
        fi
        iplimit_main
        ;;
    6)
        read -rp "Nhập địa chỉ IP sếp muốn bỏ chặn: " unban_ip
        ip_validation
        if [[ $unban_ip =~ $ipv4_regex || $unban_ip =~ $ipv6_regex ]]; then
            fail2ban-client set 3x-ipl unbanip "$unban_ip"
            echo -e "${green}Địa chỉ IP ${unban_ip} đã được bỏ chặn thành công.${plain}"
        else
            echo -e "${red}Định dạng IP không hợp lệ! Vui lòng kiểm tra lại.${plain}"
        fi
        iplimit_main
        ;;
    7)
        tail -f /var/log/fail2ban.log
        iplimit_main
        ;;
    8)
        service fail2ban status
        iplimit_main
        ;;
    9)
        if [[ $release == "alpine" ]]; then
            rc-service fail2ban restart
        else
            systemctl restart fail2ban
        fi
        echo -e "${green}Dịch vụ Fail2ban đã được khởi động lại.${plain}"
        iplimit_main
        ;;
    10)
        remove_iplimit
        iplimit_main
        ;;
    *)
        echo -e "${red}Lựa chọn không hợp lệ. Vui lòng nhập đúng số tương ứng sếp ơi!${plain}\n"
        iplimit_main
        ;;
    esac
}

install_iplimit() {
    if ! command -v fail2ban-client &>/dev/null; then
        echo -e "${green}Fail2ban chưa được cài đặt. Đang tiến hành cài đặt ngay sếp nhé...!${plain}\n"

        # Kiểm tra hệ điều hành và cài đặt các gói cần thiết
        case "${release}" in
        ubuntu)
            apt-get update
            if [[ "${os_version}" -ge 24 ]]; then
                apt-get install python3-pip -y
                python3 -m pip install pyasynchat --break-system-packages
            fi
            apt-get install fail2ban -y
            ;;
        debian)
            apt-get update
            if [ "$os_version" -ge 12 ]; then
                apt-get install -y python3-systemd
            fi
            apt-get install -y fail2ban
            ;;
        armbian)
            apt-get update && apt-get install fail2ban -y
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf -y update && dnf -y install fail2ban
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum update -y && yum install epel-release -y
                yum -y install fail2ban
            else
                dnf -y update && dnf -y install fail2ban
            fi
            ;;
        arch | manjaro | parch)
            pacman -Syu --noconfirm fail2ban
            ;;
        alpine)
            apk add fail2ban
            ;;
        *)
            echo -e "${red}Hệ điều hành không được hỗ trợ. Vui lòng kiểm tra lại script hoặc cài đặt thủ công các gói cần thiết sếp ơi!${plain}\n"
            exit 1
            ;;
        esac

        if ! command -v fail2ban-client &>/dev/null; then
            echo -e "${red}Cài đặt Fail2ban thất bại rồi.${plain}\n"
            exit 1
        fi

        echo -e "${green}Cài đặt Fail2ban thành công rực rỡ!${plain}\n"
    else
        echo -e "${yellow}Fail2ban đã được cài đặt sẵn trên hệ thống rồi.${plain}\n"
    fi

    echo -e "${green}Đang cấu hình Giới hạn IP (IP Limit)...${plain}\n"

    # Đảm bảo không có xung đột giữa các file jail
    iplimit_remove_conflicts

    # Kiểm tra nếu file log chưa tồn tại thì tạo mới để tránh lỗi
    if ! test -f "${iplimit_banned_log_path}"; then
        touch ${iplimit_banned_log_path}
    fi

    # Kiểm tra file log dịch vụ để fail2ban không báo lỗi khi khởi chạy
    if ! test -f "${iplimit_log_path}"; then
        touch ${iplimit_log_path}
    fi

    # Tạo các file cấu hình jail cho iplimit
    # Chúng ta không truyền tham số bantime ở đây để sử dụng giá trị mặc định
    create_iplimit_jails

    # Khởi chạy fail2ban
    if [[ $release == "alpine" ]]; then
        if [[ $(rc-service fail2ban status | grep -F 'status: started' -c) == 0 ]]; then
            rc-service fail2ban start
        else
            rc-service fail2ban restart
        fi
        rc-update add fail2ban
    else
        if ! systemctl is-active --quiet fail2ban; then
            systemctl start fail2ban
        else
            systemctl restart fail2ban
        fi
        systemctl enable fail2ban
    fi

    echo -e "${green}Đã cài đặt và cấu hình Giới hạn IP thành công!${plain}\n"
    before_show_menu
}

remove_iplimit() {
    echo -e "${green}\t1.${plain} Chỉ xóa cấu hình Giới hạn IP (Giữ lại Fail2ban)"
    echo -e "${green}\t2.${plain} Gỡ cài đặt hoàn toàn Fail2ban và Giới hạn IP"
    echo -e "${green}\t0.${plain} Quay lại Menu chính"
    read -rp "Vui lòng chọn một mục: " num
    case "$num" in
    1)
        rm -f /etc/fail2ban/filter.d/3x-ipl.conf
        rm -f /etc/fail2ban/action.d/3x-ipl.conf
        rm -f /etc/fail2ban/jail.d/3x-ipl.conf
        if [[ $release == "alpine" ]]; then
            rc-service fail2ban restart
        else
            systemctl restart fail2ban
        fi
        echo -e "${green}Đã xóa cấu hình Giới hạn IP thành công!${plain}\n"
        before_show_menu
        ;;
    2)
        rm -rf /etc/fail2ban
        if [[ $release == "alpine" ]]; then
            rc-service fail2ban stop
        else
            systemctl stop fail2ban
        fi
        case "${release}" in
        ubuntu | debian | armbian)
            apt-get remove -y fail2ban
            apt-get purge -y fail2ban -y
            apt-get autoremove -y
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf remove fail2ban -y
            dnf autoremove -y
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then    
                yum remove fail2ban -y
                yum autoremove -y
            else
                dnf remove fail2ban -y
                dnf autoremove -y
            fi
            ;;
        arch | manjaro | parch)
            pacman -Rns --noconfirm fail2ban
            ;;
        alpine)
            apk del fail2ban
            ;;
        *)
            echo -e "${red}Hệ điều hành không được hỗ trợ. Sếp vui lòng gỡ cài đặt Fail2ban thủ công nhé.${plain}\n"
            exit 1
            ;;
        esac
        echo -e "${green}Đã gỡ cài đặt Fail2ban và Giới hạn IP thành công!${plain}\n"
        before_show_menu
        ;;
    0)
        show_menu
        ;;
    *)
        echo -e "${red}Lựa chọn không hợp lệ. Vui lòng chọn đúng số trên menu sếp nhé.${plain}\n"
        remove_iplimit
        ;;
    esac
}

show_banlog() {
    local system_log="/var/log/fail2ban.log"

    echo -e "${green}Đang kiểm tra nhật ký chặn (ban logs)...${plain}\n"

    if [[ $release == "alpine" ]]; then
        if [[ $(rc-service fail2ban status | grep -F 'status: started' -c) == 0 ]]; then
            echo -e "${red}Dịch vụ Fail2ban hiện không chạy!${plain}\n"
            return 1
        fi
    else
        if ! systemctl is-active --quiet fail2ban; then
            echo -e "${red}Dịch vụ Fail2ban hiện không chạy!${plain}\n"
            return 1
        fi
    fi

    if [[ -f "$system_log" ]]; then
        echo -e "${green}Hoạt động chặn/bỏ chặn hệ thống gần đây (từ fail2ban.log):${plain}"
        grep "3x-ipl" "$system_log" | grep -E "Ban|Unban" | tail -n 10 || echo -e "${yellow}Không tìm thấy hoạt động chặn nào gần đây.${plain}"
        echo ""
    fi

    if [[ -f "${iplimit_banned_log_path}" ]]; then
        echo -e "${green}Các mục nhật ký chặn 3X-IPL:${plain}"
        if [[ -s "${iplimit_banned_log_path}" ]]; then
            grep -v "INIT" "${iplimit_banned_log_path}" | tail -n 10 || echo -e "${yellow}Không tìm thấy lịch sử chặn nào.${plain}"
        else
            echo -e "${yellow}Tệp nhật ký chặn đang trống.${plain}"
        fi
    else
        echo -e "${red}Không tìm thấy tệp nhật ký tại: ${iplimit_banned_log_path}${plain}"
    fi

    echo -e "\n${green}Trạng thái 'nhà tù' (jail) hiện tại:${plain}"
    fail2ban-client status 3x-ipl || echo -e "${yellow}Không thể lấy trạng thái jail.${plain}"
}

create_iplimit_jails() {
    # Sử dụng thời gian chặn mặc định nếu không truyền tham số => 30 phút
    local bantime="${1:-30}"

    # Bỏ chú thích 'allowipv6 = auto' trong fail2ban.conf để hỗ trợ IPv6
    sed -i 's/#allowipv6 = auto/allowipv6 = auto/g' /etc/fail2ban/fail2ban.conf

    # Trên Debian 12+, backend mặc định của fail2ban nên được chuyển sang systemd
    if [[  "${release}" == "debian" && ${os_version} -ge 12 ]]; then
        sed -i '0,/action =/s/backend = auto/backend = systemd/' /etc/fail2ban/jail.conf
    fi

    # Tạo tệp cấu hình jail cho 3x-ui
    cat << EOF > /etc/fail2ban/jail.d/3x-ipl.conf
[3x-ipl]
enabled=true
backend=auto
filter=3x-ipl
action=3x-ipl
logpath=${iplimit_log_path}
maxretry=2
findtime=32
bantime=${bantime}m
EOF

    # Tạo tệp định nghĩa bộ lọc (filter)
    cat << EOF > /etc/fail2ban/filter.d/3x-ipl.conf
[Definition]
datepattern = ^%%Y/%%m/%%d %%H:%%M:%%S
failregex   = \[LIMIT_IP\]\s*Email\s*=\s*<F-USER>.+</F-USER>\s*\|\|\s*Disconnecting OLD IP\s*=\s*<ADDR>\s*\|\|\s*Timestamp\s*=\s*\d+
ignoreregex =
EOF

    # Tạo tệp định nghĩa hành động (action) chặn bằng iptables
    cat << EOF > /etc/fail2ban/action.d/3x-ipl.conf
[INCLUDES]
before = iptables-allports.conf

[Definition]
actionstart = <iptables> -N f2b-<name>
              <iptables> -A f2b-<name> -j <returntype>
              <iptables> -I <chain> -p <protocol> -j f2b-<name>

actionstop = <iptables> -D <chain> -p <protocol> -j f2b-<name>
             <actionflush>
             <iptables> -X f2b-<name>

actioncheck = <iptables> -n -L <chain> | grep -q 'f2b-<name>[ \t]'

actionban = <iptables> -I f2b-<name> 1 -s <ip> -j <blocktype>
            echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   BAN   [Email] = <F-USER> [IP] = <ip> bị chặn trong <bantime> giây." >> ${iplimit_banned_log_path}

actionunban = <iptables> -D f2b-<name> -s <ip> -j <blocktype>
              echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   UNBAN   [Email] = <F-USER> [IP] = <ip> đã được bỏ chặn." >> ${iplimit_banned_log_path}

[Init]
name = default
protocol = tcp
chain = INPUT
EOF

    echo -e "${green}Đã tạo các tệp cấu hình jail Giới hạn IP với thời gian chặn là ${bantime} phút.${plain}"
}

iplimit_remove_conflicts() {
    local jail_files=(
        /etc/fail2ban/jail.conf
        /etc/fail2ban/jail.local
    )

    for file in "${jail_files[@]}"; do
        # Kiểm tra xem có cấu hình [3x-ipl] cũ trong tệp jail không và xóa bỏ để tránh xung đột
        if test -f "${file}" && grep -qw '3x-ipl' ${file}; then
            sed -i "/\[3x-ipl\]/,/^$/d" ${file}
            echo -e "${yellow}Đang loại bỏ các xung đột của [3x-ipl] trong tệp jail (${file})!${plain}\n"
        fi
    done
}

SSH_port_forwarding() {
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

    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    local existing_listenIP=$(${xui_folder}/x-ui setting -getListen true | grep -Eo 'listenIP: .+' | awk '{print $2}')
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep -Eo 'cert: .+' | awk '{print $2}')
    local existing_key=$(${xui_folder}/x-ui setting -getCert true | grep -Eo 'key: .+' | awk '{print $2}')

    local config_listenIP=""
    local listen_choice=""

    if [[ -n "$existing_cert" && -n "$existing_key" ]]; then
        echo -e "${green}Panel đã được bảo mật bằng SSL rồi sếp nhé.${plain}"
        before_show_menu
    fi
    if [[ -z "$existing_cert" && -z "$existing_key" && (-z "$existing_listenIP" || "$existing_listenIP" == "0.0.0.0") ]]; then
        echo -e "\n${red}Cảnh báo: Không tìm thấy Cert và Key! Panel hiện tại không an toàn.${plain}"
        echo "Vui lòng cài đặt SSL hoặc thiết lập Chuyển tiếp cổng qua SSH (SSH port forwarding)."
    fi

    if [[ -n "$existing_listenIP" && "$existing_listenIP" != "0.0.0.0" && (-z "$existing_cert" && -z "$existing_key") ]]; then
        echo -e "\n${green}Cấu hình Chuyển tiếp cổng SSH hiện tại:${plain}"
        echo -e "Lệnh SSH tiêu chuẩn:"
        echo -e "${yellow}ssh -L 2222:${existing_listenIP}:${existing_port} root@${server_ip}${plain}"
        echo -e "\nNếu sử dụng SSH Key:"
        echo -e "${yellow}ssh -i <đường_dẫn_key> -L 2222:${existing_listenIP}:${existing_port} root@${server_ip}${plain}"
        echo -e "\nSau khi kết nối, sếp truy cập panel tại đường dẫn:"
        echo -e "${yellow}http://localhost:2222${existing_webBasePath}${plain}"
    fi

    echo -e "\nVui lòng chọn một mục:"
    echo -e "${green}1.${plain} Thiết lập IP lắng nghe (Listen IP)"
    echo -e "${green}2.${plain} Gỡ bỏ IP lắng nghe (Về mặc định 0.0.0.0)"
    echo -e "${green}0.${plain} Quay lại Menu chính"
    read -rp "Lựa chọn của sếp: " num

    case "$num" in
    1)
        if [[ -z "$existing_listenIP" || "$existing_listenIP" == "0.0.0.0" ]]; then
            echo -e "\nChưa cấu hình listenIP. Chọn một tùy chọn:"
            echo -e "1. Sử dụng IP mặc định (127.0.0.1)"
            echo -e "2. Nhập IP tùy chỉnh"
            read -rp "Lựa chọn của sếp (1 hoặc 2): " listen_choice

            config_listenIP="127.0.0.1"
            [[ "$listen_choice" == "2" ]] && read -rp "Nhập IP tùy chỉnh sếp muốn lắng nghe: " config_listenIP

            ${xui_folder}/x-ui setting -listenIP "${config_listenIP}" >/dev/null 2>&1
            echo -e "${green}Đã thiết lập Listen IP thành ${config_listenIP}.${plain}"
            echo -e "\n${green}Cấu hình Chuyển tiếp cổng SSH (Sếp chạy lệnh này ở máy cá nhân):${plain}"
            echo -e "Lệnh SSH tiêu chuẩn:"
            echo -e "${yellow}ssh -L 2222:${config_listenIP}:${existing_port} root@${server_ip}${plain}"
            echo -e "\nNếu dùng SSH Key:"
            echo -e "${yellow}ssh -i <đường_dẫn_key> -L 2222:${config_listenIP}:${existing_port} root@${server_ip}${plain}"
            echo -e "\nSau khi kết nối SSH xong, sếp mở trình duyệt và truy cập:"
            echo -e "${yellow}http://localhost:2222${existing_webBasePath}${plain}"
            restart
        else
            config_listenIP="${existing_listenIP}"
            echo -e "${green}Listen IP hiện tại đã được thiết lập là ${config_listenIP} rồi sếp.${plain}"
        fi
        ;;
    2)
        ${xui_folder}/x-ui setting -listenIP 0.0.0.0 >/dev/null 2>&1
        echo -e "${green}Đã gỡ bỏ Listen IP (Panel hiện có thể truy cập công khai qua IP VPS).${plain}"
        restart
        ;;
    0)
        show_menu
        ;;
    *)
        echo -e "${red}Lựa chọn không hợp lệ. Vui lòng chọn lại nhé sếp.${plain}\n"
        SSH_port_forwarding
        ;;
    esac
}

show_usage() {
    echo -e "┌────────────────────────────────────────────────────────────────┐
│  ${blue}Hướng dẫn sử dụng lệnh x-ui (subcommands):${plain}                    │
│                                                                │
│  ${blue}x-ui${plain}                     - Script quản trị Admin              │
│  ${blue}x-ui start${plain}               - Khởi động                          │
│  ${blue}x-ui stop${plain}                - Dừng                               │
│  ${blue}x-ui restart${plain}             - Khởi động lại                      │
|  ${blue}x-ui restart-xray${plain}        - Khởi động lại Xray                 │
│  ${blue}x-ui status${plain}              - Trạng thái hiện tại                │
│  ${blue}x-ui settings${plain}            - Cài đặt hiện tại                   │
│  ${blue}x-ui enable${plain}              - Bật tự động chạy khi khởi động OS  │
│  ${blue}x-ui disable${plain}             - Tắt tự động chạy khi khởi động OS  │
│  ${blue}x-ui log${plain}                 - Xem nhật ký (logs)                 │
│  ${blue}x-ui banlog${plain}              - Xem nhật ký chặn của Fail2ban      │
│  ${blue}x-ui update${plain}              - Cập nhật phiên bản                 │
│  ${blue}x-ui update-all-geofiles${plain} - Cập nhật tất cả các tệp Geo        │
│  ${blue}x-ui legacy${plain}              - Phiên bản cũ (Legacy)              │
│  ${blue}x-ui install${plain}             - Cài đặt mới                        │
│  ${blue}x-ui uninstall${plain}           - Gỡ cài đặt                         │
└────────────────────────────────────────────────────────────────┘"
}

show_menu() {
    echo -e "
╔────────────────────────────────────────────────╗
│      ${green}Script Quản Lý Panel 3X-UI${plain}                │
│      ${green}0.${plain} Thoát Script                               │
│────────────────────────────────────────────────│
│      ${green}1.${plain} Cài đặt                                    │
│      ${green}2.${plain} Cập nhật                                   │
│      ${green}3.${plain} Cập nhật Menu                              │
│      ${green}4.${plain} Phiên bản cũ (Legacy)                      │
│      ${green}5.${plain} Gỡ cài đặt                                 │
│────────────────────────────────────────────────│
│      ${green}6.${plain} Đặt lại Tài khoản & Mật khẩu               │
│      ${green}7.${plain} Đặt lại Web Base Path                      │
│      ${green}8.${plain} Đặt lại toàn bộ cài đặt                    │
│      ${green}9.${plain} Thay đổi cổng (Port)                       │
│     ${green}10.${plain} Xem cài đặt hiện tại                       │
│────────────────────────────────────────────────│
│     ${green}11.${plain} Khởi động                                  │
│     ${green}12.${plain} Dừng                                      │
│     ${green}13.${plain} Khởi động lại                              │
|     ${green}14.${plain} Khởi động lại Xray                         │
│     ${green}15.${plain} Kiểm tra trạng thái                        │
│     ${green}16.${plain} Quản lý nhật ký (Logs)                     │
│────────────────────────────────────────────────│
│     ${green}17.${plain} Bật tự động chạy khi khởi động             │
│     ${green}18.${plain} Tắt tự động chạy khi khởi động             │
│────────────────────────────────────────────────│
│     ${green}19.${plain} Quản lý chứng chỉ SSL                      │
│     ${green}20.${plain} Chứng chỉ SSL qua Cloudflare               │
│     ${green}21.${plain} Quản lý Giới hạn IP (IP Limit)             │
│     ${green}22.${plain} Quản lý Tường lửa (Firewall)               │
│     ${green}23.${plain} Quản lý Chuyển tiếp cổng SSH               │
│────────────────────────────────────────────────│
│     ${green}24.${plain} Kích hoạt BBR (Tăng tốc mạng)              │
│     ${green}25.${plain} Cập nhật các tệp Geo                       │
│     ${green}26.${plain} Kiểm tra tốc độ mạng (Speedtest)           │
╚────────────────────────────────────────────────╝
"
    show_status
    echo && read -rp "Vui lòng nhập lựa chọn của sếp [0-26]: " num

    case "${num}" in
    0)
        exit 0
        ;;
    1)
        check_uninstall && install
        ;;
    2)
        check_install && update
        ;;
    3)
        check_install && update_menu
        ;;
    4)
        check_install && legacy_version
        ;;
    5)
        check_install && uninstall
        ;;
    6)
        check_install && reset_user
        ;;
    7)
        check_install && reset_webbasepath
        ;;
    8)
        check_install && reset_config
        ;;
    9)
        check_install && set_port
        ;;
    10)
        check_install && check_config
        ;;
    11)
        check_install && start
        ;;
    12)
        check_install && stop
        ;;
    13)
        check_install && restart
        ;;
    14)
        check_install && restart_xray
        ;;
    15)
        check_install && status
        ;;
    16)
        check_install && show_log
        ;;
    17)
        check_install && enable
        ;;
    18)
        check_install && disable
        ;;
    19)
        ssl_cert_issue_main
        ;;
    20)
        ssl_cert_issue_CF
        ;;
    21)
        iplimit_main
        ;;
    22)
        firewall_menu
        ;;
    23)
        SSH_port_forwarding
        ;;
    24)
        bbr_menu
        ;;
    25)
        update_geo
        ;;
    26)
        run_speedtest
        ;;
    *)
        LOGE "Vui lòng nhập đúng số thứ tự trong danh sách [0-26] sếp ơi!"
        ;;
    esac
}

if [[ $# > 0 ]]; then
    case $1 in
    "start")
        check_install 0 && start 0
        ;;
    "stop")
        check_install 0 && stop 0
        ;;
    "restart")
        check_install 0 && restart 0
        ;;
    "restart-xray")
        check_install 0 && restart_xray 0
        ;;
    "status")
        check_install 0 && status 0
        ;;
    "settings")
        check_install 0 && check_config 0
        ;;
    "enable")
        check_install 0 && enable 0
        ;;
    "disable")
        check_install 0 && disable 0
        ;;
    "log")
        check_install 0 && show_log 0
        ;;
    "banlog")
        check_install 0 && show_banlog 0
        ;;
    "update")
        check_install 0 && update 0
        ;;
    "legacy")
        check_install 0 && legacy_version 0
        ;;
    "install")
        check_uninstall 0 && install 0
        ;;
    "uninstall")
        check_install 0 && uninstall 0
        ;;
    "update-all-geofiles")
        check_install 0 && update_all_geofiles 0 && restart 0
        ;;
    *) show_usage ;;
    esac
else
    show_menu
fi
