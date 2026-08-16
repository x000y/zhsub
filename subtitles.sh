#!/bin/bash
# 一键启动悬浮双语字幕 (v4: 带设置面板)
pkill -f "zh-sub-engine/floater" 2>/dev/null
pkill -f "\./floater" 2>/dev/null
pkill -f "zhsub.py --live" 2>/dev/null
sleep 1
echo "▶ 启动悬浮双语字幕…"
nohup ~/zh-sub-engine/floater > /dev/null 2>&1 &
sleep 3
echo "✅ 已启动。"
echo "   字幕窗口: 拖动=移动 | 滚轮=缩放字号 | Option+滚轮=缓冲延迟"
echo "   字幕窗口左上角 ⚙ = 设置面板(模型管理/下载/渠道/代理)"
echo "   引擎崩溃会自动重启。停止: pkill -f './floater'"
