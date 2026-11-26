#!/bin/bash
exec /usr/bin/env python3 - "$(dirname -- "${BASH_SOURCE[0]}")/toolbox.local.plist" "$@" 3<&0 <<'PY'
import argparse
import os
import plistlib
import sys
from pathlib import Path
import stat
import subprocess
import tempfile
import time

def configured_projects(path, mode):
    if not path.is_file():
        return {}
    with path.open("rb") as config:
        values = plistlib.load(config)
    projects = {}
    for name in ("Android", "Harmony", "Extra"):
        location = values.get(f"{name}Project", "")
        roots = values.get(f"{name}{mode}Directories", [])
        if not location or not roots:
            continue
        project = Path(location).expanduser()
        if not project.is_absolute() or ".." in project.parts or project == Path(project.anchor):
            raise ValueError(f"{name}Project 必须指向具体项目的绝对路径。")
        if not isinstance(roots, list) or any(
            not isinstance(root, str) or not Path(root).parts or Path(root).is_absolute()
            or any(part in (".", "..", ".git") for part in root.split("/"))
            for root in roots
        ):
            raise ValueError(f"{name}{mode}Directories 必须是项目内的相对目录列表。")
        projects[name] = (project, tuple(dict.fromkeys(roots)))
    return projects


AGE_SECONDS = 21 * 86400


def ignored_files(project, roots):
    """取得 Git 忽略且未跟踪的文件，目录内如有其他文件则整组保留。"""
    root = subprocess.check_output(
        ["git", "-C", str(project), "rev-parse", "--show-toplevel"], text=True
    ).rstrip("\n")
    if Path(root).resolve() != project.resolve():
        raise ValueError(f"项目路径必须是 Git 工作树根目录：{project}")
    names = subprocess.check_output([
        "git", "-C", str(project), "ls-files", "-z", "--others",
        "--ignored", "--exclude-standard", "--", *roots,
    ])
    return {os.fsdecode(name) for name in names.split(b"\0") if name}


def tree_state(project, relative, ignored):
    """记录整组目录的身份和时间，确认后复核，避免拆散构建输出。"""
    root = project / relative
    if any(path.is_symlink() for path in (root, *root.parents)) or not root.is_dir():
        return None
    entries = {}
    pending = [root]
    try:
        while pending:
            path = pending.pop()
            info = path.lstat()
            if stat.S_ISDIR(info.st_mode):
                pending.extend(path.iterdir())
            elif not stat.S_ISREG(info.st_mode) or str(path.relative_to(project)) not in ignored:
                return None
            entries[path] = (info.st_dev, info.st_ino, info.st_mode, info.st_size,
                             info.st_mtime_ns, info.st_ctime_ns)
    except (FileNotFoundError, NotADirectoryError):
        return None
    return entries


def project_candidates(project, roots, cutoff):
    existing = [root for root in roots if (project / root).is_dir()]
    if not existing:
        return {}
    ignored = ignored_files(project, existing)
    candidates = {}
    for relative in existing:
        state = tree_state(project, relative, ignored)
        if state and all(item[4] < cutoff for item in state.values()):
            candidates[relative] = state
    return candidates


def preview_history(projects):
    for name, (project, roots) in projects.items():
        print(f"{name}  ·  {project}", flush=True)
        if not project.is_dir():
            print("  项目目录不存在。")
            continue
        found = False
        for relative in roots:
            root = project / relative
            if any(path.is_symlink() for path in (root, *root.parents)) or not root.is_dir():
                continue
            for item in sorted(root.iterdir()):
                if item.name.startswith(".") or item.is_symlink() or not (item.is_dir() or item.is_file()):
                    continue
                usage = subprocess.check_output(["/usr/bin/du", "-sk", str(item)])
                kib = int(usage.split(maxsplit=1)[0])
                if kib == 0:
                    continue
                size = f"{kib / 1024:.1f} MiB" if kib >= 1024 else f"{kib} KiB"
                print(f"  {size:>12}  {item.relative_to(project)}")
                found = True
        if not found:
            print("  未发现占用磁盘空间的历史产物。")
    print("清单包含当前输出。核对对应版本的安装包、符号表及验收记录后再处理。")


def main():
    parser = argparse.ArgumentParser(description="清理已配置项目中超过 21 天的可重建构建目录。")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--preview", action="store_true", help="只预览，无交互")
    mode.add_argument("--confirm-stdin", action="store_true", help=argparse.SUPPRESS)
    mode.add_argument("--history", action="store_true", help="查看安装包、符号表和发布回归批次")
    args = parser.parse_args(sys.argv[2:])
    projects = configured_projects(Path(sys.argv[1]), "History" if args.history else "Cleanup")
    if not projects:
        print("请在 toolbox.local.plist 中配置项目路径和对应的目录列表。")
        return
    if args.history:
        preview_history(projects)
        return
    cutoff = time.time_ns() - AGE_SECONDS * 10**9
    plan = {}
    total_bytes = 0
    for name, (project, roots) in projects.items():
        if not project.is_dir():
            print(f"找不到项目，跳过 {name}。")
            continue
        try:
            candidates = project_candidates(project, roots, cutoff)
        except (OSError, subprocess.CalledProcessError) as error:
            print(f"无法扫描 {name}：{error}")
            continue
        print(f"{name}：{len(candidates)} 组")
        for relative, state in candidates.items():
            size = sum(item[3] for item in state.values() if stat.S_ISREG(item[2]))
            print(f"  {relative}  {size / 1048576:.1f} MiB")
            total_bytes += size
            plan[(name, relative)] = state
    if not plan:
        print("没有符合条件的目录。")
        return
    print(f"共 {len(plan)} 组，文件大小约 {total_bytes / 1048576:.1f} MiB。")
    if args.preview:
        return
    print("请先结束相关项目正在运行的构建和 IDE 同步。移动后下次构建可能变慢。")
    try:
        terminal = os.fdopen(3, encoding="utf-8") if args.confirm_stdin else open("/dev/tty", encoding="utf-8")
    except OSError:
        print("没有交互终端，本次仅预览。")
        return
    with terminal:
        print("输入 CLEAN 移到废纸篓，直接回车取消：", end="\n" if args.confirm_stdin else "", flush=True)
        if terminal.readline().strip() != "CLEAN":
            print("已取消。")
            return

    trash = Path.home() / ".Trash"
    if trash.is_symlink() or not trash.is_dir():
        raise OSError(f"无法使用废纸篓：{trash}")
    batch = None
    moved = 0
    for name, (project, _) in projects.items():
        roots = [relative for candidate, relative in plan if candidate == name]
        if not roots:
            continue
        ignored = ignored_files(project, roots)
        for relative in roots:
            source = project / relative
            if tree_state(project, relative, ignored) != plan[(name, relative)]:
                print(f"扫描后有变化，跳过 {name}/{relative}")
                continue
            if batch is None:
                batch = Path(tempfile.mkdtemp(prefix="项目构建产物-", dir=trash))
                print(f"废纸篓批次：{batch.name}。", flush=True)
            destination = batch / name / relative
            try:
                destination.parent.mkdir(parents=True, exist_ok=True)
                # 同卷重命名整组目录，失败时保留原目录。
                source.rename(destination)
                moved += 1
            except OSError as error:
                print(f"移动失败：{source}（{error}）")
    print(f"已移动 {moved}/{len(plan)} 组。清空对应的废纸篓批次后才会释放空间。")


try:
    main()
except (OSError, ValueError, subprocess.CalledProcessError) as error:
    raise SystemExit(f"清理停止：{error}")
PY
