#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Main CLI entrypoint for Clash & Sing-box Subscription Manager.
"""

import sys
import json
import argparse
from typing import Optional

from config import ConfigManager
from server import start_server
from clash_parser import ClashParser
from qr_generator import generate_qr_ascii


def cmd_start(args):
    """Start the background daemon / HTTP server."""
    cm = ConfigManager(args.config)
    port = args.port if args.port is not None else cm.get("server", "port", 8000)
    host = args.host if args.host is not None else cm.get("server", "host", "0.0.0.0")
    start_server(host=host, port=port, config_file=args.config)


def cmd_status(args):
    """Display status, configuration, subscription URL, and QR code."""
    cm = ConfigManager(args.config)
    node_ip = cm.get_node_ip()
    port = cm.get("server", "port", 8000)
    uuid_str = cm.get_uuid()
    sub_url = cm.get_full_subscription_url()
    sb_path = cm.get("singbox", "config_path", "/etc/sing-box/config.json")
    proxy = cm.get("subscription", "upstream_proxy", "socks5h://127.0.0.1:2080")
    nodes = ClashParser.extract_singbox_inbounds(sb_path, node_ip)

    print("=" * 66)
    print(" 📊 Clash & Sing-box Subscription Manager - Status")
    print("=" * 66)
    print(f" • Web 管理面板:    http://{node_ip}:{port}/")
    print(f" • Clash 订阅地址:  {sub_url}")
    print(f" • 订阅 UUID:       {uuid_str}")
    print(f" • 节点公网 IP:     {node_ip}")
    print(f" • 上游拉取代理:    {proxy}")
    print(f" • Sing-box 路径:   {sb_path}")
    print(f" • 探测到节点数:    {len(nodes)} 个")
    for n in nodes:
        print(f"     - [{n.get('type')}] {n.get('name')} -> {n.get('server')}:{n.get('port')}")
    print(f" • 上游 Clash 订阅: {cm.get('subscription', 'clash_sub_url') or '(使用内置通用模板)'}")
    print("=" * 66)
    print("📱 订阅二维码 (终端扫描):")
    print(generate_qr_ascii(sub_url))
    print("=" * 66)


def cmd_gen_uuid(args):
    """Regenerate random UUID."""
    cm = ConfigManager(args.config)
    new_uuid = cm.regenerate_uuid()
    sub_url = cm.get_full_subscription_url()
    print(f"✅ 已生成新的随机 UUID: {new_uuid}")
    print(f"🔗 新订阅地址: {sub_url}")


def cmd_test(args):
    """Execute test run and print transformed YAML and statistics."""
    cm = ConfigManager(args.config)
    sub_url = cm.get("subscription", "clash_sub_url", "")
    proxy = cm.get("subscription", "upstream_proxy", "socks5h://127.0.0.1:2080")
    sb_path = cm.get("singbox", "config_path", "/etc/sing-box/config.json")
    node_ip = cm.get_node_ip()
    target_pattern = cm.get("filter", "target_group_pattern", "节点选择")
    exclude_patterns = cm.get("filter", "exclude_group_patterns", ["自动选择", "节点"])
    custom_name = cm.get("singbox", "custom_node_name", "")

    print(f"🔍 正在从 {sb_path} 提取代理节点 (IP: {node_ip})...")
    nodes = ClashParser.extract_singbox_inbounds(sb_path, node_ip, custom_name=custom_name)
    print(f"✅ 提取到 {len(nodes)} 个节点: {json.dumps(nodes, ensure_ascii=False)}")

    print(f"\n🔄 正在转换配置 (优先代理: '{proxy}', 目标组: '{target_pattern}', 清理组: {exclude_patterns})...")
    yaml_out, summary = ClashParser.generate_full_subscription(
        sub_url=sub_url,
        singbox_path=sb_path,
        node_ip=node_ip,
        proxy=proxy,
        target_group_pattern=target_pattern,
        exclude_patterns=exclude_patterns,
        custom_node_name=custom_name
    )

    print("\n--- 转换统计摘要 ---")
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    print("\n--- 转换后 YAML 前 60 行预览 ---")
    lines = yaml_out.splitlines()
    print("\n".join(lines[:60]))
    if len(lines) > 60:
        print(f"... (共 {len(lines)} 行)")


def cmd_export(args):
    """Export transformed Clash YAML."""
    cm = ConfigManager(args.config)
    sub_url = cm.get("subscription", "clash_sub_url", "")
    proxy = cm.get("subscription", "upstream_proxy", "socks5h://127.0.0.1:2080")
    sb_path = cm.get("singbox", "config_path", "/etc/sing-box/config.json")
    node_ip = cm.get_node_ip()
    target_pattern = cm.get("filter", "target_group_pattern", "节点选择")
    exclude_patterns = cm.get("filter", "exclude_group_patterns", ["自动选择", "节点"])
    custom_name = cm.get("singbox", "custom_node_name", "")

    yaml_out, _ = ClashParser.generate_full_subscription(
        sub_url=sub_url,
        singbox_path=sb_path,
        node_ip=node_ip,
        proxy=proxy,
        target_group_pattern=target_pattern,
        exclude_patterns=exclude_patterns,
        custom_node_name=custom_name
    )

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(yaml_out)
        print(f"✅ YAML 配置已成功导出至: {args.output}")
    else:
        sys.stdout.write(yaml_out)


def main():
    parser = argparse.ArgumentParser(
        description="Clash & Sing-box 订阅同步与管理服务",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("-c", "--config", help="指定配置文件路径 (默认自动选择)")

    subparsers = parser.add_subparsers(dest="command", help="子命令")

    p_start = subparsers.add_parser("start", help="启动订阅同步 Web 服务与守护进程")
    p_start.add_argument("-p", "--port", type=int, help="指定监听端口 (默认 8000)")
    p_start.add_argument("-H", "--host", default="0.0.0.0", help="指定监听地址 (默认 0.0.0.0)")

    subparsers.add_parser("status", help="查看当前运行状态、订阅链接与二维码")
    subparsers.add_parser("gen-uuid", help="重新生成随机 UUID")
    subparsers.add_parser("test", help="测试 Sing-box 节点提取与 Clash 转换")

    p_export = subparsers.add_parser("export", help="导出生成的 Clash YAML 配置文件")
    p_export.add_argument("-o", "--output", help="输出文件路径 (留空输出到标准输出)")

    args = parser.parse_args()

    if not args.command or args.command == "start":
        if not hasattr(args, "port"):
            args.port = None
        if not hasattr(args, "host"):
            args.host = None
        cmd_start(args)
    elif args.command == "status":
        cmd_status(args)
    elif args.command == "gen-uuid":
        cmd_gen_uuid(args)
    elif args.command == "test":
        cmd_test(args)
    elif args.command == "export":
        cmd_export(args)


if __name__ == "__main__":
    main()
