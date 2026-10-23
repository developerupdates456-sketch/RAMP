#!/usr/bin/env python3
"""Host helper: discover Samsung MDC device info for given IPs.

Usage:
  python scripts/host_helper_samsung.py 192.168.0.6 192.168.0.20

This script should be run on the host network (not inside the default bridged container)
so ARP and SSDP discovery work reliably. It prints JSON to stdout.
"""
import sys
import os
import json
import importlib.util
import traceback
import argparse
import requests


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def main(argv):
    parser = argparse.ArgumentParser(description="Host helper: discover Samsung MDC device info for given IPs")
    parser.add_argument('ips', nargs='+', help='IP addresses to discover')
    parser.add_argument('--api-base', default='http://localhost:16010', help='API base URL')
    parser.add_argument('--tenant-id', help='Tenant ID to use when posting discovered devices')
    parser.add_argument('--source-id', help='Manual source ID to use when posting discovered devices')
    parser.add_argument('--post', action='store_true', help='POST discovered device_info to the API (/api/manual-platform/devices)')
    args = parser.parse_args(argv[1:])

    root = os.getcwd()
    base_path = os.path.join(root, 'backend', 'plugins', 'base.py')
    samsung_path = os.path.join(root, 'backend', 'plugins', 'samsung_mdc_plugin.py')

    # Load plugin modules directly to avoid importing the full Flask app
    load_module('backend.plugins.base', base_path)
    mod = load_module('backend.plugins.samsung_mdc_plugin', samsung_path)
    SamsungMDCPlugin = getattr(mod, 'SamsungMDCPlugin')
    plugin = SamsungMDCPlugin()

    results = {}
    for ip in args.ips:
        try:
            info = plugin.get_device_info(ip)
            results[ip] = info

            if args.post:
                if not args.tenant_id or not args.source_id:
                    results[ip] = {"error": "--tenant-id and --source-id required when --post is used"}
                    continue

                payload = {
                    "tenant_id": args.tenant_id,
                    "source_id": args.source_id,
                    "ip_address": ip,
                    "port": info.get('port', 1515),
                    "display_id": info.get('display_id', '00'),
                    # allow device_info overrides
                    "device_name": info.get('device_name'),
                    "make": info.get('make'),
                    "model": info.get('model'),
                    "serial_number": info.get('serial_number'),
                    "firmware": info.get('firmware')
                }

                try:
                    url = args.api_base.rstrip('/') + '/api/manual-platform/devices'
                    r = requests.post(url, json=payload, timeout=10)
                    try:
                        results[ip]['post'] = {"status": r.status_code, "resp": r.json()}
                    except Exception:
                        results[ip]['post'] = {"status": r.status_code, "text": r.text}
                except Exception as e:
                    results[ip]['post'] = {"error": str(e)}

        except Exception as e:
            results[ip] = {"error": str(e), "trace": traceback.format_exc()}

    print(json.dumps(results, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
