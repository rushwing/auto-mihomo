#!/usr/bin/env python3
"""
test_nodes.py - 并发 TCP 连接测试所有代理节点延迟

从 subscription.yaml 中提取所有代理节点的 server:port,
使用线程池并发进行 TCP 连接测试, 测量延迟并返回最快节点名称。

用法:
    python3 test_nodes.py --subscription subscription.yaml
    python3 test_nodes.py --subscription subscription.yaml --workers 100 --timeout 5
"""
import argparse
import re
import socket
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import yaml


def test_tcp_latency(proxy: dict, timeout: int) -> tuple[str, str, int, int]:
    """
    TCP 连接测试单个代理节点延迟

    Args:
        proxy: 代理节点字典, 包含 name/server/port
        timeout: 连接超时时间 (秒)

    Returns:
        (节点名称, server:port, 延迟ms, 是否成功 0/1)
    """
    name = proxy.get("name", "unknown")
    server = proxy.get("server", "")
    port = int(proxy.get("port", 0))

    if not server or not port:
        return (name, f"{server}:{port}", 9999, 0)

    try:
        start = time.monotonic()
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect((server, port))
        latency_ms = int((time.monotonic() - start) * 1000)
        sock.close()
        return (name, f"{server}:{port}", latency_ms, 1)
    except (socket.timeout, ConnectionRefusedError, OSError):
        return (name, f"{server}:{port}", 9999, 0)


def main():
    parser = argparse.ArgumentParser(description="并发测试代理节点延迟")
    parser.add_argument(
        "--subscription", required=True, help="订阅文件路径 (YAML)"
    )
    parser.add_argument(
        "--workers", type=int, default=50, help="并发线程数 (默认: 50)"
    )
    parser.add_argument(
        "--timeout", type=int, default=3, help="TCP 连接超时秒数 (默认: 3)"
    )
    parser.add_argument(
        "--top-n", type=int, default=1, help="输出延迟最低的前 N 个节点名称 (默认: 1)"
    )
    parser.add_argument(
        "--exclude-file", default=None,
        help="排除列表文件路径；匹配的节点跳过 TCP 测试 (默认: 不排除)"
    )
    args = parser.parse_args()

    # 读取排除列表
    exclude_patterns: list[re.Pattern] = []
    if args.exclude_file:
        try:
            with open(args.exclude_file, "r", encoding="utf-8") as ef:
                for line in ef:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    exclude_patterns.append(re.compile(re.escape(line), re.IGNORECASE))
        except FileNotFoundError:
            pass

    def is_excluded(name: str) -> bool:
        return any(p.search(name) for p in exclude_patterns)

    # 读取订阅文件
    with open(args.subscription, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)

    proxies = data.get("proxies", [])
    if exclude_patterns:
        before = len(proxies)
        proxies = [p for p in proxies if not is_excluded(p.get("name", ""))]
        skipped = before - len(proxies)
        if skipped:
            print(f"排除列表过滤: 跳过 {skipped} 个节点", file=sys.stderr)
    if not proxies:
        print("错误: 订阅文件中没有找到代理节点", file=sys.stderr)
        sys.exit(1)

    total = len(proxies)
    print(f"共 {total} 个节点, 开始并发延迟测试...", file=sys.stderr)

    # 并发测试
    results = []
    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        futures = {
            executor.submit(test_tcp_latency, proxy, args.timeout): proxy
            for proxy in proxies
        }
        for future in as_completed(futures):
            results.append(future.result())

    # 按延迟排序
    results.sort(key=lambda x: x[2])

    # 统计
    reachable = sum(1 for r in results if r[3] == 1)
    print(f"可达节点: {reachable}/{total}", file=sys.stderr)

    # 打印 Top 10
    print("\n延迟排名 (Top 10):", file=sys.stderr)
    print(f"{'排名':<4} {'节点名称':<40} {'地址':<30} {'延迟':<8}", file=sys.stderr)
    print("-" * 82, file=sys.stderr)
    for i, (name, addr, latency, ok) in enumerate(results[:10], 1):
        status = f"{latency}ms" if ok else "超时"
        print(f"{i:<4} {name:<40} {addr:<30} {status:<8}", file=sys.stderr)

    # 返回最快的 top-n 个节点
    top = [r for r in results if r[3] == 1][: args.top_n]
    if not top:
        print("\n错误: 所有节点均不可达", file=sys.stderr)
        sys.exit(1)

    best_name, _, best_latency, _ = top[0]
    print(f"\n最快节点: {best_name} ({best_latency}ms)", file=sys.stderr)

    # 仅向 stdout 输出节点名称 (每行一个), 供 bash 脚本捕获
    for name, _, _, _ in top:
        print(name)


if __name__ == "__main__":
    main()
