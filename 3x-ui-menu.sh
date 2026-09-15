#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_NAME="3x-ui 管理菜单"

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "错误：此脚本需要 root 权限。"
        echo "请使用：sudo bash $0"
        exit 1
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
    echo "即将打开 x-ui 菜单，请按以下顺序操作："
    echo "  26 -> 1 -> 回车 -> 0"
    echo
    read -r -p "按回车键启动 x-ui，或按 Ctrl+C 取消..." _
    x-ui
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
    echo "即将打开 x-ui，请按以下顺序操作："
    echo "  1 -> 回车 -> n -> n -> 0 -> 0"
    echo
    echo "当 x-ui 提示输入域名时，请输入：${domain}"
    read -r -p "按回车键启动 x-ui，或按 Ctrl+C 取消..." _
    x-ui
}

show_menu() {
    echo
    echo "========================================"
    echo "            ${SCRIPT_NAME}"
    echo "========================================"
    echo "1. 安装 3x-ui"
    echo "2. 开启 BBR"
    echo "3. 申请域名证书"
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
            0)
                echo "已退出。"
                exit 0
                ;;
            *)
                echo "无效选项，请输入 1、2、3 或 0。"
                ;;
        esac

        echo
        read -r -p "按回车键返回主菜单..." _
    done
}

main "$@"
