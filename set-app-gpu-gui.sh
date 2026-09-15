#!/bin/bash

# ============================================
# 脚本名称：set-app-gpu-gui.sh  (v3 通用版)
# 功能：图形化管理每个桌面应用默认使用的显卡
# 特色：自动识别系统上的全部显卡（不限品牌与数量），
#       为每块卡生成 gpu-run-N 包装器，勾选式批量分配
# 依赖：zenity；推荐 switcheroo-control（用于识别显卡，
#       没有时会回退到 /sys/class/drm）
# ============================================

# ============================================
# 全局配置（可修改）
# ============================================

# 程序名与版本（发布用）
PROG_NAME="set-app-gpu-gui"
VERSION="1.0.0"

# 用户级 desktop 目录（脚本只会写这里）
USER_APPS="${HOME}/.local/share/applications"
# 系统级 desktop 目录（只读，绝不修改）
SYSTEM_APPS="/usr/share/applications"
# 显卡包装器存放目录（需要在 PATH 中）
WRAPPER_DIR="${HOME}/.local/bin"
# 包装器命令前缀，最终形如 gpu-run-0 / gpu-run-1
WRAPPER_PREFIX="gpu-run"
# 旧版脚本使用的前缀，用于识别并规范化已有配置
LEGACY_PREFIX="prime-run"
# 临时目录（退出时自动清理）
TEMP_DIR=$(mktemp -d)
# 本次操作的「目标显卡」索引（空 = 尚未选定）
TARGET_FILE="${TEMP_DIR}/target_gpu"
# 显卡信息缓存（避免反复调用 switcherooctl，每次约 180ms）
GPU_CACHE_FILE="${TEMP_DIR}/gpus.tsv"

# ============================================
# 以下代码无需修改
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --------------------------------------------
# 基础检查
# --------------------------------------------

# 本脚本用到 globstar、关联数组等 bash 4.0+ 特性
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "错误: 需要 bash 4.0 或更高版本（当前 ${BASH_VERSION:-未知}）" >&2
    exit 1
fi

check_display() {
    if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ]; then
        echo -e "${RED}错误: 未检测到图形界面${NC}"
        echo "请在图形界面下运行此脚本"
        exit 1
    fi
}

check_dependencies() {
    if ! command -v zenity &> /dev/null; then
        local install_cmd=""
        if command -v dnf &> /dev/null; then
            install_cmd="sudo dnf install zenity"
        elif command -v apt &> /dev/null; then
            install_cmd="sudo apt install zenity"
        elif command -v pacman &> /dev/null; then
            install_cmd="sudo pacman -S zenity"
        fi
        echo -e "${RED}错误: 缺少 zenity${NC}"
        echo "安装方法: $install_cmd"
        exit 1
    fi
}

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# --------------------------------------------
# 显卡识别
# --------------------------------------------

# 列出系统上的全部显卡
# 每行输出: 索引<TAB>名称<TAB>是否默认<TAB>是否独显<TAB>环境变量
detect_gpus() {
    # 结果缓存到临时文件：collect_apps 会被调用多次，
    # 每次都去问一遍 switcheroo（约 180ms）太浪费
    if [ -s "$GPU_CACHE_FILE" ]; then
        cat "$GPU_CACHE_FILE"
        return 0
    fi

    local out
    if command -v switcherooctl &> /dev/null && switcherooctl list &> /dev/null; then
        out=$(detect_gpus_switcheroo)
    else
        out=$(detect_gpus_sysfs)
    fi

    printf '%s\n' "$out" > "$GPU_CACHE_FILE" 2>/dev/null
    printf '%s\n' "$out"
}

# 首选方案：switcheroo-control（跨品牌，自动给出每块卡的环境变量）
detect_gpus_switcheroo() {
    switcherooctl list 2>/dev/null | awk '
        function emit() {
            if (idx != "")
                printf "%s\t%s\t%s\t%s\t%s\n", idx, name, def, disc, env
        }
        /^Device:/        { emit(); idx=$2; name=""; def="no"; disc="no"; env="" }
        /^ *Name:/        { sub(/^ *Name: */, "");        name = $0 }
        /^ *Default:/     { sub(/^ *Default: */, "");     def  = $0 }
        /^ *Discrete:/    { sub(/^ *Discrete: */, "");    disc = $0 }
        /^ *Environment:/ { sub(/^ *Environment: */, ""); env  = $0 }
        END { emit() }
    '
}

# 回退方案：直接读 /sys/class/drm（不依赖任何服务）
detect_gpus_sysfs() {
    local idx=0 c vendor device drv pci boot name env def disc pair
    local mesa_json="/usr/share/glvnd/egl_vendor.d/50_mesa.json"
    local nv_json="/usr/share/glvnd/egl_vendor.d/10_nvidia.json"

    for c in /sys/class/drm/card[0-9]; do
        [ -e "$c/device/vendor" ] || continue

        vendor=$(cat "$c/device/vendor" 2>/dev/null)
        device=$(cat "$c/device/device" 2>/dev/null)
        drv=$(basename "$(readlink -f "$c/device/driver" 2>/dev/null)" 2>/dev/null)
        pci=$(basename "$(readlink -f "$c/device" 2>/dev/null)" 2>/dev/null)
        boot=$(cat "$c/device/boot_vga" 2>/dev/null)

        # DRI_PRIME 需要 0000-00-02-0 这种格式
        local prime_path="pci-${pci//:/-}"

        case "$vendor" in
            0x10de)
                name="NVIDIA (${pci})"
                env="__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only"
                [ -f "$nv_json" ] && env="$env __EGL_VENDOR_LIBRARY_FILENAMES=$nv_json"
                disc="yes"
                ;;
            0x1002)
                name="AMD (${pci})"
                env="DRI_PRIME=${prime_path}"
                [ -f "$mesa_json" ] && env="$env __EGL_VENDOR_LIBRARY_FILENAMES=$mesa_json"
                disc="no"
                ;;
            0x8086)
                name="Intel (${pci})"
                env="DRI_PRIME=${prime_path}"
                [ -f "$mesa_json" ] && env="$env __EGL_VENDOR_LIBRARY_FILENAMES=$mesa_json"
                disc="no"
                ;;
            *)
                name="${drv:-未知} ${vendor}:${device} (${pci})"
                env="DRI_PRIME=${prime_path}"
                disc="no"
                ;;
        esac

        if [ "$boot" = "1" ]; then def="yes"; else def="no"; fi

        printf '%s\t%s\t%s\t%s\t%s\n' "$idx" "$name" "$def" "$disc" "$env"
        idx=$((idx + 1))
    done
}

# 显卡数量
gpu_count() {
    detect_gpus | wc -l
}

# 取某块卡的名称
gpu_name() {
    detect_gpus | awk -F'\t' -v i="$1" '$1 == i { print $2; exit }'
}

# 取某块卡的环境变量
gpu_env() {
    detect_gpus | awk -F'\t' -v i="$1" '$1 == i { print $5; exit }'
}

# 取默认卡索引
gpu_default_index() {
    detect_gpus | awk -F'\t' '$3 == "yes" { print $1; exit }'
}

# 取第一块独显索引（没有则回落到默认卡）
gpu_preferred_index() {
    local i
    i=$(detect_gpus | awk -F'\t' '$4 == "yes" { print $1; exit }')
    [ -n "$i" ] && { echo "$i"; return; }
    gpu_default_index
}

# 当前选定的目标显卡索引（未选过则自动取首选）
target_gpu() {
    local t=""
    [ -f "$TARGET_FILE" ] && t=$(cat "$TARGET_FILE" 2>/dev/null)
    if [ -z "$t" ] || ! detect_gpus | awk -F'\t' -v i="$t" '$1 == i { found=1 } END { exit !found }'; then
        t=$(gpu_preferred_index)
        echo "$t" > "$TARGET_FILE" 2>/dev/null
    fi
    echo "$t"
}

# --------------------------------------------
# 包装器管理
# --------------------------------------------

# 为每块显卡生成 ~/.local/bin/gpu-run-N
ensure_wrappers() {
    mkdir -p "$WRAPPER_DIR" 2>/dev/null || return 1

    local idx name def disc env f pair k v
    while IFS=$'\t' read -r idx name def disc env; do
        [ -z "$idx" ] && continue
        f="${WRAPPER_DIR}/${WRAPPER_PREFIX}-${idx}"

        {
            printf '#!/usr/bin/env bash\n'
            printf '# 用「%s」运行指定程序\n' "$name"
            printf '# 由 set-app-gpu-gui.sh 自动生成，请勿手动修改\n\n'
            for pair in $env; do
                case "$pair" in
                    *=*)
                        k="${pair%%=*}"
                        v="${pair#*=}"
                        printf "export %s='%s'\n" "$k" "$v"
                        ;;
                esac
            done
            printf '\nexec "$@"\n'
        } > "$f" 2>/dev/null

        chmod +x "$f" 2>/dev/null
    done < <(detect_gpus)

    return 0
}

# 包装器命令名（若 ~/.local/bin 不在 PATH 中则用绝对路径）
wrapper_cmd() {
    local idx="$1"
    case ":$PATH:" in
        *":${WRAPPER_DIR}:"*) printf '%s-%s\n' "$WRAPPER_PREFIX" "$idx" ;;
        *)                    printf '%s/%s-%s\n' "$WRAPPER_DIR" "$WRAPPER_PREFIX" "$idx" ;;
    esac
}

# --------------------------------------------
# 应用数据
# --------------------------------------------

# 列出所有可配置的桌面应用
# 每行输出: 显示名<TAB>desktop路径<TAB>显卡索引|default
collect_apps() {
    # globstar: 让 ** 递归子目录（GLib 也会扫描子目录，
    # desktop ID 形如 子目录名-文件名）
    shopt -s nullglob globstar
    local files=("$USER_APPS"/**/*.desktop "$SYSTEM_APPS"/**/*.desktop)
    shopt -u nullglob globstar

    [ ${#files[@]} -eq 0 ] && return 0

    # 旧版脚本用的是 prime-run，把它视为「首选独显」，
    # 否则已有的独显配置会被误判成「系统默认」
    local legacy_gpu
    legacy_gpu=$(gpu_preferred_index)

    awk -F= -v prefix="$WRAPPER_PREFIX" -v legacy="$LEGACY_PREFIX" -v legacy_gpu="$legacy_gpu" '
        function flush() {
            if (name != "" && ex != "" && nodisp != "true" && !(base in seen)) {
                seen[base] = 1
                if (name in used) {
                    used[name]++
                    name = name " (" used[name] ")"
                } else {
                    used[name] = 1
                }
                printf "%s\t%s\t%s\n", name, file, (gpu == "" ? "default" : gpu)
            }
        }
        FNR == 1 {
            flush()
            name = ""; ex = ""; nodisp = ""; gpu = ""
            file = FILENAME
            base = FILENAME; sub(/.*\//, "", base)
        }
        /^Name=/      && name == "" { name = substr($0, 6) }
        /^Exec=/      && ex   == "" { ex   = substr($0, 6) }
        /^NoDisplay=/               { nodisp = substr($0, 11) }
        {
            # 识别 Exec 前缀：新格式 gpu-run-N，以及旧格式 prime-run
            if (ex != "" && gpu == "") {
                n = split(ex, parts, " ")
                if (parts[1] ~ ("^" prefix "-[0-9]+$")) {
                    gpu = parts[1]
                    sub("^" prefix "-", "", gpu)
                } else if (parts[1] == legacy && legacy_gpu != "") {
                    gpu = legacy_gpu
                }
            }
        }
        END { flush() }
    ' "${files[@]}" | sort
}

# 统计: 输出 "已分配数量 未分配数量"
count_apps() {
    local a=0 b=0 st
    while IFS=$'\t' read -r _ _ st; do
        [ -z "$st" ] && continue
        if [ "$st" = "default" ]; then b=$((b + 1)); else a=$((a + 1)); fi
    done < <(collect_apps)
    echo "$a $b"
}

# 把某个 desktop 文件绑定到指定显卡
# 用法: apply_gpu <desktop路径> <索引|default>
apply_gpu() {
    local src="$1" gpu="$2"
    local base dst target

    if [[ "$src" == "$USER_APPS"/* ]]; then
        # 已在用户级目录（含子目录）→ 原地修改，避免产生重复条目
        target="$src"
    else
        # 系统级 → 复制到用户级根目录（用户级优先，系统文件保持原样）
        base=$(basename "$src")
        dst="$USER_APPS/$base"
        if [ ! -f "$dst" ]; then
            mkdir -p "$USER_APPS"
            cp "$src" "$dst" 2>/dev/null || return 1
        fi
        target="$dst"
    fi

    # 先剥掉任何已有的前缀：新格式 gpu-run-N、旧格式 prime-run
    # （分两次替换，避免 sed 的 | 同时被当成分隔符和正则交替符）
    sed -i -E "s|^Exec=${WRAPPER_PREFIX}-[0-9]+ |Exec=|" "$target" 2>/dev/null || return 1
    sed -i "s|^Exec=${LEGACY_PREFIX} |Exec=|" "$target" 2>/dev/null || return 1

    # 再按需加上新的
    if [ "$gpu" != "default" ]; then
        local cmd
        cmd=$(wrapper_cmd "$gpu")
        sed -i "s|^Exec=|Exec=${cmd} |" "$target" 2>/dev/null || return 1
    fi

    return 0
}

update_cache() {
    if command -v update-desktop-database &> /dev/null; then
        update-desktop-database "$USER_APPS" &> /dev/null
    fi
    return 0
}

# --------------------------------------------
# 界面功能
# --------------------------------------------

show_help() {
    local gpus
    gpus=$(detect_gpus | awk -F'\t' '{ printf "  %s. %s%s\\n", $1, $2, ($3=="yes" ? "  [默认]" : "") }')

    zenity --info \
        --title="使用说明" \
        --width=640 \
        --height=580 \
        --text="<b>这个脚本做什么</b>\n\n\
管理每个桌面应用<b>默认使用哪块显卡</b>。\n\n\
<b>已识别到的显卡</b>\n\
${gpus}\n\
<b>原理</b>\n\n\
脚本会为每块显卡生成一个包装器命令\n\
<tt>${WRAPPER_DIR}/${WRAPPER_PREFIX}-N</tt>，\n\
里面写好该卡的环境变量。应用的 .desktop 文件里\n\
<tt>Exec=</tt> 行加上该包装器前缀即可，与显卡品牌无关。\n\n\
<b>关于「目标显卡」</b>\n\n\
清单里<b>勾选</b> = 绑定到当前目标显卡，\n\
<b>不勾选</b> = 恢复系统默认显卡。\n\
多块卡时可用主菜单的「选择目标显卡」切换。\n\n\
<b>安全性</b>\n\n\
  • 只写 ${USER_APPS}\n\
  • 系统目录 ${SYSTEM_APPS} 不会被改动\n\
  • 取消勾选即可恢复默认\n\n\
<b>注意</b>\n\n\
改完需要<b>重启对应应用</b>才生效。"
}

# 勾选式批量分配
do_assign() {
    local total
    total=$(gpu_count)

    if [ "$total" -eq 0 ]; then
        zenity --error --width=420 --title="未识别到显卡" \
            --text="没有从 switcheroo-control 或 /sys/class/drm 读取到任何显卡。"
        return
    fi

    if [ "$total" -eq 1 ]; then
        local only
        only=$(detect_gpus | awk -F'\t' '{ print $2; exit }')
        zenity --info --width=480 --title="只有一块显卡" \
            --text="系统里只识别到一块显卡：\n\n<b>${only}</b>\n\n没有可切换的目标，无需分配。"
        return
    fi

    local tgt tgt_name
    tgt=$(target_gpu)
    tgt_name=$(gpu_name "$tgt")

    local rows=() name path status count=0
    while IFS=$'\t' read -r name path status; do
        [ -z "$name" ] && continue
        count=$((count + 1))
        if [ "$status" = "$tgt" ]; then
            rows+=(TRUE "$name" "已绑 ${tgt} 号卡")
        elif [ "$status" = "default" ]; then
            rows+=(FALSE "$name" "系统默认")
        else
            rows+=(FALSE "$name" "绑到 ${status} 号卡")
        fi
    done < <(collect_apps)

    if [ "$count" -eq 0 ]; then
        zenity --error --width=380 --title="没有可用应用" \
            --text="没有找到可配置的桌面应用。"
        return
    fi

    local selected
    selected=$(zenity --list --checklist \
        --title="分配显卡 — 目标：${tgt_name}（共 ${count} 个应用）" \
        --text="<b>勾选</b> = 用「${tgt_name}」启动\n<b>不勾选</b> = 用系统默认显卡\n\n选好后点「应用更改」" \
        --column="使用目标卡" --column="应用" --column="当前状态" \
        --width=820 --height=640 \
        --separator="|" \
        --ok-label="应用更改" \
        --cancel-label="返回" \
        "${rows[@]}" 2>/dev/null)
    [ $? -ne 0 ] && return

    local -A want
    local -a sel_arr=()
    local oldifs="$IFS"
    IFS='|' read -r -a sel_arr <<< "$selected"
    IFS="$oldifs"
    local s
    for s in "${sel_arr[@]}"; do
        [ -n "$s" ] && want["$s"]=1
    done

    # 只处理状态发生变化的
    local -a todo=()
    local want_status
    while IFS=$'\t' read -r name path status; do
        [ -z "$name" ] && continue
        want_status="default"
        [ -n "${want[$name]:-}" ] && want_status="$tgt"
        [ "$status" != "$want_status" ] && todo+=("${path}|${want_status}")
    done < <(collect_apps)

    if [ ${#todo[@]} -eq 0 ]; then
        zenity --info --width=360 --title="没有变化" \
            --text="配置没有发生变化。"
        return
    fi

    # 变更摘要 + 二次确认
    # （防止「一个都不勾就点应用更改」把已有配置静默清空）
    local summary="" item p m nm
    for item in "${todo[@]}"; do
        p="${item%|*}"
        m="${item##*|}"
        nm=$(basename "$p" .desktop)
        if [ "$m" = "default" ]; then
            summary+="   ${nm}  →  系统默认\n"
        else
            summary+="   ${nm}  →  ${m} 号卡\n"
        fi
    done

    local preview="$summary"
    if [ ${#todo[@]} -gt 15 ]; then
        preview=$(printf '%b' "$summary" | head -15)
        preview+="\n   … 其余 $(( ${#todo[@]} - 15 )) 个省略"
    else
        preview=$(printf '%b' "$summary")
    fi

    if ! zenity --question \
        --width=600 --height=520 \
        --title="确认更改" \
        --text="即将修改 <b>${#todo[@]}</b> 个应用：\n\n${preview}\n\n确定继续吗？" \
        --ok-label="确认执行" \
        --cancel-label="取消"; then
        return
    fi

    local ok=0 fail=0
    for item in "${todo[@]}"; do
        p="${item%|*}"
        m="${item##*|}"
        if apply_gpu "$p" "$m"; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done
    update_cache

    local msg="✅ 已更新 <b>${ok}</b> 个应用"
    if [ "$fail" -gt 0 ]; then
        msg+="\n\n⚠️ 有 <b>${fail}</b> 个失败（可能是权限问题）"
    fi
    msg+="\n\n<b>重启对应应用</b>后生效。"

    zenity --info --width=440 --title="完成" --text="$msg"
}

# 查看当前配置
do_view() {
    local name path status
    local lines=""
    local bound=0 free=0
    local tgt tgt_name
    tgt=$(target_gpu)
    tgt_name=$(gpu_name "$tgt")

    # 顶部：显卡编号对照表
    local gpu_list=""
    local idx gname gdef gdisc tag
    while IFS=$'\t' read -r idx gname gdef gdisc _; do
        [ -z "$idx" ] && continue
        tag=""
        [ "$gdef" = "yes" ] && tag="${tag} [默认]"
        [ "$gdisc" = "yes" ] && tag="${tag} [独显]"
        if [ "$idx" = "$tgt" ]; then
            gpu_list+="  ▶ <b>${idx} 号卡</b> — ${gname}${tag}\n"
        else
            gpu_list+="     <b>${idx} 号卡</b> — ${gname}${tag}\n"
        fi
    done < <(detect_gpus)

    while IFS=$'\t' read -r name path status; do
        [ -z "$name" ] && continue
        if [ "$status" = "default" ]; then
            free=$((free + 1))
        else
            bound=$((bound + 1))
            lines+="   ${bound}. ${name}  →  ${status} 号卡\n"
        fi
    done < <(collect_apps)

    local text="<b>显卡列表</b>\n${gpu_list}\n"
    text+="<b>当前分配</b>\n\n"
    text+="本次目标显卡：<b>${tgt} 号卡</b>\n\n"
    if [ "$bound" -eq 0 ]; then
        text+="已绑定显卡的应用：<b>暂无</b>\n"
    else
        text+="已绑定显卡的应用（<b>${bound}</b> 个）：\n${lines}"
    fi
    text+="\n其余 <b>${free}</b> 个应用使用系统默认显卡。"
    text+="\n\n💡 编号来自 switcheroo，与包装器 gpu-run-N 一一对应。"

    zenity --info \
        --title="当前配置" \
        --width=780 --height=620 \
        --text="$text"
}

# 选择目标显卡
do_select_gpu() {
    local rows=() idx name def disc
    while IFS=$'\t' read -r idx name def disc _; do
        [ -z "$idx" ] && continue
        local tag=""
        [ "$def" = "yes" ] && tag="${tag} [默认]"
        [ "$disc" = "yes" ] && tag="${tag} [独显]"
        rows+=("$idx" "${name}${tag}")
    done < <(detect_gpus)

    if [ ${#rows[@]} -eq 0 ]; then
        zenity --error --width=400 --title="未识别到显卡" \
            --text="没有读取到任何显卡。"
        return
    fi

    # 组装 radiolist：当前目标卡预选
    local cur
    cur=$(target_gpu)
    local args=() i
    for ((i = 0; i < ${#rows[@]}; i += 2)); do
        if [ "${rows[i]}" = "$cur" ]; then
            args+=(TRUE "${rows[i + 1]}" "${rows[i]}")
        else
            args+=(FALSE "${rows[i + 1]}" "${rows[i]}")
        fi
    done

    local chosen
    chosen=$(zenity --list --radiolist \
        --title="选择目标显卡" \
        --text="之后在「分配显卡」里勾选的应用，都会绑定到这块卡" \
        --column="选" --column="显卡" --column="索引" \
        --hide-column=3 --print-column=3 \
        --width=680 --height=380 \
        --ok-label="确定" --cancel-label="返回" \
        "${args[@]}" 2>/dev/null)
    [ $? -ne 0 ] && return
    [ -z "$chosen" ] && return

    echo "$chosen" > "$TARGET_FILE"
    zenity --info --width=460 --title="已切换" \
        --text="目标显卡已设为：\n\n<b>$(gpu_name "$chosen")</b>"
}

# 添加自定义命令
do_add_custom() {
    local result name cmd gpu

    # 动态生成显卡下拉选项
    local combo="" idx nm
    while IFS=$'\t' read -r idx nm _ _ _; do
        [ -z "$idx" ] && continue
        [ -n "$combo" ] && combo="${combo}|"
        combo="${combo}${idx} - ${nm}"
    done < <(detect_gpus)
    [ -z "$combo" ] && combo="default - 系统默认"

    result=$(zenity --forms \
        --title="添加自定义命令" \
        --text="为不在清单里的程序创建启动项。\n\n<b>命令示例</b>\n  wine /home/user/games/game.exe\n  /home/user/bin/run.sh\n\n<b>注意</b>\n  • 路径含空格请自己加引号\n  • 百分比符号要写成 %%" \
        --add-entry="名称（显示在清单里）" \
        --add-entry="命令" \
        --add-combo="使用显卡" --combo-values="$combo" \
        --separator="|" \
        --width=660 2>/dev/null)
    [ $? -ne 0 ] && return

    local oldifs="$IFS"
    IFS='|' read -r name cmd gpu <<< "$result"
    IFS="$oldifs"

    if [ -z "$name" ] || [ -z "$cmd" ]; then
        zenity --error --width=420 --title="输入不完整" \
            --text="<b>名称</b>和<b>命令</b>都不能为空。"
        return
    fi

    # 从 "1 - NVIDIA ..." 里取出索引
    local gpu_idx="default"
    case "$gpu" in
        default*) gpu_idx="default" ;;
        *)        gpu_idx="${gpu%% *}" ;;
    esac

    # 生成文件名（纯中文名会退化为带时间戳的名字）
    local slug file
    slug=$(printf '%s' "$name" | tr ' ' '-' | tr -cd '[:alnum:]_-')
    [ -z "$slug" ] && slug="custom-$(date +%s)"
    file="$USER_APPS/${slug}.desktop"
    local i=1
    while [ -f "$file" ]; do
        file="$USER_APPS/${slug}-${i}.desktop"
        i=$((i + 1))
    done

    # 组装 Exec 行
    local exec_line="$cmd"
    if [ "$gpu_idx" != "default" ]; then
        exec_line="$(wrapper_cmd "$gpu_idx") ${cmd}"
    fi

    if ! {
        printf '[Desktop Entry]\n'
        printf 'Type=Application\n'
        printf 'Name=%s\n' "$name"
        printf 'Comment=%s\n' "由 set-app-gpu-gui 创建"
        printf 'Exec=%s\n' "$exec_line"
        printf 'Icon=application-x-executable\n'
        printf 'Terminal=false\n'
        printf 'Categories=Utility;\n'
    } > "$file" 2>/dev/null; then
        zenity --error --width=420 --title="写入失败" \
            --text="无法写入：\n${file}"
        return
    fi

    update_cache

    zenity --info --width=600 --title="已添加" \
        --text="✅ 已创建启动项\n\n<b>${name}</b>\n<tt>${exec_line}</tt>\n\n文件：\n${file}\n\n它现在也会出现在「分配显卡」清单里。"
}

# 删除自定义命令
do_remove_custom() {
    local -a rows=()
    local f name

    while IFS= read -r f; do
        [ -z "$f" ] && continue
        name=$(grep -m1 '^Name=' "$f" 2>/dev/null | cut -d= -f2-)
        rows+=("${name:-$(basename "$f")}" "$f")
    done < <(grep -rl '^Comment=由 set-app-gpu-gui 创建' "$USER_APPS" --include='*.desktop' 2>/dev/null | sort)

    if [ ${#rows[@]} -eq 0 ]; then
        zenity --info --width=440 --title="没有自定义项" \
            --text="还没有通过本脚本创建过自定义命令。"
        return
    fi

    local chosen
    chosen=$(zenity --list \
        --title="删除自定义命令" \
        --text="选择要删除的启动项" \
        --column="名称" --column="文件" \
        --print-column=2 \
        --width=780 --height=460 \
        --ok-label="删除" \
        --cancel-label="返回" \
        "${rows[@]}" 2>/dev/null)
    [ $? -ne 0 ] && return
    [ -z "$chosen" ] && return

    if [[ "$chosen" != "$USER_APPS"/*.desktop ]]; then
        zenity --error --width=440 --title="拒绝操作" \
            --text="路径校验失败，已中止：\n${chosen}"
        return
    fi
    if [ ! -f "$chosen" ]; then
        zenity --error --width=440 --title="文件不存在" \
            --text="${chosen}"
        return
    fi

    if zenity --question --width=480 --title="确认删除" \
        --text="确定删除这个启动项吗？\n\n<b>$(basename "$chosen")</b>\n\n只会删除启动项文件，不会动程序本身。"; then
        rm -f "$chosen"
        update_cache
        zenity --info --width=400 --title="已删除" \
            --text="✅ 已删除 <b>$(basename "$chosen")</b>"
    fi
}

# 主菜单
main_menu() {
    local tgt tgt_name
    tgt=$(target_gpu)
    tgt_name=$(gpu_name "$tgt")

    zenity --list --radiolist \
        --title="应用显卡分配" \
        --text="当前目标显卡：<b>${tgt_name}</b>" \
        --column="选择" --column="操作" --column="说明" \
        --width=760 --height=460 \
        --ok-label="确定" \
        --cancel-label="退出" \
        TRUE  "分配显卡"       "勾选式批量绑定到目标显卡" \
        FALSE "选择目标显卡"   "在多块显卡之间切换目标" \
        FALSE "查看当前配置"   "列出哪些应用已绑定显卡" \
        FALSE "添加自定义命令" "为清单外的程序（exe、脚本）创建启动项" \
        FALSE "删除自定义命令" "移除本脚本创建的自定义启动项" \
        FALSE "使用说明"       "这个脚本做了什么、原理是什么" \
        FALSE "退出"           "关闭窗口" 2>/dev/null
}

# --------------------------------------------
# 命令行模式（不需要图形界面）
# --------------------------------------------

usage_cli() {
    cat <<EOF
${PROG_NAME} v${VERSION} — 按应用分配显卡（图形界面 + 命令行）

用法:
  ${PROG_NAME} [选项]

不带选项时启动图形界面。

选项:
  -h, --help       显示本帮助
  -V, --version    显示版本
  -g, --gpus       列出识别到的显卡
  -l, --list       列出显卡与已绑定显卡的应用
      --check      检查运行环境与依赖

示例:
  ${PROG_NAME}              # 打开图形界面
  ${PROG_NAME} --list       # 查看当前分配
  ${PROG_NAME} --check      # 排查依赖问题

说明:
  显卡编号来自 switcheroo-control，与包装器 ${WRAPPER_PREFIX}-N 一一对应。
  依赖: zenity（图形界面）；switcheroo-control（推荐，用于识别显卡）
EOF
}

cli_gpus() {
    echo "识别到的显卡："
    detect_gpus | awk -F'\t' '{
        printf "  [%s] %s", $1, $2
        if ($3 == "yes") printf "  [默认]"
        if ($4 == "yes") printf "  [独显]"
        printf "\n"
    }'
    echo
    if command -v switcherooctl > /dev/null 2>&1 && switcherooctl list > /dev/null 2>&1; then
        echo "识别方式：switcheroo-control"
    else
        echo "识别方式：/sys/class/drm（回退方案）"
    fi
}

cli_list() {
    cli_gpus
    echo
    echo "已绑定显卡的应用："
    local n=0 name path status
    while IFS=$'\t' read -r name path status; do
        [ -z "$name" ] && continue
        [ "$status" = "default" ] && continue
        n=$((n + 1))
        printf "  %-30s → %s 号卡   (%s)\n" "$name" "$status" "$(basename "$path")"
    done < <(collect_apps)
    [ "$n" -eq 0 ] && echo "  （无）"

    local counts a b
    counts=$(count_apps)
    a="${counts%% *}"
    b="${counts##* }"
    echo
    echo "共 $((a + b)) 个可配置应用：已绑定 ${a} 个，默认 ${b} 个。"
}

cli_check() {
    echo "环境检查"
    echo "  bash 版本 : $BASH_VERSION"
    echo "  脚本版本  : ${PROG_NAME} v${VERSION}"
    echo
    echo "  依赖:"
    local c
    for c in zenity switcherooctl update-desktop-database awk sed grep mktemp; do
        if command -v "$c" > /dev/null 2>&1; then
            printf "    %-24s ✅ %s\n" "$c" "$(command -v "$c")"
        else
            case "$c" in
                zenity)        printf "    %-24s ❌ 必需（图形界面用）\n" "$c" ;;
                switcherooctl) printf "    %-24s ⚠️  缺失，将回退 /sys/class/drm\n" "$c" ;;
                *)             printf "    %-24s ❌ 缺失\n" "$c" ;;
            esac
        fi
    done
    echo
    echo "  目录:"
    if [ -d "$USER_APPS" ]; then
        printf "    用户 desktop   ✅ %s\n" "$USER_APPS"
    else
        printf "    用户 desktop   ❌ 不存在 %s\n" "$USER_APPS"
    fi
    if [ -w "$WRAPPER_DIR" ] || [ -w "$(dirname "$WRAPPER_DIR")" ]; then
        printf "    包装器目录     ✅ %s\n" "$WRAPPER_DIR"
    else
        printf "    包装器目录     ⚠️  不可写 %s\n" "$WRAPPER_DIR"
    fi
    case ":$PATH:" in
        *":${WRAPPER_DIR}:"*) printf "    PATH           ✅ 已包含包装器目录\n" ;;
        *)                    printf "    PATH           ⚠️  不含包装器目录（将用绝对路径）\n" ;;
    esac

    echo
    echo "  包装器:"
    local w found=0
    for w in "$WRAPPER_DIR/${WRAPPER_PREFIX}"-*; do
        [ -x "$w" ] || continue
        found=1
        printf "    %-28s ✅\n" "$(basename "$w")"
    done
    [ "$found" -eq 0 ] && echo "    （尚未生成，首次运行图形界面时会自动创建）"
    echo
    cli_gpus
}

# --------------------------------------------
# 主程序
# --------------------------------------------

main() {
    # 命令行模式：不需要图形界面
    case "${1:-}" in
        -h|--help)    usage_cli;  exit 0 ;;
        -V|--version) echo "${PROG_NAME} ${VERSION}"; exit 0 ;;
        -g|--gpus)    cli_gpus;   exit 0 ;;
        -l|--list)    cli_list;   exit 0 ;;
        --check)      cli_check;  exit 0 ;;
        "")           ;;
        *)            echo "未知参数: $1" >&2; echo; usage_cli >&2; exit 2 ;;
    esac

    check_display
    check_dependencies

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  应用显卡分配管理器 (通用版)${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "用户级目录: ${YELLOW}${USER_APPS}${NC}"
    echo -e "包装器目录: ${YELLOW}${WRAPPER_DIR}${NC}"
    echo

    echo -e "${BLUE}--- 识别到的显卡 ---${NC}"
    local idx name def disc
    while IFS=$'\t' read -r idx name def disc _; do
        [ -z "$idx" ] && continue
        printf "  [%s] %s" "$idx" "$name"
        [ "$def" = "yes" ] && printf " ${GREEN}[默认]${NC}"
        [ "$disc" = "yes" ] && printf " ${YELLOW}[独显]${NC}"
        printf "\n"
    done < <(detect_gpus)

    local n
    n=$(gpu_count)
    echo -e "${BLUE}----------------------------------------${NC}"

    if [ "$n" -eq 0 ]; then
        echo -e "${RED}未识别到任何显卡，无法继续${NC}"
        zenity --error --width=440 --title="未识别到显卡" \
            --text="没有从 switcheroo-control 或 /sys/class/drm 读取到显卡。"
        exit 1
    fi

    # 生成包装器
    if ensure_wrappers; then
        echo -e "${GREEN}✓ 已生成 ${n} 个显卡包装器于 ${WRAPPER_DIR}${NC}"
    else
        echo -e "${RED}✗ 包装器生成失败（${WRAPPER_DIR} 不可写？）${NC}"
        zenity --error --width=460 --title="包装器生成失败" \
            --text="无法写入 ${WRAPPER_DIR}。\n\n请确认目录存在且可写。"
        exit 1
    fi

    # 检查 PATH
    case ":$PATH:" in
        *":${WRAPPER_DIR}:"*) ;;
        *)
            echo -e "${YELLOW}⚠ ${WRAPPER_DIR} 不在 PATH 中，将使用绝对路径${NC}"
            ;;
    esac

    local counts
    counts=$(count_apps)
    local a="${counts%% *}" b="${counts##* }"
    echo -e "可配置应用: ${YELLOW}$((a + b))${NC} 个（已绑定 ${a} / 默认 ${b}）"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    while true; do
        local choice
        choice=$(main_menu)
        [ $? -ne 0 ] && break
        [ -z "$choice" ] && break

        case "$choice" in
            "分配显卡")       do_assign ;;
            "选择目标显卡")   do_select_gpu ;;
            "查看当前配置")   do_view ;;
            "添加自定义命令") do_add_custom ;;
            "删除自定义命令") do_remove_custom ;;
            "使用说明")       show_help ;;
            "退出")           break ;;
        esac
    done
}

main "$@"
