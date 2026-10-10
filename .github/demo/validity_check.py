"""测试有效性的判定（record.sh 的 validity，docs/testing.md 第 5.1 节）。

  validity_check.py caught <结果.json> <场景编号,...> <应当报出的问题（正则，可空）>
      这一次运行报出了应当报出的问题时退出码为 0，否则为 1。
  validity_check.py summary <输出目录> <GitHub 摘要文件>
      汇总 validity-rows.tsv 里的每一行，打印结论并写进摘要；有一行不是“有效”就退出码为 1。

修复之前的版本上每条缺陷最多跑 3 次，报出一次就算测得出。第几次报出写进结论；到第 2、3 次才报出，说明这条测试不稳定。
3 次都没报出时，有一次正常跑完就记为修复前没有失败，否则记为无法判定。
"""
import glob
import json
import os
import re
import sys


def load(path):
    try:
        with open(path) as f:
            return {s["id"]: s for s in json.load(f)["scenarios"]}
    except (OSError, ValueError, KeyError):
        return None


def expected(pattern, scenario, violation):
    if pattern:
        return re.search(pattern, violation) is not None
    return violation.startswith(scenario + ":") and not violation[len(scenario) + 1:].lstrip().startswith("setup:")


def judge(result, wanted, pattern):
    """返回 (是否报出, 说明)。报出时说明列出报出的问题；没报出时列出其他问题；
    无法判定时（没有结果、有场景没跑到、有准备失败）是否报出为 None，说明写原因。"""
    if result is None:
        return None, "没有结果（编译失败或没有运行完）"
    hits = [f"{i} {v}" for i in wanted for v in result.get(i, {}).get("violations", []) if expected(pattern, i, v)]
    if hits:
        return True, "；".join(hits)
    missing = [i for i in wanted if i not in result]
    if missing:
        return None, "没跑到：" + "、".join(missing)
    others = [f"{i} {v}" for i in wanted for v in result.get(i, {}).get("violations", []) if not expected(pattern, i, v)]
    if any("setup:" in o for o in others):
        return None, "有准备失败：" + "；".join(others)
    return False, "没有报出应当报出的问题" + ("（其他问题：" + "；".join(others) + "）" if others else "")


def caught(path, ids, pattern):
    found, _ = judge(load(path), [i for i in ids.split(",") if i], pattern)
    return 0 if found else 1


def summary(out, summary_path):
    after = load(os.path.join(out, "validity-after.json")) or {}
    rows = ["| 缺陷 | 修复提交 | 场景 | 修复之前 | 当前代码 | 结论 |", "|---|---|---|---|---|---|"]
    bad = 0
    for line in open(os.path.join(out, "validity-rows.tsv")):
        name, fix, ids, pattern = (line.rstrip("\n").split("\t") + [""])[:4]
        wanted = [i for i in ids.split(",") if i]
        # 次数取自文件名：某一次没留下结果文件时，后面的次数不会算错。
        tries = sorted((int(re.search(r"-before-(\d+)\.json$", path).group(1)), path)
                       for path in glob.glob(os.path.join(out, f"validity-{name}-before-*.json")))
        found, before_text = None, "没有结果（编译失败或没有运行完）"
        results = [(number,) + judge(load(path), wanted, pattern) for number, path in tries]
        hit = next((r for r in results if r[1]), None)
        if hit:
            found, before_text = True, f"第 {hit[0]} 次报出：" + hit[2]
        elif any(r[1] is False for r in results):
            clean = [r for r in results if r[1] is False][-1]
            found, before_text = False, f"跑了 {tries[-1][0]} 次都" + clean[2]
        elif results:
            found, before_text = None, results[-1][2]
        after_ok = all(i in after and after[i].get("passed") for i in wanted)
        after_text = "通过" if after_ok else "；".join(
            f"{i}: " + ("没有结果" if i not in after else "；".join(after[i]["violations"]))
            for i in wanted if not after.get(i, {}).get("passed"))
        if found and after_ok:
            verdict = "有效"
        elif found is None:
            verdict = "无法判定"
        elif not found:
            verdict = "修复前没有失败"
        else:
            verdict = "当前代码仍失败"
        if verdict != "有效":
            bad += 1
        print(("PASS " if verdict == "有效" else "FAIL ") + f"validity {name} ({fix}, {ids}): {verdict}")
        print("     before: " + before_text)
        print("     after:  " + after_text)
        rows.append(f"| {name} | {fix} | {ids} | {before_text} | {after_text} | {verdict} |")
    with open(summary_path, "a") as f:
        f.write("\n".join(rows) + "\n")
    return 1 if bad else 0


if __name__ == "__main__":
    if sys.argv[1] == "caught":
        sys.exit(caught(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else ""))
    sys.exit(summary(sys.argv[2], sys.argv[3]))
