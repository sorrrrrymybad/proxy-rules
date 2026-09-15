#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_NAME="3x-ui 管理菜单"
readonly SUBSCRIPTION_REMARK_TEMPLATE="{{INBOUND}} | {{TRAFFIC_LEFT}} | {{DAYS_LEFT}}D"

LAST_DOMAIN=""
API_BASE=""
API_TOKEN=""

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "错误：此脚本需要 root 权限。"
        echo "请使用：sudo bash $0"
        exit 1
    fi
}

ensure_jq() {
    if command -v jq >/dev/null 2>&1; then
        return 0
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        echo "错误：第 6 项需要 jq，但当前系统未找到 apt-get。"
        return 1
    fi

    echo "未找到 jq，正在安装..."
    apt-get update
    apt-get install -y jq
}

api_call() {
    local method="$1"
    local endpoint="$2"
    local json_body="${3-}"
    local raw status body request_url
    local -a curl_args

    curl_args=(curl -ksS --max-time 30
        -H "Authorization: Bearer ${API_TOKEN}"
        -H "Accept: application/json")

    request_url="${API_BASE}"
    request_url="${request_url#\[}"
    request_url="${request_url%%\]*}"
    if [[ "${request_url}" == */panel/api ]]; then
        request_url="${request_url%/panel/api}"
    fi
    while [[ "${request_url}" == */ ]]; do
        request_url="${request_url%/}"
    done
    while [[ "${endpoint}" == /* ]]; do
        endpoint="${endpoint#/}"
    done
    request_url="${request_url}/${endpoint}"

    if [[ "${method}" == "GET" ]]; then
        if ! raw="$("${curl_args[@]}" -w $'\n%{http_code}' "${request_url}")"; then
            echo "错误：无法访问 3x-ui API：${endpoint}" >&2
            return 1
        fi
    else
        if ! raw="$("${curl_args[@]}" -H "Content-Type: application/json" -X "${method}" --data "${json_body}" -w $'\n%{http_code}' "${request_url}")"; then
            echo "错误：无法访问 3x-ui API：${endpoint}" >&2
            return 1
        fi
    fi

    status="${raw##*$'\n'}"
    body="${raw%$'\n'*}"

    if [[ ! "${status}" =~ ^2[0-9][0-9]$ ]]; then
        echo "错误：API ${method} ${endpoint} 返回 HTTP ${status}。" >&2
        [[ -n "${body}" ]] && echo "${body}" >&2
        return 1
    fi

    printf '%s\n' "${body}"
}

api_expect_success() {
    local response="$1"
    local action="$2"
    local message

    if jq -e '.success == true' >/dev/null 2>&1 <<<"${response}"; then
        return 0
    fi

    message="$(jq -r '.msg // "API 返回失败"' <<<"${response}" 2>/dev/null || echo "API 返回失败")"
    echo "错误：${action}失败：${message}" >&2
    return 1
}

discover_panel_api_base() {
    local settings_output access_url scheme authority panel_port base_path

    if ! settings_output="$(printf '11\n0\n' | x-ui 2>&1)"; then
        echo "错误：无法通过 x-ui -> 11 获取面板地址。"
        return 1
    fi

    access_url="$(printf '%s\n' "${settings_output}" \
        | sed -n -E 's/.*Access URL:[[:space:]]*//p' \
        | sed -E 's/^\[//; s/\].*$//; s/[[:space:]]+$//' \
        | tail -n 1)"

    if [[ -z "${access_url}" ]]; then
        echo "错误：未能从 x-ui -> 11 的输出中解析 Access URL。"
        echo "请确认 x-ui 可以正常运行，并包含 Access URL。"
        return 1
    fi

    if [[ "${access_url}" =~ ^(https?)://([^/]+)(/[^[:space:]]*)?$ ]]; then
        :
    else
        echo "错误：Access URL 格式无效：${access_url}"
        return 1
    fi

    scheme="${BASH_REMATCH[1]}"
    authority="${BASH_REMATCH[2]}"
    base_path="${BASH_REMATCH[3]:-/}"
    while [[ "${base_path}" == */ ]]; do
        base_path="${base_path%/}"
    done

    if [[ "${authority}" == *:* ]]; then
        panel_port="${authority##*:}"
        API_BASE="${scheme}://127.0.0.1:${panel_port}${base_path}"
    else
        API_BASE="${scheme}://127.0.0.1${base_path}"
    fi

    echo "已发现面板 API 地址：${API_BASE}"
}

random_hex() {
    local byte_count="$1"

    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "${byte_count}"
        return 0
    fi

    od -An -N "${byte_count}" -tx1 /dev/urandom | tr -d '[:space:]'
}

get_existing_inbound_id() {
    local inbounds_response="$1"
    local protocol="$2"
    local port="$3"
    local listen_mode="$4"

    jq -r --arg protocol "${protocol}" --argjson port "${port}" --arg listen_mode "${listen_mode}" '
        [
            .obj[]
            | select(.protocol == $protocol)
            | select((.port // 0) == $port)
            | select(
                $listen_mode == "any"
                or ($listen_mode == "loopback" and (.listen // "") == "127.0.0.1")
                or ($listen_mode == "public" and (.listen // "") != "127.0.0.1")
            )
        ][0].id // empty
    ' <<<"${inbounds_response}"
}

get_existing_inbound_clients() {
    local inbound_id="$1"
    local inbound_response

    if [[ -z "${inbound_id}" ]]; then
        printf '[]\n'
        return 0
    fi

    inbound_response="$(api_call GET "/panel/api/inbounds/get/${inbound_id}")" || return 1
    api_expect_success "${inbound_response}" "读取入站 ${inbound_id}" || return 1

    jq -c '
        (.obj.settings // {})
        | if type == "string" then fromjson else . end
        | .clients // []
    ' <<<"${inbound_response}"
}

upsert_inbound() {
    local inbound_id="$1"
    local payload="$2"
    local label="$3"
    local response

    if [[ -n "${inbound_id}" ]]; then
        response="$(api_call POST "/panel/api/inbounds/update/${inbound_id}" "${payload}")" || return 1
        api_expect_success "${response}" "更新 ${label}" || return 1
        echo "${label}已更新。"
    else
        response="$(api_call POST "/panel/api/inbounds/add" "${payload}")" || return 1
        api_expect_success "${response}" "创建 ${label}" || return 1
        echo "${label}已创建。"
    fi
}

install_3x_ui() {
    if ! command -v curl >/dev/null 2>&1; then
        echo "错误：未找到 curl，请先安装 curl 后重试。"
        return 1
    fi

    echo "正在启动 3x-ui 安装程序..."
    bash <(curl -fsSL "https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh")
}

enable_bbr() {
    if ! command -v x-ui >/dev/null 2>&1; then
        echo "错误：未找到 x-ui 命令，请先选择菜单中的 1 安装 3x-ui。"
        return 1
    fi

    echo
    echo "正在通过 x-ui 自动执行：26 -> 1 -> 回车 -> 0"
    echo
    printf '26\n1\n\n0\n0\n' | x-ui
}

request_domain_certificate() {
    if ! command -v x-ui >/dev/null 2>&1; then
        echo "错误：未找到 x-ui 命令，请先选择菜单中的 1 安装 3x-ui。"
        return 1
    fi

    local domain
    read -r -p "请输入域名: " domain

    if [[ -z "${domain}" ]]; then
        echo "错误：域名不能为空。"
        return 1
    fi

    echo
    echo "域名：${domain}"
    LAST_DOMAIN="${domain}"
    echo "正在通过 x-ui 自动执行：20 -> 1 -> ${domain} -> 回车 -> n -> n -> 0 -> 0"
    echo
    printf '20\n1\n%s\n\nn\nn\n0\n0\n' "${domain}" | x-ui
}

install_komari() {
    if ! command -v curl >/dev/null 2>&1; then
        echo "错误：未找到 curl，请先安装 curl 后重试。"
        return 1
    fi

    local auto_discovery_token
    read -r -s -p "请输入 Komari 的 auto-discovery 值: " auto_discovery_token
    echo

    if [[ -z "${auto_discovery_token}" ]]; then
        echo "错误：auto-discovery 值不能为空。"
        return 1
    fi

    echo "正在安装 Komari 监控客户端..."
    bash <(curl -fsSL "https://raw.githubusercontent.com/komari-monitor/komari-agent/refs/heads/main/install.sh") \
        -e "https://komari.buuuug.com" \
        --auto-discovery "${auto_discovery_token}"

    echo "Komari 安装完成，正在替换为轻量版客户端..."
    curl -fsSL "https://raw.githubusercontent.com/luodaoyi/komari-zig-agent/refs/heads/main/replace.sh" | sh
}

configure_nginx() {
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "错误：未找到 apt-get，此选项适用于 Debian/Ubuntu 系统。"
        return 1
    fi

    local domain nginx_site cert_dir
    read -r -p "请输入域名: " domain
    domain="${domain// /}"

    if [[ ! "${domain}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
        echo "错误：域名格式无效。"
        return 1
    fi

    LAST_DOMAIN="${domain}"

    nginx_site="/etc/nginx/sites-available/${domain}"
    cert_dir="/root/cert/${domain}"

    echo "正在安装 Nginx..."
    apt-get update
    apt-get install -y nginx

    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled /var/www/html
    cat > "${nginx_site}" <<EOF
server {
    listen 8443 ssl;
    server_name ${domain} www.${domain};

    ssl_certificate ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/privkey.pem;

    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    ln -sfn "${nginx_site}" "/etc/nginx/sites-enabled/${domain}"
    rm -f /etc/nginx/sites-enabled/default

    nginx -t
    systemctl reload nginx
    echo "Nginx 配置完成：${nginx_site}"
}

configure_xui_api() {
    ensure_jq || return 1

    if ! command -v x-ui >/dev/null 2>&1; then
        echo "错误：未找到 x-ui 命令，请先选择菜单中的 1 安装 3x-ui。"
        return 1
    fi

    local api_token domain node_name client_name total_gb
    local current_day expiry_time total_bytes
    local reality_response reality_private_key short_ids short_id
    local inbounds_response helper_id vless_id hy2_id
    local helper_clients vless_clients hy2_clients
    local helper_remark vless_remark hy2_remark
    local helper_payload vless_payload hy2_payload
    local client_payload client_request client_response
    local settings_response settings_obj settings_payload settings_update_response

    read -r -s -p "请输入 3x-ui API Token: " api_token
    echo

    if [[ -z "${api_token}" ]]; then
        echo "错误：API Token 不能为空。"
        return 1
    fi

    API_TOKEN="${api_token}"
    discover_panel_api_base || {
        API_TOKEN=""
        return 1
    }

    if [[ -n "${LAST_DOMAIN}" ]]; then
        read -r -p "请输入域名（回车使用 ${LAST_DOMAIN}）: " domain
        domain="${domain:-${LAST_DOMAIN}}"
    else
        read -r -p "请输入域名（用于 Reality 和 Hysteria2 TLS）: " domain
    fi
    domain="${domain// /}"

    if [[ ! "${domain}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
        echo "错误：域名格式无效。"
        API_TOKEN=""
        return 1
    fi

    if [[ ! -f "/root/cert/${domain}/fullchain.pem" || ! -f "/root/cert/${domain}/privkey.pem" ]]; then
        echo "错误：未找到域名证书：/root/cert/${domain}/"
        echo "请先选择菜单中的 3 申请域名证书。"
        API_TOKEN=""
        return 1
    fi

    read -r -p "请输入节点名称: " node_name
    read -r -p "请输入客户端名称: " client_name
    read -r -p "请输入客户端流量上限（GB，0 表示不限）: " total_gb

    if [[ -z "${node_name}" || -z "${client_name}" ]]; then
        echo "错误：节点名称和客户端名称不能为空。"
        API_TOKEN=""
        return 1
    fi

    if [[ ! "${total_gb}" =~ ^[0-9]+$ ]]; then
        echo "错误：流量上限必须是非负整数，单位为 GB。"
        API_TOKEN=""
        return 1
    fi

    current_day="$(date +%d | sed 's/^0*//')"
    total_bytes=$((total_gb * 1073741824))
    expiry_time="$(( $(date +%s) + 30 * 86400 ))000"

    echo "正在生成 Reality 密钥..."
    reality_response="$(api_call GET "/panel/api/server/getNewX25519Cert")" || {
        API_TOKEN=""
        return 1
    }
    api_expect_success "${reality_response}" "生成 Reality 密钥" || {
        API_TOKEN=""
        return 1
    }

    reality_private_key="$(jq -r '.obj.privateKey // empty' <<<"${reality_response}")"
    if [[ -z "${reality_private_key}" ]]; then
        echo "错误：API 未返回 Reality privateKey。"
        API_TOKEN=""
        return 1
    fi

    short_ids='[]'
    for _ in 1 2 3 4 5 6 7 8; do
        short_id="$(random_hex 8)"
        short_ids="$(jq -c --arg short_id "${short_id}" '. + [$short_id]' <<<"${short_ids}")"
    done

    inbounds_response="$(api_call GET "/panel/api/inbounds/list")" || {
        API_TOKEN=""
        return 1
    }
    api_expect_success "${inbounds_response}" "读取入站列表" || {
        API_TOKEN=""
        return 1
    }

    helper_id="$(get_existing_inbound_id "${inbounds_response}" "vless" 4431 "any")"
    vless_id="$(get_existing_inbound_id "${inbounds_response}" "vless" 443 "public")"
    hy2_id="$(get_existing_inbound_id "${inbounds_response}" "hysteria" 443 "any")"

    helper_clients="$(get_existing_inbound_clients "${helper_id}")" || {
        API_TOKEN=""
        return 1
    }
    vless_clients="$(get_existing_inbound_clients "${vless_id}")" || {
        API_TOKEN=""
        return 1
    }
    hy2_clients="$(get_existing_inbound_clients "${hy2_id}")" || {
        API_TOKEN=""
        return 1
    }

    helper_remark="in-8443-tcp ${node_name}"
    vless_remark="in-443-tcp ${node_name} - A"
    hy2_remark="in-443-udp ${node_name} - B"

    helper_payload="$(jq -n \
        --arg remark "${helper_remark}" \
        --argjson clients "${helper_clients}" \
        ' {
            enable: true,
            remark: $remark,
            listen: "127.0.0.1",
            port: 4431,
            protocol: "vless",
            expiryTime: 0,
            total: 0,
            settings: {
                clients: $clients,
                decryption: "none",
                fallbacks: []
            },
            streamSettings: {
                network: "tcp",
                security: "none",
                tcpSettings: {
                    acceptProxyProtocol: false,
                    header: { type: "none" }
                }
            },
            sniffing: {
                enabled: true,
                destOverride: ["http", "tls", "quic"],
                metadataOnly: false,
                routeOnly: false
            }
        }')"

    vless_payload="$(jq -n \
        --arg remark "${vless_remark}" \
        --arg domain "${domain}" \
        --arg private_key "${reality_private_key}" \
        --argjson short_ids "${short_ids}" \
        --argjson clients "${vless_clients}" \
        ' {
            enable: true,
            remark: $remark,
            listen: "",
            port: 443,
            protocol: "vless",
            expiryTime: 0,
            total: 0,
            settings: {
                clients: $clients,
                decryption: "none",
                fallbacks: [{ dest: 8443, xver: 0 }]
            },
            streamSettings: {
                network: "tcp",
                security: "reality",
                realitySettings: {
                    show: false,
                    xver: 0,
                    dest: "127.0.0.1:8443",
                    serverNames: [$domain],
                    privateKey: $private_key,
                    shortIds: $short_ids
                },
                tcpSettings: {
                    acceptProxyProtocol: false,
                    header: { type: "none" }
                }
            },
            sniffing: {
                enabled: true,
                destOverride: ["http", "tls", "quic"],
                metadataOnly: false,
                routeOnly: false
            }
        }')"

    hy2_payload="$(jq -n \
        --arg remark "${hy2_remark}" \
        --arg domain "${domain}" \
        --arg cert_file "/root/cert/${domain}/fullchain.pem" \
        --arg key_file "/root/cert/${domain}/privkey.pem" \
        --argjson clients "${hy2_clients}" \
        ' {
            enable: true,
            remark: $remark,
            listen: "",
            port: 443,
            protocol: "hysteria",
            expiryTime: 0,
            total: 0,
            settings: {
                version: 2,
                clients: $clients,
                masquerade: "",
                udpIdleTimeout: 60
            },
            streamSettings: {
                network: "hysteria",
                security: "tls",
                hysteriaSettings: {
                    version: 2,
                    masquerade: "",
                    udpIdleTimeout: 60
                },
                tlsSettings: {
                    serverName: $domain,
                    alpn: ["h3"],
                    certificates: [{
                        certificateFile: $cert_file,
                        keyFile: $key_file
                    }]
                }
            },
            sniffing: {
                enabled: true,
                destOverride: ["http", "tls", "quic"],
                metadataOnly: false,
                routeOnly: false
            }
        }')"

    upsert_inbound "${helper_id}" "${helper_payload}" "${helper_remark}" || {
        API_TOKEN=""
        return 1
    }
    upsert_inbound "${vless_id}" "${vless_payload}" "${vless_remark}" || {
        API_TOKEN=""
        return 1
    }
    upsert_inbound "${hy2_id}" "${hy2_payload}" "${hy2_remark}" || {
        API_TOKEN=""
        return 1
    }

    inbounds_response="$(api_call GET "/panel/api/inbounds/list")" || {
        API_TOKEN=""
        return 1
    }
    api_expect_success "${inbounds_response}" "读取更新后的入站列表" || {
        API_TOKEN=""
        return 1
    }

    helper_id="$(get_existing_inbound_id "${inbounds_response}" "vless" 4431 "loopback")"
    vless_id="$(get_existing_inbound_id "${inbounds_response}" "vless" 443 "public")"
    hy2_id="$(get_existing_inbound_id "${inbounds_response}" "hysteria" 443 "any")"

    if [[ -z "${helper_id}" || -z "${vless_id}" || -z "${hy2_id}" ]]; then
        echo "错误：更新后未能找到全部 3 个入站。"
        API_TOKEN=""
        return 1
    fi

    client_payload="$(jq -n \
        --arg email "${client_name}" \
        --argjson total_gb "${total_bytes}" \
        --argjson expiry_time "${expiry_time}" \
        --argjson reset_day "${current_day}" \
        ' {
            email: $email,
            totalGB: $total_gb,
            expiryTime: $expiry_time,
            enable: true,
            limitIp: 0,
            limitHwid: 0,
            tgId: 0,
            reset: 0,
            resetDay: $reset_day,
            resetMax: 0,
            flow: "xtls-rprx-vision"
        }')"

    client_request="$(jq -n \
        --argjson client "${client_payload}" \
        --argjson inbound_ids "[${helper_id}, ${vless_id}, ${hy2_id}]" \
        '{ client: $client, inboundIds: $inbound_ids }')"

    client_response="$(api_call POST "/panel/api/clients/add" "${client_request}")" || {
        API_TOKEN=""
        return 1
    }
    api_expect_success "${client_response}" "创建客户端" || {
        API_TOKEN=""
        return 1
    }
    echo "客户端 ${client_name} 已创建或更新。"

    settings_response="$(api_call POST "/panel/api/setting/all" '{}')" || {
        API_TOKEN=""
        return 1
    }
    api_expect_success "${settings_response}" "读取面板设置" || {
        API_TOKEN=""
        return 1
    }

    settings_obj="$(jq -c '.obj' <<<"${settings_response}")"
    if [[ "$(jq -r 'type' <<<"${settings_obj}")" != "object" ]]; then
        echo "错误：面板设置 API 未返回有效的设置对象。"
        API_TOKEN=""
        return 1
    fi

    settings_payload="$(jq --arg template "${SUBSCRIPTION_REMARK_TEMPLATE}" '.remarkTemplate = $template' <<<"${settings_obj}")"
    settings_update_response="$(api_call POST "/panel/api/setting/update" "${settings_payload}")" || {
        API_TOKEN=""
        return 1
    }
    api_expect_success "${settings_update_response}" "设置订阅备注模板" || {
        API_TOKEN=""
        return 1
    }

    API_TOKEN=""
    echo
    echo "3x-ui API 配置完成。"
    echo "入站：${helper_remark}（127.0.0.1:4431，仅用于订阅显示）"
    echo "入站：${vless_remark}（VLESS + Reality，443/TCP）"
    echo "入站：${hy2_remark}（Hysteria2，443/UDP）"
    echo "订阅备注模板：${SUBSCRIPTION_REMARK_TEMPLATE}"
}

show_menu() {
    echo
    echo "========================================"
    echo "            ${SCRIPT_NAME}"
    echo "========================================"
    echo "1. 安装 3x-ui"
    echo "2. 开启 BBR"
    echo "3. 申请域名证书"
    echo "4. 安装 Komari 监控"
    echo "5. 配置 Nginx"
    echo "6. 通过 API 配置 3x-ui 入站、客户端和面板设置"
    echo "0. 退出"
    echo "========================================"
}

main() {
    require_root

    while true; do
        show_menu
        read -r -p "请输入数字选项: " choice

        case "${choice}" in
            1)
                install_3x_ui
                ;;
            2)
                enable_bbr
                ;;
            3)
                request_domain_certificate
                ;;
            4)
                install_komari
                ;;
            5)
                configure_nginx
                ;;
            6)
                configure_xui_api
                ;;
            0)
                echo "已退出。"
                exit 0
                ;;
            *)
                echo "无效选项，请输入 1、2、3、4、5、6 或 0。"
                ;;
        esac

        echo
        read -r -p "按回车键返回主菜单..." _
    done
}

main "$@"
