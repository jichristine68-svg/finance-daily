"""
财经日报构建脚本
读取所有 YYYY-MM-DD.md 文件，生成 data.js 供 index.html 使用。
用法: python build.py
"""
import json
import os
import re
import sys
from pathlib import Path

# Windows 控制台默认 GBK，打印 emoji 会报 UnicodeEncodeError，统一转 UTF-8 输出
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

BASE = Path(__file__).parent
reports = {}

for md_file in sorted(BASE.glob("*.md")):
    name = md_file.stem
    # 只处理日期格式的 MD 文件
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", name):
        continue

    content = md_file.read_text(encoding="utf-8")

    # 提取标题（第一个 # 开头的那行）
    title = "全球财经日报"
    title_match = re.search(r"^#\s+(.+)$", content, re.MULTILINE)
    if title_match:
        title = title_match.group(1).strip()

    # 提取关键词
    keywords = []
    kw_section = re.search(
        r"##?\s*🔑\s*关键词索引\s*\n+(.*?)(?:\n##|\n---|\Z)", content, re.DOTALL
    )
    if kw_section:
        keywords = re.findall(r"`([^`]+)`", kw_section.group(1))

    # 提取摘要（"今日摘要"小节下前几段）
    summary = ""
    sum_section = re.search(
        r"##?\s*🎯\s*今日摘要.*?\n+(.*?)(?:\n##|\Z)", content, re.DOTALL
    )
    if sum_section:
        lines = [l.strip() for l in sum_section.group(1).strip().split("\n") if l.strip()]
        summary = " ".join(lines)[:200]

    reports[name] = {
        "title": title,
        "summary": summary,
        "raw": content,
        "keywords": keywords,
    }

# 按日期倒序排列
ordered = {k: reports[k] for k in sorted(reports.keys(), reverse=True)}

js = "window.NEWS_DATA = " + json.dumps(
    {"reports": ordered}, ensure_ascii=False, indent=2
) + ";\n"

(BASE / "data.js").write_text(js, encoding="utf-8")
print(f"✅ data.js 已生成 · {len(reports)} 篇日报")

for d in sorted(reports.keys(), reverse=True):
    kw = reports[d]["keywords"]
    print(f"  📄 {d}  [{len(kw)} 个关键词]")
