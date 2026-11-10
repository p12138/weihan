#!/usr/bin/env python3
"""把 CI 原生构建日志的关键行合并成一条 ::error:: 批注。

GitHub 匿名访问看不到 job logs（需仓库 admin），但 ::error:: 批注可以通过
 /check-runs/{id}/annotations 匿名读取。用 %0A 在单条批注里嵌入换行，
 既避开单步批注数量限制，又能在 Actions 页面直接看到真实 Gradle / Xcode 报错。

用法:
  python3 scripts/emit_build_error.py <日志文件> <步骤说明> [第几次尝试]
"""

import re
import sys

PATTERN = re.compile(
    r'(?i)(error|failure|exception|what went wrong|cannot|could not|failed|'
    r'not found|conflict|requires|unresolved|undefined|no such|undefined symbol)'
)
MAX_LINES = 100


def escape(text):
    """按 workflow command 规则转义，换行用 %0A 表示。"""
    return (text.replace('%', '%25')
                .replace('\r', '%0D')
                .replace('\n', '%0A'))


def main():
    if len(sys.argv) < 3:
        print('用法: emit_build_error.py <日志文件> <说明> [第几次]',
              file=sys.stderr)
        return 2
    path, label = sys.argv[1], sys.argv[2]
    attempt = sys.argv[3] if len(sys.argv) > 3 else ''
    with open(path, encoding='utf-8', errors='replace') as handle:
        lines = handle.read().splitlines()

    keys = [line for line in lines if PATTERN.search(line)]
    # 关键错误行 + 日志末尾，去重后保序，避免把所有 Gradle 进度噪声塞进批注
    seen, picked = set(), []
    for line in keys[-35:] + lines[-60:]:
        if line not in seen:
            seen.add(line)
            picked.append(line)

    body = '%0A'.join(escape(line) for line in picked[-MAX_LINES:])
    prefix = ('%s 第 %s 次失败' % (label, attempt) if attempt
              else '%s 失败' % label)
    print('::error::%s，真实日志：%s' % (prefix, body))
    return 0


if __name__ == '__main__':
    sys.exit(main())
