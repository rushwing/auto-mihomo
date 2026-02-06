#!/usr/bin/env python3
"""
generate_config.py - 根据订阅内容生成 Mihomo (Clash Meta) 配置文件

读取 subscription.yaml 中的代理节点列表, 结合最快节点信息,
生成完整的 Mihomo 配置文件, 包含 DNS / 代理组 / 规则等。

用法:
    python3 generate_config.py \
        --subscription subscription.yaml \
        --output config.yaml \
        --best-node "节点名称" \
        --mixed-port 7893 \
        --api-port 9090
"""
import argparse
import sys

import yaml


def load_proxies(sub_file: str) -> list[dict]:
    """从订阅文件加载代理节点列表"""
    with open(sub_file, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)

    proxies = data.get("proxies", [])
    if not proxies:
        print("错误: 订阅文件中没有代理节点", file=sys.stderr)
        sys.exit(1)

    return proxies


def build_config(
    proxies: list[dict],
    best_node: str,
    mixed_port: int,
    api_port: int,
) -> dict:
    """
    构建完整的 Mihomo 配置

    Args:
        proxies: 代理节点列表
        best_node: 延迟最低的节点名称 (作为默认选中)
        mixed_port: HTTP/SOCKS5 混合代理端口
        api_port: RESTful API 端口
    """
    proxy_names = [p["name"] for p in proxies]

    # 将最快节点排到首位
    ordered_names = [best_node] + [n for n in proxy_names if n != best_node]

    config = {
        # ===== 基础设置 =====
        "mixed-port": mixed_port,
        "allow-lan": True,
        "bind-address": "*",
        "mode": "rule",
        "log-level": "info",
        "ipv6": False,
        "external-controller": f"0.0.0.0:{api_port}",
        "secret": "",
        # ===== TCP 并发 =====
        "tcp-concurrent": True,
        # ===== 进程匹配 =====
        "find-process-mode": "off",
        # ===== GeoIP =====
        "geodata-mode": True,
        "geox-url": {
            "geoip": "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.dat",
            "geosite": "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat",
            "mmdb": "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/country.mmdb",
        },
        # ===== DNS 设置 =====
        "dns": {
            "enable": True,
            "ipv6": False,
            "listen": "0.0.0.0:1053",
            "enhanced-mode": "fake-ip",
            "fake-ip-range": "198.18.0.1/16",
            "fake-ip-filter": [
                "*.lan",
                "*.local",
                "localhost.ptlogin2.qq.com",
                "+.stun.*.*",
                "+.stun.*.*.*",
                "+.stun.*.*.*.*",
                "*.n.n.srv.nintendo.net",
                "+.stun.playstation.net",
                "xbox.*.*.microsoft.com",
                "*.*.xboxlive.com",
                "*.msftncsi.com",
                "*.msftconnecttest.com",
            ],
            "default-nameserver": [
                "223.5.5.5",
                "119.29.29.29",
            ],
            "nameserver": [
                "https://doh.pub/dns-query",
                "https://dns.alidns.com/dns-query",
            ],
            "fallback": [
                "https://1.1.1.1/dns-query",
                "https://dns.google/dns-query",
                "tls://8.8.8.8:853",
            ],
            "fallback-filter": {
                "geoip": True,
                "geoip-code": "CN",
                "ipcidr": [
                    "240.0.0.0/4",
                ],
            },
        },
        # ===== 代理节点 =====
        "proxies": proxies,
        # ===== 代理组 =====
        "proxy-groups": [
            {
                "name": "Proxy",
                "type": "select",
                "proxies": ["Auto", "Fallback"] + ordered_names + ["DIRECT"],
            },
            {
                "name": "Auto",
                "type": "url-test",
                "proxies": proxy_names,
                "url": "http://www.gstatic.com/generate_204",
                "interval": 300,
                "tolerance": 50,
            },
            {
                "name": "Fallback",
                "type": "fallback",
                "proxies": ordered_names,
                "url": "http://www.gstatic.com/generate_204",
                "interval": 300,
            },
        ],
        # ===== 分流规则 =====
        "rules": [
            # 私有地址直连
            "GEOIP,private,DIRECT,no-resolve",
            # 国内流量直连
            "GEOSITE,cn,DIRECT",
            "GEOIP,CN,DIRECT,no-resolve",
            # 常见海外服务走代理
            "GEOSITE,google,Proxy",
            "GEOSITE,github,Proxy",
            "GEOSITE,twitter,Proxy",
            "GEOSITE,telegram,Proxy",
            "GEOSITE,youtube,Proxy",
            # 默认走代理
            "MATCH,Proxy",
        ],
    }

    return config


def write_config(config: dict, output_file: str):
    """将配置写入 YAML 文件"""

    # 自定义 Dumper: 确保中文不被转义, 保持键顺序
    class ConfigDumper(yaml.SafeDumper):
        pass

    # 禁止 YAML 自动排序
    def _dict_representer(dumper, data):
        return dumper.represent_mapping(
            yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, data.items()
        )

    ConfigDumper.add_representer(dict, _dict_representer)

    with open(output_file, "w", encoding="utf-8") as f:
        f.write("# Mihomo 配置文件 (由 auto-mihomo 自动生成, 请勿手动修改)\n")
        f.write(f"# 生成时间: {__import__('datetime').datetime.now().isoformat()}\n\n")
        yaml.dump(
            config,
            f,
            Dumper=ConfigDumper,
            default_flow_style=False,
            allow_unicode=True,
            sort_keys=False,
            width=120,
        )

    print(f"配置已写入: {output_file}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="生成 Mihomo 配置文件")
    parser.add_argument("--subscription", required=True, help="订阅文件路径")
    parser.add_argument("--output", required=True, help="输出配置文件路径")
    parser.add_argument("--best-node", required=True, help="最快节点名称")
    parser.add_argument("--mixed-port", type=int, default=7893, help="混合代理端口")
    parser.add_argument("--api-port", type=int, default=9090, help="API 端口")
    args = parser.parse_args()

    proxies = load_proxies(args.subscription)

    # 验证 best-node 存在于代理列表中
    proxy_names = {p["name"] for p in proxies}
    if args.best_node not in proxy_names:
        print(
            f"警告: 指定的最快节点 '{args.best_node}' 不在代理列表中, "
            f"将使用第一个节点作为默认",
            file=sys.stderr,
        )
        args.best_node = proxies[0]["name"]

    config = build_config(proxies, args.best_node, args.mixed_port, args.api_port)
    write_config(config, args.output)


if __name__ == "__main__":
    main()
