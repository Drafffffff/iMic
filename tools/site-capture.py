#!/usr/bin/env python3
"""Compatibility entrypoint for the retired 30fps preview montage generator.

The website now uses the product-recorded 60fps pipeline. Refuse to recreate
removed assets or overwrite its recordings with preview montages.
"""
raise SystemExit(
    "旧版预览拼接工具已停用。录制请使用 scripts/site-demo.sh；"
    "已有真机素材只需重新合成：python3 tools/site-demo-compose.py "
    "<raw-dir> <work-dir> site hero hero-mobile。"
)
